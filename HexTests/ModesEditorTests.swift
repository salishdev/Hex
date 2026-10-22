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
        initial.sample = "Sample 🌊"
        let store = TestStore(initialState: initial) { ModesFeature() } withDependencies: {
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
    func testTemplateRequiresProcessorForSaveAndDuplicate() async {
        var initial = ModesFeature.State(library: Shared(value: .init()), settings: Shared(value: .init()))
        initial.document = .init(mode: .init(name: "Notes"), prompt: "Notes instructions")
        initial.requiresProcessor = true
        let store = TestStore(initialState: initial) { ModesFeature() }
        store.exhaustivity = .off
        await store.send(.save)
        XCTAssertEqual(store.state.error, "Choose a processor before saving this template")
        await store.send(.duplicate)
        XCTAssertEqual(store.state.error, "Choose a processor before saving this template")
        XCTAssertEqual(store.state.library.modes.count, 1)
        await store.finish()
    }

}
