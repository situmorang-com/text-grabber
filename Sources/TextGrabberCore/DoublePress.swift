import Foundation

/// Decides, key event by key event, whether a shortcut was pressed twice (⌥2 2).
///
/// The first press of a watched shortcut is held back, because nobody can know yet whether a second will follow.
/// A second press soon enough is the shortcut: both are swallowed. Anything else (the time runs out, another key,
/// the key held down until it repeats) means it was an ordinary press: the held events are sent on, in order.
/// The caller keeps the held events and runs the timer; this only decides.
public struct DoublePressMachine {
    public struct Key: Hashable {
        public var code: UInt16
        /// Only ⌘ ⇧ ⌥ ⌃, as `NSEvent.ModifierFlags` (and `CGEventFlags`) raw values.
        public var modifiers: UInt

        public init(code: UInt16, modifiers: UInt) {
            self.code = code
            self.modifiers = modifiers
        }
    }

    public enum Decision: Equatable {
        /// Let the event through.
        case pass
        /// Keep the event back, after the ones already held.
        case hold
        /// Throw the event away.
        case drop
        /// The shortcut was pressed twice: throw away this event and the held ones, and run it.
        case fire(Key)
        /// Send the held events on, then this one, in that order.
        case release
    }

    /// How long the second press may take, from the first.
    public static let window: TimeInterval = 0.25

    public var watched: Set<Key>
    private var held: Key?
    private var heldKeyUp = false
    /// Key ups still to come from a double press that fired: they belong to presses the app never saw.
    private var pendingUps: [UInt16: Int] = [:]

    public init(watched: Set<Key> = []) {
        self.watched = watched
    }

    /// True while a first press is held back (the caller's timer should be running).
    public var isHolding: Bool { held != nil }

    public mutating func keyDown(_ key: Key, isRepeat: Bool) -> Decision {
        // A new press of a key: an old key up that never came must not swallow this one's.
        if !isRepeat { pendingUps[key.code] = nil }
        if let first = held {
            held = nil
            guard key == first, !isRepeat else { return .release }   // something else, or the key is held down
            pendingUps[key.code, default: 0] += heldKeyUp ? 1 : 2
            return .fire(key)
        }
        if watched.contains(key), !isRepeat {
            held = key
            heldKeyUp = false
            return .hold
        }
        return .pass
    }

    public mutating func keyUp(code: UInt16) -> Decision {
        if let first = held, first.code == code, !heldKeyUp {
            heldKeyUp = true
            return .hold
        }
        if let count = pendingUps[code] {
            pendingUps[code] = count > 1 ? count - 1 : nil
            return .drop
        }
        return .pass
    }

    /// The time for a second press ran out. True when held events should be sent on.
    public mutating func timeout() -> Bool {
        guard held != nil else { return false }
        held = nil
        return true
    }
}
