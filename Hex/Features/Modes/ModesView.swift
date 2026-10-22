import AppKit
import ComposableArchitecture
import HexCore
import SwiftUI

struct ModesView: View {
    @Bindable var store: StoreOf<ModesFeature>

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            Group {
                switch store.selection {
                case .tool: ToolDetailView(store: store)
                case .mode: ModeDetailView(store: store)
                case nil: Text("Select a mode or tool").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $store.isAddingTool) { AddToolSheet(store: store) }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { store.send(.confirmDelete) }
        } message: { Text("This removes its files from the Hex configuration folder.") }
        .alert("Couldn't complete that", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") {}
        } message: { Text(store.error ?? "") }
    }

    private var deleteTitle: String {
        switch store.pendingDelete {
        case let .mode(id): "Delete “\(store.library.modes.first { $0.id == id }?.mode.name ?? "mode")”?"
        case let .tool(id): "Delete “\(store.library.processors.first { $0.id == id }?.name ?? "tool")”?"
        case nil: ""
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selection.sending(\.select)) {
                Section("Modes") {
                    ForEach(store.library.modes) { document in modeRow(document) }
                }
                Section("Tools") {
                    ForEach(store.library.processors) { tool in
                        let uses = store.state.modes(using: tool.id).count
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.selection == .tool(tool.id) ? store.tool.name : tool.name)
                            Text(uses == 0 ? "Not used" : uses == 1 ? "Used by 1 mode" : "Used by \(uses) modes")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(ModesFeature.Selection.tool(tool.id))
                        .contextMenu { Button("Delete…") { store.send(.requestDelete(.tool(tool.id))) } }
                    }
                    if store.library.processors.isEmpty {
                        Button("Add a tool…") { store.send(.showAddTool(assignToMode: false)) }.buttonStyle(.link)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 2) {
                Menu {
                    Button("New Mode") { store.send(.newMode) }
                    Button("Add Tool…") { store.send(.showAddTool(assignToMode: false)) }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("New mode or tool")
                Button { if let selection = store.selection { store.send(.requestDelete(selection)) } } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless).disabled(store.selection == nil || store.selection == .mode("dictation")).help("Delete")
                Spacer()
                ProblemsButton(problems: store.library.problems)
                Menu {
                    Button("Show Configuration Folder") { NSWorkspace.shared.open(HexStoragePaths.live.config) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    private func modeRow(_ document: ModeDocument) -> some View {
        let isActive = document.id == store.settings.selectedModeID
        let available = store.library.available(document.mode)
        let name = store.selection == .mode(document.id) ? store.document.mode.name : document.mode.name
        return HStack(spacing: 6) {
            Button { store.send(.setActive(document.id)) } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).disabled(!available)
            .help(isActive ? "This mode is used when you dictate" : "Use this mode when dictating")
            Text(name.isEmpty ? "Untitled" : name)
            Spacer()
            if !available {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("This mode's tool is missing")
            }
        }
        .tag(ModesFeature.Selection.mode(document.id))
        .contextMenu {
            Button("Use When Dictating") { store.send(.setActive(document.id)) }.disabled(isActive || !available)
            Button("Duplicate") { store.send(.duplicate(document.id)) }
            if document.id != "dictation" {
                Divider()
                Button("Delete…") { store.send(.requestDelete(.mode(document.id))) }
            }
        }
    }
}

// MARK: - Mode detail

private struct ModeDetailView: View {
    @Bindable var store: StoreOf<ModesFeature>
    @State private var showAdvanced = false
    @State private var showDetails = false

    var body: some View {
        Form {
            if store.conflict { ConflictBanner(store: store, noun: "mode") }
            Section {
                TextField("Name", text: $store.document.mode.name)
                if store.document.mode.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Give this mode a name to save it.").font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Rewrite with") {
                    HStack {
                        Picker("Rewrite with", selection: $store.document.mode.processorID) {
                            Text("Nothing (paste as dictated)").tag(String?.none)
                            if let id = store.document.mode.processorID, !store.library.processors.contains(where: { $0.id == id }) {
                                Text("Missing tool").tag(Optional(id))
                            }
                            if !store.library.processors.isEmpty { Divider() }
                            ForEach(store.library.processors) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                        Button("Add Tool…") { store.send(.showAddTool(assignToMode: true)) }
                    }
                }
            } footer: {
                if store.document.mode.processorID == nil {
                    Text("A tool, such as Codex or your own script, rewrites your dictation using this mode's instructions.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.selectedProcessor == nil {
                    Text("This mode can't be used until you choose a tool.").font(.caption).foregroundStyle(.orange)
                }
            }

            if store.document.mode.processorID != nil {
                Section("Instructions") {
                    TextEditor(text: $store.document.prompt)
                        .font(.body).frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                    if store.document.prompt.isEmpty {
                        HStack(spacing: 10) {
                            Text("Start from:").foregroundStyle(.secondary)
                            ForEach(InstructionTemplate.all) { template in
                                Button(template.name) { store.send(.applyTemplate(template.name)) }.buttonStyle(.link)
                            }
                        }.font(.callout)
                    }
                }
                tryIt
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    formattingPicker("Lowercase", value: $store.document.mode.formatting.lowercase)
                    formattingPicker("Remove punctuation", value: $store.document.mode.formatting.removePunctuation)
                    HStack {
                        Button("Open Instructions File") {
                            store.send(.flush)
                            openAsText(ModeConfigurationStore(root: HexStoragePaths.live.config).modeDirectory(store.document.id).appendingPathComponent("prompt.md"))
                        }
                        Button("Show in Finder") {
                            store.send(.flush)
                            NSWorkspace.shared.activateFileViewerSelecting([ModeConfigurationStore(root: HexStoragePaths.live.config).modeDirectory(store.document.id)])
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var tryIt: some View {
        Section {
            TextEditor(text: $store.sample).frame(minHeight: 60).scrollContentBackground(.hidden)
            HStack {
                Button("Use Last Dictation") { store.send(.useLastDictation) }
                Spacer()
                if store.testID != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { store.send(.cancelTest) }
                } else {
                    Button(store.testResult == nil && store.testError == nil ? "Try It" : "Try Again") { store.send(.runTest) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(store.selectedProcessor == nil)
                }
            }
            if let result = store.testResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Result · %.1fs", result.elapsed)).font(.caption).foregroundStyle(.secondary)
                    Text(result.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(store.staleTest ? 0.5 : 1)
            }
            if let error = store.testError {
                Text(error).foregroundStyle(.red).textSelection(.enabled).opacity(store.staleTest ? 0.5 : 1)
            }
            if store.staleTest && (store.testResult != nil || store.testError != nil) && store.testID == nil {
                Text("You've made changes since this ran.").font(.caption).foregroundStyle(.secondary)
            }
            if store.testError != nil, !store.testDiagnostics.isEmpty {
                // On failure the tool's own message is usually the fix, so show its last lines directly.
                Text(store.testDiagnostics.split(separator: "\n", omittingEmptySubsequences: true).suffix(8).joined(separator: "\n"))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !store.testDiagnostics.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    Text(store.testDiagnostics).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } header: {
            Text("Try It")
        } footer: {
            Text("Runs the tool for real. Nothing is pasted or saved to history.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formattingPicker(_ title: String, value: Binding<Bool?>) -> some View {
        Picker(title, selection: value) {
            Text("Same as Settings").tag(Bool?.none)
            Text("On").tag(Optional(true))
            Text("Off").tag(Optional(false))
        }
    }
}

// MARK: - Tool detail

private struct ToolDetailView: View {
    @Bindable var store: StoreOf<ModesFeature>
    @State private var showMore = false

    var body: some View {
        let users = store.state.modes(using: store.tool.id)
        Form {
            if store.toolConflict { ConflictBanner(store: store, noun: "tool") }
            Section {
                TextField("Name", text: $store.tool.name)
                LabeledContent("Command") {
                    HStack {
                        TextField("Command", text: $store.toolCommand, prompt: Text("/path/to/script.sh --option value"))
                            .labelsHidden().font(.body.monospaced())
                        Button("Choose…") { if let path = chooseExecutable() { store.send(.chooseExecutable(path)) } }
                    }
                }
                if let problem = store.toolProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            } footer: {
                Text("The full path to a program or script, then any options. Quotes work as in Terminal, but nothing runs in a shell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("More Options", isExpanded: $showMore) {
                    TextField("Working folder", text: Binding(
                        get: { store.tool.workingDirectory ?? "" },
                        set: { store.tool.workingDirectory = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("Your home folder"))
                    Stepper("Time limit: \(Int(store.tool.timeout)) seconds", value: $store.tool.timeout, in: 1...300, step: 5)
                }
            }
            Section {
                LabeledContent("Used by", value: users.isEmpty ? "No modes" : users.joined(separator: ", "))
                HStack {
                    Button("Open Script") { openAsText(URL(fileURLWithPath: store.tool.executable)) }
                        .disabled(!isTextScript(store.tool.executable))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.tool.executable)]) }
                    Spacer()
                    Button("Delete Tool…", role: .destructive) { store.send(.requestDelete(.tool(store.tool.id))) }
                        .disabled(!users.isEmpty)
                        .help(users.isEmpty ? "" : "Switch its modes to another tool first")
                }
            } footer: {
                Text("Tools run as you and can read your files and use the network. Hex sends the dictation on standard input and the instructions in the file named by HEX_PROMPT_FILE, and pastes whatever the tool prints.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Add tool

private struct AddToolSheet: View {
    @Bindable var store: StoreOf<ModesFeature>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Tool").font(.title2.bold())
            Text("A tool gets your dictation plus the mode's instructions and returns the rewritten text.")
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(ToolPreset.all) { preset in
                    choice(preset.name, preset.summary, systemImage: "sparkles") { store.send(.addPreset(preset.id)) }
                }
                choice("Write My Own Script", "Creates a starter shell script and opens it in TextEdit.", systemImage: "doc.text") {
                    store.send(.addScript)
                }
            }

            Divider()
            Text("Or use a program you already have").font(.headline)
            TextField("Name", text: $store.addTool.name, prompt: Text("Name (optional)"))
            HStack {
                TextField("Command", text: $store.addTool.command, prompt: Text("/path/to/program --option value"))
                    .font(.body.monospaced())
                Button("Choose…") { if let path = chooseExecutable() { store.send(.chooseExecutable(path)) } }
            }
            if let problem = store.addTool.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { store.send(.addCustom) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.addTool.command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func choice(_ title: String, _ subtitle: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared pieces

private struct ConflictBanner: View {
    let store: StoreOf<ModesFeature>
    let noun: String
    var body: some View {
        Section {
            Label("This \(noun) was changed in another app while you were editing.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            HStack {
                Button("Use Their Version") { store.send(.useFileVersion) }
                Button("Keep Mine") { store.send(.keepMine) }
            }
        }
    }
}

private struct ProblemsButton: View {
    let problems: [String]
    @State private var showing = false
    var body: some View {
        if !problems.isEmpty {
            Button { showing.toggle() } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help(problems.count == 1 ? "1 file couldn't be loaded" : "\(problems.count) files couldn't be loaded")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(problems.count == 1 ? "1 file couldn't be loaded" : "\(problems.count) files couldn't be loaded").font(.headline)
                    ForEach(problems, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    Button("Show Configuration Folder") { NSWorkspace.shared.open(HexStoragePaths.live.config) }
                }
                .padding().frame(maxWidth: 360)
            }
        }
    }
}

@MainActor private func chooseExecutable() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.message = "Choose a program or script"
    return panel.runModal() == .OK ? panel.url?.path : nil
}

private func isTextScript(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
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
