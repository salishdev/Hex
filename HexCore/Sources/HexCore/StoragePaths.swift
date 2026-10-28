import IssueReporting
import Foundation

/// Explicit roots keep Debug and identity overrides out of the release app's data.
public struct HexStoragePaths: Sendable {
    public let home: URL
    public let bundleID: String
    public let config: URL
    public var data: URL { home.appendingPathComponent("Library/Application Support/\(bundleID)") }
    public var caches: URL { home.appendingPathComponent("Library/Caches/\(bundleID)") }
    public var modes: URL { config.appendingPathComponent("modes") }
    public var scripts: URL { config.appendingPathComponent("scripts") }
    public var settings: URL { config.appendingPathComponent("settings.json") }
    public var history: URL { data.appendingPathComponent("history/transcription_history.json") }
    public var recordings: URL { data.appendingPathComponent("recordings") }
    public var models: URL { data.appendingPathComponent("models") }
    public var parakeetModels: URL { models.appendingPathComponent("FluidAudio") }
    public var container: URL { home.appendingPathComponent("Library/Containers/\(bundleID)/Data") }

    public init(home: URL, bundleID: String, environment: [String: String] = [:], configName: String? = nil) {
        self.home = home
        self.bundleID = bundleID
        let xdg = environment["XDG_CONFIG_HOME"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        } ?? home.appendingPathComponent(".config")
        // Only the canonical fork identity uses the short name by default.
        let name = configName ?? (bundleID == "com.salishdev.Hex" ? "hex" :
            bundleID == "com.salishdev.Hex.debug" ? "hex-debug" : bundleID)
        self.config = xdg.appendingPathComponent(name)
    }

    /// Copy-only, restartable migration. Completion is recorded only after every copy
    /// succeeds. Existing destinations always win; originals remain available for rollback.
    public func migrate(fileManager fm: FileManager = .default) throws {
        let marker = data.appendingPathComponent(".unsandbox-migration-v1")
        for directory in [config, data, caches, history.deletingLastPathComponent(), recordings, models] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard !(try exists(marker, fileManager: fm)) else { return }
        let support = container.appendingPathComponent("Library/Application Support")
        var sources = [data, support.appendingPathComponent(bundleID), container.appendingPathComponent("Documents")]
        // Unscoped Documents belonged to pre-container release builds. Importing it
        // into Debug or a fork would silently mix identities.
        if bundleID == "com.salishdev.Hex" { sources.append(home.appendingPathComponent("Documents")) }

        if !(try exists(settings, fileManager: fm)),
           let source = try sources.map({ $0.appendingPathComponent("hex_settings.json") }).first(where: { try exists($0, fileManager: fm) }) {
            // Validate before publishing, but preserve the original JSON and unknown keys.
            let bytes = try Data(contentsOf: source)
            _ = try JSONDecoder().decode(HexSettings.self, from: bytes)
            try publish(bytes, to: settings, fileManager: fm)
        }
        // Keep orphaned recordings too. Stable namespaces prevent filename collisions.
        for (index, source) in sources.enumerated() {
            let oldRecordings = source.appendingPathComponent("Recordings")
            if !sameItem(oldRecordings, recordings) {
                try merge(oldRecordings, into: recordings.appendingPathComponent("legacy-\(index)"), fileManager: fm)
            }
        }
        if !(try exists(history, fileManager: fm)),
           let source = try sources.map({ $0.appendingPathComponent("transcription_history.json") }).first(where: { try exists($0, fileManager: fm) }) {
            let original = try Data(contentsOf: source)
            // File-backed history can exist as a zero-byte file before its first
            // entry. There is no history to recover, but preserve that original
            // and publish a valid empty history in the new layout. Nonempty,
            // malformed files still stop migration rather than losing entries.
            let bytes = original.isEmpty ? try JSONEncoder().encode(TranscriptionHistory()) : original
            let decoded = try JSONDecoder().decode(TranscriptionHistory.self, from: bytes)
            var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            var entries = json["history"] as! [[String: Any]]
            for (index, transcript) in decoded.history.enumerated() {
                guard let audio = transcript.audioPath, audio.isFileURL, try exists(audio, fileManager: fm) else { continue }
                var destination = recordings.appendingPathComponent("imported/\(transcript.id.uuidString).\(audio.pathExtension.isEmpty ? "wav" : audio.pathExtension)")
                for (sourceIndex, root) in sources.enumerated() {
                    let prefix = root.appendingPathComponent("Recordings").standardizedFileURL.path + "/"
                    if audio.standardizedFileURL.path.hasPrefix(prefix) {
                        let oldRecordings = root.appendingPathComponent("Recordings")
                        let targetRoot = sameItem(oldRecordings, recordings) ? recordings :
                            recordings.appendingPathComponent("legacy-\(sourceIndex)")
                        destination = targetRoot.appendingPathComponent(String(audio.standardizedFileURL.path.dropFirst(prefix.count)))
                        break
                    }
                }
                try merge(audio, into: destination, fileManager: fm)
                if try exists(destination, fileManager: fm) {
                    entries[index]["audioPath"] = destination.absoluteString
                }
            }
            json["history"] = entries
            try publish(JSONSerialization.data(withJSONObject: json), to: history, fileManager: fm)
        }
        // WhisperKit's installed layout is unchanged beneath models/.
        try merge(support.appendingPathComponent("\(bundleID)/models"), into: models, fileManager: fm)
        // FluidAudio accepts an explicit parent, but requires its own repo folder names.
        var fluidRoots = [support.appendingPathComponent("FluidAudio/Models"),
                          support.appendingPathComponent("fluidaudio/Models"),
                          container.appendingPathComponent(".cache/fluidaudio/Models"),
                          data.appendingPathComponent("cache/fluidaudio/Models"),
                          data.appendingPathComponent("cache/FluidAudio/Models"),
                          support.appendingPathComponent("\(bundleID)/cache/fluidaudio/Models"),
                          support.appendingPathComponent("\(bundleID)/cache/FluidAudio/Models")]
        if bundleID == "com.salishdev.Hex" {
            fluidRoots += [home.appendingPathComponent("Library/Application Support/FluidAudio/Models"),
                           home.appendingPathComponent(".cache/fluidaudio/Models")]
        }
        for root in fluidRoots { try merge(root, into: parakeetModels, fileManager: fm) }
        try publish(Data(), to: marker, fileManager: fm)
    }

