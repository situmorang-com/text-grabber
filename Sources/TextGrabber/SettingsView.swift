import SwiftUI
import AppKit
import ServiceManagement
import TextGrabberCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            RecognitionSettings().tabItem { Label("Recognition", systemImage: "text.viewfinder") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(12)
        .frame(width: 520, height: 480)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.showHUD) private var showHUD = true
    @AppStorage(Prefs.Key.muteShutter) private var muteShutter = true
    @AppStorage(Prefs.Key.keepHistory) private var keepHistory = true
    @AppStorage(Prefs.Key.openLinks) private var openLinks = false
    @AppStorage(Prefs.Key.additive) private var additive = false
    @AppStorage(Prefs.Key.speak) private var speak = false
    @AppStorage(Prefs.Key.speechRate) private var speechRate = 0.5
    @AppStorage(Prefs.Key.openEditor) private var openEditor = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("After a capture") {
                Toggle("Open the editor (edit, translate, clean up) instead of only copying", isOn: $openEditor)
                Toggle("Show a confirmation with a preview", isOn: $showHUD)
                Toggle("Keep a history of captures on this Mac", isOn: $keepHistory)
                Toggle("Open the link when the capture is a single link", isOn: $openLinks)
                Toggle("Additive clipboard: add each capture to the previous ones", isOn: $additive)
                Toggle("Speak the text", isOn: $speak)
                HStack {
                    Text("Speaking speed")
                    Slider(value: $speechRate, in: 0.3...0.65)
                }
            }
            Section("Capturing") {
                Toggle("Mute the screenshot sound", isOn: $muteShutter)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecognitionSettings: View {
    @AppStorage(Prefs.Key.lineMode) private var lineMode = LineMode.paragraphs.rawValue
    @AppStorage(Prefs.Key.preferredLanguage) private var language = ""
    @AppStorage(Prefs.Key.detectsLanguage) private var detectsLanguage = true
    @AppStorage(Prefs.Key.customWords) private var customWords = ""
    @AppStorage(Prefs.Key.upscale) private var upscale = true
    @AppStorage(Prefs.Key.detectColumns) private var detectColumns = true
    @AppStorage(Prefs.Key.detectTables) private var detectTables = true
    @AppStorage(Prefs.Key.exactText) private var exactText = true
    @AppStorage(Prefs.Key.outputFormat) private var outputFormat = StructuredText.Format.plain.rawValue
    @AppStorage(Prefs.Key.tableStyle) private var tableStyle = StructuredText.TableStyle.tabs.rawValue
    @State private var accessibilityGranted = AccessibilityText.isTrusted
    private let accessCheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let languages = Recognizer.supportedLanguages()

    var body: some View {
        Form {
            Section("Text layout") {
                Picker("Line breaks", selection: $lineMode) {
                    Text("Smart paragraphs").tag(LineMode.paragraphs.rawValue)
                    Text("Keep every line break").tag(LineMode.keepLines.rawValue)
                    Text("Single line").tag(LineMode.singleLine.rawValue)
                }
                Toggle("Read side-by-side columns one after the other", isOn: $detectColumns)
                Toggle("Recognise tables", isOn: $detectTables)
                Picker("Copy as", selection: $outputFormat) {
                    Text("Plain text").tag(StructuredText.Format.plain.rawValue)
                    Text("Markdown").tag(StructuredText.Format.markdown.rawValue)
                }
                if outputFormat == StructuredText.Format.plain.rawValue {
                    Picker("Tables in plain text", selection: $tableStyle) {
                        Text("Tabs (paste into a spreadsheet)").tag(StructuredText.TableStyle.tabs.rawValue)
                        Text("CSV").tag(StructuredText.TableStyle.csv.rawValue)
                        Text("Markdown").tag(StructuredText.TableStyle.markdown.rawValue)
                    }
                }
            }
            Section("Language") {
                Picker("Main language", selection: $language) {
                    Text("Automatic").tag("")
                    ForEach(languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                Toggle("Also detect other languages automatically", isOn: $detectsLanguage)
            }
            Section("Accuracy") {
                Toggle("Use the app's own text when it matches (emoji, ⌘ and other symbols)", isOn: $exactText)
                if exactText {
                    HStack {
                        Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(accessibilityGranted ? .green : .orange)
                        Text(accessibilityGranted ? "Accessibility access is on." : "Needs Accessibility access to read text from other apps.")
                            .font(.caption)
                        Spacer()
                        if !accessibilityGranted {
                            Button("Grant Access…") { AccessibilityText.requestAccess() }
                        }
                    }
                    .onReceive(accessCheck) { _ in accessibilityGranted = AccessibilityText.isTrusted }
                }
                Toggle("Enlarge small captures before reading", isOn: $upscale)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom words")
                    TextField("Names and terms, separated by commas", text: $customWords, axis: .vertical)
                        .lineLimit(2...4)
                        .labelsHidden()
                    Text("Product names, jargon or people's names that are often misread. Phrases are fine.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @State private var conflicts = HotKeyCenter.shared.conflicts

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: 6) {
                            if conflicts.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Another app already uses this shortcut.")
                            }
                            ShortcutRecorder(action: action) { conflicts = HotKeyCenter.shared.conflicts }
                        }
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new keys. Press Delete to remove it, Esc to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A button that records the next key combination pressed.
private struct ShortcutRecorder: View {
    let action: HotKeyAction
    var onChange: () -> Void
    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : (shortcut?.display ?? "None")) {
            recording ? stop() : start()
        }
        .frame(minWidth: 110)
        .onAppear { shortcut = Shortcut.stored(for: action) }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 53 {            // Esc
                stop()
            } else if event.keyCode == 51 || event.keyCode == 117 {   // Delete
                save(nil)
            } else if !modifiers.intersection([.command, .option, .control]).isEmpty,
                      let key = event.charactersIgnoringModifiers, !key.isEmpty {
                save(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: Self.name(for: event, fallback: key)))
            } else {
                NSSound.beep()   // needs ⌘, ⌥ or ⌃ so it cannot swallow ordinary typing
            }
            return nil
        }
    }

    private func save(_ new: Shortcut?) {
        Shortcut.store(new, for: action)
        shortcut = new
        HotKeyCenter.shared.reload()
        onChange()
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private static func name(for event: NSEvent, fallback: String) -> String {
        switch Int(event.keyCode) {
        case 49: return "Space"
        case 36: return "↩"
        case 48: return "⇥"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return fallback.uppercased()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    var copy: (String) -> Void
    var edit: (HistoryEntry) -> Void = { _ in }
    @State private var query = ""

    private var matches: [HistoryEntry] {
        query.isEmpty ? store.entries : store.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if matches.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No captures yet" : "No matches",
                                       systemImage: "text.viewfinder",
                                       description: Text(query.isEmpty ? "Text you capture appears here." : "Try a different search."))
            } else {
                List(matches) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).lineLimit(4).textSelection(.enabled)
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            if entry.kind == .barcode { Text("· QR or barcode") }
                            Spacer()
                            Button("Edit") { edit(entry) }
                            Button("Copy") { copy(entry.text) }
                            Button("Delete", role: .destructive) { store.remove(entry) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                Text("\(store.entries.count) saved on this Mac only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", role: .destructive) { store.clear() }.disabled(store.entries.isEmpty)
            }
            .padding(10)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search captures")
        .frame(minWidth: 440, minHeight: 360)
    }
}
