import FluidAudio
import HexCore
import XCTest

@testable import Hex

final class ParakeetStorageTests: XCTestCase {
  func testExplicitInstalledPathsRecognizeBothVersionsAndDeleteOnlyInstalledCopy() async throws {
    let paths = HexStoragePaths.live
    // This guard makes an accidental loss of hosted-test isolation fail before any write.
    XCTAssertTrue(paths.home.lastPathComponent.hasPrefix("hex-tests-"))
    guard paths.home.lastPathComponent.hasPrefix("hex-tests-") else { return }
    XCTAssertTrue(paths.config.path.hasPrefix(paths.home.path + "/"))
    let fm = FileManager.default
    let client = ParakeetClient()
    for (variant, version) in [(ParakeetModel.englishV2, AsrModelVersion.v2), (.multilingualV3, .v3)] {
      let installed = paths.parakeetModels.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent)
      let legacyName = paths.parakeetModels.appendingPathComponent(variant.identifier)
      defer { try? fm.removeItem(at: installed); try? fm.removeItem(at: legacyName) }
      // Synthetic filenames exercise FluidAudio's own availability check without
      // downloading models or trying to load invalid Core ML data.
      let names = ModelNames.ASR.requiredModels
        .union(ModelNames.ASR.requiredModelsFused)
        .union(ModelNames.ASR.requiredModelsV3())
        .union([ModelNames.ASR.vocabularyFile])
      try fm.createDirectory(at: legacyName, withIntermediateDirectories: true)
      for name in names { try Data().write(to: legacyName.appendingPathComponent(name)) }
      let available = await client.isModelAvailable(variant.identifier)
      XCTAssertTrue(available)
      XCTAssertTrue(AsrModels.modelsExist(at: installed, version: version))
      XCTAssertTrue(installed.path.hasPrefix(paths.models.path + "/"))
      let original = paths.container.appendingPathComponent("Library/Application Support/FluidAudio/Models/\(variant.identifier)")
      try fm.createDirectory(at: original, withIntermediateDirectories: true)
      try await client.deleteCaches(modelName: variant.identifier)
      XCTAssertFalse(fm.fileExists(atPath: installed.path))
      XCTAssertTrue(fm.fileExists(atPath: original.path))
      let afterDeletion = await client.isModelAvailable(variant.identifier)
      XCTAssertFalse(afterDeletion)
    }
  }
}
