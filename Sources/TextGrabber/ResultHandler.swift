import AppKit
import AVFoundation
import NaturalLanguage
import TextGrabberCore

enum ResultKind: String, Codable {
    case text, barcode
}

/// Everything that happens once text has been recognised: clipboard, history, HUD, speech, links.
final class ResultHandler {
    let history = HistoryStore()
    private let hud = HUD()
    private let synthesizer = AVSpeechSynthesizer()
    private var progressTimer: Timer?
    private(set) lazy var editor = ResultPanelController(output: self)
    /// The most recent capture, for "Edit Last Capture".
    private(set) var lastResult: CaptureResult?
    /// Open the editor for the next capture only ("Capture and Edit").
    var editNext = false

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Called once with the next result's text, or nil when the capture is cancelled or fails (Shortcuts).
    var onNextResult: ((String?) -> Void)?

    func cancelPending() {
        editNext = false
        cancelProgress()
        finishPending(nil)
    }

    private func finishPending(_ text: String?) {
        let handler = onNextResult
        onNextResult = nil
        handler?(text)
    }

    func deliver(_ text: String, kind: ResultKind, note: String? = nil, result: CaptureResult? = nil) {
        cancelProgress()
        let openEditor = editNext || Prefs.bool(Prefs.Key.openEditor)
        editNext = false
        finishPending(text)
        guard !text.isEmpty else {
            hud.show(symbol: kind == .barcode ? "qrcode.viewfinder" : "text.magnifyingglass",
                     title: kind == .barcode ? "No code found" : "No text found", detail: nil)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "No text found"])
            return
        }

        copy(text)
        if Prefs.bool(Prefs.Key.keepHistory) { history.add(text, kind: kind) }
        lastResult = result ?? .fixed(text, kind: kind)
        if openEditor, let lastResult {
            editor.show(lastResult)
            return
        }

        let words = text.split(whereSeparator: \.isWhitespace).count
        let additive = Prefs.bool(Prefs.Key.additive)
        hud.show(symbol: "checkmark.circle.fill",
                 title: additive ? "Added to clipboard" : "Copied",
                 detail: preview(text),
                 footnote: "\(words) word\(words == 1 ? "" : "s") · \(text.count) characters" + (note.map { " · " + $0 } ?? ""))
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Text copied to clipboard"])

        if Prefs.bool(Prefs.Key.speak) { speak(text) }
        if Prefs.bool(Prefs.Key.openLinks) {
            // Only when the capture is plainly "a link": one link, and little else around it.
            let links = Links.find(in: text)
            if links.count == 1, let link = links.first, text.count <= link.absoluteString.count + 40 {
                NSWorkspace.shared.open(link)
            }
        }
    }

    func fail(_ title: String, detail: String?) {
        cancelProgress()
        finishPending(nil)
        hud.show(symbol: "exclamationmark.triangle.fill", title: title, detail: detail)
    }

    func notify(symbol: String, title: String) {
        hud.show(symbol: symbol, title: title, detail: nil)
    }

    // MARK: Clipboard

    func copy(_ text: String) {
        var value = text
        if Prefs.bool(Prefs.Key.additive) {
            let buffer = Prefs.additiveBuffer
            value = buffer.isEmpty ? text : buffer + "\n" + text
            Prefs.additiveBuffer = value
        }
        write(value)
    }

    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Speech

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(Prefs.defaults.double(forKey: Prefs.Key.speechRate))
        // Read it in the language it is written in, not always the system voice.
        if let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue,
           let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: Progress

    /// Recognition is usually instant; only say something when it is not.
    func showProgressIfSlow() {
        cancelProgress()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.hud.show(symbol: "hourglass", title: "Reading text…", detail: nil, stays: true)
        }
    }

    private func cancelProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }
}

// MARK: - HUD

/// A small panel near the bottom of the screen that confirms what happened and shows what was captured.
final class HUD {
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    func show(symbol: String, title: String, detail: String?, footnote: String? = nil, stays: Bool = false) {
        guard Prefs.bool(Prefs.Key.showHUD) else { return }
        dismissal?.cancel()
        panel?.orderOut(nil)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .medium))
        icon.contentTintColor = symbol.hasPrefix("exclamationmark") ? .systemOrange : .labelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        if let detail, !detail.isEmpty {
            let label = NSTextField(wrappingLabelWithString: detail)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byTruncatingTail
            label.preferredMaxLayoutWidth = 290
            textStack.addArrangedSubview(label)
        }
        if let footnote {
            let label = NSTextField(labelWithString: footnote)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            textStack.addArrangedSubview(label)
        }

        let row = NSStackView(views: [icon, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            background.widthAnchor.constraint(lessThanOrEqualToConstant: 370),
        ])

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = background
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize

        // On the screen the pointer is on, a little above the bottom edge.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.1,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        self.panel = panel

        guard !stays else { return }
        // Long enough to read the preview, then a short fade.
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                panel?.animator().alphaValue = 0
            }, completionHandler: { panel?.orderOut(nil) })
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail == nil ? 1.1 : 1.8), execute: work)
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var text: String
    var kind: ResultKind
}

/// Past captures, kept in a local file only. Newest first.
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let limit = 200
    private let file: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextGrabber", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ text: String, kind: ResultKind) {
        entries.removeAll { $0.text == text }
        entries.insert(HistoryEntry(text: text, kind: kind), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
