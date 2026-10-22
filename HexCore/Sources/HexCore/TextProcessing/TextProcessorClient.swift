import Foundation
import Darwin
import Dependencies

public struct TextProcessorRequest: Codable, Equatable, Sendable {
    public var runID: UUID
    public var input: String
    public var prompt: String
    public var processor: ProcessorConfiguration
    public init(runID: UUID = UUID(), input: String, prompt: String, processor: ProcessorConfiguration) {
        self.runID = runID; self.input = input; self.prompt = prompt; self.processor = processor
    }
}

public struct TextProcessorResult: Equatable, Sendable {
    public var text: String
    public var diagnostics: String
    public var elapsed: TimeInterval
    public init(text: String, diagnostics: String, elapsed: TimeInterval) {
        self.text = text; self.diagnostics = diagnostics; self.elapsed = elapsed
    }
}

public struct TextProcessorFailure: Error, LocalizedError, Equatable, Sendable {
    public var reason: String
    public var diagnostics: String
    public init(_ reason: String, diagnostics: String = "") { self.reason = reason; self.diagnostics = diagnostics }
    public var errorDescription: String? { reason }
}

public struct TextProcessorClient: Sendable {
    public var run: @Sendable (TextProcessorRequest) async throws -> TextProcessorResult
    /// Normal app termination cannot rely on detached tasks running after exit.
    public static func terminateRunsForAppExit() { ProcessorGroups.shared.terminateAll() }
    public init(run: @escaping @Sendable (TextProcessorRequest) async throws -> TextProcessorResult) { self.run = run }
}
extension TextProcessorClient: DependencyKey {
    public static let liveValue = Self { request in
        let cancellation = ProcessorCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached { try ProcessorRun.execute(request, cancellation: cancellation) }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }
    public static let testValue = Self { _ in throw TextProcessorFailure("Processor not configured in test") }
}
public extension DependencyValues {
    var textProcessor: TextProcessorClient {
        get { self[TextProcessorClient.self] }
        set { self[TextProcessorClient.self] = newValue }
    }
}

private final class ProcessorGroups: @unchecked Sendable {
    static let shared = ProcessorGroups()
    private let lock = NSLock()
    private var groups: Set<pid_t> = []
    func insert(_ pid: pid_t) { lock.lock(); groups.insert(pid); lock.unlock() }
    func remove(_ pid: pid_t) { lock.lock(); groups.remove(pid); lock.unlock() }
    func terminateAll() {
        lock.lock(); defer { lock.unlock() }
        for pid in groups { kill(-pid, SIGKILL) }
    }
}

