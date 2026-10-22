import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

struct ModesView: View {
    @Bindable var store: StoreOf<ModesFeature>
    var body: some View {
        Form {
            Section("Modes") {
                ForEach(store.library.modes) { document in
                    HStack {
                        Button(document.mode.name) { store.send(.select(document.id)) }.buttonStyle(.link)
                        if !store.library.available(document.mode) { Text("Processor unavailable").foregroundStyle(.red) }
                        Spacer()
                        if document.id == store.settings.selectedModeID { Text("Active").foregroundStyle(.secondary) }
                        else { Button("Use") { store.$settings.withLock { $0.selectedModeID = document.id } }.disabled(!store.library.available(document.mode)) }
                    }
                }
                HStack {
                    Menu("New Mode") {
                        ForEach(["Dictation", "Notes", "Message"], id: \.self) { name in Button(name) { store.send(.create(name)) } }
                    }
                    Button("Duplicate") { store.send(.duplicate) }
                    Button("Delete", role: .destructive) { store.send(.delete) }.disabled(store.document.id == "dictation")
                    Button("Show Files") { NSWorkspace.shared.open(HexStoragePaths.live.config) }
                }
                ForEach(store.library.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
            Section("Mode Editor") {
                TextField("Name", text: $store.document.mode.name)
                Picker("Processor", selection: $store.document.mode.processorID) {
                    Text("None — Dictation").tag(String?.none)
                    if store.editingProcessor && !store.library.processors.contains(where: { $0.id == store.processor.id }) {
                        Text(store.processor.name + " (unsaved)").tag(Optional(store.processor.id))
                    }
                    ForEach(store.library.processors) { processor in Text(processor.name).tag(Optional(processor.id)) }
                }
                HStack {
                    Button("New Processor…") { store.send(.editProcessor(nil)) }
                    Button("Edit Processor…") { store.send(.editProcessor(store.document.mode.processorID)) }.disabled(store.document.mode.processorID == nil)
                }
                if store.selectedProcessor?.usesModeInstructions ?? !store.document.prompt.isEmpty {
                    Text("Instructions").font(.headline)
                    TextEditor(text: $store.document.prompt).font(.body.monospaced()).frame(minHeight: 140)
                    Button("Edit prompt.md Externally") {
                        openAsText(ModeConfigurationStore(root: HexStoragePaths.live.config).modeDirectory(store.document.id).appendingPathComponent("prompt.md"))
                    }.disabled(store.dirty)
                }
                formattingPicker("Lowercase", value: $store.document.mode.formatting.lowercase)
                formattingPicker("Remove punctuation", value: $store.document.mode.formatting.removePunctuation)
                if store.conflict {
                    Text("Files changed outside Hex. Choose how to resolve your unsaved edits.").foregroundStyle(.orange)
                    HStack {
                        Button("Reload") { store.send(.reload) }
                        Button("Keep my edits") { store.send(.keepEdits) }
                    }
                }
                HStack {
                    Button("Save Mode") { store.send(.save) }.disabled(store.conflict)
                    Button("Reload") { store.send(.reload) }
                    if store.dirty { Text("Unsaved edits").foregroundStyle(.secondary) }
                }
            }
            if store.editingProcessor { processorEditor }
            Section("Test") {
                Text("Runs the real command with the current editor instructions and processor edits. Commands must run without a terminal or prompts and write only final text to stdout. Tests never paste or save history.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.sample).frame(minHeight: 90)
                HStack {
                    Button("Run") { store.send(.runTest) }.disabled(store.testID != nil || store.selectedProcessor == nil)
                    Button("Cancel") { store.send(.cancelTest) }.disabled(store.testID == nil)
                    if store.testID != nil { ProgressView().controlSize(.small) }
                }
                if store.staleTest && (store.testResult != nil || store.testError != nil) { Text("These results belong to earlier edits.").foregroundStyle(.orange) }
                if let result = store.testResult {
                    Text(String(format: "Output · %.2fs", result.elapsed)).font(.headline)
                    Text(result.text).textSelection(.enabled)
                }
                if let error = store.testError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !store.testDiagnostics.isEmpty {
                    Text("stderr (may contain private text)").font(.headline)
                    Text(store.testDiagnostics).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped)
    }
    private func openAsText(_ url: URL) {
        // Explicitly choose a text editor: default handlers for .command/.py can execute files.
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
    private func formattingPicker(_ title: String, value: Binding<Bool?>) -> some View {
        Picker(title, selection: value) {
            Text("Use global setting").tag(Bool?.none)
            Text("On").tag(Optional(true)); Text("Off").tag(Optional(false))
        }
    }
    private var processorEditor: some View {
        Section("Processor") {
            Text("Commands are trusted automation and can access your files and network using your normal account permissions.").font(.caption).foregroundStyle(.secondary)
            TextField("Name", text: $store.processor.name)
            VStack(alignment: .leading, spacing: 6) {
                Text("Executable path")
                HStack {
                    TextField("", text: $store.processor.executable, prompt: Text("/opt/homebrew/bin/your-tool"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Executable path")
                        .help("Type or paste the absolute path to an executable or script.")
                        .frame(maxWidth: .infinity)
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url { store.processor.executable = url.path }
                    }
                }
                Text("Type or paste an absolute path, or choose a file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(store.processor.arguments.indices), id: \.self) { index in
                HStack {
                    TextField("Argument", text: $store.processor.arguments[index])
                    Button("Remove") { store.processor.arguments.remove(at: index) }
                }
            }
            Button("Add Argument") { store.processor.arguments.append("") }
            TextField("Working directory (blank uses home)", text: Binding(get: { store.processor.workingDirectory ?? "" }, set: { store.processor.workingDirectory = $0.isEmpty ? nil : $0 }))
            Toggle("Uses mode instructions", isOn: $store.processor.usesModeInstructions)
            Stepper("Timeout: \(Int(store.processor.timeout)) seconds", value: $store.processor.timeout, in: 1...300)
            HStack {
                Button("Show Executable") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.processor.executable)]) }
                Button("Edit Script") { openAsText(URL(fileURLWithPath: store.processor.executable)) }
            }
            if store.processorConflict {
                Text("Processor file changed outside Hex.").foregroundStyle(.orange)
                HStack {
                    Button("Reload Processor") { store.send(.reloadProcessor) }
                    Button("Keep my edits") { store.send(.keepProcessorEdits) }
                }
            }
            HStack {
                Button("Save Processor") { store.send(.saveProcessor) }.disabled(store.processorConflict)
                Button("Reload Processor") { store.send(.reloadProcessor) }
                Button("Delete Processor", role: .destructive) { store.send(.deleteProcessor) }
                    .disabled(store.library.modes.contains { $0.mode.processorID == store.processor.id })
                if store.processorDirty { Text("Unsaved edits").foregroundStyle(.secondary) }
            }
        }
    }
}

struct ModeMenu: View {
    let store: StoreOf<AppFeature>
    var body: some View {
        Menu("Mode: " + (store.modes.library.modes.first { $0.id == store.hexSettings.selectedModeID }?.mode.name ?? "Dictation")) {
            ForEach(store.modes.library.modes) { document in
                Button((store.hexSettings.selectedModeID == document.id ? "✓ " : "") + document.mode.name + (store.modes.library.available(document.mode) ? "" : " (unavailable)")) {
                    store.modes.$settings.withLock { $0.selectedModeID = document.id }
                }.disabled(!store.modes.library.available(document.mode))
            }
        }
        if store.transcription.isRecording || store.transcription.isTranscribing {
            Button("Cancel Recording / Processing") { store.send(.transcription(.cancel)) }
        }
        if let error = store.transcription.error, store.transcription.recovery == nil { Text(error) }
        if let recovery = store.transcription.recovery, store.transcription.phase == "ready" || store.transcription.phase == "failed" {
            Text(recovery.failure ?? "Result ready — destination app changed")
            if !recovery.diagnostics.isEmpty { Text("stderr: " + String(recovery.diagnostics.prefix(300))) }
            if let original = recovery.transcript.originalText { Text(String(original.prefix(100))) }
            if recovery.failure != nil {
                Button("Retry Processing") { store.send(.transcription(.retry)) }
                Button("Copy Original") { store.send(.transcription(.copyOriginal)) }
                Button("Paste Original") { store.send(.transcription(.pasteOriginal)) }
            } else {
                Button("Copy Result") { store.send(.transcription(.copyResult)) }
                Button("Paste Result") { store.send(.transcription(.pasteResult)) }
            }
            Button("Dismiss Result") { store.send(.transcription(.dismissResult)) }
        }
    }
}
