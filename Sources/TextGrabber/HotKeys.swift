import AppKit
import Carbon.HIToolbox

/// The things a global shortcut can trigger.
enum HotKeyAction: String, CaseIterable, Identifiable {
    case captureText, captureLastArea, captureKeepLines, captureBarcode, clipboardImage, stopSpeaking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureText: return "Capture text"
        case .captureLastArea: return "Capture the last area again"
        case .captureKeepLines: return "Capture text, keeping line breaks"
        case .captureBarcode: return "Read QR code or barcode"
        case .clipboardImage: return "Recognise image on the clipboard"
        case .stopSpeaking: return "Stop speaking"
        }
    }

    var defaultShortcut: Shortcut? {
        self == .captureText ? Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: [.command, .shift], key: "1") : nil
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
        return text + key.uppercased()
    }

    static func stored(for action: HotKeyAction) -> Shortcut? {
        let key = "shortcut." + action.rawValue
        guard let data = UserDefaults.standard.data(forKey: key) else {
            // Never set: use the default. An explicit "none" is stored as empty data.
            return UserDefaults.standard.object(forKey: key) == nil ? action.defaultShortcut : nil
        }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    static func store(_ shortcut: Shortcut?, for action: HotKeyAction) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        UserDefaults.standard.set(data, forKey: "shortcut." + action.rawValue)
    }
}

/// Registers system-wide shortcuts through Carbon, which needs no accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var handler: ((HotKeyAction) -> Void)?
    /// Actions whose shortcut another app already owns.
    private(set) var conflicts: Set<HotKeyAction> = []

    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: HotKeyAction] = [:]
    private var installed = false

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
            let hotKeyID = EventHotKeyID(signature: OSType(0x5447_5242), id: id) // "TGRB"
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

    fileprivate func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        handler?(action)
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
