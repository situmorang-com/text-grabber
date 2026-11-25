import AppKit
import SwiftUI

/// The confirmation for a capture that held a QR code or barcode: a frosted glass panel near the bottom of the
/// screen. ⏎ runs the main action (open the link), ⎋ the escape action (copy both), ⌘C and ⌘L the others.
///
/// While it shows, it takes the keyboard without activating TextGrabber, so the app in front stays in front.
/// Any other key closes it and goes on to that app, so typing or ⌘V right after a capture is not lost
/// (passing a key on needs Accessibility; without it the panel never takes the keyboard and works by click).
final class CodeConfirmation {
    struct Action {
        var title: String
        /// ⌘ plus this key runs the action while the panel shows (secondary actions), e.g. "c" for ⌘C.
        var commandKey: Character?
        var perform: () -> Void

        init(title: String, commandKey: Character? = nil, perform: @escaping () -> Void) {
            self.title = title
            self.commandKey = commandKey
            self.perform = perform
        }
    }

    struct Content {
        var card: CardContent
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

        // The ⌘ ones at the left, then esc's, then the main action at the right.
        var buttons = content.secondary.enumerated().map { index, action in
            CardButton(title: action.title, key: action.commandKey.map { "⌘" + String($0).uppercased() }) { [weak self] in
                self?.choose(.secondary(index))
            }
        }
        if let escape = content.escape {
            buttons.append(CardButton(title: escape.title, key: "⎋", trailing: true) { [weak self] in self?.choose(.cancel) })
        }
        buttons.append(CardButton(title: content.primary.title, key: "⏎", prominent: true, trailing: true) { [weak self] in
            self?.choose(.primary)
        })
        let card = ConfirmationCardView.sized(content.card, buttons: buttons, keyHints: takesKeyboard)
        let view = card.onHover { [weak self] inside in
            if inside { self?.dismissal?.cancel() } else { self?.scheduleClose(after: 3) }
        }
        let host = FirstClickHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.takesKeyboard = takesKeyboard
        panel.title = WindowSnapshot.titles["codes"] ?? ""
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
        panel.onCommandKey = { [weak self] key in
            guard let index = content.secondary.firstIndex(where: { $0.commandKey == key }) else { return false }
            self?.choose(.secondary(index))
            return true
        }
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
    /// ⌘ plus a key; true when an action took it.
    var onCommandKey: ((Character) -> Bool)?

    override var canBecomeKey: Bool { takesKeyboard }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return super.sendEvent(event) }
        switch Int(event.keyCode) {
        case 36, 76: onReturn?()      // return, keypad enter
        case 53: onEscape?()          // esc
        default:
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased().first,
               onCommandKey?(key) == true { return }
            onOtherKey?(event)
        }
    }
}

/// Buttons answer the first click even when the panel is not key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Frosted glass: a see-through tint in the panel's rounded shape and a fine light edge, over what the window
/// server blurs behind the panel. It keeps the colour of what is behind, where system materials turn grey.
final class FrostedSurface: NSView {
    static let cornerRadius: CGFloat = 16

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
