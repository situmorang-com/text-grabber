import AppKit
import Carbon.HIToolbox
import TextGrabberCore

/// Something a shortcut can be stored for: a global action, or an option switched while selecting an area.
protocol ShortcutSlot {
    var title: String { get }
    var storageKey: String { get }
    var defaultShortcut: Shortcut? { get }
    /// Why these keys cannot be used here, or nil when they can.
    func problem(with shortcut: Shortcut) -> String?
}

/// The things a global shortcut can trigger.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case captureText, captureAndEdit, captureScrolling, captureLastArea, captureKeepLines, captureBarcode, clipboardImage, stopSpeaking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureText: return "Capture text"
        case .captureLastArea: return "Capture the last area again"
        case .captureKeepLines: return "Capture text, keeping line breaks"
        case .captureAndEdit: return "Capture text and open the editor"
        case .captureScrolling: return "Scrolling capture (press again to finish)"
        case .captureBarcode: return "Read QR code or barcode"
        case .clipboardImage: return "Recognise image on the clipboard"
        case .stopSpeaking: return "Stop speaking"
        }
    }

    var defaultShortcut: Shortcut? {
        self == .captureText ? Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: [.command, .shift], key: "1") : nil
    }
}

extension HotKeyAction: ShortcutSlot {
    var storageKey: String { "shortcut." + rawValue }

    func problem(with shortcut: Shortcut) -> String? {
        // Works in every app, all the time: without ⌘, ⌥ or ⌃ it would swallow ordinary typing.
        shortcut.modifiers.isDisjoint(with: [.command, .option, .control])
            ? "A shortcut that works everywhere needs ⌘, ⌥ or ⌃." : nil
    }
}

/// Keys that switch an option for one capture. They work only while the selection crosshair shows, so a plain
/// letter is safe: nothing else can be typed then, and the key is given back the moment the crosshair goes.
extension CaptureOption: ShortcutSlot {
    var title: String {
        switch self {
        case .additive: return "Add to the clipboard"
        case .keepLines: return "Keep line breaks"
        case .speak: return "Read aloud"
        }
    }

    var symbol: String {
        switch self {
        case .additive: return "plus.square.on.square"
        case .keepLines: return "text.alignleft"
        case .speak: return "speaker.wave.2.fill"
        }
    }

    var storageKey: String { "captureShortcut." + rawValue }

