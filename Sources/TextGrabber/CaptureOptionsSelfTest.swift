import AppKit
import Carbon.HIToolbox
import TextGrabberCore

/// Self-test for the option keys: `textgrabber://selftest-capture-options?keys=additive,keepLines,speak&base=…`
///
/// Shows a window with two lines of known text, starts a real capture, presses the option keys and drags over the
/// window as a person would, then writes what happened to the capture log. The clipboard is pretend (`base`),
/// nothing is spoken and nothing goes to the history; the pointer is put back afterwards. The options panel is
/// placed inside the selected area, so the log also says whether it stayed out of the picture, and a drawing of
/// it is saved beside the log.
///
/// `variant=middrag` presses the keys with the mouse button held, halfway through the drag. `variant=command`
/// first presses ⌘ alone: on macOS 27 that switches the crosshair to Visual Intelligence, and the selection then
/// never ends, which is why the option keys cannot use ⌘. The log shows whether that is still so.
///
/// Pressing keys and moving the pointer needs Accessibility. A person using the Mac at the same moment can end the
/// selection early; the log says when that happened.
enum CaptureOptionsSelfTest {
    private static var running = false

    static func run(capture: CaptureController, output: ResultHandler, keys: [CaptureOption], clipboard: String, variant: String = "") {
        var log = "capture options self-test\n"
        guard !running, !capture.isBusy else {
            AccessibilityText.writeLog(log + "not started: a capture is running\n")
            return
        }
        guard AccessibilityText.isTrusted else {
            AccessibilityText.writeLog(log + "not started: pressing keys needs Accessibility access\n")
            return
        }
        running = true
        let started = Date()
        let elapsed = { String(format: "%.2f s", Date().timeIntervalSince(started)) }
        let primary = NSScreen.screens[0].frame   // global display coordinates start at its top-left corner
        let area = NSRect(x: primary.midX - 330, y: primary.midY - 90, width: 660, height: 180)
        let window = showWindow(in: area)
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let lastRect = Prefs.lastRect
        let dryRun = DryRun(clipboard: clipboard)
        output.dryRun = dryRun
        capture.optionsPanel.testOrigin = NSPoint(x: area.minX + 16, y: area.minY + 12)
        if !variant.isEmpty { log += "variant: \(variant)\n" }
        log += "keys to press: \(keys.isEmpty ? "none" : keys.map(\.rawValue).joined(separator: ", "))\n"
        log += "pretend clipboard before: \(quoted(clipboard))\n"

        var done = false
        let finish = { (reason: String) in
            guard !done else { return }
            done = true
            log += "ended: \(reason)\n"
            log += "switches used: \(describe(capture.switches))\n"
            log += "events: \(dryRun.events.isEmpty ? "none" : dryRun.events.joined(separator: "; "))\n"
            log += "clipboard after: \(quoted(dryRun.clipboard))\n"
            log += "spoken: \(dryRun.spoken.isEmpty ? "nothing" : dryRun.spoken.map(quoted).joined(separator: ", "))\n"
            let panelWords = ["This capture"] + CaptureOption.allCases.map(\.title)
            let leaked = panelWords.filter { dryRun.clipboard.localizedCaseInsensitiveContains($0) }
            log += "options panel in the picture: \(leaked.isEmpty ? "no" : "YES (\(leaked.joined(separator: ", ")))")\n"
            AccessibilityText.writeLog(log)

            window.orderOut(nil)
            releaseModifiers()
            capture.optionsPanel.testOrigin = nil
            CGWarpMouseCursorPosition(cursor)
            Prefs.lastRect = lastRect
            // A capture still being read would otherwise reach the real clipboard: keep the pretend one until then.
            if capture.isBusy {
                dryRun.onRecord = { if output.dryRun === dryRun { output.dryRun = nil } }
                // A capture that ends without a result never records: never let the pretend clipboard outlive it
                // and swallow the next real capture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if output.dryRun === dryRun { output.dryRun = nil } }
            } else {
                output.dryRun = nil
            }
            running = false
        }
        dryRun.onRecord = { finish("delivered") }
        /// Called just before the mouse is let go: the state the selection ends with.
        let beforeRelease = {
            log += "switches before releasing the mouse: \(describe(capture.switches))\n"
            if let frame = capture.optionsPanel.frame {
                let file = WindowSnapshot.file(for: "capture-options")
                let drawn = capture.optionsPanel.writeSnapshot(to: file)
                log += "options panel: showing, \(Int(frame.width))×\(Int(frame.height)) pt, inside the selected area"
                log += drawn ? "; drawn to \(file.path)\n" : "\n"
            } else {
                log += "options panel: not showing\n"
            }
            log += "\(elapsed()): letting go of the mouse (crosshair \(capture.isSelecting ? "up" : "NOT up"))\n"
        }
        /// The selection should end when the mouse is let go; if it does not, end it.
        let expectEnd = { (delay: Double) in
            after(delay) {
                guard !done, capture.isSelecting else { return }
                log += "the selection was still open after the mouse was let go\n"
                capture.cancelSelection()
                finish("the selection did not end")
            }
        }

        guard capture.captureScreen(.text(nil)) else {
            finish("the capture did not start")
            return
        }
        log += "\(elapsed()): capture started\n"
        after(1.2) {
            if !capture.isSelecting {
                // Nothing has been pressed or moved by this test yet: any recent input is a person's.
                let since = { (type: CGEventType) in CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type) }
                log += String(format: "the crosshair closed by itself within 1.2 s (%@); last key press %.1f s ago, last click %.1f s ago\n",
                              capture.lastExit.map { "exit \($0.status), \($0.picture ? "with" : "no") picture" } ?? "no exit seen",
                              since(.keyDown), since(.leftMouseDown))
            }
            let working = capture.optionKeys.map(\.option)
            log += "keys working while selecting: \(working.isEmpty ? "none" : working.map(\.rawValue).joined(separator: ", "))\n"
            for option in keys where !working.contains(option) { log += "not pressed (no working key): \(option.rawValue)\n" }
            let shortcuts = keys.filter(working.contains).compactMap { option in Shortcut.stored(for: option).map { (option, $0) } }
            let pressAndCheck = { (option: CaptureOption, shortcut: Shortcut) in
                let before = capture.switches[option]
                // With the crosshair gone the key would be typed into the app in front: never press it then.
                guard capture.isSelecting else {
                    log += "\(elapsed()): not pressing \(shortcut.display): the crosshair is gone\n"
                    return
                }
                log += "\(elapsed()): pressing \(shortcut.display) (crosshair up)\n"
                press(shortcut)
                after(0.15) { log += "  \(option.rawValue) \(capture.switches[option] != before ? "switched" : "NOT switched")\n" }
            }

            if variant.contains("middrag") {
                dragPressing(shortcuts.map { item in { pressAndCheck(item.0, item.1) } }, over: area, primaryHeight: primary.height,
                             beforeRelease: beforeRelease)
                expectEnd(Double(shortcuts.count) * 0.25 + 2.5)
                return
            }
            var delay = 0.0
            if variant.contains("command") {
                log += "\(elapsed()): pressing ⌘ alone\n"
                pressCommandAlone()
                delay = 0.25
            }
            for item in shortcuts {
                after(delay) { pressAndCheck(item.0, item.1) }
                delay += 0.25
            }
            after(delay + 0.25) {
                drag(over: area, primaryHeight: primary.height, beforeRelease: beforeRelease)
                expectEnd(2.0)
            }
        }
        after(60) {
            guard !done else { return }   // a later run's selection is not this run's to end
            capture.cancelSelection()
            finish("timed out")
        }
    }

    // MARK: Window

    private static func showWindow(in area: NSRect) -> NSPanel {
        let window = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.backgroundColor = .white
        window.appearance = NSAppearance(named: .aqua)
        // Two lines of one sentence: smart paragraphs join them, keeping line breaks does not.
        let label = NSTextField(wrappingLabelWithString: "Selftest words that wrap onto\na second line of the same text")
        label.font = .systemFont(ofSize: 30)
        label.textColor = .black
        label.frame = NSRect(x: 24, y: 70, width: area.width - 48, height: 90)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        return window
    }

    // MARK: Keys

    private static func after(_ delay: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Each modifier with the bit a keyboard adds for its left-hand key (NX_DEVICELCTLKEYMASK and so on).
    private static let modifierKeys: [(NSEvent.ModifierFlags, Int, CGEventFlags)] = [
        (.control, kVK_Control, CGEventFlags.maskControl.union(CGEventFlags(rawValue: 0x01))),
        (.option, kVK_Option, CGEventFlags.maskAlternate.union(CGEventFlags(rawValue: 0x20))),
        (.shift, kVK_Shift, CGEventFlags.maskShift.union(CGEventFlags(rawValue: 0x02))),
        (.command, kVK_Command, CGEventFlags.maskCommand.union(CGEventFlags(rawValue: 0x08))),
    ]

    /// Presses a shortcut as a keyboard does: each modifier down, the key down and up, then the modifiers up.
    private static func press(_ shortcut: Shortcut) {
        let held = modifierKeys.filter { shortcut.modifiers.contains($0.0) }
        var flags: CGEventFlags = []
        for (_, key, flag) in held {
            flags.insert(flag)
            post(key, down: true, flags: flags, modifier: true)
        }
        // A keyboard marks function and arrow keys with fn; a hot key on one of them matches only then (measured).
        let keyFlags = functionKeys.contains(Int(shortcut.keyCode)) ? flags.union(.maskSecondaryFn) : flags
        post(Int(shortcut.keyCode), down: true, flags: keyFlags)
        post(Int(shortcut.keyCode), down: false, flags: keyFlags)
        for (_, key, flag) in held.reversed() {
            flags.remove(flag)
            post(key, down: false, flags: flags, modifier: true)
        }
    }

    private static func pressCommandAlone() {
        let command = CGEventFlags.maskCommand.union(CGEventFlags(rawValue: 0x08))
        post(kVK_Command, down: true, flags: command, modifier: true)
        post(kVK_Command, down: false, flags: [], modifier: true)
    }

    /// Leaves the system's record of held modifiers empty, as after letting go of every key.
    private static func releaseModifiers() {
        post(kVK_Command, down: false, flags: [], modifier: true)
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
        kVK_ForwardDelete, kVK_Help,
    ]

    /// - Parameter modifier: a modifier key goes as a flags-changed event, as a keyboard sends it. Sent as a key
    ///   press instead, it left `screencapture -i` ignoring the drag that followed (measured).
    private static func post(_ key: Int, down: Bool, flags: CGEventFlags, modifier: Bool = false) {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: CGKeyCode(key), keyDown: down)
        if modifier { event?.type = .flagsChanged }
        event?.flags = flags.union(.maskNonCoalesced)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: Mouse

    /// Drags from corner to corner of `area` (screen points, bottom-left origin) and lets go.
    private static func drag(over area: NSRect, primaryHeight: CGFloat, beforeRelease: @escaping () -> Void) {
        dragPressing([], over: area, primaryHeight: primaryHeight, beforeRelease: beforeRelease)
    }

    /// Mouse down at one corner of `area`, half the drag, `presses` with the button still held (none for a plain
    /// drag), the rest of the drag, then `beforeRelease` and the mouse up at the other corner.
    private static func dragPressing(_ presses: [() -> Void], over area: NSRect, primaryHeight: CGFloat,
                                     beforeRelease: @escaping () -> Void) {
        let start = CGPoint(x: area.minX + 6, y: primaryHeight - area.maxY + 6)
        let end = CGPoint(x: area.maxX - 6, y: primaryHeight - area.minY - 6)
        let point = { (t: CGFloat) in CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t) }
        mouse(.mouseMoved, at: start)
        after(0.1) { mouse(.leftMouseDown, at: start) }
        for step in 1...3 { after(0.1 + 0.07 * Double(step)) { mouse(.leftMouseDragged, at: point(CGFloat(step) / 6)) } }
        var time = 0.4
        for press in presses {
            after(time, press)
            time += 0.25
        }
        for step in 4...6 { after(time + 0.07 * Double(step - 3)) { mouse(.leftMouseDragged, at: point(CGFloat(step) / 6)) } }
        after(time + 0.3, beforeRelease)
        after(time + 0.35) { mouse(.leftMouseUp, at: end) }
    }

    private static func mouse(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: Log

    private static func describe(_ switches: CaptureSwitches) -> String {
        CaptureOption.allCases.map { "\($0.rawValue) \(switches[$0] ? "on" : "off")" }.joined(separator: ", ")
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "⏎") + "\""
    }
}
