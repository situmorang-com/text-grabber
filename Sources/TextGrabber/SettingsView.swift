import SwiftUI
import Combine
import AppKit
import ServiceManagement
import TextGrabberCore

struct SettingsView: View {
    /// The tab last shown ("general", "recognition", "shortcuts"); also set by `snapshot?window=settings&tab=`.
    @AppStorage(Prefs.Key.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            RecognitionSettings().tabItem { Label("Recognition", systemImage: "text.viewfinder") }.tag("recognition")
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
        }
        .padding(12)
        .frame(width: 520, height: 600)
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
    @AppStorage(Prefs.Key.historyPictures) private var historyPictures = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    /// "⌘C, ⌘L and ⌘S", or "the keys in the Shortcuts tab" when none is set.
    private static var optionKeysText: String {
        let keys = CaptureOption.allCases.compactMap { Shortcut.stored(for: $0)?.display }
        guard let last = keys.last else { return "the keys in Shortcuts" }
        return keys.count == 1 ? last : keys.dropLast().joined(separator: ", ") + " and " + last
    }

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
            Section {
                Toggle("Open the editor (edit, translate, clean up) instead of only copying", isOn: $openEditor)
                Toggle("Show a confirmation with a preview", isOn: $showHUD)
                Toggle("Keep a history of captures on this Mac", isOn: $keepHistory)
                Toggle("Include a small picture of each capture in the history", isOn: $historyPictures)
                    .disabled(!keepHistory)
                Toggle("Open the link when the capture is a single link", isOn: $openLinks)
                Toggle("Additive clipboard: add each capture to the text on the clipboard", isOn: $additive)
                Toggle("Read the text aloud", isOn: $speak)
                HStack {
                    Text("Speaking speed")
                    Slider(value: $speechRate, in: 0.3...0.65)
                }
            } header: {
                Text("After a capture")
            } footer: {
                Text("While you select an area, \(Self.optionKeysText) switch these and line breaks for that capture only. Added text goes on the same line, or on a new line when line breaks are kept.")
                    .font(.caption).foregroundStyle(.secondary)
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
    @AppStorage(Prefs.Key.readCodes) private var readCodes = true
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
            Section("QR codes and barcodes") {
                Toggle("Read codes in text captures", isOn: $readCodes)
                Text("A capture that is about a code copies what the code contains; a page with a code copies its text and then the code. The confirmation can switch between them, and opens links only when you click Open.")
                    .font(.caption).foregroundStyle(.secondary)
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
    @State private var needAccessibility = HotKeyCenter.shared.needAccessibility
    /// A shortcut that was refused because another one uses it: which section, and why.
    @State private var problem: (inOptions: Bool, message: String)?

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
                            } else if needAccessibility.contains(action) {
                                Button {
                                    AccessibilityText.requestAccess()
                                } label: {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                                .buttonStyle(.borderless)
                                .help("A shortcut pressed twice needs Accessibility. Click to allow it.")
                            }
                            ShortcutRecorder(slot: action, allowsTwice: true, report: { problem = $0.map { (false, $0) } }) {
                                conflicts = HotKeyCenter.shared.conflicts
                                needAccessibility = HotKeyCenter.shared.needAccessibility
                            }
                        }
                    }
                }
            } footer: {
                footer("Click a shortcut, then press the new keys. Press them twice quickly for a shortcut pressed twice, such as ⌥2 2: the first press then reaches the app in front a quarter second later, unless the second follows. Press Delete to remove it, Esc to cancel.", inOptions: false)
            }
            Section {
                ForEach(CaptureOption.allCases) { option in
                    LabeledContent(option.title) {
                        ShortcutRecorder(slot: option, report: { problem = $0.map { (true, $0) } }) {}
                    }
                }
            } header: {
                Text("While selecting an area")
            } footer: {
                footer("Press these while the crosshair shows; they are ordinary keys again as soon as it goes. Each press switches that option on or off for that capture alone, starting from the settings in General. Added text goes after the text on the clipboard: on the same line, or on a new line when line breaks are kept. ⌘ and ⌃ belong to macOS while you select.", inOptions: true)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: HotKeyCenter.changed)) { _ in
            conflicts = HotKeyCenter.shared.conflicts
            needAccessibility = HotKeyCenter.shared.needAccessibility
        }
    }

    @ViewBuilder
    private func footer(_ text: String, inOptions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem, problem.inOptions == inOptions {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(text).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

/// A button that records the next key combination pressed.
private struct ShortcutRecorder: View {
    let slot: any ShortcutSlot
    /// The same keys pressed twice quickly record a shortcut pressed twice.
    var allowsTwice = false
    /// Told why a shortcut was refused, or nil once recording starts again.
    var report: (String?) -> Void = { _ in }
    var onChange: () -> Void
    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?
    /// A first press, saved unless the same keys come again within the double-press time.
    @State private var first: (shortcut: Shortcut, save: DispatchWorkItem)?

    var body: some View {
        Button(recording ? "Press keys…" : (shortcut?.display ?? "None")) {
            recording ? stop() : start()
        }
        .frame(minWidth: 110)
        .onAppear { shortcut = Shortcut.stored(for: slot) }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.recording = true
        report(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 53 {            // Esc
                stop()
            } else if event.keyCode == 51 || event.keyCode == 117 {   // Delete
                save(nil)
            } else if let key = event.charactersIgnoringModifiers, !key.isEmpty {
                let new = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: Self.name(for: event, fallback: key))
                // Refused keys keep the recorder listening, so another can be pressed straight away.
                if let problem = slot.problem(with: new) {
                    NSSound.beep()
                    report(problem)
                } else if let owner = Shortcut.owner(of: new, besides: slot) {
                    NSSound.beep()
                    report("\(new.display) is already used for “\(owner.title)”.")
                } else if allowsTwice, let first, first.shortcut.sameKeys(as: new), !event.isARepeat {
                    first.save.cancel()
                    self.first = nil
                    save(new.doubled)
                } else if allowsTwice {
                    guard !event.isARepeat else { return nil }
                    first?.save.cancel()
                    let work = DispatchWorkItem { save(new) }
                    first = (new, work)
                    // A little longer than the shortcut allows: recording should not be the hard part.
                    DispatchQueue.main.asyncAfter(deadline: .now() + DoublePressMachine.window + 0.15, execute: work)
                } else {
                    save(new)
                }
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func save(_ new: Shortcut?) {
        first?.save.cancel()
        first = nil
        Shortcut.store(new, for: slot)
        shortcut = new
        HotKeyCenter.shared.reload()
        onChange()
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        first?.save.cancel()
        first = nil
        recording = false
        HotKeyCenter.shared.recording = false
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
    @ObservedObject var store: CaptureHistory
    var copy: (String) -> Void
    var edit: (HistoryEntry) -> Void = { _ in }
    @State private var query = ""
    @State private var confirmClear = false

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
                    HStack(alignment: .top, spacing: 10) {
                        Thumbnail(url: store.thumbnailURL(entry))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text).lineLimit(4).textSelection(.enabled)
                            HStack {
                                if entry.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                if entry.kind == "barcode" { Text("· QR or barcode") }
                                Spacer()
                                Button(entry.pinned ? "Unpin" : "Pin") { store.setPinned(entry, !entry.pinned) }
                                Button("Edit") { edit(entry) }
                                Button("Copy") { copy(entry.text) }
                                Button("Delete", role: .destructive) { store.remove(entry) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                let pinned = store.entries.filter(\.pinned).count
                Text("\(store.entries.count) saved on this Mac only" + (pinned > 0 ? ", \(pinned) pinned" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .disabled(store.entries.allSatisfy(\.pinned))
            }
            .padding(10)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search captures")
        .frame(minWidth: 480, minHeight: 360)
        .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
            Button("Clear All but Pinned", role: .destructive) { store.clearUnpinned() }
        } message: {
            Text("Captures and their pictures are deleted from this Mac. Pinned captures stay.")
        }
    }
}

/// A small picture of the capture, loaded from disk.
private struct Thumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "text.viewfinder").font(.title2).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 84, height: 56)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
