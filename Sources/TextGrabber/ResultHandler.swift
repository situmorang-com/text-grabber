import AppKit
import SwiftUI
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

/// A self-test's stand-in for the clipboard and the speakers.
final class DryRun {
    /// Starts as the pretend clipboard text; holds what would have been copied.
    var clipboard: String
    var spoken: [String] = []
    private(set) var events: [String] = []
    var onRecord: (() -> Void)?

    init(clipboard: String) {
        self.clipboard = clipboard
    }

    func record(_ event: String) {
        events.append(event)
        onRecord?()
    }
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
    /// Self-test: clipboard and speech are recorded here instead of used; no history, confirmation or editor.
    var dryRun: DryRun?
    /// The clipboard text the last capture was added to (nil: it replaced the clipboard), and how.
    private var additiveBase: String?
    private var additiveNewLine = false

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

    /// - Parameter switches: the capture's options (add to the clipboard, line breaks, read aloud); nil: the settings.
    func deliver(_ text: String, kind: ResultKind, note: String? = nil, result: CaptureResult? = nil, picture: CGImage? = nil,
                 codes offer: CodeOffer? = nil, switches: CaptureSwitches? = nil) {
        cancelProgress()
        let switches = switches ?? .settings()
        let openEditor = (editNext || Prefs.bool(Prefs.Key.openEditor)) && dryRun == nil
        editNext = false
        finishPending(text)
        guard !text.isEmpty else {
            dryRun?.record("no text")
            guard dryRun == nil else { return }
            hud.show(symbol: kind == .barcode ? "qrcode.viewfinder" : "text.magnifyingglass",
                     title: kind == .barcode ? "No code found" : "No text found", detail: nil)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "No text found"])
            return
        }

        // A table never runs into the clipboard's last line, whatever format it is written in (CSV looks like prose).
        let isTable = switches.additive && (result?.structured(lineMode: .paragraphs).hasTable ?? false)
        let added = copy(text, switches: switches, textIsTable: isTable)
        if Prefs.bool(Prefs.Key.keepHistory), dryRun == nil {
            history.add(text, kind: kind.rawValue, picture: Prefs.bool(Prefs.Key.historyPictures) ? picture : nil)
        }
        if dryRun == nil {
            lastResult = result ?? .fixed(text, kind: kind)
            if added, let base = additiveBase { lastResult?.addedTo = (base, additiveNewLine) }
        }
        // Read the capture itself, not everything on the clipboard: what was copied, and for a page with a code,
        // its text without the link.
        if switches.speak {
            speak(offer.flatMap { $0.choice == .textAndCodes && !$0.textOnly.isEmpty ? $0.textOnly : nil } ?? text)
        }
        if let dryRun {
            hud.hide()   // a "Reading text…" that showed while the test capture was read
            dryRun.record("delivered (\(added ? (additiveNewLine ? "added on a new line" : "added on the same line") : "replaced the clipboard"))")
            return
        }
        if openEditor, let lastResult {
            editor.show(lastResult)
            return
        }

        let words = text.split(whereSeparator: \.isWhitespace).count
        if let offer {
            confirmCodes(offer, copied: text, kind: kind)
        } else {
            var footnote = "\(words) word\(words == 1 ? "" : "s") · \(text.count) characters"
            if added { footnote += additiveNewLine ? " · on a new line" : " · on the same line" }
            if let note { footnote += " · " + note }
            hud.show(symbol: added ? "plus.square.on.square" : "checkmark.circle.fill",
                     title: added ? "Added to clipboard" : "Copied",
                     detail: preview(text), footnote: footnote)
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: added ? "Text added to clipboard" : "Text copied to clipboard"])

        if Prefs.bool(Prefs.Key.openLinks) {
            // Only when the capture is plainly "a link": one link, and little else around it.
            let links = Links.find(in: text)
            if links.count == 1, let link = links.first, text.count <= link.absoluteString.count + 40 {
                NSWorkspace.shared.open(link)
            }
        }
    }

    /// The confirmation for a capture with codes. Whatever was copied first (the code, or the text and the code),
    /// it offers: Text (⌘C), QR (⌘L), Both (⎋, on separate lines), and Open Link (⏎), which copies both too.
    /// A link never opens by itself (unless the "open links" setting says so).
    private func confirmCodes(_ offer: CodeOffer, copied: String, kind: ResultKind) {
        let links = offer.codes.compactMap(\.link)
        let link = links.count == 1 ? links.first : nil
        let name = offer.codes.count == 1 ? offer.codes[0].kind : "\(offer.codes.count) codes"
        let symbol = offer.codes.allSatisfy { $0.kind == "barcode" } ? "barcode" : "qrcode"
        // Short button names: "QR" for a QR code (link or not), "Barcode", "Codes" for several.
        let codeWord = offer.codes.count > 1 ? "Codes" : offer.codes[0].kind == "QR code" ? "QR" : offer.codes[0].kind.uppercasedFirst
        // Both, each on its own lines: the text, then every code it does not already contain.
        let extra = CodeTriage.codes(notIn: offer.textOnly, offer.codes)
        let both = offer.textOnly.isEmpty ? offer.codesOnly
            : extra.isEmpty ? offer.textOnly : offer.textOnly + "\n\n" + CodeTriage.codesText(extra)

        var current = copied
        // What this capture was added to, if anything: a choice made here goes in the same place.
        let base = additiveBase
        let newLine = additiveNewLine
        let copy = { [weak self] (new: String, newKind: ResultKind, message: String) in
            guard let self else { return }
            if new != current {
                self.replaceCopied(current, with: new, kind: newKind, addedTo: base, newLine: newLine)
                current = new
            }
            self.hud.show(symbol: "checkmark.circle.fill", title: message, detail: self.preview(new))
        }
        var secondary: [CodeConfirmation.Action] = []
        var escape: CodeConfirmation.Action?
        if !offer.textOnly.isEmpty {
            secondary = [
                .init(title: "Text", commandKey: "c") { copy(offer.textOnly, .text, "Copied the text only") },
                .init(title: codeWord, commandKey: "l") { copy(offer.codesOnly, .barcode, "Copied the \(name.lowercasedFirst) only") },
            ]
            escape = .init(title: "Both") { copy(both, .text, "Copied the text and the \(name.lowercasedFirst)") }
        }
        // Opening the link also leaves both the text and the link on the clipboard.
        let primary = link.map { url in
            CodeConfirmation.Action(title: "Open Link") {
                if !offer.textOnly.isEmpty { copy(both, .text, "Copied the text and the \(name.lowercasedFirst)") }
                NSWorkspace.shared.open(url)
            }
        } ?? CodeConfirmation.Action(title: "Done") {}

        let card: CardContent
        if offer.choice == .textAndCodes {
            card = CardContent(
                symbol: symbol, tint: .accentColor, headline: "Text and \(name.lowercasedFirst) copied",
                text: preview(offer.textOnly),
                chip: link?.absoluteString ?? offer.codesOnly.replacingOccurrences(of: "\n", with: "  ·  "),
                chipSymbol: link != nil ? "link" : symbol)
        } else if let link {
            // The site in large type: it is what to check before opening a link from a code.
            card = CardContent(symbol: symbol, tint: .accentColor, headline: "Link from \(name.lowercasedFirst) copied",
                               text: link.host ?? link.absoluteString, style: .prominent, detail: link.absoluteString)
        } else {
            // Only the code, and nothing to choose: the notice every capture shows, not a panel to dismiss.
            let digits = offer.codesOnly.allSatisfy(\.isNumber)
            hud.show(symbol: symbol, title: "\(name.uppercasedFirst) copied", detail: offer.codesOnly, detailIsCode: true,
                     footnote: offer.codes.count > 1 ? nil : "\(offer.codesOnly.count) \(digits ? "digits" : "characters")")
            return
        }
        codeConfirmation.show(CodeConfirmation.Content(card: card, primary: primary, escape: escape, secondary: secondary))
    }

    /// Shows a card with made-up content, for checking how it looks (textgrabber://demo?card=…). Copies nothing.
    func showDemo(_ name: String) {
        switch name {
        case "barcode":
            hud.show(symbol: "barcode", title: "Barcode copied", detail: "020590016345026", detailIsCode: true, footnote: "15 digits")
        case "link":
            codeConfirmation.show(.init(card: CardContent(
                symbol: "qrcode", tint: .accentColor, headline: "Link from QR code copied", text: "example.com", style: .prominent,
                detail: "https://example.com/menu/table-12?lang=en"), primary: .init(title: "Open Link") {}))
        case "textcode":
            codeConfirmation.show(.init(card: CardContent(
                symbol: "qrcode", tint: .accentColor, headline: "Text and QR code copied",
                text: preview("Scan to see today's menu\nOrder at the counter and pay by card"),
                chip: "https://example.com/menu", chipSymbol: "link"),
                primary: .init(title: "Open Link") {}, escape: .init(title: "Both") {},
                secondary: [.init(title: "Text", commandKey: "c") {}, .init(title: "QR", commandKey: "l") {}]))
        case "long":
            hud.show(symbol: "checkmark.circle.fill", title: "Copied",
                     detail: preview("The quick brown fox jumps over the lazy dog, then runs across the field to the river where it stops to drink before heading home again."),
                     footnote: "27 words · 141 characters")
        case "added":
            hud.show(symbol: "plus.square.on.square", title: "Added to clipboard", detail: "+62 812-555-0199",
                     footnote: "1 word · 16 characters · on a new line")
        default:
            hud.show(symbol: "checkmark.circle.fill", title: "Copied", detail: "020590016345026", footnote: "1 word · 15 characters")
        }
    }

    /// The clipboard, history and "Edit Last Capture" switch from what a capture copied to another version of it.
    private func replaceCopied(_ old: String, with new: String, kind: ResultKind, addedTo base: String?, newLine: Bool) {
        if let base {
            write(AdditiveText.append(new, to: base, newLine: newLine, isWord: Dictionary.isWholeWord))
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

    /// Puts a capture on the clipboard: in place of what is there, or, when `switches.additive`, after the text
    /// already on it (on the same line, or a new one with `switches.keepLines`; see `AdditiveText`).
    /// - Returns: whether it was added to earlier text. A clipboard with no text (an image, nothing) is replaced.
    @discardableResult
    func copy(_ text: String, switches: CaptureSwitches, textIsTable: Bool = false) -> Bool {
        additiveBase = nil
        additiveNewLine = switches.keepLines
        guard switches.additive, let base = clipboardText(), !base.allSatisfy(\.isWhitespace) else {
            write(text)
            return false
        }
        additiveBase = base
        write(AdditiveText.append(text, to: base, newLine: switches.keepLines, textIsTable: textIsTable, isWord: Dictionary.isWholeWord))
        return true
    }

    func write(_ text: String) {
        if let dryRun {
            dryRun.clipboard = text
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The clipboard's text, when it is text a capture may be added to. A password (marked concealed or transient
    /// by password managers) or copied files (whose text is only their names) count as no text: they are replaced.
    private func clipboardText() -> String? {
        if let dryRun { return dryRun.clipboard }
        let pasteboard = NSPasteboard.general
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let notText: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "public.file-url",
                                    NSPasteboard.PasteboardType.fileURL.rawValue]
        guard types.isDisjoint(with: notText) else { return nil }
        return pasteboard.string(forType: .string)
    }

    // MARK: Speech

    func speak(_ text: String) {
        if let dryRun {
            dryRun.spoken.append(text)
            return
        }
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

    func hide() {
        dismissal?.cancel()
        panel?.orderOut(nil)
    }
    /// - Parameter detailIsCode: the detail is a code's contents, shown in monospaced type.
    func show(symbol: String, title: String, detail: String?, detailIsCode: Bool = false, footnote: String? = nil, stays: Bool = false) {
        guard Prefs.bool(Prefs.Key.showHUD) else { return }
        dismissal?.cancel()
        panel?.orderOut(nil)

        let card = ConfirmationCardView.sized(CardContent(
            symbol: symbol, tint: CardContent.tint(for: symbol), headline: title,
            text: detail, style: detailIsCode ? .code : .preview, footnote: footnote))
        let host = NSHostingView(rootView: card)
        let size = host.fittingSize
        let surface = FrostedSurface(frame: NSRect(origin: .zero, size: size))
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
        surface.addSubview(host)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = WindowSnapshot.titles["hud"] ?? ""
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.contentView = surface

        // On the screen the pointer is on, a little above the bottom edge.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.1,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        FrostedSurface.blurBehind(panel)
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