    var defaultShortcut: Shortcut? {
        switch self {
        case .additive: return Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: [], key: "C")
        case .keepLines: return Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: [], key: "L")
        case .speak: return Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: [], key: "S")
        }
    }

    /// The system crosshair has keys of its own. Measured on macOS 27: each press of ⌘ switches it to Visual
    /// Intelligence and back ("Press ⌘ for Visual Intelligence"), and a selection made then is no screenshot.
    /// ⌃ held when the mouse is let go sends the screenshot to the clipboard; Space and Esc belong to it too.
    func problem(with shortcut: Shortcut) -> String? {
        if shortcut.modifiers.contains(.command) {
            return "While you select, ⌘ switches macOS to Visual Intelligence. Use a key without ⌘."
        }
        if shortcut.modifiers.contains(.control) {
            return "While you select, ⌃ makes macOS put the screenshot on the clipboard. Use a key without ⌃."
        }
        let reserved: [Int: String] = [
            kVK_Space: "Space", kVK_Escape: "Esc", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter", kVK_Tab: "Tab",
            kVK_Delete: "Delete", kVK_ForwardDelete: "Delete", kVK_LeftArrow: "the arrow keys", kVK_RightArrow: "the arrow keys",
            kVK_UpArrow: "the arrow keys", kVK_DownArrow: "the arrow keys",
        ]
        if let name = reserved[Int(shortcut.keyCode)] {
            return "\(name) cannot be used while you select an area."
        }
        return nil
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifierFlags: UInt
    /// What to show for the key, e.g. "1" or "F5".
    var key: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.intersection([.command, .shift, .option, .control]).rawValue
        self.key = key
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + baseKey.uppercased()
    }

    /// The key as printed on the keycap: "2", not the "@" that Shift makes of it. Recording stores the character
    /// the key typed, which includes Shift, so a printable key is named again from the keyboard layout.
    var baseKey: String {
        guard key.count == 1, let name = Self.unshiftedCharacter(for: keyCode) else { return key }
        return name
    }

    private static func unshiftedCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: characters, count: length)
        return name.unicodeScalars.allSatisfy({ $0.properties.isWhitespace || $0.value < 0x20 }) ? nil : name
    }

    /// The same key and modifiers (the stored name of the key may differ: "@" or "2").
    func sameKeys(as other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifierFlags == other.modifierFlags
    }

    static func stored(for slot: some ShortcutSlot) -> Shortcut? {
        let key = slot.storageKey
        guard let data = UserDefaults.standard.data(forKey: key) else {
            // Never set: use the default. An explicit "none" is stored as empty data.
            return UserDefaults.standard.object(forKey: key) == nil ? slot.defaultShortcut : nil
        }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func store(_ shortcut: Shortcut?, for slot: some ShortcutSlot) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: slot.storageKey)
    }

    /// Every slot with a shortcut, global actions first.
    static var allSlots: [any ShortcutSlot] {
        HotKeyAction.allCases.map { $0 as any ShortcutSlot } + CaptureOption.allCases.map { $0 as any ShortcutSlot }
    }

    /// The slot other than `slot` that already uses these keys, if any.
    static func owner(of shortcut: Shortcut, besides slot: some ShortcutSlot) -> (any ShortcutSlot)? {
        allSlots.first { other in
            other.storageKey != slot.storageKey && stored(for: other).map { $0.sameKeys(as: shortcut) } == true
        }
    }
}

/// Registers system-wide shortcuts through Carbon, which needs no accessibility permission.
///
/// The capture option keys (C, L, S) are registered the same way, but only while the selection crosshair shows:
/// measured on macOS 27, a Carbon hot key still fires while `screencapture -i` has the keyboard, and the key
/// never reaches the crosshair or the app in front. (An NSEvent global monitor sees nothing then.)
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var handler: ((HotKeyAction) -> Void)?
    /// Actions whose shortcut another app already owns.
    private(set) var conflicts: Set<HotKeyAction> = []

    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: HotKeyAction] = [:]
    private var optionReferences: [EventHotKeyRef] = []
    private var options: [UInt32: CaptureOption] = [:]
    private var optionHandler: ((CaptureOption) -> Void)?
    private var installed = false
    private static let signature = OSType(0x5447_5242) // "TGRB"

    func reload() {
        installHandlerIfNeeded()
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        actions.removeAll()
        conflicts.removeAll()

        for (index, action) in HotKeyAction.allCases.enumerated() {
            guard let shortcut = Shortcut.stored(for: action) else { continue }
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references.append(reference)
                actions[id] = action
            } else {
                conflicts.insert(action)
            }
        }
    }

    /// Registers the capture option keys until `endCaptureOptions()`; `handler` runs on the main thread for each
    /// press. Returns the options whose key could be registered.
    @discardableResult
    func beginCaptureOptions(_ handler: @escaping (CaptureOption) -> Void) -> Set<CaptureOption> {
        endCaptureOptions()
        installHandlerIfNeeded()
        optionHandler = handler
        var working: Set<CaptureOption> = []
        for (index, option) in CaptureOption.allCases.enumerated() {
            guard let shortcut = Shortcut.stored(for: option) else { continue }
            let id = UInt32(100 + index)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                optionReferences.append(reference)
                options[id] = option
                working.insert(option)
            }
        }
        return working
    }

    /// Gives the capture option keys back: typing C, L and S works again everywhere.
    func endCaptureOptions() {
        optionReferences.forEach { UnregisterEventHotKey($0) }
        optionReferences.removeAll()
        options.removeAll()
        optionHandler = nil
    }

    fileprivate func fire(_ id: UInt32) {
        if let option = options[id] {
            optionHandler?(option)
        } else if let action = actions[id] {
            handler?(action)
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
