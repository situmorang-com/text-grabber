import AppKit
import TextGrabberCore

enum CaptureKind {
    case text(LineMode?)   // nil: use the setting
    case barcode
    /// Select an area, then keep capturing it while the user scrolls.
    case scrolling
}

/// Lets the user pick an area with the system crosshair, then hands the pixels to recognition.
final class CaptureController {
    private(set) var isBusy = false
    private let output: ResultHandler
    private(set) lazy var scrolling = ScrollingCapture(output: output) { [weak self] in self?.isBusy = false }

    init(output: ResultHandler) {
        self.output = output
    }

    // MARK: Screen

    /// - Parameter probeRect: capture this exact area ("x,y,w,h") and only write the capture log:
    ///   no clipboard, history or confirmation. For checking what the app does on a known piece of screen.
    /// - Returns: whether a capture started (false when one is already running or access is missing).
    @discardableResult
    func captureScreen(_ kind: CaptureKind, lastArea: Bool = false, probeRect: String? = nil) -> Bool {
        guard !isBusy else { return false }
        guard ensureScreenAccess() else { return false }
        if Prefs.bool(Prefs.Key.exactText) { AccessibilityText.wakeRunningApps() }

        var arguments: [String] = []
        if let probeRect {
            arguments += ["-R", probeRect]
        } else if lastArea, let rect = Prefs.lastRect {
            arguments += ["-R", rect]
        } else {
            arguments += ["-i"]
        }
        if Prefs.bool(Prefs.Key.muteShutter) { arguments += ["-x"] }
        // No window shadow, so the image covers exactly the recorded rectangle.
        arguments += ["-o"]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("textgrabber-\(UUID().uuidString).png")
        arguments += ["-t", "png", file.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { [weak self] _ in
            // Take the pixels into memory and remove the file straight away: nothing stays on disk.
            let data = try? Data(contentsOf: file)
            let rect = Self.captureRect(of: file)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data, let image = ImagePrep.image(from: data) else {
                    self.isBusy = false   // Esc pressed: nothing to do
                    self.output.cancelPending()
                    return
                }
                if let probeRect {
                    self.recognise([image], kind: kind, screenRect: Self.rect(from: probeRect), probe: true)
                    return
                }
                if let rect { Prefs.lastRect = rect }
                if case .scrolling = kind {
                    guard let area = Self.rect(from: rect) else {
                        self.isBusy = false
                        self.output.fail("Scrolling capture needs an area", detail: "Drag to select the part of the window to scroll through.")
                        return
                    }
                    self.scrolling.start(rect: area, firstFrame: image)   // stays busy until Done or Cancel
                    return
                }
                self.recognise([image], kind: kind, screenRect: Self.rect(from: rect ?? (lastArea ? Prefs.lastRect : nil)))
            }
        }
        isBusy = true
        do {
            try process.run()
        } catch {
            isBusy = false
            output.fail("Screen capture could not start", detail: error.localizedDescription)
            return false
        }
        return true
    }

    /// The selected rectangle, which macOS records on the screenshot file itself.
    static func captureRect(of file: URL) -> String? {
        let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
              values.count == 4 else { return nil }
        return values.map { String($0.intValue) }.joined(separator: ",")
    }

    /// For the first few screen captures without Accessibility access, say what it would add.
    private func accessHint(_ screenRect: CGRect?) -> String? {
        let key = "accessHintsShown"
        let shown = Prefs.defaults.integer(forKey: key)
        guard screenRect != nil, Prefs.bool(Prefs.Key.exactText), !AccessibilityText.isTrusted, shown < 3 else { return nil }
        Prefs.defaults.set(shown + 1, forKey: key)
        return "for exact emoji and symbols, grant Accessibility in Settings → Recognition"
    }

    /// True when every sampled pixel is nearly the same colour.
    static func looksBlank(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let colour = pixels.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
        return (colour.max() ?? 0) - (colour.min() ?? 0) < 12
    }

