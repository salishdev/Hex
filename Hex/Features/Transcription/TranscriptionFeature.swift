//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

struct RecordingSnapshot: Equatable, Sendable {
  var id: UUID
  var mode: ModeDocument
  var processor: ProcessorConfiguration?
  var settings: HexSettings
  var scratchpad: Bool
}

/// The original temporary recording has one owner, including while effects are cancelled.
final class RecordingArtifact: @unchecked Sendable, Equatable {
  let url: URL
  let temporary: Bool
  init(_ url: URL, temporary: Bool = true) { self.url = url; self.temporary = temporary }
  deinit { if temporary { FileManager.default.removeItemIfExists(at: url) } }
  static func == (lhs: RecordingArtifact, rhs: RecordingArtifact) -> Bool { lhs === rhs }
}

struct RecoveryResult: Equatable {
  var transcript: Transcript
  var artifact: RecordingArtifact
  var persisted = false
  var published = false
  var failure: String?
  var diagnostics = ""
}

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State: Equatable {
    var session: RecordingSnapshot?
    var phase = "idle"
    var recovery: RecoveryResult?
    @Shared(.modeLibrary) var modeLibrary: ModeLibrary
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case historyDisabled
    case task
    case sessionTranscript(UUID, String, RecordingArtifact, TimeInterval)
    case sessionError(UUID, String)
    case processed(UUID, String?, TextProcessorFailure?)
    case persisted(UUID, Transcript, Bool)
    case deliver(UUID, Bool)
    case delivered(UUID, Bool)
    case retryHistorical(Transcript)
    case retry, copyOriginal, pasteOriginal, copyResult, pasteResult, dismissResult
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
  }

  @Dependency(\.uuid) var uuid
  @Dependency(\.textProcessor) var textProcessor
  @Dependency(\.transcription) var transcription
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .historyDisabled:
        state.session?.settings.saveTranscriptionHistory = false
        if var recovery = state.recovery {
          let cleanup = cleanupUnpublished(recovery)
          recovery.persisted = false; recovery.published = false; recovery.transcript.audioPath = recovery.artifact.url
          state.recovery = recovery
          return cleanup
        }
        return .none

      case .task:
        // Starts two concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect()
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .sessionTranscript(id, text, artifact, duration):
        guard state.session?.id == id else { return .none }
        return acceptTranscript(&state, result: text, artifact: artifact, duration: duration)

      case let .sessionError(id, message):
        guard state.session?.id == id else { return .none }
        state.error = message; state.isTranscribing = false; state.isPrewarming = false
        if state.recovery != nil { state.recovery?.failure = message; state.phase = "failed" }
        else { state.phase = "idle"; state.session = nil }
        return .none

      case let .processed(id, output, failure):
        guard let snapshot = state.session, snapshot.id == id, var recovery = state.recovery else { return .none }
        recovery.failure = failure?.reason; recovery.diagnostics = failure?.diagnostics ?? ""
        if let output {
          recovery.transcript.text = snapshot.scratchpad ? output : TranscriptFormattingApplier.apply(output,
            lowercase: snapshot.mode.mode.formatting.lowercase ?? snapshot.settings.lowercaseTranscripts,
            removePunctuation: snapshot.mode.mode.formatting.removePunctuation ?? snapshot.settings.removePunctuation)
          recovery.transcript.processingOutcome = "succeeded"
        } else {
          recovery.transcript.text = ""; recovery.transcript.processingOutcome = "failed"
        }
        if output != nil && snapshot.processor != nil && recovery.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          recovery.failure = "Final formatting produced empty output"; recovery.transcript.processingOutcome = "failed"
        }
        if output != nil && recovery.transcript.text.isEmpty && snapshot.processor == nil {
          state.recovery = nil; state.session = nil; state.phase = "idle"; state.isTranscribing = false
          return .none
        }
        state.recovery = recovery; state.phase = "saving"
        if snapshot.settings.saveTranscriptionHistory && state.hexSettings.saveTranscriptionHistory && !recovery.persisted {
          return .run { [recovery] send in
            do {
              var stored = try await transcriptPersistence.save(recovery.transcript.text, recovery.artifact.url, recovery.transcript.duration, recovery.transcript.sourceAppBundleID, recovery.transcript.sourceAppName)
              stored.originalText = recovery.transcript.originalText; stored.processorInput = recovery.transcript.processorInput
              stored.modeID = recovery.transcript.modeID; stored.modeName = recovery.transcript.modeName
              stored.processingOutcome = recovery.transcript.processingOutcome; stored.processingRequest = recovery.transcript.processingRequest
              stored.finalFormatting = recovery.transcript.finalFormatting
              if Task.isCancelled { try? await transcriptPersistence.deleteAudio(stored); return }
              await send(.persisted(id, stored, true))
            } catch { await send(.sessionError(id, "Could not save recording: " + error.localizedDescription)) }
          }.cancellable(id: CancelID.transcription)
        }
        return .send(.persisted(id, recovery.transcript, false))

      case let .persisted(id, transcript, newlySaved):
        guard state.session?.id == id, var recovery = state.recovery else {
          return newlySaved ? .run { _ in try? await transcriptPersistence.deleteAudio(transcript) } : .none
        }
        var stored = transcript
        let historyEnabled = state.hexSettings.saveTranscriptionHistory && state.session?.settings.saveTranscriptionHistory == true
        let justSaved = newlySaved
        if justSaved && !historyEnabled {
          let audio = stored
          Task { try? await transcriptPersistence.deleteAudio(audio) }
          stored.audioPath = recovery.artifact.url
        }
        recovery.transcript = stored
        recovery.persisted = historyEnabled && (justSaved || recovery.persisted)
        state.recovery = recovery
        if let failure = recovery.failure {
          state.error = failure; state.isTranscribing = false; state.isPrewarming = false; state.phase = "failed"
          return publishHistory(&state)
        }
        state.phase = "delivering"
        return .send(.deliver(id, false))

      case let .deliver(id, explicit):
        guard state.session?.id == id, let recovery = state.recovery else { return .none }
        return .run { send in
          try Task.checkCancellation()
          let allowed = await MainActor.run { explicit || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == recovery.transcript.sourceAppBundleID }
          guard allowed else { await send(.delivered(id, false)); return }
          try Task.checkCancellation()
          let pasted: Bool
          if explicit { await pasteboard.paste(recovery.transcript.text); pasted = true }
          else { pasted = await pasteboard.pasteGuarded(recovery.transcript.text, recovery.transcript.sourceAppBundleID) }
          try Task.checkCancellation()
          await send(.delivered(id, pasted))
        }.cancellable(id: CancelID.transcription)

      case let .delivered(id, pasted):
        guard state.session?.id == id else { return .none }
        state.isTranscribing = false; state.isPrewarming = false; state.phase = pasted ? "idle" : "ready"
        let cleanup = publishHistory(&state)
        if pasted { state.recovery = nil; state.session = nil }
        return pasted ? .merge(cleanup, .run { _ in soundEffect.play(.pasteTranscript) }) : cleanup

      case let .retryHistorical(transcript):
        guard !state.isRecording && !state.isTranscribing, transcript.processingRequest != nil else { return .none }
        state.recovery = .init(transcript: transcript, artifact: RecordingArtifact(transcript.audioPath, temporary: false), persisted: true, published: true)
        return .send(.retry)

      case .retry:
        guard !state.isTranscribing, let recovery = state.recovery, var request = recovery.transcript.processingRequest else { return .none }
        let id = uuid(); request.runID = id
        let settings = state.session?.settings ?? state.hexSettings
        state.session = .init(id: id, mode: .init(mode: .init(id: recovery.transcript.modeID ?? "dictation", name: recovery.transcript.modeName ?? "Dictation", formatting: recovery.transcript.finalFormatting ?? .init())), processor: request.processor, settings: settings, scratchpad: false)
        state.isTranscribing = true; state.phase = "processing"; state.error = nil
        return processingEffect(request)
      case .copyOriginal, .copyResult:
        guard let recovery = state.recovery else { return .none }
        let text = action.isCopyOriginal ? recovery.transcript.originalText ?? recovery.transcript.text : recovery.transcript.text
        return .run { _ in await pasteboard.copy(text) }
      case .pasteOriginal:
        guard let recovery = state.recovery else { return .none }
        let text = recovery.transcript.originalText ?? recovery.transcript.text
        return .run { _ in try Task.checkCancellation(); await pasteboard.paste(text) }.cancellable(id: CancelID.transcription)
      case .pasteResult:
        guard let id = state.session?.id else { return .none }
        return .send(.deliver(id, true))
      case .dismissResult:
        return handleCancel(&state)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing || state.recovery != nil else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

		  // Process the key event
		  switch hotKeyProcessor.process(keyEvent: keyEvent) {
		  case .startRecording:
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    guard isTranscribing else { return .send(.startRecording) }
    return .concatenate(
      .send(.cancel),
      .send(.startRecording)
    )
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    guard !state.isRecording else { return .none }
    guard let document = state.modeLibrary.modes.first(where: { $0.id == state.hexSettings.selectedModeID }) else {
      state.error = "The selected mode is unavailable. Choose a mode from the menu or repair its configuration in Settings."
      return .none
    }
    guard state.isRemappingScratchpadFocused || state.modeLibrary.available(document.mode) else {
      state.error = "The selected mode's tool is missing. Open Modes to fix it."
      return .none
    }
    let previousCleanup = cleanupUnpublished(state.recovery)
    state.recovery = nil
    state.session = .init(id: uuid(), mode: document, processor: state.modeLibrary.processor(for: document.mode), settings: state.hexSettings, scratchpad: state.isRemappingScratchpadFocused)
    state.phase = "recording"
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    
    // Capture the active application
    state.sourceAppBundleID = nil; state.sourceAppName = nil
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Prevent system sleep during recording
    return .merge(
      previousCleanup,
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] _ in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.session?.settings.hotkey ?? state.hexSettings.hotkey,
        minimumKeyTime: state.session?.settings.minimumKeyTime ?? state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    let snapshot = state.session ?? RecordingSnapshot(id: uuid(), mode: .init(mode: .dictation), processor: nil, settings: state.hexSettings, scratchpad: state.isRemappingScratchpadFocused)
    state.session = snapshot
    state.phase = "transcribing"
    let model = snapshot.settings.selectedModel
    guard !model.isEmpty else {
      // Defense-in-depth: handleStartRecording already blocks recording when the
      // bootstrap state says no model is ready, but settings can change while a
      // recording is in flight (or the in-memory bootstrap default can race a
      // cold launch). Never hand an empty model name to the transcriber: it
      // silently produces nothing (or junk like "[BLANK_AUDIO]").
      transcriptionFeatureLogger.error("Recording stopped with no transcription model selected; discarding audio")
      return .merge(
        handleDiscard(&state),
        .send(.modelMissing)
      )
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let language = snapshot.settings.outputLanguage

    state.isPrewarming = true

    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var audioURL: URL?
        defer {
          if let audioURL {
            FileManager.default.removeItemIfExists(at: audioURL)
          }
        }
        do {
          let stopResult = await recording.stopRecording()
          let capturedURL: URL
          switch stopResult {
          case let .captured(url):
            capturedURL = url
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
            return
          case .ignored(.noActiveRecording):
            transcriptionFeatureLogger.error("Recording stopped without captured audio")
            await send(.sessionError(snapshot.id, RecordingFailure.noCapturedAudio.localizedDescription))
            return
          case let .failed(error):
            transcriptionFeatureLogger.error("Recording stop failed: \(error.localizedDescription)")
            await send(.sessionError(snapshot.id, error.localizedDescription))
            return
          }
          audioURL = capturedURL
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

          let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }

          transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
          guard !Task.isCancelled else { return }
          let artifact = RecordingArtifact(capturedURL)
          audioURL = nil
          await send(.sessionTranscript(snapshot.id, result, artifact, duration))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.sessionError(snapshot.id, error.localizedDescription))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func acceptTranscript(_ state: inout State, result: String, artifact: RecordingArtifact, duration: TimeInterval) -> Effect<Action> {
    guard let snapshot = state.session else { return .none }
    if ForceQuitCommandDetector.matches(result) {
      state.session = nil; state.isTranscribing = false
      return .run { _ in await MainActor.run { NSApp.terminate(nil) } }
    }
    guard !result.isEmpty else {
      state.session = nil; state.isTranscribing = false; state.isPrewarming = false; state.phase = "idle"
      return .none
    }
    var input = result
    if !snapshot.scratchpad {
      if snapshot.settings.wordRemovalsEnabled { input = WordRemovalApplier.apply(input, removals: snapshot.settings.wordRemovals) }
      input = WordRemappingApplier.apply(input, remappings: snapshot.settings.wordRemappings)
    }
    var transcript = Transcript(timestamp: now, text: "", audioPath: artifact.url, duration: duration, sourceAppBundleID: state.sourceAppBundleID, sourceAppName: state.sourceAppName)
    transcript.originalText = result; transcript.processorInput = input
    transcript.modeID = snapshot.mode.id; transcript.modeName = snapshot.mode.mode.name
    transcript.finalFormatting = .init(lowercase: snapshot.mode.mode.formatting.lowercase ?? snapshot.settings.lowercaseTranscripts, removePunctuation: snapshot.mode.mode.formatting.removePunctuation ?? snapshot.settings.removePunctuation)
    state.isTranscribing = true; state.isPrewarming = false
    if let processor = snapshot.processor, !snapshot.scratchpad {
      let request = TextProcessorRequest(runID: snapshot.id, input: input, prompt: snapshot.mode.prompt, processor: processor)
      transcript.processingRequest = request
      state.recovery = .init(transcript: transcript, artifact: artifact)
      state.phase = "processing"
      return processingEffect(request)
    }
    state.recovery = .init(transcript: transcript, artifact: artifact)
    return .send(.processed(snapshot.id, input, nil))
  }

  func cleanupUnpublished(_ recovery: RecoveryResult?) -> Effect<Action> {
    guard let recovery, recovery.persisted, !recovery.published else { return .none }
    return .run { _ in try? await transcriptPersistence.deleteAudio(recovery.transcript) }
  }

  func publishHistory(_ state: inout State) -> Effect<Action> {
    guard var recovery = state.recovery, recovery.persisted, state.hexSettings.saveTranscriptionHistory else { return .none }
    recovery.published = true; state.recovery = recovery
    let transcript = recovery.transcript
    var removed: [Transcript] = []
    state.$transcriptionHistory.withLock { history in
      history.history.removeAll { $0.id == transcript.id }; history.history.insert(transcript, at: 0)
      if let maximum = state.session?.settings.maxHistoryEntries, maximum > 0 {
        while history.history.count > maximum { removed.append(history.history.removeLast()) }
      }
    }
    return .run { [removed] _ in for entry in removed { try? await transcriptPersistence.deleteAudio(entry) } }
  }

  func processingEffect(_ request: TextProcessorRequest) -> Effect<Action> {
    .run { send in
      do {
        let result = try await textProcessor.run(request)
        try Task.checkCancellation()
        await send(.processed(request.runID, result.text, nil))
      } catch is CancellationError { }
      catch { await send(.processed(request.runID, nil, (error as? TextProcessorFailure) ?? .init(error.localizedDescription))) }
    }.cancellable(id: CancelID.transcription, cancelInFlight: true)
  }

}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    let previousCleanup = cleanupUnpublished(state.recovery)
    state.session = nil; state.recovery = nil; state.phase = "idle"
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false

    return .merge(
      previousCleanup,
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
		soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    state.session = nil; state.recovery = nil; state.phase = "idle"
    state.isRecording = false
    state.isPrewarming = false

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
		guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    VStack(spacing: 6) {
      if store.isRecording || store.isTranscribing {
        Text("\(store.session?.mode.mode.name ?? "Dictation") · \(store.phase.capitalized)")
          .font(.caption).padding(5).background(.regularMaterial, in: Capsule())
      }
      TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
      if store.isRecording || store.isTranscribing { Text("Esc to cancel").font(.caption).padding(4).background(.regularMaterial, in: Capsule()) }
    }
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

private extension TranscriptionFeature.Action {
  var isCopyOriginal: Bool { if case .copyOriginal = self { return true }; return false }
}
