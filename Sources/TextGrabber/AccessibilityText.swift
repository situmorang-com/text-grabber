import AppKit
import ApplicationServices
import TextGrabberCore

/// Reads the real text of whatever is on screen at a point, through the Accessibility API.
enum AccessibilityText {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "TextGrabber would like to control this computer" prompt (once), and opens the settings pane.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Replaces OCR text with the app's own text where the two line up.
    /// - Parameter screenRect: the captured area in global screen points, top-left origin.
    /// - Returns: the fragments, and how many of them were replaced.
    static func refine(_ fragments: [TextFragment], capturedFrom screenRect: CGRect) -> (fragments: [TextFragment], replaced: Int) {
        guard isTrusted, !fragments.isEmpty else { return (fragments, 0) }
        let collector = Collector(budget: 1.2)
        let candidates: [[Int]] = fragments.map { fragment in
            // Three points along the line, so a line made of several text runs finds all of them.
            var found: [Int] = []
            for share in [0.5, 0.2, 0.8] {
                let point = CGPoint(x: screenRect.minX + (fragment.box.minX + fragment.box.width * share) * screenRect.width,
                                    y: screenRect.minY + fragment.box.midY * screenRect.height)
                for index in collector.sources(at: point) where !found.contains(index) { found.append(index) }
            }
            return found
        }
        guard !collector.texts.isEmpty else { return (fragments, 0) }
        let outcome = ExactText.refine(lines: fragments.map(\.text), candidates: candidates, sources: collector.texts)
        var refined = fragments
        for index in refined.indices { refined[index].text = outcome.lines[index] }
        return (refined, outcome.replaced)
    }

    /// Gathers text from the elements under screen points, reading each element once.
    final class Collector {
        private(set) var texts: [String] = []
        private var indexOfText: [String: Int] = [:]
        private var seen: [AXUIElement: [Int]] = [:]
        private var preparedApps: Set<pid_t> = []
        private let system = AXUIElementCreateSystemWide()
        private let deadline: Date

        init(budget: TimeInterval) {
            deadline = Date().addingTimeInterval(budget)
            AXUIElementSetMessagingTimeout(system, 0.25)
        }

        func sources(at point: CGPoint) -> [Int] {
            guard Date() < deadline else { return [] }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let element = hit else { return [] }
            if let known = seen[element] { return known }
            prepareApp(of: element)

            var found: [Int] = []
            if let own = Self.text(of: element) { found.append(store(own)) }
            // A sentence is often split into runs (plain text, a link, an emoji image): read the siblings together.
            if let parent: AXUIElement = Self.attribute(element, kAXParentAttribute),
               let children: [AXUIElement] = Self.attribute(parent, kAXChildrenAttribute), children.count > 1, children.count <= 200 {
                var joined = ""
                for child in children {
                    guard let piece = Self.text(of: child), !piece.isEmpty else { continue }
                    let needsSpace = !joined.isEmpty && !(joined.last?.isWhitespace ?? true) && !(piece.first?.isWhitespace ?? true)
                    joined += (needsSpace ? " " : "") + piece
                    if joined.count > ExactText.maxSourceLength { break }
                }
                if !joined.isEmpty { found.append(store(joined)) }
            }
            seen[element] = found
            return found
        }

        private func store(_ text: String) -> Int {
            if let index = indexOfText[text] { return index }
            texts.append(text)
            indexOfText[text] = texts.count - 1
            return texts.count - 1
        }

        /// Electron apps only build their accessibility tree when asked.
        private func prepareApp(of element: AXUIElement) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, !preparedApps.contains(pid) else { return }
            preparedApps.insert(pid)
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        /// The text an element shows: its value, or failing that its title or description.
        static func text(of element: AXUIElement) -> String? {
            if let role: String = attribute(element, kAXRoleAttribute), role == "AXSecureTextField" { return nil }
            if let count: Int = attribute(element, kAXNumberOfCharactersAttribute), count > ExactText.maxSourceLength {
                // A whole document: take only what is visible.
                var range: CFTypeRef?
                var visible: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &range) == .success, let range,
                   AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, range, &visible) == .success,
                   let text = visible as? String {
                    return text
                }
            }
            for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text: String = attribute(element, name), !text.isEmpty { return text }
            }
            return nil
        }

        static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value as? T
        }
    }
}
