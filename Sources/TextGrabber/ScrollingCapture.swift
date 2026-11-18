import AppKit
import SwiftUI
import TextGrabberCore

/// Captures an area again and again while the user scrolls its content, then reads the pictures as one page.
final class ScrollingCapture {
    private let output: ResultHandler
    private let onFinish: () -> Void
    private var rect: CGRect = .zero              // global, top-left origin, points
    private var frames: [CGImage] = []
    private var lastFrameData: Data?
    private var running = false
    private var panel: NSPanel?
    private let state = ScrollingState()
    /// Self-test: write the result to the capture log only.
    private var logOnly = false
    private static let maximumFrames = 120

    var isRunning: Bool { running }

    init(output: ResultHandler, onFinish: @escaping () -> Void) {
        self.output = output
        self.onFinish = onFinish
    }

    /// Starts with the area the user selected and the picture of it taken at that moment.
    func start(rect: CGRect, firstFrame: CGImage, logOnly: Bool = false) {
        self.rect = rect
        self.logOnly = logOnly
        frames = [firstFrame]
        lastFrameData = nil
        running = true
        state.frames = 1
        showPanel()
        scheduleNext()
    }

    func finish() {
        guard running else { return }
        running = false
        closePanel()
        let captured = frames
        frames = []
        output.showProgressIfSlow()
        let options = Prefs.recognitionOptions()
        DispatchQueue.global(qos: .userInitiated).async {
            var stitchFrames: [ScrollStitcher.Frame] = []
            var recognitionOptions = options
            recognitionOptions.useDocumentStructure = false
            for image in captured {
                let fragments = (try? Recognizer.readFragments(in: image, options: recognitionOptions).fragments) ?? []
                stitchFrames.append(ScrollStitcher.Frame(fragments: fragments, size: CGSize(width: image.width, height: image.height)))
            }
            let stitched = ScrollStitcher.stitch(stitchFrames)
            DispatchQueue.main.async {
                self.onFinish()
                let result = CaptureResult(pages: [stitched.fragments], structures: [nil], options: options, kind: .text)
                let text = result.structured(lineMode: options.lineMode).render(OutputFormat.format, tables: OutputFormat.tableStyle)
                var note = "\(captured.count) pictures"
                if stitched.gaps > 0 { note += " · scrolled too fast in \(stitched.gaps) place\(stitched.gaps == 1 ? "" : "s"): text may be missing" }
                if self.logOnly {
                    self.output.cancelPending()
                    AccessibilityText.writeLog("scrolling capture self-test\npictures: \(captured.count), gaps: \(stitched.gaps), unchanged: \(stitched.unchanged)\n\ntext delivered:\n\(text)\n")
                    return
                }
                self.output.deliver(text, kind: .text, note: note, result: result, picture: captured.first)
            }
        }
    }

    func cancel() {
        running = false
        frames = []
        closePanel()
        output.cancelPending()
        onFinish()
    }

    // MARK: Frames

    private func scheduleNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.grab() }
    }

    private func grab() {
        guard running else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("textgrabber-scroll-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", "-t", "png", file.path]
        process.terminationHandler = { [weak self] _ in
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                // A picture identical to the last one means nothing moved: keep only pictures that differ.
                if let data, data != self.lastFrameData, let image = ImagePrep.image(from: data) {
                    if self.lastFrameData != nil { self.frames.append(image) }
                    self.lastFrameData = data
                    self.state.frames = self.frames.count
                }
                if self.frames.count >= Self.maximumFrames {
                    self.finish()
                } else {
                    self.scheduleNext()
                }
            }
        }
        do { try process.run() } catch { cancel() }
    }

    // MARK: Panel

    private func showPanel() {
        let view = ScrollingPanelView(state: state, done: { [weak self] in self?.finish() }, cancel: { [weak self] in self?.cancel() })
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.setFrameOrigin(Self.panelOrigin(for: rect, size: size))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Just above the captured area, or just below it when there is no room above; never on top of it.
    /// Self-test: shows a long image in a window of its own, scrolls it step by step, and scroll-captures it.
    /// Writes the result to the capture log; touches neither the clipboard nor the history.
    func selfTest(image: NSImage) {
        guard !running else { return }
        let size = NSSize(width: image.size.width, height: min(260, image.size.height))
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleNone
        let flipped = FlippedView(frame: imageView.frame)
        flipped.addSubview(imageView)
        scroll.documentView = flipped
        scroll.hasVerticalScroller = false
        window.contentView = scroll
        window.center()
        window.orderFrontRegardless()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = window.frame
        let area = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let first = Process()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("textgrabber-selftest.png")
            first.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            first.arguments = ["-x", "-R", "\(Int(area.minX)),\(Int(area.minY)),\(Int(area.width)),\(Int(area.height))", file.path]
            try? first.run()
            first.waitUntilExit()
            guard let data = try? Data(contentsOf: file), let image = ImagePrep.image(from: data) else { window.orderOut(nil); return }
            try? FileManager.default.removeItem(at: file)
            self.start(rect: area, firstFrame: image, logOnly: true)
            var offset: CGFloat = 0
            let total = imageView.frame.height - size.height
            Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { timer in
                offset = min(offset + 90, total)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                if offset >= total {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.finish()
                        window.orderOut(nil)
                    }
                }
            }
        }
    }

    static func panelOrigin(for rect: CGRect, size: CGSize) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let areaTop = primaryHeight - rect.minY            // in AppKit coordinates (bottom-left origin)
        let areaBottom = primaryHeight - rect.maxY
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: primaryHeight - rect.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = CGPoint(x: rect.midX - size.width / 2, y: areaTop + 8)
        if origin.y + size.height > visible.maxY { origin.y = areaBottom - size.height - 8 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        return origin
    }
}

final class ScrollingState: ObservableObject {
    @Published var frames = 0
}

private struct ScrollingPanelView: View {
    @ObservedObject var state: ScrollingState
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.and.down.text.horizontal")
                .font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text("Scroll through the text").font(.system(size: 13, weight: .semibold))
                Text("\(state.frames) picture\(state.frames == 1 ? "" : "s") taken · press Done at the end")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("Cancel", action: cancel)
            Button("Done", action: done).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
