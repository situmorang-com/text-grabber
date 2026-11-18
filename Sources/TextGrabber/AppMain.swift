import AppKit
import SwiftUI
import TextGrabberCore

enum AppMain {
    static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let output = ResultHandler()
    private lazy var capture = CaptureController(output: output)
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "TextGrabber")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "TextGrabber: click for the menu, right-click to capture"
        }
        menu.delegate = self

        HotKeyCenter.shared.handler = { [weak self] in self?.perform($0) }
        HotKeyCenter.shared.reload()

        // So the first capture is as quick as the rest.
        DispatchQueue.global(qos: .utility).async { Recognizer.warmUp() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Dropping or opening files onto the app reads them.
    func application(_ application: NSApplication, open urls: [URL]) {
        capture.recogniseFiles(urls)
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .captureText: capture.captureScreen(.text(nil))
        case .captureLastArea: capture.captureScreen(.text(nil), lastArea: true)
        case .captureKeepLines: capture.captureScreen(.text(.keepLines))
        case .captureBarcode: capture.captureScreen(.barcode)
        case .clipboardImage: capture.recogniseClipboard()
        case .stopSpeaking: output.stopSpeaking()
        }
    }

    // MARK: Menu

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            capture.captureScreen(.text(nil))
        } else {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        add("Capture Text", #selector(captureText), shortcut: .captureText)
        add("Capture Last Area Again", #selector(captureLast), shortcut: .captureLastArea).isEnabled = Prefs.lastRect != nil
        add("Read QR Code or Barcode", #selector(captureBarcode), shortcut: .captureBarcode)
        add("Recognise Image on Clipboard", #selector(clipboardImage), shortcut: .clipboardImage)
        add("Open Image or PDF…", #selector(openFiles))
        menu.addItem(.separator())

        let modes = NSMenu()
        for (mode, title) in [(LineMode.paragraphs, "Smart Paragraphs"), (.keepLines, "Keep Every Line Break"), (.singleLine, "Single Line")] {
            let item = NSMenuItem(title: title, action: #selector(chooseLineMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = Prefs.lineMode == mode ? .on : .off
            modes.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Line Breaks", action: nil, keyEquivalent: "")
        modeItem.submenu = modes
        menu.addItem(modeItem)

        add("Additive Clipboard", #selector(toggleAdditive)).state = Prefs.bool(Prefs.Key.additive) ? .on : .off
        add("Clear Additive Clipboard", #selector(clearAdditive)).isEnabled = !Prefs.additiveBuffer.isEmpty
        add("Speak After Capture", #selector(toggleSpeak)).state = Prefs.bool(Prefs.Key.speak) ? .on : .off
        add("Stop Speaking", #selector(stopSpeaking), shortcut: .stopSpeaking).isEnabled = output.isSpeaking
        menu.addItem(.separator())

        let recent = NSMenu()
        for entry in output.history.entries.prefix(10) {
            let flat = entry.text.replacingOccurrences(of: "\n", with: " ")
            let item = NSMenuItem(title: flat.count > 60 ? String(flat.prefix(60)) + "…" : flat,
                                  action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            item.toolTip = String(entry.text.prefix(600))
            recent.addItem(item)
        }
        if recent.items.isEmpty {
            recent.addItem(NSMenuItem(title: "Nothing captured yet", action: nil, keyEquivalent: ""))
        }
        let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        add("Show History…", #selector(showHistory))
        menu.addItem(.separator())

        add("Settings…", #selector(showSettings)).keyEquivalent = ","
        add("Quit TextGrabber", #selector(quit)).keyEquivalent = "q"
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, shortcut: HotKeyAction? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut, let stored = Shortcut.stored(for: shortcut) {
            item.keyEquivalent = stored.key.lowercased()
            item.keyEquivalentModifierMask = stored.modifiers
        }
        menu.addItem(item)
        return item
    }

    // Menu validation is manual: items set isEnabled themselves.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { menuItem.isEnabled }

    @objc private func captureText() { afterMenuCloses { self.capture.captureScreen(.text(nil)) } }
    @objc private func captureLast() { afterMenuCloses { self.capture.captureScreen(.text(nil), lastArea: true) } }
    @objc private func captureBarcode() { afterMenuCloses { self.capture.captureScreen(.barcode) } }
    @objc private func clipboardImage() { capture.recogniseClipboard() }
    @objc private func openFiles() { capture.chooseFiles() }
    @objc private func stopSpeaking() { output.stopSpeaking() }
    @objc private func quit() { NSApp.terminate(nil) }

    /// Give the menu a moment to disappear so it is not in the screenshot.
    private func afterMenuCloses(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func chooseLineMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = LineMode(rawValue: raw) { Prefs.lineMode = mode }
    }

    @objc private func toggleAdditive() {
        Prefs.toggle(Prefs.Key.additive)
        output.notify(symbol: "plus.square.on.square", title: Prefs.bool(Prefs.Key.additive) ? "Additive clipboard on" : "Additive clipboard off")
    }

    @objc private func clearAdditive() {
        Prefs.additiveBuffer = ""
        output.notify(symbol: "trash", title: "Additive clipboard cleared")
    }

    @objc private func toggleSpeak() { Prefs.toggle(Prefs.Key.speak) }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        output.write(text)
        output.notify(symbol: "doc.on.clipboard", title: "Copied again")
    }

    // MARK: Windows

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "TextGrabber Settings", size: NSSize(width: 520, height: 480),
                                        content: SettingsView())
        }
        present(settingsWindow)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let view = HistoryView(store: output.history) { [weak self] text in
                self?.output.write(text)
                self?.output.notify(symbol: "doc.on.clipboard", title: "Copied again")
            }
            historyWindow = makeWindow(title: "Capture History", size: NSSize(width: 560, height: 520), content: view,
                                       resizable: true)
        }
        present(historyWindow)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content, resizable: Bool = false) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
