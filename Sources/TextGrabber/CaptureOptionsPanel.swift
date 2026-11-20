import AppKit
import SwiftUI
import TextGrabberCore

/// While the user selects an area: the options the keys switch for this capture, and which are on.
///
/// It appears at the first key press, centred at the bottom of the screen with the pointer, and moves to the top
/// while the pointer is low, so it never covers what is being selected. It is left out of the screenshot itself:
/// measured on macOS 27, `screencapture -i` and `-R` leave out a window whose `sharingType` is `.none`.
final class CaptureOptionsPanel {
    private var panel: NSPanel?
    private var host: NSHostingView<CaptureOptionsView>?
    private let model = CaptureOptionsModel()
    private var follow: Timer?
    private var atTop = false
    /// Self-test: put the panel here (bottom-left corner, screen points) instead of out of the pointer's way.
    var testOrigin: NSPoint?

    /// The panel's frame while it shows.
    var frame: NSRect? { panel?.frame }

    /// Shows the panel, or updates it. `keys`: the options whose key works, each with the key's name ("⌘C").
    func show(_ switches: CaptureSwitches, keys: [OptionKey]) {
        model.switches = switches
        model.keys = keys
        if panel == nil { open() }
        place()
    }

    /// Draws the panel as it is now to a PNG, for checking its layout: a screenshot leaves it out. Without the
    /// blur behind it, which only the window server draws.
    func writeSnapshot(to file: URL) -> Bool {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: file)) != nil
    }

    func close() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
        host = nil
        atTop = false
    }

    private func open() {
        let host = NSHostingView(rootView: CaptureOptionsView(model: model))
        let size = host.fittingSize
        let surface = FrostedSurface(frame: NSRect(origin: .zero, size: size))
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
        surface.addSubview(host)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.sharingType = .none   // never part of the picture being captured
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = surface
        self.panel = panel
        self.host = host
        place()
        panel.orderFrontRegardless()
        FrostedSurface.blurBehind(panel)
        // The pointer moves while the user drags; keep out of its way.
        follow = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.place() }
    }

    private func place() {
        guard let panel, let host else { return }
        let size = host.fittingSize
        if let testOrigin {
            panel.setFrame(NSRect(origin: testOrigin, size: size), display: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let bottom = visible.minY + 24
        let top = visible.maxY - size.height - 24
        // Switch edges when the pointer comes near the one in use; the other edge is far away, so it cannot flicker.
        if !atTop, mouse.y < bottom + size.height + 90 { atTop = true }
        if atTop, mouse.y > top - 90 { atTop = false }
        let frame = NSRect(x: visible.midX - size.width / 2, y: atTop ? top : bottom, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// An option and the name of the key that switches it ("⌘C").
struct OptionKey: Identifiable, Equatable {
    var option: CaptureOption
    var key: String
    var id: CaptureOption { option }
}

final class CaptureOptionsModel: ObservableObject {
    @Published var switches = CaptureSwitches()
    @Published var keys: [OptionKey] = []
}

struct CaptureOptionsView: View {
    @ObservedObject var model: CaptureOptionsModel

    var body: some View {
        HStack(spacing: 8) {
            Text("This capture")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            ForEach(model.keys) { item in
                chip(item.option, key: item.key, on: model.switches[item.option])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .fixedSize()
    }

    private func chip(_ option: CaptureOption, key: String, on: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: option.symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(option.title)
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(on ? 0 : 0.08)))
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(on ? 0.25 : 0)))
        }
        .font(.system(size: 12, weight: on ? .semibold : .medium))
        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.6))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.07))))
        .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.3 : 0.15), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.12), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.title), \(on ? "on" : "off"), \(key)")
    }
}