private final class ProcessorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// posix_spawn establishes a new process group atomically, before user code executes.
/// A single nonblocking poll loop writes stdin and drains both outputs without deadlock.
private enum ProcessorRun {
    static func execute(_ request: TextProcessorRequest, cancellation: ProcessorCancellation) throws -> TextProcessorResult {
        try request.processor.validate()
        if cancellation.isCancelled { throw CancellationError() }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("hex-processor-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let prompt = temporary.appendingPathComponent("prompt.md")
        guard fm.createFile(atPath: prompt.path, contents: Data(request.prompt.utf8), attributes: [.posixPermissions: 0o600]) else { throw TextProcessorFailure("Could not create private prompt file") }
        var environment = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path
        environment["HOME"] = home
        // Preserve inherited absolute search directories, then append conventional paths.
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        var seen = Set<String>()
        environment["PATH"] = (inherited + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["HEX_PROMPT_FILE"] = prompt.path
        var pipes: [[Int32]] = []
        defer { for pair in pipes { for fd in pair where fd >= 0 { close(fd) } } }
        for _ in 0..<3 {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw TextProcessorFailure("Could not create processor pipes") }
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            pipes.append(pair)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, pipes[0][0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes[1][1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes[2][1], STDERR_FILENO)
        for pair in pipes { for fd in pair { posix_spawn_file_actions_addclose(&actions, fd) } }
        let directory = request.processor.workingDirectory ?? home
        let cwdError = directory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        guard cwdError == 0 else { throw TextProcessorFailure("Invalid working directory") }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([request.processor.executable] + request.processor.arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { if let p { free(p) } } }
        var pid: pid_t = 0
        let started = Date()
        let spawnError = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, request.processor.executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard spawnError == 0 else { throw TextProcessorFailure("Launch failed: \(String(cString: strerror(spawnError)))") }
        ProcessorGroups.shared.insert(pid)
        var reaped = false
        func closePipe(_ index: Int, _ end: Int) { if pipes[index][end] >= 0 { close(pipes[index][end]); pipes[index][end] = -1 } }
        closePipe(0, 0); closePipe(1, 1); closePipe(2, 1)
        for fd in [pipes[0][1], pipes[1][0], pipes[2][0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        _ = fcntl(pipes[0][1], F_SETNOSIGPIPE, 1)
        let input = Data(request.input.utf8)
        var written = 0, status: Int32 = 0
        var output = Data(), diagnostics = Data()
        var exited = false
        var failure: String?
        var terminationTime: Date?
        var escalated = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Always reap the direct child; kill descendants left holding pipes on any error.
        defer {
            // Keep the leader unreaped until all group signaling is finished. Its
            // reserved PID prevents accidental signaling of a reused process group.
            if !reaped { kill(-pid, SIGKILL) }
            ProcessorGroups.shared.remove(pid)
            if !reaped { while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        while true {
            if failure == nil {
                if cancellation.isCancelled { failure = "Cancelled" }
                else if Date().timeIntervalSince(started) >= request.processor.timeout { failure = "Processor timed out" }
            }
            if failure != nil, terminationTime == nil { kill(-pid, SIGTERM); terminationTime = Date(); closePipe(0, 1) }
            if let terminationTime, Date().timeIntervalSince(terminationTime) >= 0.2, !escalated {
                kill(-pid, SIGKILL); escalated = true
            }
            if !exited {
                var info = siginfo_t()
                let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0 && info.si_pid == pid { exited = true }
            }
            if pipes[0][1] >= 0 {
                if written == input.count { closePipe(0, 1) }
                else {
                    let count = input.withUnsafeBytes { bytes in Darwin.write(pipes[0][1], bytes.baseAddress!.advanced(by: written), min(16_384, input.count - written)) }
                    if count > 0 { written += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { failure = failure ?? "Could not write processor input (broken pipe)"; closePipe(0, 1) }
                }
            }
            for index in 1...2 where pipes[index][0] >= 0 {
                // One chunk per iteration prevents a noisy stream starving cancellation/other pipes.
                let count = Darwin.read(pipes[index][0], &buffer, buffer.count)
                if count > 0 {
                    let limit = index == 1 ? 4 * 1024 * 1024 : 256 * 1024
                    let current = index == 1 ? output.count : diagnostics.count
                    if current + count > limit { failure = failure ?? "Processor exceeded the \(index == 1 ? "stdout (4 MiB)" : "stderr (256 KiB)") limit" }
                    let chunk = buffer.prefix(min(count, max(0, limit - current)))
                    if index == 1 { output.append(contentsOf: chunk) } else { diagnostics.append(contentsOf: chunk) }
                } else if count == 0 { closePipe(index, 0) }
                else if errno != EAGAIN && errno != EINTR { failure = failure ?? "Could not read processor output"; closePipe(index, 0) }
            }
            if let terminationTime, escalated, Date().timeIntervalSince(terminationTime) > 0.5, exited { break }
            if exited && pipes[1][0] < 0 && pipes[2][0] < 0 && (terminationTime == nil || escalated) { break }
            var pollFDs = [pollfd(fd: pipes[0][1], events: Int16(POLLOUT), revents: 0), pollfd(fd: pipes[1][0], events: Int16(POLLIN), revents: 0), pollfd(fd: pipes[2][0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&pollFDs, nfds_t(pollFDs.count), 10)
        }
        ProcessorGroups.shared.remove(pid)
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        reaped = true
        if cancellation.isCancelled { throw CancellationError() }
        let stderr = String(decoding: diagnostics, as: UTF8.self)
        if let failure { throw TextProcessorFailure(failure, diagnostics: stderr) }
        guard status == 0 else {
            let reason = (status & 0x7f) == 0 ? "exit code \(status >> 8)" : "signal \(status & 0x7f)"
            throw TextProcessorFailure("Processor exited unsuccessfully (\(reason))", diagnostics: stderr)
        }
        guard let text = String(data: output, encoding: .utf8) else { throw TextProcessorFailure("Processor stdout is not valid UTF-8", diagnostics: stderr) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextProcessorFailure("Processor returned empty output", diagnostics: stderr) }
        return .init(text: text, diagnostics: stderr, elapsed: Date().timeIntervalSince(started))
    }
}
