import Foundation
import Testing
@testable import HexCore

@Suite struct TextProcessorTests {
    private func request(_ script: String, input: String = "Hello 🌊\nsecond line\n", timeout: Double = 3) -> TextProcessorRequest {
        .init(input: input, prompt: "Instructions 🐙\n", processor: .init(name: "Fixture", executable: "/bin/sh", arguments: ["-c", script], timeout: timeout))
    }
    @Test func unicodeEOFPromptAndEnvironment() async throws {
        let result = try await TextProcessorClient.liveValue.run(request("cat; cat \"$HEX_PROMPT_FILE\"; printf '%s' \"$HOME\"; printf diagnostics >&2"))
        #expect(result.text == "Hello 🌊\nsecond line\nInstructions 🐙\n" + FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(result.diagnostics == "diagnostics")
    }
    @Test func preservesWhitespace() async throws {
        let result = try await TextProcessorClient.liveValue.run(request("cat >/dev/null; printf '  final\n\n'"))
        #expect(result.text == "  final\n\n")
    }
    @Test(arguments: ["cat >/dev/null; printf error >&2; exit 7", "cat >/dev/null; printf '  \n'", "cat >/dev/null; printf '\\377'", "sleep 10", "exec 0<&-; sleep 0.1; printf done"])
    func reportsFailures(_ script: String) async {
        do {
            _ = try await TextProcessorClient.liveValue.run(request(script, input: String(repeating: "a", count: 100_000), timeout: 1))
            Issue.record("Expected failure")
        } catch { #expect(error is TextProcessorFailure) }
    }
    @Test func launchFailure() async {
        var request = request("cat"); request.processor.executable = "/no/such/hex-fixture"
        do { _ = try await TextProcessorClient.liveValue.run(request); Issue.record("Expected launch failure") }
        catch { #expect(error.localizedDescription.contains("Launch failed")) }
    }
    @Test func drainsConcurrentStreamsAndWritesInput() async throws {
        let result = try await TextProcessorClient.liveValue.run(request("(head -c 200000 /dev/zero | tr '\\0' 'e' >&2) & cat; wait", input: String(repeating: "x", count: 200_000)))
        #expect(result.text.count == 200_000); #expect(result.diagnostics.count == 200_000)
    }
    @Test(arguments: [false, true]) func outputLimits(_ stderr: Bool) async {
        do {
            _ = try await TextProcessorClient.liveValue.run(request("cat >/dev/null; yes x" + (stderr ? " >&2" : ""), timeout: 10))
            Issue.record("Expected output limit")
        } catch { #expect(error.localizedDescription.contains("limit")) }
    }
    @Test func cancellationKillsDescendantsAndRemovesPrompt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("child")
        let prompt = directory.appendingPathComponent("prompt")
        let task = Task {
            try await TextProcessorClient.liveValue.run(request("cat >/dev/null; printf '%s' \"$HEX_PROMPT_FILE\" > '\(prompt.path)'; (sleep 1; touch '\(marker.path)') & wait", timeout: 10))
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: prompt.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: prompt.path))
        let promptPath = try String(contentsOf: prompt, encoding: .utf8)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(1100))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: promptPath))
    }
}
