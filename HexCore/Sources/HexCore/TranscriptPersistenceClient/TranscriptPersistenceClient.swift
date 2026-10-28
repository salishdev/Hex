import Dependencies
import Foundation

public struct TranscriptPersistenceClient: Sendable {
    public var save: @Sendable (
        _ result: String,
        _ audioURL: URL?, // nil saves the transcript without audio
        _ duration: TimeInterval,
        _ sourceAppBundleID: String?,
        _ sourceAppName: String?
    ) async throws -> Transcript
    
    public var deleteAudio: @Sendable (_ transcript: Transcript) async throws -> Void
}

extension TranscriptPersistenceClient: DependencyKey {
    public static let liveValue: TranscriptPersistenceClient = {
        return TranscriptPersistenceClient(
            save: { result, audioURL, duration, sourceAppBundleID, sourceAppName in
                var finalURL: URL?
                if let audioURL {
                    let fm = FileManager.default
                    let recordingsFolder = HexStoragePaths.live.recordings
                    try fm.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
                    let destination = recordingsFolder.appendingPathComponent("\(UUID().uuidString).wav")
                    try fm.copyItem(at: audioURL, to: destination)
                    finalURL = destination
                }
                
                return Transcript(
                    timestamp: Date(),
                    text: result,
                    audioPath: finalURL,
                    duration: duration,
                    sourceAppBundleID: sourceAppBundleID,
                    sourceAppName: sourceAppName
                )
            },
            deleteAudio: { transcript in
                if let audio = transcript.audioPath { FileManager.default.removeItemIfExists(at: audio) }
            }
        )
    }()
    
    public static let testValue = TranscriptPersistenceClient(
        save: { _, _, _, _, _ in
            Transcript(timestamp: Date(), text: "", audioPath: URL(fileURLWithPath: "/"), duration: 0)
        },
        deleteAudio: { _ in }
    )
}

public extension DependencyValues {
    var transcriptPersistence: TranscriptPersistenceClient {
        get { self[TranscriptPersistenceClient.self] }
        set { self[TranscriptPersistenceClient.self] = newValue }
    }
}
