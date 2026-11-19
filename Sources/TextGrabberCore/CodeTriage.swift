import Foundation
import CoreGraphics

/// Decides what a capture containing QR codes or barcodes is for: the codes alone, or the text and the codes.
///
/// Text that came along by accident is set aside first: text read inside a code (its squares look like
/// letters), lines cut by the edge of the selection, text that repeats a code's content (the link printed under
/// it, a barcode's digits) and fragments that are not words. What is left is the text the person meant to take.
///
/// Measured on the corpus in `Fixtures/codes`: captures aimed at a code kept 0–5 words (a title and "Scan to
/// join"), captures of a page or a card with a code kept 16 or more. The threshold sits in that gap.
public struct CodeTriage {
    public enum Choice: String { case textOnly, codesOnly, textAndCodes }

    public struct Decision {
        public var choice: Choice
        /// The fragments to lay out as text: everything except what was read inside a code.
        public var fragments: [TextFragment]
        public var codes: [FoundCode]
        /// Words of text the person meant to take, after setting aside the accidental text.
        public var wantedWords: Int
        /// One line per fragment set aside and why, for the capture log.
        public var report: String
    }

    /// Fewer wanted words than this, and the capture is about its codes.
    public static let wantedWordsForText = 8

    public var isWord: (String) -> Bool

    public init(isWord: @escaping (String) -> Bool) {
        self.isWord = isWord
    }

    public func decide(fragments: [TextFragment], codes: [FoundCode]) -> Decision {
        guard !codes.isEmpty else {
            return Decision(choice: .textOnly, fragments: fragments, codes: [], wantedWords: 0, report: "")
        }
        var kept: [TextFragment] = []
        var wanted = 0
        var report = ""
        let payloads = codes.map { Self.squeezed($0.payload) }

        for fragment in fragments {
            let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if codes.contains(where: { Self.share(of: fragment.box, inside: $0.box) > 0.5 }) {
                report += "  inside a code, dropped: \(text)\n"
                continue
            }
            kept.append(fragment)
            if fragment.confidence < 0.5 {
                report += "  uncertain (\(String(format: "%.2f", fragment.confidence))), not counted: \(text)\n"
            } else if isCutByTheSelection(fragment) {
                report += "  cut by the selection, not counted: \(text)\n"
            } else if let squeezed = Optional(Self.squeezed(text)), squeezed.count >= 4,
                      payloads.contains(where: { $0.contains(squeezed) }) {
                report += "  repeats a code, not counted: \(text)\n"
            } else {
                let words = text.split(whereSeparator: \.isWhitespace).filter { word in
                    let core = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                    guard core.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
                    return core.allSatisfy { $0.isNumber || $0 == "," || $0 == "." || $0 == ":" } || isWord(core)
                }
                wanted += words.count
            }
        }
        let choice: Choice = wanted >= Self.wantedWordsForText ? .textAndCodes : .codesOnly
        report = "codes: \(codes.count), wanted words: \(wanted) → \(choice.rawValue)\n" + report
        return Decision(choice: choice, fragments: kept, codes: codes, wantedWords: wanted, report: report)
    }

    /// What goes on the clipboard, given the text laid out from `decision.fragments`.
    public static func clipboard(text: String, decision: Decision) -> String {
        switch decision.choice {
        case .textOnly: return text
        case .codesOnly: return codesText(decision.codes)
        case .textAndCodes:
            let extra = codes(notIn: text, decision.codes)
            return extra.isEmpty ? text : text + "\n\n" + codesText(extra)
        }
    }

    /// The codes whose content is not already in the text: those are added after it, the others would repeat it.
    public static func codes(notIn text: String, _ codes: [FoundCode]) -> [FoundCode] {
        let squeezedText = squeezed(text)
        return codes.filter { !squeezedText.contains(squeezed($0.payload)) }
    }

    public static func codesText(_ codes: [FoundCode]) -> String {
        codes.map(\.payload).joined(separator: "\n")
    }

    // MARK: Rules

    /// A line the selection cut through: it touches the left or right edge and the word there is not a word
    /// ("nt the" from "plant the"), or it touches the top or bottom edge at much less than full height.
    private func isCutByTheSelection(_ fragment: TextFragment) -> Bool {
        let box = fragment.box, margin: CGFloat = 0.01
        let words = fragment.text.split(whereSeparator: \.isWhitespace)
        func broken(_ word: Substring?) -> Bool {
            guard let word else { return false }
            let letters = word.filter(\.isLetter)
            return !letters.isEmpty && !isWord(String(letters))
        }
        if box.minX <= margin, broken(words.first) { return true }
        if box.maxX >= 1 - margin, broken(words.last) { return true }
        return false
    }

    /// How much of `inner` lies inside `outer`, 0…1.
    static func share(of inner: CGRect, inside outer: CGRect) -> CGFloat {
        let overlap = inner.intersection(outer)
        guard !overlap.isNull, inner.width > 0, inner.height > 0 else { return 0 }
        return (overlap.width * overlap.height) / (inner.width * inner.height)
    }

    /// Lowercased letters and digits only, without a web scheme or "www.": "https://www.Example.com/a" → "examplecoma".
    static func squeezed(_ text: String) -> String {
        var value = text.lowercased()
        for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        return String(value.filter { $0.isLetter || $0.isNumber })
    }
}
