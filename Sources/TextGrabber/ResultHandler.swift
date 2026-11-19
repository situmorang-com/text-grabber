import AppKit
import AVFoundation
import NaturalLanguage
import TextGrabberCore

enum ResultKind: String, Codable {
    case text, barcode
}

/// A capture that held QR codes or barcodes: what was copied, and the alternatives the confirmation offers.
struct CodeOffer {
    var choice: CodeTriage.Choice
    var codes: [FoundCode]
    /// The capture's text without the codes ("" when it had none worth keeping).
    var textOnly: String
    var codesOnly: String
}

/// Everything that happens once text has been recognised: clipboard, history, HUD, speech, links.
final class ResultHandler {
    let history = CaptureHistory.standard()
    private let hud = HUD()
    private let codeConfirmation = CodeConfirmation()
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

    func deliver(_ text: String, kind: ResultKind, note: String? = nil, result: CaptureResult? = nil, picture: CGImage? = nil,
                 codes offer: CodeOffer? = nil) {
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
        if Prefs.bool(Prefs.Key.keepHistory) {
            history.add(text, kind: kind.rawValue, picture: Prefs.bool(Prefs.Key.historyPictures) ? picture : nil)
        }
        lastResult = result ?? .fixed(text, kind: kind)
        if openEditor, let lastResult {
            editor.show(lastResult)
            return
        }

        let words = text.split(whereSeparator: \.isWhitespace).count
        let additive = Prefs.bool(Prefs.Key.additive)
        if let offer {
            confirmCodes(offer, copied: text, kind: kind)
        } else {
        hud.show(symbol: "checkmark.circle.fill",
                 title: additive ? "Added to clipboard" : "Copied",
                 detail: preview(text),
                 footnote: "\(words) word\(words == 1 ? "" : "s") · \(text.count) characters" + (note.map { " · " + $0 } ?? ""))
        }
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

    /// The confirmation for a capture with codes. A link opens with ↩ or a click, never by itself (unless the
    /// "open links" setting says so); esc leaves what was copied. The other buttons switch the clipboard to the
    /// text only or the codes only.
    private func confirmCodes(_ offer: CodeOffer, copied: String, kind: ResultKind) {
        let links = offer.codes.compactMap(\.link)
        let link = links.count == 1 ? links.first : nil
        let name = offer.codes.count == 1 ? offer.codes[0].kind : "\(offer.codes.count) codes"
        let symbol = offer.codes.allSatisfy { $0.kind == "barcode" } ? "barcode" : "qrcode"
        var current = copied
        let swap = { [weak self] (new: String, newKind: ResultKind, message: String) in
            guard let self else { return }
            self.replaceCopied(current, with: new, kind: newKind)
            current = new
            self.hud.show(symbol: "checkmark.circle.fill", title: message, detail: self.preview(new))
        }
        let open = link.map { url in CodeConfirmation.Action(title: "Open Link") { NSWorkspace.shared.open(url) } }
        let done = CodeConfirmation.Action(title: "Done") {}

        var content: CodeConfirmation.Content
        switch offer.choice {
        case .textAndCodes:
            let lines = offer.textOnly.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let rest = lines.dropFirst().joined(separator: " ")
            content = CodeConfirmation.Content(
                symbol: symbol, caption: "Text and \(name.lowercasedFirst) copied",
                title: lines.first ?? "", detail: rest.isEmpty ? nil : rest,
                linkRow: link?.absoluteString ?? offer.codesOnly.replacingOccurrences(of: "\n", with: "  ·  "),
                primary: open ?? done, showsCancel: open != nil,
                secondary: [
                    .init(title: "Text Only") { swap(offer.textOnly, .text, "Copied the text only") },
                    .init(title: offer.codes.count == 1 ? "Code Only" : "Codes Only") { swap(offer.codesOnly, .barcode, "Copied the code only") },
                ])
        default:
            content = CodeConfirmation.Content(
                symbol: symbol,
                caption: link != nil ? "Link from \(name.lowercasedFirst) copied" : "\(name.uppercasedFirst) copied",
                // The site in large type: it is what to check before opening a link from a code.
                title: link?.host ?? offer.codesOnly, titleIsCode: link == nil,
                detail: link?.absoluteString,
                primary: open ?? done, showsCancel: open != nil)
            if !offer.textOnly.isEmpty {
                content.secondary = [.init(title: "Copy the Text Instead") { swap(offer.textOnly, .text, "Copied the text") }]
            }
        }
        codeConfirmation.show(content)
    }

    /// The clipboard, history and "Edit Last Capture" switch from what a capture copied to another version of it.
    private func replaceCopied(_ old: String, with new: String, kind: ResultKind) {
        if Prefs.bool(Prefs.Key.additive), Prefs.additiveBuffer.hasSuffix(old) {
            let buffer = String(Prefs.additiveBuffer.dropLast(old.count)) + new
            Prefs.additiveBuffer = buffer
            write(buffer)
        } else {
            write(new)
        }
        if Prefs.bool(Prefs.Key.keepHistory) { history.replaceText(old, with: new) }
        lastResult = .fixed(new, kind: kind)
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
            // Tail truncation on the label itself would make it one line; truncate only the last visible line.
            label.lineBreakMode = .byWordWrapping
            label.cell?.truncatesLastVisibleLine = true
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
        scheduleFade(after: detail == nil ? 1.1 : 1.8)
    }

    private func scheduleFade(after delay: TimeInterval) {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                panel?.animator().alphaValue = 0
            }, completionHandler: { panel?.orderOut(nil) })
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

private extension String {
    /// "Aztec code" → "aztec code", for use mid-sentence; an acronym ("QR code") stays as it is.
    var lowercasedFirst: String {
        guard let first, first.isUppercase, dropFirst().first?.isLowercase ?? true else { return self }
        return first.lowercased() + dropFirst()
    }

    /// "barcode" → "Barcode", for a title.
    var uppercasedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - History

typealias HistoryStore = CaptureHistory

extension CaptureHistory {
    /// The app's history, in Application Support.
    static func standard() -> CaptureHistory {
        CaptureHistory(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextGrabber", isDirectory: true))
    }
}

extension HistoryEntry {
    var resultKind: ResultKind { ResultKind(rawValue: kind) ?? .text }
}
