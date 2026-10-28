import Foundation

public struct Transcript: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var text: String
    /// Nil when the recording was not kept.
    public var audioPath: URL?
    public var duration: TimeInterval
    public var sourceAppBundleID: String?
    public var sourceAppName: String?
    public var originalText: String?
    public var processorInput: String?
    public var modeID: String?
    public var modeName: String?
    public var processingOutcome: String?
    public var processingRequest: TextProcessorRequest?
    public var finalFormatting: FinalFormatting?
    public var isUsableOutput: Bool { processingOutcome != "failed" && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    
    public init(
        id: UUID = UUID(),
        timestamp: Date,
        text: String,
        audioPath: URL?,
        duration: TimeInterval,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.audioPath = audioPath
        self.duration = duration
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
    }
}

public struct TranscriptionHistory: Codable, Equatable, Sendable {
    public var history: [Transcript] = []
    
    public init(history: [Transcript] = []) {
        self.history = history
    }
}