    /// Missing sources are normal; unreadable sources must stop migration so a
    /// privacy denial or filesystem failure cannot be mistaken for a fresh install.
    private func exists(_ url: URL, fileManager fm: FileManager) throws -> Bool {
        do {
            _ = try fm.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return false
        }
    }

    private func publish(_ bytes: Data, to destination: URL, fileManager fm: FileManager) throws {
        guard !(try exists(destination, fileManager: fm)) else { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A sibling staging file plus rename never exposes partial JSON or model files.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".hex-migration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try bytes.write(to: staging)
        try fm.moveItem(at: staging, to: destination)
    }

    private func sameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
              let right = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject else { return false }
        return left == right
    }

    private func merge(_ source: URL, into destination: URL, fileManager fm: FileManager) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              try exists(source, fileManager: fm) else { return }
        // APFS commonly treats Recordings and recordings as the same directory.
        // Also refuse any copy into a descendant of its source.
        var ancestor = destination
        while ancestor.path != "/" {
            if sameItem(source, ancestor) { return }
            ancestor.deleteLastPathComponent()
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        // Copy symlinks themselves; never traverse them out of a legacy tree.
        if values.isDirectory == true && values.isSymbolicLink != true {
            if try exists(destination, fileManager: fm),
               (try destination.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true { return }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try merge(child, into: destination.appendingPathComponent(child.lastPathComponent), fileManager: fm)
            }
        } else if !(try exists(destination, fileManager: fm)) {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".hex-migration-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            try fm.moveItem(at: staging, to: destination)
        }
    }

    public static let live: HexStoragePaths = {
        let paths = HexStoragePaths(
            // Hosted app tests must never migrate or read the developer's data.
            home: isTesting ? FileManager.default.temporaryDirectory.appendingPathComponent("hex-tests-\(UUID().uuidString)") : FileManager.default.homeDirectoryForCurrentUser,
            bundleID: Bundle.main.bundleIdentifier ?? "com.salishdev.Hex",
            environment: isTesting ? [:] : ProcessInfo.processInfo.environment,
            configName: Bundle.main.object(forInfoDictionaryKey: "HexConfigDirectoryName") as? String
        )
        do { try paths.migrate() }
        catch {
            HexLog.caches.error("Storage migration failed; originals retained: \(error.localizedDescription, privacy: .private)")
            // Never let file-backed defaults overwrite data after a failed migration.
            fatalError("Hex could not prepare storage. Check filesystem access and free disk space, then relaunch.")
        }
        return paths
    }()
}

public extension URL {
    static var hexApplicationSupport: URL { get throws { HexStoragePaths.live.data } }
    static var hexModelsDirectory: URL { get throws { HexStoragePaths.live.models } }
    static var hexParakeetModelsDirectory: URL { get throws { HexStoragePaths.live.parakeetModels } }
    static var hexCachesDirectory: URL { HexStoragePaths.live.caches }
}

public extension FileManager {
    func removeItemIfExists(at url: URL) {
        guard fileExists(atPath: url.path) else { return }
        try? removeItem(at: url)
    }
}
