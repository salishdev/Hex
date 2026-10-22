import XCTest
@testable import HexCore

final class StoragePathsTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("hex-storage-tests-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    private func paths(_ id: String = "com.salishdev.Hex") -> HexStoragePaths {
        HexStoragePaths(home: home, bundleID: id)
    }

    private func write(_ data: Data, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func support(_ paths: HexStoragePaths) -> URL {
        paths.container.appendingPathComponent("Library/Application Support/\(paths.bundleID)")
    }

    func testRootsHonorOnlyAbsoluteXDGAndIsolateIdentities() {
        XCTAssertEqual(paths().config, home.appendingPathComponent(".config/hex"))
        XCTAssertEqual(paths("com.salishdev.Hex.debug").config, home.appendingPathComponent(".config/hex-debug"))
        XCTAssertEqual(paths("org.example.Hex").config, home.appendingPathComponent(".config/org.example.Hex"))
        for value in ["", "relative", "~/config"] {
            XCTAssertEqual(HexStoragePaths(home: home, bundleID: "com.salishdev.Hex", environment: ["XDG_CONFIG_HOME": value]).config, paths().config)
        }
        XCTAssertEqual(HexStoragePaths(home: home, bundleID: "com.salishdev.Hex", environment: ["XDG_CONFIG_HOME": "/custom"]).settings.path, "/custom/hex/settings.json")
        XCTAssertEqual(HexStoragePaths(home: home, bundleID: "org.fork", configName: "my-hex").config.lastPathComponent, "my-hex")
        XCTAssertNotEqual(paths().data, paths("com.salishdev.Hex.debug").data)
        XCTAssertEqual(paths().caches, home.appendingPathComponent("Library/Caches/com.salishdev.Hex"))
    }

    func testContainerMigrationPreservesOriginalsAndRewritesAudio() throws {
        let p = paths()
        let old = support(p)
        var settings = HexSettings()
        settings.soundEffectsEnabled = false
        try write(JSONEncoder().encode(settings), old.appendingPathComponent("hex_settings.json"))
        let audio = old.appendingPathComponent("Recordings/sample.wav")
        try write(Data([1, 2, 3]), audio)
        let transcript = Transcript(timestamp: Date(), text: "synthetic fixture", audioPath: audio, duration: 1)
        let history = old.appendingPathComponent("transcription_history.json")
        try write(JSONEncoder().encode(TranscriptionHistory(history: [transcript])), history)
        try write(Data([4]), old.appendingPathComponent("models/argmaxinc/whisperkit-coreml/test/model.bin"))
        try write(Data([5]), p.container.appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/model.bin"))
        try p.migrate()
        XCTAssertEqual(try JSONDecoder().decode(HexSettings.self, from: Data(contentsOf: p.settings)), settings)
        let migrated = try JSONDecoder().decode(TranscriptionHistory.self, from: Data(contentsOf: p.history)).history[0]
        XCTAssertEqual(migrated.id, transcript.id)
        XCTAssertEqual(migrated.text, transcript.text)
        XCTAssertEqual(migrated.audioPath, p.recordings.appendingPathComponent("legacy-1/sample.wav"))
        XCTAssertEqual(try Data(contentsOf: migrated.audioPath), Data([1, 2, 3]))
        for original in [audio, history, old.appendingPathComponent("hex_settings.json")] {
            XCTAssertTrue(fm.fileExists(atPath: original.path))
        }
        XCTAssertTrue(fm.fileExists(atPath: p.models.appendingPathComponent("argmaxinc/whisperkit-coreml/test/model.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: p.parakeetModels.appendingPathComponent("parakeet-tdt-0.6b-v3/model.bin").path))
        // Completed migration must not resurrect deleted installed models or history.
        try fm.removeItem(at: p.parakeetModels)
        try fm.removeItem(at: p.history)
        try p.migrate()
        XCTAssertFalse(fm.fileExists(atPath: p.history.path))
        XCTAssertFalse(fm.fileExists(atPath: p.parakeetModels.path))
    }

    func testExistingDestinationsWinAndMissingModelFilesAreMerged() throws {
        let p = paths()
        let settings = Data("{}".utf8)
        let history = try JSONEncoder().encode(TranscriptionHistory())
        try write(settings, p.settings)
        try write(history, p.history)
        try write(Data("invalid source".utf8), support(p).appendingPathComponent("hex_settings.json"))
        try write(Data("invalid source".utf8), support(p).appendingPathComponent("transcription_history.json"))
        try write(Data([1]), p.models.appendingPathComponent("existing.bin"))
        try write(Data([2]), support(p).appendingPathComponent("models/existing.bin"))
        try write(Data([3]), support(p).appendingPathComponent("models/missing.bin"))
        try p.migrate()
        XCTAssertEqual(try Data(contentsOf: p.settings), settings)
        XCTAssertEqual(try Data(contentsOf: p.history), history)
        XCTAssertEqual(try Data(contentsOf: p.models.appendingPathComponent("existing.bin")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: p.models.appendingPathComponent("missing.bin")), Data([3]))
    }

    func testEmptyLegacyHistoryMigratesWithoutReplacingOriginal() throws {
        let p = paths()
        let source = support(p).appendingPathComponent("transcription_history.json")
        try write(Data(), source)
        try p.migrate()
        XCTAssertTrue(try Data(contentsOf: source).isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionHistory.self, from: Data(contentsOf: p.history)), TranscriptionHistory())
        XCTAssertTrue(fm.fileExists(atPath: p.data.appendingPathComponent(".unsandbox-migration-v1").path))
    }

    func testInterruptedMigrationRetriesWithoutOverwritingPublishedSettings() throws {
        let p = paths()
        try write(Data("{}".utf8), support(p).appendingPathComponent("hex_settings.json"))
        let legacyHistory = support(p).appendingPathComponent("transcription_history.json")
        try write(Data("incomplete".utf8), legacyHistory)
        XCTAssertThrowsError(try p.migrate())
        XCTAssertFalse(fm.fileExists(atPath: p.history.path))
        XCTAssertFalse(fm.fileExists(atPath: p.data.appendingPathComponent(".unsandbox-migration-v1").path))
        try write(Data("{\"soundEffectsEnabled\":false}".utf8), p.settings)
        try write(JSONEncoder().encode(TranscriptionHistory()), legacyHistory)
        try p.migrate()
        XCTAssertFalse(try JSONDecoder().decode(HexSettings.self, from: Data(contentsOf: p.settings)).soundEffectsEnabled)
        XCTAssertTrue(fm.fileExists(atPath: p.history.path))
    }

    func testLegacyDocumentsAndPreContainerApplicationSupport() throws {
        let p = paths()
        let docs = home.appendingPathComponent("Documents")
        try write(Data("{}".utf8), docs.appendingPathComponent("hex_settings.json"))
        let audio = docs.appendingPathComponent("old.wav")
        try write(Data([8]), audio)
        let transcript = Transcript(timestamp: Date(), text: "fixture", audioPath: audio, duration: 1)
        try write(JSONEncoder().encode(TranscriptionHistory(history: [transcript])), p.data.appendingPathComponent("transcription_history.json"))
        try p.migrate()
        let entry = try JSONDecoder().decode(TranscriptionHistory.self, from: Data(contentsOf: p.history)).history[0]
        XCTAssertTrue(entry.audioPath.path.hasPrefix(p.recordings.path + "/imported/"))
        XCTAssertEqual(try Data(contentsOf: entry.audioPath), Data([8]))
        XCTAssertTrue(fm.fileExists(atPath: audio.path))
    }

    func testCaseInsensitiveRecordingAliasDoesNotRecurse() throws {
        let p = paths()
        let audio = p.data.appendingPathComponent("Recordings/old.wav")
        try write(Data([9]), audio)
        let entry = Transcript(timestamp: Date(), text: "fixture", audioPath: audio, duration: 1)
        try write(JSONEncoder().encode(TranscriptionHistory(history: [entry])), p.data.appendingPathComponent("transcription_history.json"))
        try p.migrate()
        let migrated = try JSONDecoder().decode(TranscriptionHistory.self, from: Data(contentsOf: p.history)).history[0]
        XCTAssertEqual(try Data(contentsOf: migrated.audioPath), Data([9]))
        XCTAssertFalse(fm.fileExists(atPath: p.recordings.appendingPathComponent("legacy-0/legacy-0").path))
    }

    func testUnreadableLegacySettingsDoNotMarkMigrationComplete() throws {
        let p = paths()
        let source = support(p).appendingPathComponent("hex_settings.json")
        try write(Data("{}".utf8), source)
        XCTAssertThrowsError(try p.migrate(fileManager: DeniedLegacyFileManager()))
        XCTAssertFalse(fm.fileExists(atPath: p.settings.path))
        XCTAssertFalse(fm.fileExists(atPath: p.data.appendingPathComponent(".unsandbox-migration-v1").path))
        try p.migrate()
        XCTAssertEqual(try Data(contentsOf: p.settings), Data("{}".utf8))
    }

    func testFailedFileCopyNeverPublishesPartialModelAndCanRetry() throws {
        let p = paths()
        let source = support(p).appendingPathComponent("models/model.bin")
        try write(Data([1, 2, 3]), source)
        XCTAssertThrowsError(try p.migrate(fileManager: InterruptedCopyFileManager()))
        let destination = p.models.appendingPathComponent("model.bin")
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: p.models.path).isEmpty)
        try p.migrate()
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
    }

    func testSymlinkCopiesPreserveLinkWithoutTraversingTargetDirectory() throws {
        let p = paths()
        let target = home.appendingPathComponent("outside-models")
        try write(Data([1]), target.appendingPathComponent("weights.bin"))
        let link = support(p).appendingPathComponent("models/linked")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        try p.migrate()
        let copiedLink = p.models.appendingPathComponent("linked")
        XCTAssertTrue(try copiedLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: copiedLink.path), target.path)
    }

    func testDebugImportsOnlyItsOwnContainerAndRetainsMissingAudioReferences() throws {
        let debug = paths("com.salishdev.Hex.debug")
        try write(Data("{\"soundEffectsEnabled\":false}".utf8), home.appendingPathComponent("Documents/hex_settings.json"))
        try write(Data("{}".utf8), support(paths()).appendingPathComponent("hex_settings.json"))
        try debug.migrate()
        XCTAssertFalse(fm.fileExists(atPath: debug.settings.path))
        // A separate overridden identity can still import its own legacy Documents.
        let fork = paths("org.example.Hex.debug")
        try write(Data("{}".utf8), fork.container.appendingPathComponent("Documents/hex_settings.json"))
        let missing = home.appendingPathComponent("missing.wav")
        let entry = Transcript(timestamp: Date(), text: "fixture", audioPath: missing, duration: 1)
        try write(JSONEncoder().encode(TranscriptionHistory(history: [entry])), support(fork).appendingPathComponent("transcription_history.json"))
        try fork.migrate()
        XCTAssertTrue(fm.fileExists(atPath: fork.settings.path))
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionHistory.self, from: Data(contentsOf: fork.history)).history[0].audioPath, missing)
    }
}

private final class InterruptedCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try Data([0]).write(to: dstURL)
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

private final class DeniedLegacyFileManager: FileManager, @unchecked Sendable {
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path.contains("/Containers/") && path.hasSuffix("hex_settings.json") {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
    }
}
