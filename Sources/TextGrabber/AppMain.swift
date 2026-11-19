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
    let output = ResultHandler()
    private(set) lazy var capture = CaptureController(output: output)

    /// Captures an area the user selects and returns its text (for Shortcuts). Nil when cancelled.
    func captureForShortcut(kind: CaptureKind) async -> String? {
        await withCheckedContinuation { continuation in
            output.onNextResult = { continuation.resume(returning: $0) }
            if !capture.captureScreen(kind) {
                output.onNextResult = nil
                continuation.resume(returning: nil)
            }
        }
    }
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var setupWindow: NSWindow?
    private let setupState = SetupState()

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

        // Until setup is finished, and whenever capture is not possible, show the setup window.
        if !Prefs.bool(Prefs.Key.setupDone) || !CGPreflightScreenCaptureAccess() { showSetup() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Dropping or opening files onto the app reads them.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { capture.recogniseFiles(files) }
        for url in urls where url.scheme == "textgrabber" { handle(url) }
    }

    /// URL actions, for Shortcuts, Raycast, Alfred and scripts. See the README for the list.
    private func handle(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        if value("edit") == "1" || value("edit") == "true" { output.editNext = true }
        switch url.host {
        case "capture": perform(.captureText)
        case "capture-edit": perform(.captureAndEdit)
        case "capture-scrolling": perform(.captureScrolling)
        case "capture-last-area": perform(.captureLastArea)
        case "capture-keep-lines": perform(.captureKeepLines)
        case "read-code": perform(.captureBarcode)
        case "clipboard": perform(.clipboardImage)
        case "edit-last": editLast()
        case "stop-speaking": perform(.stopSpeaking)
        case "open":
            // textgrabber://open?path=/absolute/file.png (repeat path for several files)
            let files = query.filter { $0.name == "path" }.compactMap(\.value).map { URL(fileURLWithPath: $0) }
            if !files.isEmpty { capture.recogniseFiles(files) }
        case "settings": showSettings()
        case "setup": showSetup()
        case "history": showHistory()
        case "selftest-scrolling":
            if let path = value("path"), let image = NSImage(contentsOfFile: path) { capture.scrolling.selfTest(image: image) }
        case "probe":
            guard let rect = value("rect"), CaptureController.rect(from: rect) != nil else {
                AccessibilityText.writeLog("probe: rect \"\(value("rect") ?? "")\" is not x,y,w,h\n")
                return
            }
            capture.captureScreen(.text(nil), probeRect: rect)
        case "snapshot":
            // textgrabber://snapshot?window=setup|settings|history|editor: opens it, then draws it to a PNG.
            // It does not take focus from the app the user is in, and closes the window again if it was closed,
            // unless keep=1 (to screenshot the real window; textgrabber://hide?window=… closes it after).
            let name = value("window") ?? "setup"
            let wasOpen = WindowSnapshot.window(named: name) != nil
            WindowSnapshot.isTaking = true
            switch name {
            case "setup": showSetup()
            case "settings": showSettings()
            case "history": showHistory()
            case "editor": editLast()
            default: break
            }
            WindowSnapshot.isTaking = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WindowSnapshot.write(name: name)
                if !wasOpen, value("keep") != "1" { WindowSnapshot.window(named: name)?.orderOut(nil) }
            }
        case "hide":
            WindowSnapshot.window(named: value("window") ?? "")?.orderOut(nil)
        default:
            output.editNext = false
        }
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .captureText: capture.captureScreen(.text(nil))
        case .captureLastArea: capture.captureScreen(.text(nil), lastArea: true)
        case .captureKeepLines: capture.captureScreen(.text(.keepLines))
        case .captureAndEdit:
            output.editNext = true
            capture.captureScreen(.text(nil))
        case .captureScrolling:
            // The same shortcut finishes a scrolling capture that is running.
            if capture.scrolling.isRunning { capture.scrolling.finish() } else { capture.captureScreen(.scrolling) }
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
        add("Capture and Edit…", #selector(captureAndEdit), shortcut: .captureAndEdit)
        add(capture.scrolling.isRunning ? "Finish Scrolling Capture" : "Scrolling Capture…", #selector(captureScrolling), shortcut: .captureScrolling)
        add("Edit Last Capture…", #selector(editLast)).isEnabled = output.lastResult != nil
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
            let flat = (entry.pinned ? "📌 " : "") + entry.text.replacingOccurrences(of: "\n", with: " ")
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

        add("Set Up TextGrabber…", #selector(showSetup))
        add("Settings…", #selector(showSettings)).keyEquivalent = ","
        add("Quit TextGrabber", #selector(quit)).keyEquivalent = "q"
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, shortcut: HotKeyAction? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let shortcut, let stored = Shortcut.stored(for: shortcut) {
            item.keyEquivalent = stored.baseKey.lowercased()
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
    @objc private func captureAndEdit() { afterMenuCloses { self.perform(.captureAndEdit) } }
    @objc private func captureScrolling() { afterMenuCloses { self.perform(.captureScrolling) } }
    @objc private func editLast() { if let last = output.lastResult { output.editor.show(last) } }
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

    @objc func showSetup() {
        setupState.refresh()
        if setupWindow == nil {
            let view = SetupView(state: setupState, tryCapture: { [weak self] in
                self?.setupWindow?.orderOut(nil)
                self?.afterMenuCloses { self?.perform(.captureText) }
            }, finish: { [weak self] in
                if self?.setupState.screenRecording == true { Prefs.defaults.set(true, forKey: Prefs.Key.setupDone) }
                self?.setupWindow?.close()
            })
            setupWindow = makeWindow(title: "Set Up TextGrabber", size: NSSize(width: 520, height: 470), content: view)
        }
        present(setupWindow)
    }

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
            } edit: { [weak self] entry in
                self?.output.editor.show(.fixed(entry.text, kind: entry.resultKind))
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
        if WindowSnapshot.isTaking { window?.orderFrontRegardless(); return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
