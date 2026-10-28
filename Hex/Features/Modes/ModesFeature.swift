import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

extension SharedReaderKey where Self == InMemoryKey<ModeLibrary>.Default {
    static var modeLibrary: Self { Self[.inMemory("modeLibrary"), default: ModeLibrary()] }
}

/// Root folder for modes, tools, and scripts. Tests point it at a temporary directory.
enum ModeConfigurationRootKey: DependencyKey {
    static var liveValue: URL { HexStoragePaths.live.config }
    static var testValue: URL { FileManager.default.temporaryDirectory.appendingPathComponent("hex-modes-\(UUID().uuidString)") }
}

extension DependencyValues {
    var modeConfigurationRoot: URL {
        get { self[ModeConfigurationRootKey.self] }
        set { self[ModeConfigurationRootKey.self] = newValue }
    }
}

/// Edits save automatically shortly after typing stops. A conflict banner appears only
/// when a file changes in another app while Hex still has an unsaved edit to it.
@Reducer
struct ModesFeature {
    enum Selection: Hashable { case mode(String), tool(String) }

    struct AddTool: Equatable {
        var assignToMode = false
        var name = ""
        var command = ""
        var problem: String?
    }

    @ObservableState
    struct State: Equatable {
        @Shared(.modeLibrary) var library: ModeLibrary
        @Shared(.hexSettings) var settings: HexSettings
        var selection: Selection? = .mode("dictation")
        var error: String?
        var pendingDelete: Selection?
        var addTool = AddTool()
        var isAddingTool = false

        // Mode editor
        var document = ModeDocument(mode: .dictation)
        var savedDocument = ModeDocument(mode: .dictation)
        var revision: [Data?] = []
        var conflict = false

        // Tool editor
        var tool = ProcessorConfiguration()
        var savedTool = ProcessorConfiguration()
        var toolRevision: Data?
        var toolCommand = ""
        var toolProblem: String?
        var toolConflict = false

        // Try it
        var sample = "Today we discussed the launch. Follow up with the team tomorrow."
        var testID: UUID?
        var testResult: TextProcessorResult?
        var testError: String?
        var testDiagnostics = ""
        var testInput: String?
        var testSnapshot: ModeDocument?
        var testProcessor: ProcessorConfiguration?

        var dirty: Bool { document != savedDocument }
        var toolDirty: Bool { tool != savedTool }
        var staleTest: Bool { testSnapshot != document || testProcessor != selectedProcessor || testInput != sample }
        var selectedProcessor: ProcessorConfiguration? { library.processor(for: document.mode) }
        func modes(using toolID: String) -> [String] {
            library.modes.filter { $0.mode.processorID == toolID }.map(\.mode.name)
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task, refresh, flush
        case select(Selection?)
        case setActive(String)
        case newMode, duplicate(String)
        case requestDelete(Selection), confirmDelete
        case autosave, autosaveTool
        case useFileVersion, keepMine
        case applyTemplate(String)
        case chooseExecutable(String)
        case showAddTool(assignToMode: Bool), addPreset(String), addScript, addCustom
        case runTest, cancelTest, useLastDictation
        case tested(UUID, Result<TextProcessorResult, TextProcessorFailure>)
    }

