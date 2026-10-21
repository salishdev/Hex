import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

actor ParakeetClient {
  private var asr: AsrManager?
  private var models: AsrModels?
  private var currentVariant: ParakeetModel?
  private let logger = HexLog.parakeet
  private func modelDirectory(_ variant: ParakeetModel) throws -> URL {
    try URL.hexParakeetModelsDirectory.appendingPathComponent(
      AsrModels.defaultCacheDirectory(for: variant.asrVersion).lastPathComponent,
      isDirectory: true
    )
  }

  func isModelAvailable(_ modelName: String) async -> Bool {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      logger.error("Unknown Parakeet variant requested: \(modelName)")
      return false
    }
    if currentVariant == variant, asr != nil { return true }

    guard let directory = try? modelDirectory(variant) else { return false }
    migrateLegacyCacheIfNeeded(variant, to: directory)
    let available = AsrModels.modelsExist(
      at: directory,
      version: variant.asrVersion
    )
    if available {
      logger.notice("Found Parakeet cache at \(directory.path, privacy: .private)")
    } else {
      logger.debug("No Parakeet cache detected variant=\(variant.identifier) path=\(directory.path, privacy: .private)")
    }
    return available
  }

  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else {
      throw NSError(
        domain: "Parakeet",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Parakeet variant: \(modelName)"]
      )
    }
    if currentVariant == variant, asr != nil { return }
    if currentVariant != variant {
      asr = nil
      models = nil
    }
    let directory = try modelDirectory(variant)
    migrateLegacyCacheIfNeeded(variant, to: directory)
    let t0 = Date()
    logger.notice("Starting Parakeet load variant=\(variant.identifier)")
    let p = Progress(totalUnitCount: 100)
    p.completedUnitCount = 1
    progress(p)

    // Best-effort progress polling while FluidAudio downloads
    let faDir = directory
    let pollTask = Task {
      while p.completedUnitCount < 95 {
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let size = directorySize(faDir) {
          let target: Double = 650 * 1024 * 1024 // ~650MB
          let frac = max(0.0, min(1.0, Double(size) / target))
          p.completedUnitCount = Int64(5 + frac * 90)
          progress(p)
        }
        if Task.isCancelled { break }
      }
    }
    defer { pollTask.cancel() }

    // Download + load the requested variant (returns when all assets are present)
    let models = try await AsrModels.downloadAndLoad(to: directory, version: variant.asrVersion)
    self.models = models
    let manager = AsrManager(config: .init(), models: models)
    self.asr = manager
    self.currentVariant = variant
    p.completedUnitCount = 100
    progress(p)
    logger.notice("Parakeet ensureLoaded completed in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
  }

  private func directorySize(_ dir: URL) -> UInt64? {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: .skipsHiddenFiles) else { return nil }
    var total: UInt64 = 0
    for case let url as URL in en {
      if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
        total &+= UInt64(vals.fileSize ?? 0)
      }
    }
    return total
  }

  private func migrateLegacyCacheIfNeeded(_ variant: ParakeetModel, to directory: URL) {
    let legacyDirectory = directory
      .deletingLastPathComponent()
      .appendingPathComponent(variant.identifier, isDirectory: true)

    do {
      if try LegacyModelCacheMigrator.migrate(
        from: legacyDirectory,
        to: directory,
        isValid: {
          AsrModels.modelsExist(at: $0, version: variant.asrVersion)
        }
      ) {
        logger.notice("Migrated legacy Parakeet cache from \(legacyDirectory.path, privacy: .private) to \(directory.path, privacy: .private)")
      }
    } catch {
      logger.error("Failed to migrate legacy Parakeet cache: \(error.localizedDescription, privacy: .private)")
    }
  }

  func transcribe(_ url: URL) async throws -> String {
    guard let asr else { throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet not initialized"]) }
    let t0 = Date()
    logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent, privacy: .private)")
    var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
    let result = try await asr.transcribe(url, decoderState: &decoderState)
    logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    return result.text
  }

  // Delete cached Parakeet models from known locations and reset state
  func deleteCaches(modelName: String) async throws {
    guard let variant = ParakeetModel(rawValue: modelName) else { return }
    let fm = FileManager.default

    let directory = try modelDirectory(variant)
    if fm.fileExists(atPath: directory.path) {
      try fm.removeItem(at: directory)
    }
    // Only this identity's installed model is deleted. Legacy originals stay intact.
    self.asr = nil
    self.models = nil
    self.currentVariant = nil
  }

}

private extension ParakeetModel {
  var asrVersion: AsrModelVersion {
    switch self {
    case .englishV2: return .v2
    case .multilingualV3: return .v3
    }
  }
}

#else

actor ParakeetClient {
  func isModelAvailable(_ modelName: String) async -> Bool { false }
  func ensureLoaded(modelName: String, progress: @escaping (Progress) -> Void) async throws {
    throw NSError(
      domain: "Parakeet",
      code: -2,
      userInfo: [NSLocalizedDescriptionKey: "Parakeet support not linked. Add Swift Package: https://github.com/FluidInference/FluidAudio.git and link FluidAudio to Hex."]
    )
  }
  func transcribe(_ url: URL) async throws -> String { throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "Parakeet not available"]) }
  func deleteCaches(modelName: String) async throws {}
}

#endif
