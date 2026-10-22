import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

extension SharedReaderKey where Self == InMemoryKey<ModeLibrary>.Default {
    static var modeLibrary: Self { Self[.inMemory("modeLibrary"), default: ModeLibrary()] }
}

@Reducer
struct ModesFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.modeLibrary) var library: ModeLibrary
        @Shared(.hexSettings) var settings: HexSettings
        var document = ModeDocument(mode: .dictation)
        var loadedDocument = ModeDocument(mode: .dictation)
        var revision: [Data?] = []
        var processor = ProcessorConfiguration()
        var loadedProcessor = ProcessorConfiguration()
        var processorRevision: Data?
        var editingProcessor = false
        var requiresProcessor = false
        var testInput: String?
        var conflict = false
        var processorConflict = false
        var error: String?
        var sample = "Today we discussed the launch. Follow up with the team tomorrow."
        var testID: UUID?
        var testResult: TextProcessorResult?
        var testError: String?
        var testDiagnostics = ""
        var testSnapshot: ModeDocument?
        var testProcessor: ProcessorConfiguration?
        var dirty: Bool { document != loadedDocument }
        var processorDirty: Bool { processor != loadedProcessor }
        var staleTest: Bool { testSnapshot != document || testProcessor != selectedProcessor || testInput != sample }
        var selectedProcessor: ProcessorConfiguration? {
            if editingProcessor && processor.id == document.mode.processorID { return processor }
            return library.processor(for: document.mode)
        }
    }
    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case task, refresh, reload, keepEdits, save
        case select(String), create(String), duplicate, delete
        case editProcessor(String?), saveProcessor, deleteProcessor, reloadProcessor, keepProcessorEdits
        case runTest, cancelTest
        case tested(UUID, Result<TextProcessorResult, TextProcessorFailure>)
    }
    @Dependency(\.textProcessor) var textProcessor
    private var files: ModeConfigurationStore { .init(root: HexStoragePaths.live.config) }
    enum CancelID { case test }
    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            do {
                switch action {
                case .binding: return .none
                case .task:
                    return .run { send in
                        await send(.reload)
                        let observation = ModeFileObservation(root: HexStoragePaths.live.config)
                        defer { observation.cancel() }
                        for await _ in observation.stream {
                            try await Task.sleep(for: .milliseconds(150))
                            try Task.checkCancellation()
                            await send(.refresh)
                        }
                    }
                case .refresh:
                    var library = try files.load()
                    for old in state.library.modes where !library.modes.contains(where: { $0.id == old.id }) && FileManager.default.fileExists(atPath: files.modeDirectory(old.id).path) {
                        library.modes.append(old)
                    }
                    // A broken processor is unavailable immediately; do not run a stale executable configuration.
                    state.$library.withLock { $0 = library }
                    if !library.modes.contains(where: { $0.id == state.settings.selectedModeID }) {
                        state.$settings.withLock { $0.selectedModeID = "dictation" }
                    }
                    let revision = files.revision(modeID: state.document.id)
                    if revision != state.revision {
                        if state.dirty { state.conflict = true }
                        else if let fresh = library.modes.first(where: { $0.id == state.document.id }) {
                            state.document = fresh; state.loadedDocument = fresh; state.revision = revision
                        }
                    }
                    if state.editingProcessor, files.processorRevision(state.processor.id) != state.processorRevision {
                        if state.processorDirty { state.processorConflict = true }
                        else if let fresh = library.processors.first(where: { $0.id == state.processor.id }) {
                            state.processor = fresh; state.loadedProcessor = fresh; state.processorRevision = files.processorRevision(fresh.id)
                        }
                    }
                    return .none
                case .reload:
                    let library = try files.load()
                    state.$library.withLock { $0 = library }
                    if !library.modes.contains(where: { $0.id == state.settings.selectedModeID }) {
                        state.$settings.withLock { $0.selectedModeID = "dictation" }
                    }
                    let fresh = library.modes.first(where: { $0.id == state.document.id }) ?? library.modes.first!
                    state.document = fresh; state.loadedDocument = fresh
                    state.revision = files.revision(modeID: fresh.id); state.conflict = false; state.error = nil; state.requiresProcessor = false
                    return .none
                case .keepEdits:
                    state.revision = files.revision(modeID: state.document.id); state.conflict = false
                    return .none
                case .save:
                    guard !state.conflict else { throw ModeConfigurationError.conflict }
                    if state.requiresProcessor && state.document.mode.processorID == nil { throw ModeConfigurationError.invalid("Choose a processor before saving this template") }
                    if let id = state.document.mode.processorID, !state.library.processors.contains(where: { $0.id == id }) { throw ModeConfigurationError.invalid("Choose a saved processor first") }
                    try files.save(state.document, expectedRevision: state.revision)
                    state.loadedDocument = state.document; state.revision = files.revision(modeID: state.document.id); state.error = nil
                    return .send(.refresh)
                case let .select(id):
                    guard !state.dirty && (!state.editingProcessor || !state.processorDirty) else { throw ModeConfigurationError.invalid("Save or Reload your edits before switching modes") }
                    guard let document = state.library.modes.first(where: { $0.id == id }) else { return .none }
                    state.document = document; state.loadedDocument = document; state.revision = files.revision(modeID: id)
                    state.conflict = false; state.error = nil; state.requiresProcessor = false
                    return .none
                case let .create(template):
                    guard !state.dirty && (!state.editingProcessor || !state.processorDirty) else { throw ModeConfigurationError.invalid("Save or Reload your edits first") }
                    let prompt = template == "Notes" ? "Turn the dictation into concise notes with headings and action items. Preserve facts; do not invent details. Return only the notes." : template == "Message" ? "Turn the dictation into a clear, natural chat message. Preserve meaning and tone. Return only the message." : ""
                    // Templates are drafts until a processor is explicitly selected and saved.
                    state.document = .init(mode: .init(name: template), prompt: prompt)
                    state.loadedDocument = .init(mode: .init(id: state.document.id, name: ""))
                    state.revision = [nil, nil]; state.conflict = false; state.requiresProcessor = template != "Dictation"
                    return .none
                case .duplicate:
                    if state.requiresProcessor && state.document.mode.processorID == nil { throw ModeConfigurationError.invalid("Choose a processor before saving this template") }
                    if let id = state.document.mode.processorID, !state.library.processors.contains(where: { $0.id == id }) { throw ModeConfigurationError.invalid("Choose a saved processor first") }
                    var copy = state.document; copy.mode.id = UUID().uuidString; copy.mode.name += " Copy"
                    try files.save(copy)
                    state.document = copy; state.loadedDocument = copy; state.revision = files.revision(modeID: copy.id)
                    return .send(.refresh)
                case .delete:
                    try files.deleteMode(state.document.id)
                    state.document = .init(mode: .dictation)
                    return .send(.reload)
                case let .editProcessor(id):
                    guard !state.processorDirty || !state.editingProcessor else { throw ModeConfigurationError.invalid("Save or Reload processor edits first") }
                    state.processor = state.library.processors.first(where: { $0.id == id }) ?? .init()
                    state.loadedProcessor = state.processor; state.processorRevision = files.processorRevision(state.processor.id)
                    state.editingProcessor = true; state.processorConflict = false
                    state.document.mode.processorID = state.processor.id
                    return .none
                case .saveProcessor:
                    guard !state.processorConflict else { throw ModeConfigurationError.conflict }
                    try files.save(state.processor, expectedRevision: state.processorRevision, checkRevision: true)
                    state.loadedProcessor = state.processor; state.processorRevision = files.processorRevision(state.processor.id)
                    state.document.mode.processorID = state.processor.id; state.error = nil
                    return .send(.refresh)
                case .deleteProcessor:
                    try files.deleteProcessor(state.processor.id); state.editingProcessor = false
                    return .send(.refresh)
                case .reloadProcessor:
                    if let fresh = try files.load().processors.first(where: { $0.id == state.processor.id }) {
                        state.processor = fresh; state.loadedProcessor = fresh
                    } else {
                        if state.document.mode.processorID == state.processor.id { state.document.mode.processorID = state.loadedDocument.mode.processorID }
                        state.editingProcessor = false
                    }
                    state.processorRevision = files.processorRevision(state.processor.id); state.processorConflict = false
                    return .none
                case .keepProcessorEdits:
                    state.processorRevision = files.processorRevision(state.processor.id); state.processorConflict = false
                    return .none
                case .runTest:
                    guard let processor = state.selectedProcessor else { throw ModeConfigurationError.invalid("Select a processor to test") }
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
            } catch { state.error = error.localizedDescription; return .none }
        }
    }
}
