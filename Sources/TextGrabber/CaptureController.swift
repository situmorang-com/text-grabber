import AppKit
import TextGrabberCore

enum CaptureKind {
    case text(LineMode?)   // nil: use the setting
    case barcode
}

/// Lets the user pick an area with the system crosshair, then hands the pixels to recognition.
final class CaptureController {
    private(set) var isBusy = false
    private let output: ResultHandler

    init(output: ResultHandler) {
        self.output = output
    }

    // MARK: Screen

    func captureScreen(_ kind: CaptureKind, lastArea: Bool = false) {
        guard !isBusy else { return }
        guard ensureScreenAccess() else { return }

        var arguments: [String] = []
        if lastArea, let rect = Prefs.lastRect {
            arguments += ["-R", rect]
        } else {
            arguments += ["-i"]
        }
        if Prefs.bool(Prefs.Key.muteShutter) { arguments += ["-x"] }
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
                    return
                }
                if let rect { Prefs.lastRect = rect }
                self.recognise([image], kind: kind)
            }
        }
        isBusy = true
        do {
            try process.run()
        } catch {
            isBusy = false
            output.fail("Screen capture could not start", detail: error.localizedDescription)
        }
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

    private func recognise(_ images: [CGImage], kind: CaptureKind) {
        isBusy = true
        output.showProgressIfSlow()
        DispatchQueue.global(qos: .userInitiated).async {
            switch kind {
            case .barcode:
                let payloads = images.flatMap { (try? Recognizer.readBarcodes(in: $0)) ?? [] }
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.output.deliver(payloads.joined(separator: "\n"), kind: .barcode)
                }
            case .text(let override):
                let options = Prefs.recognitionOptions(lineMode: override)
                var pages: [[TextFragment]] = []
                var failure: Error?
                for image in images {
                    do { pages.append(try Recognizer.readFragments(in: image, options: options).fragments) }
                    catch { failure = error }
                }
                DispatchQueue.main.async {
                    self.isBusy = false
                    // Layout uses the spelling dictionary, which belongs on the main thread.
                    let text = pages.map { Recognizer.compose($0, options: options) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    if text.isEmpty, let failure {
                        self.output.fail("Text recognition failed", detail: failure.localizedDescription)
                    } else {
                        self.output.deliver(text, kind: .text)
                    }
                }
            }
        }
    }
}
