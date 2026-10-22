import AppKit
import ComposableArchitecture
import HexCore
import XCTest
@testable import Hex

@MainActor
final class TranscriptionModesTests: XCTestCase {
    private func state(processor: Bool = true, history: Bool = false, scratchpad: Bool = false) -> TranscriptionFeature.State {
        var library = ModeLibrary()
        let filter = ProcessorConfiguration(id: "fixture", name: "Fixture", executable: "/bin/cat")
        library.processors = [filter]
        library.modes.append(.init(mode: .init(id: "notes", name: "Notes", processorID: processor ? filter.id : nil), prompt: "Snapshot instructions"))
        var settings = HexSettings(saveTranscriptionHistory: history, wordRemappings: [.init(match: "hello", replacement: "goodbye")])
        settings.selectedModeID = "notes"
        return .init(modeLibrary: Shared(value: library), hexSettings: Shared(value: settings), isRemappingScratchpadFocused: scratchpad, modelBootstrapState: Shared(value: .init(isModelReady: true)), transcriptionHistory: Shared(value: .init()))
    }
    private func audio() throws -> RecordingArtifact {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hex-mode-test-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: url)
        return RecordingArtifact(url)
    }
    func testSnapshotsInstructionsAndIgnoresStaleResults() async throws {
        let store = TestStore(initialState: state()) { TranscriptionFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1234)
            $0.uuid = .incrementing
            $0.recording.startRecording = {}
            $0.recording.stopRecording = { .ignored(.noActiveRecording) }
            $0.pasteboard.pasteGuarded = { _, _ in false }
            $0.sleepManagement.allowSleep = {}
            $0.sleepManagement.preventSleep = { _ in }
            $0.soundEffects.play = { _ in }
            $0.textProcessor.run = { request in
                XCTAssertEqual(request.prompt, "Snapshot instructions")
                XCTAssertEqual(request.input, "goodbye")
                return .init(text: "Notes", diagnostics: "", elapsed: 0)
            }
        }
        store.exhaustivity = .off
        await store.send(.startRecording)
        let id = try XCTUnwrap(store.state.session?.id)
        store.state.$modeLibrary.withLock { $0.modes[1].prompt = "Changed outside recording" }
        let artifact = try audio()
        await store.send(.sessionTranscript(UUID(), "stale", artifact, 1))
        XCTAssertNil(store.state.recovery)
        await store.send(.sessionTranscript(id, "hello", artifact, 1))
        await store.receive(\.processed)
        XCTAssertEqual(store.state.recovery?.transcript.text, "Notes")
        XCTAssertEqual(store.state.recovery?.transcript.originalText, "hello")
        await store.send(.cancel)
        await store.finish()
        XCTAssertNil(store.state.session)
        XCTAssertTrue(store.state.transcriptionHistory.history.isEmpty)
    }
    func testCancelDuringProcessingInvalidatesLateCompletion() async throws {
        let id = UUID()
        var initial = state()
        initial.session = .init(id: id, mode: initial.modeLibrary.modes[1], processor: initial.modeLibrary.processors[0], settings: initial.hexSettings, scratchpad: false)
        initial.isTranscribing = true
        let artifact = try audio()
        initial.recovery = .init(transcript: .init(timestamp: Date(), text: "", audioPath: artifact.url, duration: 1), artifact: artifact)
        let store = TestStore(initialState: initial) { TranscriptionFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1234)
            $0.sleepManagement.allowSleep = {}; $0.soundEffects.play = { _ in }
            $0.pasteboard.paste = { _ in XCTFail("Cancelled run pasted") }
            $0.pasteboard.pasteGuarded = { _, _ in XCTFail("Cancelled run pasted"); return true }
        }
        store.exhaustivity = .off
        await store.send(.cancel)
        await store.send(.processed(id, "stale output", nil))
        await store.send(.deliver(id, false))
        await store.finish()
        XCTAssertNil(store.state.recovery)
        XCTAssertTrue(store.state.transcriptionHistory.history.isEmpty)
    }
    func testFailureKeepsOriginalInMemoryWithoutHistory() async throws {
        let id = UUID()
        var initial = state()
        initial.session = .init(id: id, mode: initial.modeLibrary.modes[1], processor: initial.modeLibrary.processors[0], settings: initial.hexSettings, scratchpad: false)
        initial.isTranscribing = true
        let store = TestStore(initialState: initial) { TranscriptionFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1234)
            $0.textProcessor.run = { _ in throw TextProcessorFailure("Fixture failure", diagnostics: "Private diagnostics") }
            $0.transcriptPersistence.save = { _, _, _, _, _ in XCTFail("History disabled"); throw TextProcessorFailure("Unexpected save") }
            $0.pasteboard.paste = { _ in XCTFail("Failure pasted") }
        }
        store.exhaustivity = .off
        let artifact = try audio()
        await store.send(.sessionTranscript(id, "hello", artifact, 1))
        await store.receive(\.processed)
        await store.receive(\.persisted)
        XCTAssertEqual(store.state.phase, "failed")
        XCTAssertEqual(store.state.recovery?.transcript.originalText, "hello")
        XCTAssertEqual(store.state.recovery?.diagnostics, "Private diagnostics")
        XCTAssertTrue(store.state.transcriptionHistory.history.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
        await store.finish()
    }
    func testScratchpadBypassesProcessorAndFormatting() async throws {
        let id = UUID()
        var initial = state(scratchpad: true)
        initial.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        initial.session = .init(id: id, mode: initial.modeLibrary.modes[1], processor: initial.modeLibrary.processors[0], settings: initial.hexSettings, scratchpad: true)
        initial.isTranscribing = true
        let store = TestStore(initialState: initial) { TranscriptionFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1234)
            $0.textProcessor.run = { _ in XCTFail("Scratchpad ran processor"); throw TextProcessorFailure("Unexpected") }
            $0.pasteboard.pasteGuarded = { text, _ in XCTAssertEqual(text, "Hello!"); return true }
            $0.soundEffects.play = { _ in }
        }
        store.exhaustivity = .off
        await store.send(.sessionTranscript(id, "Hello!", try audio(), 1))
        await store.receive(\.processed)
        await store.receive(\.persisted)
        await store.receive(\.deliver)
        await store.receive(\.delivered)
        XCTAssertNil(store.state.recovery)
        await store.finish()
    }
    func testDestinationChangeRetainsReadyResult() async throws {
        let id = UUID()
        var initial = state(processor: false)
        initial.session = .init(id: id, mode: initial.modeLibrary.modes[1], processor: nil, settings: initial.hexSettings, scratchpad: false)
        initial.isTranscribing = true
        let artifact = try audio()
        let transcript = Transcript(timestamp: Date(), text: "Ready output", audioPath: artifact.url, duration: 1, sourceAppBundleID: "com.hex.fixture.different-app")
        initial.recovery = .init(transcript: transcript, artifact: artifact)
        let store = TestStore(initialState: initial) { TranscriptionFeature() } withDependencies: {
            $0.pasteboard.paste = { _ in XCTFail("Destination changed") }
            $0.pasteboard.pasteGuarded = { _, _ in XCTFail("Destination changed"); return false }
        }
        store.exhaustivity = .off
        await store.send(.deliver(id, false))
        await store.receive(\.delivered)
        XCTAssertEqual(store.state.phase, "ready")
        XCTAssertEqual(store.state.recovery?.transcript.text, "Ready output")
        XCTAssertTrue(store.state.transcriptionHistory.history.isEmpty)
        await store.finish()
    }

    func testCancelBeforeDeliveryDeletesUnpublishedAudio() async throws {
        let id = UUID()
        var initial = state(history: true)
        initial.session = .init(id: id, mode: initial.modeLibrary.modes[1], processor: initial.modeLibrary.processors[0], settings: initial.hexSettings, scratchpad: false)
        initial.isTranscribing = true
        let artifact = try audio()
        let transcript = Transcript(timestamp: Date(), text: "Pending output", audioPath: artifact.url, duration: 1)
        initial.recovery = .init(transcript: transcript, artifact: artifact, persisted: true)
        let deleted = expectation(description: "Unpublished audio removed")
        let store = TestStore(initialState: initial) { TranscriptionFeature() } withDependencies: {
            $0.transcriptPersistence.deleteAudio = { _ in deleted.fulfill() }
            $0.sleepManagement.allowSleep = {}; $0.soundEffects.play = { _ in }
        }
        store.exhaustivity = .off
        await store.send(.cancel)
        await store.send(.delivered(id, true))
        await store.finish()
        await fulfillment(of: [deleted], timeout: 1)
        XCTAssertTrue(store.state.transcriptionHistory.history.isEmpty)
        XCTAssertNil(store.state.recovery)
    }

    func testTwoModesReuseRealProcessorInSignedApp() async throws {
        let processor = ProcessorConfiguration(id: "shared-fixture", name: "Prompt plus stdin", executable: "/bin/sh", arguments: ["-c", "cat \"$HEX_PROMPT_FILE\"; printf '\\n'; cat"])
        for name in ["Notes", "Message"] {
            var initial = state()
            initial.$modeLibrary.withLock { library in
                library.processors = [processor]
                library.modes = [.init(mode: .dictation)] + ["Notes", "Message"].map {
                    .init(mode: .init(id: $0.lowercased(), name: $0, processorID: processor.id), prompt: $0)
                }
            }
            initial.$hexSettings.withLock {
                $0.selectedModeID = name.lowercased(); $0.hotkey = .init(key: .a, modifiers: [.command])
            }
            let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("hex-real-run-\(UUID().uuidString).wav")
            try Data("fixture audio".utf8).write(to: audioURL)
            let delivered = expectation(description: "Delivered \(name)")
            let store = TestStore(initialState: initial) { TranscriptionFeature() } withDependencies: {
                $0.uuid = .incrementing; $0.date.now = Date(timeIntervalSince1970: 1234)
                $0.recording.startRecording = {}; $0.recording.stopRecording = { .captured(audioURL) }
                $0.sleepManagement.preventSleep = { _ in }; $0.sleepManagement.allowSleep = {}
                $0.soundEffects.play = { _ in }
                $0.transcription.transcribe = { _, _, _, _ in "hello" }
                $0.textProcessor = .liveValue
                $0.pasteboard.pasteGuarded = { text, _ in
                    XCTAssertEqual(text, name + "\ngoodbye")
                    delivered.fulfill(); return true
                }
            }
            store.exhaustivity = .off
            await store.send(.startRecording)
            store.state.$modeLibrary.withLock { library in
                for index in library.modes.indices { library.modes[index].prompt = "Changed after recording started" }
            }
            await store.send(.stopRecording)
            await store.receive(\.sessionTranscript)
            await store.receive(\.processed)
            await store.receive(\.persisted)
            await store.receive(\.deliver)
            await store.receive(\.delivered)
            await store.finish()
            await fulfillment(of: [delivered], timeout: 1)
            XCTAssertFalse(store.state.isTranscribing)
            XCTAssertTrue(store.state.transcriptionHistory.history.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        }
    }

    func testMissingSelectedModeDoesNotFallBackToRawDictation() async {
        var initial = state()
        initial.$hexSettings.withLock { $0.selectedModeID = "missing" }
        let store = TestStore(initialState: initial) { TranscriptionFeature() } withDependencies: {
            $0.recording.startRecording = { XCTFail("Missing mode started dictation") }
        }
        store.exhaustivity = .off
        await store.send(.startRecording)
        XCTAssertFalse(store.state.isRecording)
        XCTAssertNil(store.state.session)
        XCTAssertNotNil(store.state.error)
        await store.finish()
    }

}
