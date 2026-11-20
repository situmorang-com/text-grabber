import Foundation

/// An option a key switches while the user is selecting the area to capture.
public enum CaptureOption: String, CaseIterable, Identifiable, Codable {
    /// Add the text to what is on the clipboard instead of replacing it.
    case additive
    /// Keep every line break, and start added text on a new line.
    case keepLines
    /// Read the text aloud once it is copied.
    case speak

    public var id: String { rawValue }
}

/// The options of one capture. They start from the settings; each key press during the selection switches one.
public struct CaptureSwitches: Equatable {
    public var additive: Bool
    public var keepLines: Bool
    public var speak: Bool

    public init(additive: Bool = false, keepLines: Bool = false, speak: Bool = false) {
        self.additive = additive
        self.keepLines = keepLines
        self.speak = speak
    }

    /// The settings as a starting point: `lineMode` is the line mode the capture would be read with.
    public init(additive: Bool, lineMode: LineMode, speak: Bool) {
        self.init(additive: additive, keepLines: lineMode == .keepLines, speak: speak)
    }

    public subscript(option: CaptureOption) -> Bool {
        get {
            switch option {
            case .additive: return additive
            case .keepLines: return keepLines
            case .speak: return speak
            }
        }
        set {
            switch option {
            case .additive: additive = newValue
            case .keepLines: keepLines = newValue
            case .speak: speak = newValue
            }
        }
    }

    public mutating func toggle(_ option: CaptureOption) {
        self[option].toggle()
    }

    /// The line mode to read the capture with, given the one it would use otherwise. Keeping line breaks reads
    /// every line. Switched off, it leaves the usual mode, or smart paragraphs when the usual mode keeps lines.
    public func lineMode(otherwise usual: LineMode) -> LineMode {
        if keepLines { return .keepLines }
        return usual == .keepLines ? .paragraphs : usual
    }
}

/// How a capture is added to the text already on the clipboard.
public enum AdditiveText {
    /// `base` and then `text`. On a new line when `newLine`; otherwise on the same line, joined the way lines of
    /// a paragraph are: with a space, a word hyphenated across the two repaired, and no space between Chinese or
    /// Japanese characters. Text never runs into a table or a list item: next to a table row, when `text` is a
    /// table (`textIsTable`, which also covers CSV) or when it starts with a list item, it starts a new line,
    /// and after a Markdown table a blank line, so it is not read as another row.
    /// - Parameter isWord: says whether a word put back together from a hyphenation is a real word.
    public static func append(_ text: String, to base: String, newLine: Bool, textIsTable: Bool = false,
                              isWord: ((String) -> Bool)? = nil) -> String {
        // Only spaces and line breaks are trimmed at the joint: a tab there is an empty table cell.
        let head = trimmingTrailingWhitespace(base)
        let tail = String(text.drop(while: { $0 == " " || $0.isNewline }))
        guard !head.isEmpty else { return text }
        guard !tail.isEmpty else { return base }
        let lastLine = head.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let firstLine = tail.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        if isMarkdownRow(lastLine) {
            return head + "\n\n" + tail
        }
        if newLine || textIsTable || isTableRow(lastLine) || isTableRow(firstLine)
            || !ExactText.splitListMarker(String(firstLine)).marker.isEmpty {
            return head + "\n" + tail
        }
        return LayoutEngine(mode: .paragraphs, isWord: isWord).join(head, tail)
    }

    /// A row of a table as TextGrabber writes them: tab-separated cells, or a Markdown row between pipes.
    static func isTableRow(_ line: Substring) -> Bool {
        line.contains("\t") || isMarkdownRow(line)
    }

    static func isMarkdownRow(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 1 && trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }

    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let before = text.index(before: end)
            guard text[before] == " " || text[before].isNewline else { break }
            end = before
        }
        return String(text[..<end])
    }
}