    @Dependency(\.textProcessor) var textProcessor
    @Dependency(\.continuousClock) var clock
    @Dependency(\.modeConfigurationRoot) var root
    private var files: ModeConfigurationStore { .init(root: root) }
    enum CancelID { case test, save, saveTool }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            do { return try reduce(&state, action) }
            catch { state.error = error.localizedDescription; return .none }
        }
    }

    private func reduce(_ state: inout State, _ action: Action) throws -> Effect<Action> {
        switch action {
        case .binding(\.toolCommand):
            state.toolProblem = nil
            do {
                let words = try CommandLineSyntax.split(state.toolCommand)
                state.tool.executable = words.first ?? ""
                state.tool.arguments = Array(words.dropFirst())
            } catch {
                state.toolProblem = error.localizedDescription
                return .cancel(id: CancelID.saveTool)
            }
            return debounce(.autosaveTool, id: .saveTool)

        case .binding:
            if state.isAddingTool { state.addTool.problem = nil }
            var effects: [Effect<Action>] = []
            if state.dirty { effects.append(debounce(.autosave, id: .save)) }
            if state.toolDirty { effects.append(debounce(.autosaveTool, id: .saveTool)) }
            return .merge(effects)

        case .task:
            return .run { [root] send in
                await send(.refresh)
                let observation = ModeFileObservation(root: root)
                defer { observation.cancel() }
                for await _ in observation.stream {
                    try await Task.sleep(for: .milliseconds(150))
                    try Task.checkCancellation()
                    await send(.refresh)
                }
            }

        case .refresh:
            var library = try files.load()
            // Keep a mode visible while another app is midway through replacing its files.
            for old in state.library.modes where !library.modes.contains(where: { $0.id == old.id }) && FileManager.default.fileExists(atPath: files.modeDirectory(old.id).path) {
                library.modes.append(old)
            }
            state.$library.withLock { $0 = library }
            if !library.modes.contains(where: { $0.id == state.settings.selectedModeID }) {
                state.$settings.withLock { $0.selectedModeID = "dictation" }
            }
            switch state.selection {
            case let .mode(id):
                guard let fresh = library.modes.first(where: { $0.id == id }) else { loadMode(&state, "dictation"); break }
                if files.revision(modeID: id) != state.revision, !state.dirty {
                    state.document = fresh; state.savedDocument = fresh; state.revision = files.revision(modeID: id)
                }
            case let .tool(id):
                guard let fresh = library.processors.first(where: { $0.id == id }) else {
                    // A tool whose file is broken or deleted is reported in problems instead.
                    if !state.toolDirty { loadMode(&state, "dictation") }
                    break
                }
                if files.processorRevision(id) != state.toolRevision, !state.toolDirty { loadTool(&state, fresh) }
            case nil: break
            }
            return .none

        case .flush:
            try flush(&state)
            return .merge(.cancel(id: CancelID.save), .cancel(id: CancelID.saveTool))

        case let .select(selection):
            guard selection != state.selection else { return .none }
            try flush(&state)
            switch selection {
            case let .mode(id): loadMode(&state, id)
            case let .tool(id):
                guard let tool = state.library.processors.first(where: { $0.id == id }) else { return .none }
                state.selection = selection; loadTool(&state, tool)
            case nil: state.selection = nil
            }
            state.error = nil
            return .merge(.cancel(id: CancelID.save), .cancel(id: CancelID.saveTool))

        case let .setActive(id):
            guard let document = state.library.modes.first(where: { $0.id == id }), state.library.available(document.mode) else { return .none }
            state.$settings.withLock { $0.selectedModeID = id }
            return .none

        case .newMode:
            try flush(&state)
            let names = Set(state.library.modes.map(\.mode.name))
            let name = (["New Mode"] + (2...99).map { "New Mode \($0)" }).first { !names.contains($0) } ?? "New Mode"
            // Default to the tool most modes already use, so a new mode usually works right away.
            let counts = Dictionary(grouping: state.library.modes.compactMap(\.mode.processorID), by: { $0 }).mapValues(\.count)
            let toolID = state.library.processors.max { counts[$0.id, default: 0] < counts[$1.id, default: 0] }?.id
            let document = ModeDocument(mode: .init(name: name, processorID: toolID))
            try files.save(document)
            try reloadLibrary(&state)
            loadMode(&state, document.id)
            return .none

        case let .duplicate(id):
            try flush(&state)
            guard var copy = state.library.modes.first(where: { $0.id == id }) else { return .none }
            copy.mode.id = UUID().uuidString; copy.mode.name += " Copy"
            try files.save(copy)
            try reloadLibrary(&state)
            loadMode(&state, copy.id)
            return .none

        case let .requestDelete(target):
            if case let .mode(id) = target, id == "dictation" { return .none }
            if case let .tool(id) = target, !state.modes(using: id).isEmpty {
                throw ModeConfigurationError.invalid("Switch \(state.modes(using: id).joined(separator: ", ")) to another tool first")
            }
            state.pendingDelete = target
            return .none

        case .confirmDelete:
            guard let target = state.pendingDelete else { return .none }
            state.pendingDelete = nil
            switch target {
            case let .mode(id):
                try files.deleteMode(id)
                if state.selection == target { state.savedDocument = state.document }
            case let .tool(id):
                try files.deleteProcessor(id)
                if state.selection == target { state.savedTool = state.tool }
            }
            try reloadLibrary(&state)
            if state.selection == target { loadMode(&state, "dictation") }
            return .merge(.cancel(id: CancelID.save), .cancel(id: CancelID.saveTool))

        case .autosave:
            try saveMode(&state)
            return .none

        case .autosaveTool:
            try saveTool(&state)
            return .none

        case .useFileVersion:
            switch state.selection {
            case let .mode(id):
                state.savedDocument = state.document
                try reloadLibrary(&state)
                loadMode(&state, id)
            case let .tool(id):
                state.savedTool = state.tool
                try reloadLibrary(&state)
                if let fresh = state.library.processors.first(where: { $0.id == id }) { loadTool(&state, fresh) } else { loadMode(&state, "dictation") }
            case nil: break
            }
            return .none

        case .keepMine:
            if state.conflict {
                state.revision = files.revision(modeID: state.document.id); state.conflict = false
                try saveMode(&state)
            }
            if state.toolConflict {
                state.toolRevision = files.processorRevision(state.tool.id); state.toolConflict = false
                try saveTool(&state)
            }
            return .none

        case let .applyTemplate(name):
            guard let template = InstructionTemplate.all.first(where: { $0.name == name }) else { return .none }
            state.document.prompt = template.text
            return debounce(.autosave, id: .save)

        case let .chooseExecutable(path):
            // Replace only the program; keep any arguments already typed after it.
            if state.isAddingTool {
                let words = (try? CommandLineSyntax.split(state.addTool.command)) ?? []
                state.addTool.command = CommandLineSyntax.join([path] + words.dropFirst())
                if state.addTool.name.isEmpty { state.addTool.name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
                state.addTool.problem = nil
                return .none
            }
            state.toolCommand = CommandLineSyntax.join([path] + state.tool.arguments)
            state.tool.executable = path
            return debounce(.autosaveTool, id: .saveTool)

        case let .showAddTool(assign):
            state.addTool = .init(assignToMode: assign); state.isAddingTool = true
            return .none

        case let .addPreset(id):
            guard let preset = ToolPreset.all.first(where: { $0.id == id }) else { return .none }
            var tool = try preset.install(in: files)
            // Reuse an existing tool that already runs this wrapper instead of adding a duplicate.
            if let existing = state.library.processors.first(where: { $0.executable == tool.executable }) { tool = existing }
            return try finishAddingTool(&state, tool)

        case .addScript:
            let fm = FileManager.default
            try fm.createDirectory(at: files.scriptsDirectory, withIntermediateDirectories: true)
            let url = (["my-tool"] + (2...99).map { "my-tool-\($0)" })
                .map { files.scriptsDirectory.appendingPathComponent($0 + ".sh") }
                .first { !fm.fileExists(atPath: $0.path) } ?? files.scriptsDirectory.appendingPathComponent(UUID().uuidString + ".sh")
            let script = """
            #!/bin/sh
            # Dictation arrives on stdin. The mode's instructions are in the file "$HEX_PROMPT_FILE".
            # Print only the final text to stdout; send progress or errors to stderr.
            set -eu
            exec /bin/cat
            """
            try Data(script.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            let effect = try finishAddingTool(&state, .init(name: "My Script", executable: url.path))
            return .merge(effect, .run { _ in await MainActor.run { openAsText(url) } })

        case .addCustom:
            var sheet = state.addTool
            let words: [String]
            do { words = try CommandLineSyntax.split(sheet.command) } catch { state.addTool.problem = error.localizedDescription; return .none }
            var tool = ProcessorConfiguration(name: sheet.name, executable: words.first ?? "", arguments: Array(words.dropFirst()))
            if tool.name.trimmingCharacters(in: .whitespaces).isEmpty {
                tool.name = URL(fileURLWithPath: tool.executable).deletingPathExtension().lastPathComponent
            }
            if let problem = Self.problem(with: tool) { sheet.problem = problem; state.addTool = sheet; return .none }
            return try finishAddingTool(&state, tool)

        case .useLastDictation:
            @Shared(.transcriptionHistory) var history: TranscriptionHistory
            if let last = history.history.first(where: { !($0.processorInput ?? $0.originalText ?? $0.text).isEmpty }) {
                state.sample = last.processorInput ?? last.originalText ?? last.text
            }
            return .none

        case .runTest:
            try flush(&state)
            guard let processor = state.selectedProcessor else { throw ModeConfigurationError.invalid("Choose a tool to try this mode") }
            try processor.validate()
            let request = TextProcessorRequest(input: state.sample, prompt: state.document.prompt, processor: processor)
            state.testInput = state.sample; state.testID = request.runID; state.testSnapshot = state.document; state.testProcessor = processor
            state.testResult = nil; state.testError = nil; state.testDiagnostics = ""
            return .run { send in
                do { let result = try await textProcessor.run(request); try Task.checkCancellation(); await send(.tested(request.runID, .success(result))) }
                catch is CancellationError { }
                catch { await send(.tested(request.runID, .failure((error as? TextProcessorFailure) ?? .init(error.localizedDescription)))) }
            }.cancellable(id: CancelID.test, cancelInFlight: true)

        case .cancelTest:
            state.testID = nil; state.testError = "Cancelled"
            return .cancel(id: CancelID.test)

        case let .tested(id, result):
            guard state.testID == id else { return .none }
            state.testID = nil
            switch result {
            case let .success(result): state.testResult = result; state.testDiagnostics = result.diagnostics
            case let .failure(error): state.testError = error.reason; state.testDiagnostics = error.diagnostics
            }
            return .none
        }
    }

    // MARK: - Helpers

    private func debounce(_ action: Action, id: CancelID) -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: .milliseconds(600))
            await send(action)
        }.cancellable(id: id, cancelInFlight: true)
    }

    private func loadMode(_ state: inout State, _ id: String) {
        let document = state.library.modes.first { $0.id == id } ?? state.library.modes.first ?? .init(mode: .dictation)
        state.selection = .mode(document.id)
        state.document = document; state.savedDocument = document
        state.revision = files.revision(modeID: document.id); state.conflict = false
    }

    private func loadTool(_ state: inout State, _ tool: ProcessorConfiguration) {
        state.tool = tool; state.savedTool = tool
        state.toolCommand = CommandLineSyntax.join([tool.executable] + tool.arguments)
        state.toolRevision = files.processorRevision(tool.id)
        state.toolProblem = nil; state.toolConflict = false
    }

    private func reloadLibrary(_ state: inout State) throws {
        let library = try files.load()
        state.$library.withLock { $0 = library }
    }

    /// Saves pending edits now (used before switching away). An empty name falls back to the last saved name.
    private func flush(_ state: inout State) throws {
        if state.dirty, state.document.mode.name.trimmingCharacters(in: .whitespaces).isEmpty {
            state.document.mode.name = state.savedDocument.mode.name
        }
        try saveMode(&state)
        try saveTool(&state)
        // Leaving a tool with an unfixable edit discards it rather than blocking navigation.
        if state.toolDirty, !state.toolConflict { state.tool = state.savedTool }
    }

    private func saveMode(_ state: inout State) throws {
        guard state.dirty, !state.conflict, !state.document.mode.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do { try files.save(state.document, expectedRevision: state.revision) }
        catch ModeConfigurationError.conflict { state.conflict = true; return }
        state.savedDocument = state.document; state.revision = files.revision(modeID: state.document.id); state.error = nil
        let saved = state.document
        state.$library.withLock { library in
            if let index = library.modes.firstIndex(where: { $0.id == saved.id }) { library.modes[index] = saved } else { library.modes.append(saved) }
        }
    }

    private func saveTool(_ state: inout State) throws {
        guard state.toolDirty, !state.toolConflict else { return }
        if let problem = Self.problem(with: state.tool) { state.toolProblem = problem; return }
        do { try files.save(state.tool, expectedRevision: state.toolRevision, checkRevision: true) }
        catch ModeConfigurationError.conflict { state.toolConflict = true; return }
        state.savedTool = state.tool; state.toolRevision = files.processorRevision(state.tool.id); state.toolProblem = nil
        try reloadLibrary(&state)
    }

    private func finishAddingTool(_ state: inout State, _ tool: ProcessorConfiguration) throws -> Effect<Action> {
        if !state.library.processors.contains(where: { $0.id == tool.id }) { try files.save(tool) }
        try reloadLibrary(&state)
        let assign = state.isAddingTool && state.addTool.assignToMode
        state.isAddingTool = false
        if assign, case .mode = state.selection {
            state.document.mode.processorID = tool.id
            try saveMode(&state)
        } else {
            try flush(&state)
            state.selection = .tool(tool.id); loadTool(&state, tool)
        }
        return .none
    }

    /// A plain-language reason the tool can't run yet, or nil when it can be saved.
    static func problem(with tool: ProcessorConfiguration) -> String? {
        let fm = FileManager.default
        if tool.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the tool a name" }
        if tool.executable.isEmpty { return "Enter the program or script to run" }
        if !tool.executable.hasPrefix("/") { return "Start with the full path to the program, for example /opt/homebrew/bin/\(tool.executable)" }
        if !fm.fileExists(atPath: tool.executable) { return "No file at \(tool.executable)" }
        if !fm.isExecutableFile(atPath: tool.executable) { return "This file can't be run. Make it executable with: chmod +x \(CommandLineSyntax.join([tool.executable]))" }
        if let directory = tool.workingDirectory {
            var isDirectory: ObjCBool = false
            if !directory.hasPrefix("/") || !fm.fileExists(atPath: directory, isDirectory: &isDirectory) || !isDirectory.boolValue { return "Working folder doesn't exist" }
        }
        do { try tool.validateFiles() } catch { return error.localizedDescription }
        return nil
    }
}

/// Opens a file in TextEdit explicitly: default handlers for .sh/.command/.py can execute files.
@MainActor func openAsText(_ url: URL) {
    guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return }
    NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
}
