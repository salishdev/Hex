import Foundation
import Testing
@testable import HexCore

@Suite struct ModeConfigurationTests {
    @Test func bootstrapRenameConflictAndBrokenFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModeConfigurationStore(root: root)
        #expect(try store.load().modes.map(\.id) == ["dictation"])
        let processor = ProcessorConfiguration(name: "Filter", executable: "/bin/cat")
        try store.save(processor)
        var document = ModeDocument(mode: .init(name: "Notes / 🌊", processorID: processor.id), prompt: "Prompt")
        try store.save(document)
        let revision = store.revision(modeID: document.id)
        document.mode.name = "Renamed"
        try store.save(document, expectedRevision: revision)
        #expect(try store.load().modes.contains(document))
        #expect(throws: ModeConfigurationError.self) { try store.save(document, expectedRevision: revision) }
        #expect(throws: ModeConfigurationError.self) { try store.deleteProcessor(processor.id) }
        try Data("partial".utf8).write(to: store.processorURL(processor.id), options: .atomic)
        let broken = try store.load()
        #expect(!broken.available(document.mode)); #expect(broken.problems.count == 1)
        #expect(try String(contentsOf: store.processorURL(processor.id), encoding: .utf8) == "partial")
        document.mode.processorID = nil; try store.save(document)
        try store.deleteProcessor(processor.id)
        #expect(try store.load().available(document.mode))
    }
    @Test func rejectsTraversalAndRelativePaths() throws {
        #expect(throws: ModeConfigurationError.self) { try TranscriptionMode(id: "../escape", name: "Bad").validate() }
        #expect(throws: ModeConfigurationError.self) { try ProcessorConfiguration(executable: "cat").validate() }
        #expect(throws: ModeConfigurationError.self) { try ProcessorConfiguration(executable: "/bin/cat", timeout: .infinity).validate() }
    }
    @Test func oldHistoryAndSettingsDecode() throws {
        let old = Transcript(timestamp: Date(), text: "Old output", audioPath: URL(fileURLWithPath: "/tmp/old.wav"), duration: 1)
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(old))
        #expect(decoded.originalText == nil); #expect(decoded.processingRequest == nil); #expect(decoded.isUsableOutput)
        #expect(try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8)).selectedModeID == "dictation")
        var failure = old; failure.processingOutcome = "failed"
        #expect(!failure.isUsableOutput)
    }
}
