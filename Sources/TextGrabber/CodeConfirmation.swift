import AppKit
import SwiftUI

/// The confirmation for a capture that held a QR code or barcode: a frosted glass panel near the bottom of the
/// screen. ↩ runs the main action (open the link), esc runs the escape action (copy both the text and the code).
///
/// While it shows, it takes the keyboard without activating TextGrabber, so the app in front stays in front.
/// Any other key closes it and goes on to that app, so typing or ⌘V right after a capture is not lost
/// (passing a key on needs Accessibility; without it the panel never takes the keyboard and works by click).
final class CodeConfirmation {
    struct Action {
        var title: String
        var perform: () -> Void
    }

    struct Content {
        var symbol: String
        /// Small line above the title: what happened ("Link from QR code copied").
        var caption: String
        var title: String
        var titleIsCode = false
        var detail: String?
        /// A link shown as its own row under the text (text and code captures).
        var linkRow: String?
        var primary: Action
        /// Run by esc and shown as a button with an "esc" hint; nil: esc only closes.
        var escape: Action?
        var secondary: [Action] = []
    }

    private var panel: KeyPanel?
    private var dismissal: DispatchWorkItem?
    private var content: Content?

    func show(_ content: Content) {
        close()
        self.content = content
        let takesKeyboard = AccessibilityText.isTrusted

        let view = CodeConfirmationView(
            content: content,
            keyHints: takesKeyboard,
            choose: { [weak self] choice in self?.choose(choice) },
            hovering: { [weak self] inside in
                if inside { self?.dismissal?.cancel() } else { self?.scheduleClose(after: 3) }
            })
        let host = FirstClickHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.takesKeyboard = takesKeyboard
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        let surface = FrostedSurface(frame: NSRect(origin: .zero, size: size))
        host.frame = surface.bounds
        host.autoresizingMask = [.width, .height]
        surface.addSubview(host)
        panel.contentView = surface
        panel.onReturn = { [weak self] in self?.choose(.primary) }
        panel.onEscape = { [weak self] in self?.choose(.cancel) }
        panel.onOtherKey = { [weak self] event in
            self?.close()
            // Hand the key to the app in front once the panel has let go of the keyboard.
            if let copy = event.cgEvent?.copy() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { copy.post(tap: .cghidEventTap) }
            }
        }

        // On the screen the pointer is on, a little above the bottom edge.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.1,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 0
        if takesKeyboard { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        FrostedSurface.blurBehind(panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        scheduleClose(after: 10)
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }

    enum Choice { case primary, cancel, secondary(Int) }

    private func choose(_ choice: Choice) {
        guard let content else { return }
        close()
        self.content = nil
        switch choice {
        case .primary: content.primary.perform()
        case .cancel: content.escape?.perform()
        case .secondary(let index): if content.secondary.indices.contains(index) { content.secondary[index].perform() }
        }
    }

    private func scheduleClose(after delay: TimeInterval) {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.panel === panel { self?.close() }
            })
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - Window

/// A panel that can take the keyboard without activating the app, and turns ↩ and esc into actions.
private final class KeyPanel: NSPanel {
    var takesKeyboard = false
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onOtherKey: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { takesKeyboard }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.sendEvent(event) }
        switch Int(event.keyCode) {
        case 36, 76: onReturn?()      // return, keypad enter
        case 53: onEscape?()          // esc
        default: onOtherKey?(event)
        }
    }
}

/// Buttons answer the first click even when the panel is not key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Frosted glass: a see-through tint in the panel's rounded shape and a fine light edge, over what the window
/// server blurs behind the panel. It keeps the colour of what is behind, where system materials turn grey.
private final class FrostedSurface: NSView {
    static let cornerRadius: CGFloat = 20

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let radius = Self.cornerRadius
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        (dark ? NSColor(calibratedWhite: 0.10, alpha: 0.55) : NSColor(calibratedWhite: 1, alpha: 0.45)).setFill()
        shape.fill()
        // A faint sheen from the top, as light catches glass.
        NSGradient(starting: NSColor.white.withAlphaComponent(dark ? 0.07 : 0.25), ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: shape, angle: -90)
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.7)).setStroke()
        edge.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Asks the window server to blur what is behind the panel. A private call (iTerm uses it too), looked up at
    /// run time: if a future macOS removes it, the panel is simply not blurred.
    static func blurBehind(_ window: NSWindow, radius: Int32 = 30) {
        typealias Connection = @convention(c) () -> Int32
        typealias SetBlur = @convention(c) (Int32, Int32, Int32) -> Int32
        guard window.windowNumber > 0,
              let connection = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSDefaultConnectionForThread"),
              let setBlur = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetWindowBackgroundBlurRadius") else { return }
        _ = unsafeBitCast(setBlur, to: SetBlur.self)(unsafeBitCast(connection, to: Connection.self)(), Int32(window.windowNumber), radius)
    }
}

// MARK: - Content

private struct CodeConfirmationView: View {
    let content: CodeConfirmation.Content
    let keyHints: Bool
    let choose: (CodeConfirmation.Choice) -> Void
    let hovering: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(content.caption)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                    Text(content.title)
                        .font(content.titleIsCode ? .system(size: 14, weight: .semibold, design: .monospaced)
                                                  : .system(size: 18, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = content.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(content.linkRow == nil ? 2 : 3)
                            // A link loses its middle (the site and the end stay visible); prose loses its end.
                            .truncationMode(content.linkRow == nil ? .middle : .tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let link = content.linkRow {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text(link).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(Array(content.secondary.enumerated()), id: \.offset) { index, action in
                    Button(action.title) { choose(.secondary(index)) }.buttonStyle(GlassButton()).focusable(false)
                }
                Spacer(minLength: 8)
                if let escape = content.escape {
                    Button { choose(.cancel) } label: { label(escape.title, key: "esc") }.buttonStyle(GlassButton()).focusable(false)
                }
                Button { choose(.primary) } label: { label(content.primary.title, key: "↩") }
                    .buttonStyle(GlassButton(prominent: true)).focusable(false)
            }
        }
        .padding(18)
        .frame(width: 540)
        // ↩ and esc belong to the panel; no button takes keyboard focus or draws a focus ring.
        .focusEffectDisabled()
        .onHover(perform: hovering)
    }

    private var badge: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .overlay(Image(systemName: content.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white))
            .frame(width: 44, height: 44)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 3)
    }

    @ViewBuilder
    private func label(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if keyHints {
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.22)))
            }
        }
    }
}

/// A capsule button for glass: translucent, with a fine light edge; the prominent one in the accent colour.
private struct GlassButton: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.3 : 0.2), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
