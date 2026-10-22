import Foundation

public struct FinalFormatting: Codable, Equatable, Sendable {
    public var lowercase: Bool?
    public var removePunctuation: Bool?
    public init(lowercase: Bool? = nil, removePunctuation: Bool? = nil) {
        self.lowercase = lowercase; self.removePunctuation = removePunctuation
    }
}

public struct TranscriptionMode: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var name: String
    public var processorID: String?
    public var formatting: FinalFormatting
    public init(id: String = UUID().uuidString, name: String, processorID: String? = nil, formatting: FinalFormatting = .init()) {
        self.id = id; self.name = name; self.processorID = processorID; self.formatting = formatting
    }
    public static let dictation = Self(id: "dictation", name: "Dictation")
    public func validate() throws {
        guard schemaVersion == 1, ModeConfigurationStore.validID(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              processorID.map(ModeConfigurationStore.validID) ?? true else { throw ModeConfigurationError.invalid("Invalid mode configuration") }
    }
}

public struct ProcessorConfiguration: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var usesModeInstructions: Bool
    public var timeout: Double
    public init(id: String = UUID().uuidString, name: String = "New processor", executable: String = "", arguments: [String] = [], workingDirectory: String? = nil, usesModeInstructions: Bool = true, timeout: Double = 30) {
        self.id = id; self.name = name; self.executable = executable; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.usesModeInstructions = usesModeInstructions; self.timeout = timeout
    }
    public func validate() throws {
        guard schemaVersion == 1, ModeConfigurationStore.validID(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              executable.hasPrefix("/"), !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }),
              workingDirectory.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true,
              timeout.isFinite, (1...300).contains(timeout) else { throw ModeConfigurationError.invalid("Use an absolute executable/working directory and a timeout from 1 to 300 seconds") }
    }
    public func validateFiles() throws {
        try validate()
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw ModeConfigurationError.invalid("Executable is missing or is not executable") }
        if let workingDirectory {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &directory), directory.boolValue else { throw ModeConfigurationError.invalid("Working directory is missing") }
        }
    }
}

public struct ModeDocument: Equatable, Sendable, Identifiable {
    public var mode: TranscriptionMode
    public var prompt: String
    public var id: String { mode.id }
    public init(mode: TranscriptionMode, prompt: String = "") { self.mode = mode; self.prompt = prompt }
}

public struct ModeLibrary: Equatable, Sendable {
    public var modes: [ModeDocument] = [.init(mode: .dictation)]
    public var processors: [ProcessorConfiguration] = []
    public var problems: [String] = []
    public init() {}
    public func processor(for mode: TranscriptionMode) -> ProcessorConfiguration? { processors.first { $0.id == mode.processorID } }
    public func available(_ mode: TranscriptionMode) -> Bool { mode.processorID == nil || processor(for: mode) != nil }
}

public enum ModeConfigurationError: LocalizedError {
    case invalid(String), conflict
    public var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case .conflict: return "This file changed outside Hex. Reload or Keep my edits before saving."
        }
    }
}

/// Each file is published atomically. Revision checks cover both mode.json and prompt.md.
/// Invalid external files remain on disk and are reported, never rewritten on load.
public struct ModeConfigurationStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    public func modeDirectory(_ id: String) -> URL { root.appendingPathComponent("modes/\(id)") }
    public func processorURL(_ id: String) -> URL { root.appendingPathComponent("processors/\(id).json") }
    public func revision(modeID: String) -> [Data?] {
        ["mode.json", "prompt.md"].map { try? Data(contentsOf: modeDirectory(modeID).appendingPathComponent($0)) }
    }
    public func processorRevision(_ id: String) -> Data? { try? Data(contentsOf: processorURL(id)) }
    public func load() throws -> ModeLibrary {
        let fm = FileManager.default
        for folder in ["modes", "processors", "scripts"] { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let initial = modeDirectory("dictation")
        if !fm.fileExists(atPath: initial.path) { try save(.init(mode: .dictation)) }
        var library = ModeLibrary(); library.modes = []
        for url in try fm.contentsOfDirectory(at: root.appendingPathComponent("modes"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            do {
                let mode = try JSONDecoder().decode(TranscriptionMode.self, from: Data(contentsOf: url.appendingPathComponent("mode.json")))
                try mode.validate()
                guard mode.id == url.lastPathComponent else { throw ModeConfigurationError.invalid("Mode ID differs from its directory") }
                let prompt = try String(contentsOf: url.appendingPathComponent("prompt.md"), encoding: .utf8)
                library.modes.append(.init(mode: mode, prompt: prompt))
            } catch { library.problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        for url in try fm.contentsOfDirectory(at: root.appendingPathComponent("processors"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles) where url.pathExtension == "json" {
            do {
                let processor = try JSONDecoder().decode(ProcessorConfiguration.self, from: Data(contentsOf: url))
                try processor.validateFiles()
                guard processor.id == url.deletingPathExtension().lastPathComponent else { throw ModeConfigurationError.invalid("Processor ID differs from its filename") }
                library.processors.append(processor)
            } catch { library.problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        // Always retain a usable, in-memory escape hatch without replacing broken user files.
        if !library.modes.contains(where: { $0.id == "dictation" }) { library.modes.append(.init(mode: .dictation)) }
        library.modes.sort { $0.id == "dictation" || ($1.id != "dictation" && $0.mode.name.localizedStandardCompare($1.mode.name) == .orderedAscending) }
        return library
    }
    public func save(_ document: ModeDocument, expectedRevision: [Data?]? = nil) throws {
        try document.mode.validate()
        if let expectedRevision, expectedRevision != revision(modeID: document.id) { throw ModeConfigurationError.conflict }
        let directory = modeDirectory(document.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(document.prompt.utf8).write(to: directory.appendingPathComponent("prompt.md"), options: .atomic)
        try encode(document.mode).write(to: directory.appendingPathComponent("mode.json"), options: .atomic)
    }
    public func save(_ processor: ProcessorConfiguration, expectedRevision: Data? = nil, checkRevision: Bool = false) throws {
        try processor.validateFiles()
        if checkRevision, expectedRevision != processorRevision(processor.id) { throw ModeConfigurationError.conflict }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("processors"), withIntermediateDirectories: true)
        try encode(processor).write(to: processorURL(processor.id), options: .atomic)
    }
    public func deleteMode(_ id: String) throws {
        guard Self.validID(id), id != "dictation" else { throw ModeConfigurationError.invalid("Dictation cannot be deleted") }
        try FileManager.default.removeItem(at: modeDirectory(id))
    }
    public func deleteProcessor(_ id: String) throws {
        guard Self.validID(id), !(try load()).modes.contains(where: { $0.mode.processorID == id }) else { throw ModeConfigurationError.invalid("Detach or reassign this processor's modes first") }
        try FileManager.default.removeItem(at: processorURL(id))
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
