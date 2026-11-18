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

    /// Web-based apps (Electron, Chromium) build their accessibility tree only when asked, and take a moment
    /// to do it. Ask as the capture starts, so the text is there by the time the selection is made.
    static func wakeRunningApps() {
        guard isTrusted else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        DispatchQueue.global(qos: .userInitiated).async {
            for app in apps {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.2)
                AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Replaces OCR text with the app's own text where the two line up.
    /// - Parameter screenRect: the captured area in global screen points, top-left origin.
    /// - Returns: the fragments, how many of them were replaced, and a plain-text account of what happened.
    static func refine(_ fragments: [TextFragment], capturedFrom screenRect: CGRect) -> (fragments: [TextFragment], replaced: Int, report: String) {
        var report = "accessibility access: \(isTrusted ? "yes" : "NO (Settings → Recognition → Grant Access)")\n"
        report += "captured area: \(Int(screenRect.minX)),\(Int(screenRect.minY)) \(Int(screenRect.width))×\(Int(screenRect.height))\n"
        guard isTrusted, !fragments.isEmpty else { return (fragments, 0, report) }

        var attempt = collect(fragments, screenRect)
        if attempt.collector.texts.isEmpty {
            // The app may still be building its tree: give it one more chance.
            Thread.sleep(forTimeInterval: 0.4)
            attempt = collect(fragments, screenRect)
            report += "no text from the app on the first try; retried\n"
        }
        let (collector, candidates) = attempt
        report += "apps under the capture: \(collector.appNames.sorted().joined(separator: ", "))\n"
        report += "pieces of app text found: \(collector.texts.count)\n"
        guard !collector.texts.isEmpty else { return (fragments, 0, report + "result: the app exposed no text here; recognition only\n") }

        let outcome = ExactText.refine(lines: fragments.map(\.text), candidates: candidates, sources: collector.texts)
        var refined = fragments
        for index in refined.indices {
            if refined[index].text != outcome.lines[index] { refined[index].text = outcome.lines[index]; refined[index].wordBoxes = [] }
            let sources = candidates[index].map { "\"" + collector.texts[$0].prefix(90).replacingOccurrences(of: "\n", with: "⏎") + "\"" }
            report += "\nline \(index + 1) recognised: \"\(fragments[index].text)\"\n"
            report += "  app text here: \(sources.isEmpty ? "none" : sources.joined(separator: " | "))\n"
            report += "  used: \"\(outcome.lines[index])\"\(outcome.lines[index] == fragments[index].text ? "" : "   ← from the app")\n"
        }
        return (refined, outcome.replaced, report + "\nresult: \(outcome.replaced) of \(fragments.count) lines taken from the app\n")
    }

    private static func collect(_ fragments: [TextFragment], _ screenRect: CGRect) -> (collector: Collector, candidates: [[Int]]) {
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
        return (collector, candidates)
    }

    /// Where the account of the last capture is kept, for working out why a capture was not exact.
    static let logFile = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/TextGrabber/last-capture.txt")

    static func writeLog(_ text: String) {
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (Date().formatted(date: .abbreviated, time: .standard) + "\n" + text).write(to: logFile, atomically: true, encoding: .utf8)
    }

    /// Gathers text from the elements under screen points, reading each element once.
    final class Collector {
        private(set) var texts: [String] = []
        private(set) var appNames: Set<String> = []
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
            // A list item's bullet or number is its own element; put it back in front of the item's text.
            let marker = Self.listMarker(for: element) ?? ""
            if let own = Self.text(of: element) { found.append(store(marker + own)) }
            // A sentence is often split into runs (plain text, a link, an emoji image): read the siblings together.
            if let parent: AXUIElement = Self.attribute(element, kAXParentAttribute),
               let children: [AXUIElement] = Self.attribute(parent, kAXChildrenAttribute), children.count > 1, children.count <= 200 {
                var joined = ""
                for child in children {
                    guard let piece = Self.deepText(of: child, depth: 0), !piece.isEmpty else { continue }
                    let needsSpace = !joined.isEmpty && !(joined.last?.isWhitespace ?? true) && !(piece.first?.isWhitespace ?? true)
                    joined += (needsSpace ? " " : "") + piece
                    if joined.count > ExactText.maxSourceLength { break }
                }
                if !joined.isEmpty { found.append(store(joined.hasPrefix(marker.trimmingCharacters(in: .whitespaces)) ? joined : marker + joined)) }
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
            appNames.insert(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)")
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }

        /// An element's text, or when it has none of its own (inline code, bold, a link), its descendants' text in order.
        static func deepText(of element: AXUIElement, depth: Int) -> String? {
            if let own = text(of: element) { return own }
            guard depth < 3, let children: [AXUIElement] = attribute(element, kAXChildrenAttribute), !children.isEmpty, children.count <= 40 else { return nil }
            let pieces = children.compactMap { deepText(of: $0, depth: depth + 1) }
            return pieces.isEmpty ? nil : pieces.joined()
        }

        /// The marker ("• ", "1. ") of the list item this element sits in, if any.
        static func listMarker(for element: AXUIElement) -> String? {
            var current = element
            for _ in 0..<4 {
                guard let parent: AXUIElement = attribute(current, kAXParentAttribute) else { return nil }
                if let children: [AXUIElement] = attribute(parent, kAXChildrenAttribute), let first = children.first,
                   let role: String = attribute(first, kAXRoleAttribute), role == "AXListMarker" {
                    guard let text = text(of: first), !text.isEmpty else { return nil }
                    return text.hasSuffix(" ") ? text : text + " "
                }
                current = parent
            }
            return nil
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
