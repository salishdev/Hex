import ComposableArchitecture
import HexCore
import XCTest
@testable import Hex

@MainActor
final class ModesEditorTests: XCTestCase {
    func testRunsUnsavedPromptAndMarksResultStaleAfterEdit() async {
        var library = ModeLibrary()
        let processor = ProcessorConfiguration(id: "fixture", name: "Fixture", executable: "/bin/cat")
        library.processors = [processor]
        let document = ModeDocument(mode: .init(name: "Notes", processorID: processor.id), prompt: "Unsaved instructions")
        var initial = ModesFeature.State(library: Shared(value: library), settings: Shared(value: .init()))
        initial.document = document
        initial.revision = [nil, nil] // a new mode that hasn't been written yet
        initial.sample = "Sample 🌊"
        let store = TestStore(initialState: initial) { ModesFeature() } withDependencies: {
            $0.modeConfigurationRoot = temporaryRoot()
            $0.continuousClock = InstantClock()
            $0.textProcessor.run = { request in
                XCTAssertEqual(request.prompt, "Unsaved instructions")
                XCTAssertEqual(request.input, "Sample 🌊")
                return .init(text: "Result", diagnostics: "Diagnostic", elapsed: 0.1)
            }
        }
        store.exhaustivity = .off
        await store.send(.runTest)
        await store.receive(\.tested)
        XCTAssertEqual(store.state.testResult?.text, "Result")
        XCTAssertFalse(store.state.staleTest)
        await store.send(.binding(.set(\.sample, "Changed sample")))
        XCTAssertTrue(store.state.staleTest)
        await store.finish()
    }
    func testCancellationRejectsLateTestResult() async {
        let id = UUID()
        var initial = ModesFeature.State(library: Shared(value: .init()), settings: Shared(value: .init()))
        initial.testID = id
        let store = TestStore(initialState: initial) { ModesFeature() }
        store.exhaustivity = .off
        await store.send(.cancelTest)
        await store.send(.tested(id, .success(.init(text: "Late result", diagnostics: "", elapsed: 1))))
        XCTAssertNil(store.state.testResult)
        XCTAssertNil(store.state.testID)
        await store.finish()
    }
    private func makeStore(_ root: URL, clock: InstantClock = InstantClock()) throws -> TestStoreOf<ModesFeature> {
        let library = try ModeConfigurationStore(root: root).load()
        let store = TestStore(initialState: ModesFeature.State(library: Shared(value: library), settings: Shared(value: .init()))) { ModesFeature() } withDependencies: {
            $0.modeConfigurationRoot = root
            $0.continuousClock = clock
        }
        store.exhaustivity = .off
        return store
    }
    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hex-modes-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEditsSaveAutomaticallyAfterTypingStops() async throws {
        let root = temporaryRoot(), clock = InstantClock()
        let files = ModeConfigurationStore(root: root)
        let store = try makeStore(root, clock: clock)
        await store.send(.newMode)
        let id = store.state.document.id
        XCTAssertEqual(try files.load().modes.first { $0.id == id }?.mode.name, "New Mode")

        var document = store.state.document
        document.mode.name = "Notes"; document.prompt = "Make notes"
        await store.send(.binding(.set(\.document, document)))
        await store.receive(\.autosave)
        let saved = try files.load().modes.first { $0.id == id }
        XCTAssertEqual(saved?.mode.name, "Notes"); XCTAssertEqual(saved?.prompt, "Make notes")

        // An empty name is never written; leaving the mode keeps the last saved name.
        document.mode.name = ""
        await store.send(.binding(.set(\.document, document)))
        await store.receive(\.autosave)
        XCTAssertEqual(try files.load().modes.first { $0.id == id }?.mode.name, "Notes")
        await store.send(.select(.mode("dictation")))
        XCTAssertEqual(try files.load().modes.first { $0.id == id }?.mode.name, "Notes")
        XCTAssertEqual(store.state.document.id, "dictation")
        await store.finish()
    }

    func testAddingCustomToolAssignsItAndParsesTheCommand() async throws {
        let root = temporaryRoot(), clock = InstantClock()
        let files = ModeConfigurationStore(root: root)
        let store = try makeStore(root, clock: clock)
        await store.send(.newMode)
        XCTAssertNil(store.state.document.mode.processorID)
        await store.send(.showAddTool(assignToMode: true))

        await store.send(.binding(.set(\.addTool, .init(assignToMode: true, command: "/bin/cat 'open"))))
        await store.send(.addCustom)
        XCTAssertEqual(store.state.addTool.problem, "Close the quote at the end of the command")
        await store.send(.binding(.set(\.addTool, .init(assignToMode: true, command: "cat"))))
        await store.send(.addCustom)
        XCTAssertTrue(store.state.addTool.problem?.contains("full path") == true)
        XCTAssertTrue(store.state.isAddingTool)

        await store.send(.binding(.set(\.addTool, .init(assignToMode: true, command: "/bin/cat --flag 'two words'"))))
        await store.send(.addCustom)
        XCTAssertFalse(store.state.isAddingTool)
        let tool = try XCTUnwrap(try files.load().processors.first)
        XCTAssertEqual(tool.name, "cat"); XCTAssertEqual(tool.arguments, ["--flag", "two words"])
        XCTAssertEqual(try files.load().modes.first { $0.id == store.state.document.id }?.mode.processorID, tool.id)

        await store.send(.select(.tool(tool.id)))
        XCTAssertEqual(store.state.toolCommand, "/bin/cat --flag 'two words'")
        await store.send(.binding(.set(\.toolCommand, "/bin/cat -u")))
        await store.receive(\.autosaveTool)
        XCTAssertEqual(try files.load().processors.first?.arguments, ["-u"])

        await store.send(.requestDelete(.tool(tool.id)))
        XCTAssertEqual(store.state.error, "Switch New Mode to another tool first")
        XCTAssertNil(store.state.pendingDelete)
        await store.finish()
    }

    func testPresetInstallsOnceAndNewModesUseIt() async throws {
        let root = temporaryRoot()
        let files = ModeConfigurationStore(root: root)
        let store = try makeStore(root)
        await store.send(.showAddTool(assignToMode: false))
        await store.send(.addPreset("codex"))
        await store.send(.showAddTool(assignToMode: false))
        await store.send(.addPreset("codex"))
        let tools = try files.load().processors
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(store.state.selection, .tool(tools[0].id))
        await store.send(.newMode)
        XCTAssertEqual(store.state.document.mode.processorID, tools[0].id)
        await store.finish()
    }
}

/// Fires debounced saves right away so tests don't wait.
struct InstantClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Self { .init(offset: offset + duration) }
        func duration(to other: Self) -> Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }
    var now: Instant { .init() }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws { try Task.checkCancellation() }
}