    static func rect(from text: String?) -> CGRect? {
        guard let parts = text?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private func ensureScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // The first call makes macOS show its own prompt; later calls do nothing, so explain.
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "TextGrabber needs Screen Recording permission"
        alert.informativeText = "Turn on TextGrabber under System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen TextGrabber."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: Other sources

    func recogniseClipboard() {
        guard !isBusy else { return }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            recogniseFiles(urls)
        } else if let image = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            recognise([image], kind: .text(nil))
        } else {
            output.fail("No image on the clipboard", detail: nil)
        }
    }

    func chooseFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images or PDFs to read text from"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { recogniseFiles(panel.urls) }
    }

    func recogniseFiles(_ urls: [URL]) {
        var images: [CGImage] = []
        for url in urls {
            do {
                images += try Recognizer.loadImages(from: url)
            } catch {
                output.fail("Could not read \(url.lastPathComponent)", detail: error.localizedDescription)
                return
            }
        }
        recognise(images, kind: .text(nil))
    }

    // MARK: Recognition

    private func recognise(_ images: [CGImage], kind: CaptureKind, screenRect: CGRect? = nil, probe: Bool = false) {
        isBusy = true
        if !probe { output.showProgressIfSlow() }
        DispatchQueue.global(qos: .userInitiated).async {
            switch kind {
            case .barcode:
                let payloads = images.flatMap { (try? Recognizer.readBarcodes(in: $0)) ?? [] }
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.output.deliver(payloads.joined(separator: "\n"), kind: .barcode, picture: images.first)
                }
            case .scrolling:
                // Started from the selection instead (see captureScreen); a file or clipboard image is read normally.
                DispatchQueue.main.async { self.isBusy = false }
                self.recognise(images, kind: .text(nil), screenRect: screenRect, probe: probe)
            case .text(let override):
                let options = Prefs.recognitionOptions(lineMode: override)
                var pages: [[TextFragment]] = []
                var structures: [DocumentStructure?] = []
                var failure: Error?
                var exactLines = 0
                var report = ""
                if probe, let image = images.first {
                    report += "image: \(image.width)×\(image.height) px, \(Self.looksBlank(image) ? "BLANK (one flat colour: the app may lack Screen Recording access)" : "has content")\n"
                }
                for image in images {
                    do {
                        let result = try Recognizer.readFragments(in: image, options: options)
                        pages.append(result.fragments)
                        structures.append(result.structure)
                    } catch { failure = error }
                }
                // A screen capture of a real window: swap in the app's own text where it lines up (emoji, symbols).
                if let screenRect, pages.count == 1, Prefs.bool(Prefs.Key.exactText) {
                    let refined = AccessibilityText.refine(pages[0], capturedFrom: screenRect)
                    pages[0] = refined.fragments
                    exactLines = refined.replaced
                    report += refined.report
                }
                DispatchQueue.main.async {
                    self.isBusy = false
                    // Layout uses the spelling dictionary, which belongs on the main thread.
                    let structured = StructuredText(zip(pages, structures).flatMap { page, structure in
                        Recognizer.compose(page, structure: structure, options: options).blocks
                    })
                    let text = structured.render(OutputFormat.format, tables: OutputFormat.tableStyle)
                    if let structure = structures.first ?? nil {
                        report += "document structure: \(structure.paragraphs.count) paragraphs, \(structure.tables.count) tables\n"
                    }
                    if !report.isEmpty || probe {
                        report += "lines recognised: \(pages.reduce(0) { $0 + $1.count })\n"
                        AccessibilityText.writeLog(report + "\ntext delivered (\(options.lineMode.rawValue)):\n" + text + "\n")
                    }
                    if probe { return }
                    if text.isEmpty, let failure {
                        self.output.fail("Text recognition failed", detail: failure.localizedDescription)
                    } else {
                        self.output.deliver(text, kind: .text, note: exactLines > 0 ? "exact text from the app" : self.accessHint(screenRect),
                                            result: CaptureResult(pages: pages, structures: structures, options: options, kind: .text),
                                            picture: images.first)
                    }
                }
            }
        }
    }
}
