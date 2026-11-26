import AppKit
import TextGrabberCore

/// Watches the keyboard for shortcuts pressed twice (⌥2 2), which Carbon hot keys cannot do.
///
/// A first press of such a shortcut is held back for `DoublePressMachine.window` (a quarter second); without a
/// second press it is sent on to the app in front unchanged, just that much later. Changing key events needs
/// Accessibility; without it the tap cannot be made and `start` says so.
final class DoublePressTap {
    /// Runs on the main thread.
    var fire: ((DoublePressMachine.Key) -> Void)?
    /// While true every key goes straight through (the shortcut recorder is listening).
    var paused = false

    private var machine = DoublePressMachine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The events held back, in order, to send on when the press turns out to be an ordinary one.
    private var held: [CGEvent] = []
    private var timer: DispatchWorkItem?
    /// Events sent on that have not come round yet, and when the last was sent. Until they have, later events
    /// are sent on behind them too: let through at once, a key up would reach the app before its key down.
    private var inFlight = 0
    private var lastSent = Date.distantPast
    /// Marks the events this tap sends on, so it lets them pass when they come round again.
    private static let marker: Int64 = 0x5447_5242

    /// Watches these keys (an empty set stops watching). False when the tap could not be made (no Accessibility).
    @discardableResult
    func start(watching keys: Set<DoublePressMachine.Key>) -> Bool {
        flush()
        machine = DoublePressMachine(watched: keys)
        guard !keys.isEmpty else {
            stop()
            return true
        }
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<DoublePressTap>.fromOpaque(info).takeUnretainedValue()
            return owner.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        flush()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches off a tap it finds slow; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            inFlight = max(inFlight - 1, 0)
            return Unmanaged.passUnretained(event)
        }
        // One that never came round must not hold up the keyboard.
        if inFlight > 0, Date().timeIntervalSince(lastSent) > 0.5 { inFlight = 0 }
        guard !paused else { return passOrQueue(event) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let decision: DoublePressMachine.Decision
        switch type {
        case .keyDown:
            let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).rawValue
            decision = machine.keyDown(.init(code: code, modifiers: UInt(modifiers)),
                                       isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            decision = machine.keyUp(code: code)
        default:
            return passOrQueue(event)
        }

        switch decision {
        case .pass:
            return passOrQueue(event)
        case .hold:
            if held.isEmpty { startTimer() }
            if let copy = event.copy() { held.append(copy) }
            return nil
        case .drop:
            return nil
        case .fire(let key):
            timer?.cancel()
            held.removeAll()
            DispatchQueue.main.async { [weak self] in self?.fire?(key) }
            return nil
        case .release:
            // This event goes after the held ones, so it is sent on too rather than let through now.
            if let copy = event.copy() { held.append(copy) }
            sendHeld()
            return nil
        }
    }

    /// Lets the event through, or sends it on behind events still on their way, so the order stays the same.
    private func passOrQueue(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard inFlight > 0, let copy = event.copy() else { return Unmanaged.passUnretained(event) }
        send([copy])
        return nil
    }

    private func startTimer() {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.machine.timeout() else { return }
            self.sendHeld()
        }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DoublePressMachine.window, execute: work)
    }

    private func sendHeld() {
        timer?.cancel()
        let events = held
        held.removeAll()
        send(events)
    }

    private func send(_ events: [CGEvent]) {
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            inFlight += 1
            lastSent = Date()
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Sends on anything still held, e.g. before the watched keys change.
    private func flush() {
        if machine.timeout() { sendHeld() }
    }
}

