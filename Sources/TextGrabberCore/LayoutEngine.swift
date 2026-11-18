import Foundation
import CoreGraphics

/// One recognised piece of text and where it sits on the image.
/// `box` uses a top-left origin and any consistent unit (normalised 0…1 or pixels).
public struct TextFragment: Equatable {
    public var text: String
    public var box: CGRect
    /// How sure recognition was, 0…1. Text that did not come from recognition is 1.
    public var confidence: Float = 1
    /// Box of each space-separated word of `text`, when recognition provided them. Empty once `text` is changed.
    public var wordBoxes: [CGRect] = []

    /// The words of the text, as `wordBoxes` counts them.
    public var words: [Substring] { text.split(separator: " ", omittingEmptySubsequences: true) }

    public init(_ text: String, _ box: CGRect) {
        self.text = text
        self.box = box
    }

    /// Build from a Vision bounding box (normalised, bottom-left origin).
    public init(text: String, visionBox: CGRect, confidence: Float = 1) {
        self.text = text
        self.confidence = confidence
        self.box = CGRect(x: visionBox.minX, y: 1 - visionBox.maxY, width: visionBox.width, height: visionBox.height)
    }
}

public enum LineMode: String, CaseIterable, Codable {
    /// Every visual line on its own line; blank line between paragraphs.
    case keepLines
    /// Lines of a paragraph are joined; paragraphs, bullets, headings and tables keep their breaks.
    case paragraphs
    /// Everything on one line.
    case singleLine
}

/// Turns loose OCR fragments into readable text: reading order, columns, tables, paragraphs.
public struct LayoutEngine {
    public var mode: LineMode
    /// Says whether a de-hyphenated candidate is a real word. `nil` means "always merge".
    public var isWord: ((String) -> Bool)?
    public var detectColumns = true
    public var detectTables = true

    public init(mode: LineMode = .paragraphs, isWord: ((String) -> Bool)? = nil) {
        self.mode = mode
        self.isWord = isWord
    }

    // MARK: Model

    struct Line {
        var cells: [TextFragment]
        var box: CGRect
        var text: String { cells.map(\.text).joined(separator: " ") }
    }

    // MARK: Entry point

    public func compose(_ input: [TextFragment]) -> String {
        let fragments = input
            .map { TextFragment($0.text.trimmingCharacters(in: .whitespacesAndNewlines), $0.box) }
            .filter { !$0.text.isEmpty && $0.box.width > 0 && $0.box.height > 0 }
        guard !fragments.isEmpty else { return "" }
        return Self.tidy(composeBlock(fragments, depth: 0))
    }

    private func composeBlock(_ fragments: [TextFragment], depth: Int) -> String {
        let charWidth = Self.median(fragments.map { $0.box.width / CGFloat(max($0.text.count, 1)) })

        // Separate panes of a window (a sidebar beside its content) are read one after the other.
        if detectColumns, depth < 4, let panes = Self.splitPanes(fragments, charWidth: charWidth) {
            return [panes.left, panes.right].map { composeBlock($0, depth: depth + 1) }
                .filter { !$0.isEmpty }
                .joined(separator: mode == .singleLine ? " " : "\n\n")
        }

        let rows = Self.rows(from: fragments, charWidth: charWidth)

        if detectTables, let table = tableText(rows: rows, charWidth: charWidth) {
            return mode == .singleLine ? table.replacingOccurrences(of: "\n", with: " ") : table
        }

        let columns = detectColumns ? Self.splitColumns(fragments, charWidth: charWidth) : [fragments]
        let blocks = columns.map { column -> String in
            composeColumn(Self.rows(from: column, charWidth: charWidth), charWidth: charWidth)
        }.filter { !$0.isEmpty }

        return blocks.joined(separator: mode == .singleLine ? " " : "\n\n")
    }

    // MARK: Rows

    /// Groups fragments into visual rows (top to bottom), each sorted left to right.
    static func rows(from fragments: [TextFragment], charWidth: CGFloat) -> [Line] {
        let sorted = fragments.sorted {
            $0.box.midY != $1.box.midY ? $0.box.midY < $1.box.midY : $0.box.minX < $1.box.minX
        }
        var rows: [[TextFragment]] = []
        var bands: [ClosedRange<CGFloat>] = []
        for fragment in sorted {
            var placed = false
            // Look at the most recent rows first; a fragment belongs to a row when they overlap vertically by half.
            for index in stride(from: rows.count - 1, through: max(rows.count - 3, 0), by: -1) {
                let band = bands[index]
                let overlap = min(band.upperBound, fragment.box.maxY) - max(band.lowerBound, fragment.box.minY)
                let smaller = min(band.upperBound - band.lowerBound, fragment.box.height)
                let collides = rows[index].contains { $0.box.insetBy(dx: charWidth * 0.5, dy: 0).intersects(fragment.box) && horizontalOverlap($0.box, fragment.box) > charWidth }
                if overlap >= smaller * 0.5 && !collides {
                    rows[index].append(fragment)
                    bands[index] = min(band.lowerBound, fragment.box.minY)...max(band.upperBound, fragment.box.maxY)
                    placed = true
                    break
                }
            }
            if !placed {
                rows.append([fragment])
                bands.append(fragment.box.minY...fragment.box.maxY)
            }
        }
        return rows.map { row in
            let cells = row.sorted { $0.box.minX < $1.box.minX }
            return Line(cells: cells, box: cells.dropFirst().reduce(cells[0].box) { $0.union($1.box) })
        }
        .sorted { $0.box.midY < $1.box.midY }
    }

    static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }

    // MARK: Panes

    /// Vertical strips that no fragment touches, at least `minWidth` wide.
    static func gutters(in fragments: [TextFragment], minWidth: CGFloat) -> [(left: CGFloat, right: CGFloat)] {
        let spans = fragments.map { ($0.box.minX, $0.box.maxX) }.sorted { $0.0 < $1.0 }
        guard var reach = spans.first?.1 else { return [] }
        var found: [(left: CGFloat, right: CGFloat)] = []
        for span in spans.dropFirst() {
            if span.0 - reach >= minWidth { found.append((reach, span.0)) }
            reach = max(reach, span.1)
        }
        return found
    }

    /// Splits at a gap when the lines on its two sides do not line up with each other.
    ///
    /// In a table or grid nearly every row continues across the gap. Between two panes of a window the
    /// lines sit at unrelated heights: measured on a real capture, 11–19 % of rows happen to line up
    /// closely across a pane boundary, against 100 % across the columns of a real table.
    static func splitPanes(_ fragments: [TextFragment], charWidth: CGFloat) -> (left: [TextFragment], right: [TextFragment])? {
        guard fragments.count >= 6 else { return nil }
        let candidates = gutters(in: fragments, minWidth: charWidth * 2.5).sorted { $0.right - $0.left > $1.right - $1.left }
        for gutter in candidates {
            let middle = (gutter.left + gutter.right) / 2
            let left = fragments.filter { $0.box.midX < middle }
            let right = fragments.filter { $0.box.midX >= middle }
            let leftRows = rowCentres(left), rightRows = rowCentres(right)
            guard leftRows.count >= 3, rightRows.count >= 3 else { continue }
            let (fewer, more) = leftRows.count <= rightRows.count ? (leftRows, rightRows) : (rightRows, leftRows)
            let aligned = fewer.filter { row in
                more.contains { abs($0.midY - row.midY) <= 0.25 * min($0.height, row.height) }
            }.count
            if Double(aligned) / Double(fewer.count) < 0.5 { return (left, right) }
        }
        return nil
    }

    static func rowCentres(_ fragments: [TextFragment]) -> [(midY: CGFloat, height: CGFloat)] {
        var rows: [(midY: CGFloat, height: CGFloat)] = []
        for fragment in fragments.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = rows.last, abs(last.midY - fragment.box.midY) <= 0.5 * min(last.height, fragment.box.height) { continue }
            rows.append((fragment.box.midY, fragment.box.height))
        }
        return rows
    }

    // MARK: Columns

    /// Splits prose laid out in side-by-side columns, so each column is read top to bottom.
    static func splitColumns(_ fragments: [TextFragment], charWidth: CGFloat) -> [[TextFragment]] {
        guard fragments.count >= 6 else { return [fragments] }
        let minX = fragments.map(\.box.minX).min()!
        let maxX = fragments.map(\.box.maxX).max()!
        let minGutter = charWidth * 2.5

        // Find vertical strips no fragment touches.
        let spans = fragments.map { ($0.box.minX, $0.box.maxX) }.sorted { $0.0 < $1.0 }
        var gutters: [(CGFloat, CGFloat)] = []
        var reach = spans[0].1
        for span in spans.dropFirst() {
            if span.0 - reach >= minGutter { gutters.append((reach, span.0)) }
            reach = max(reach, span.1)
        }
        guard !gutters.isEmpty else { return [fragments] }

        var columns: [[TextFragment]] = []
        var edges = [minX] + gutters.map { ($0.0 + $0.1) / 2 } + [maxX + 1]
        edges.sort()
        for index in 0..<(edges.count - 1) {
            let members = fragments.filter { $0.box.midX >= edges[index] && $0.box.midX < edges[index + 1] }
            if !members.isEmpty { columns.append(members) }
        }
        // Only treat it as columns of prose when every column has real lines of text.
        let prose = columns.allSatisfy { column in
            column.count >= 3 && median(column.map { CGFloat($0.text.count) }) >= 18
        }
        return prose && columns.count > 1 ? columns : [fragments]
    }

    // MARK: Tables

    /// Returns tab-separated text when the rows line up as a grid of short cells.
    func tableText(rows: [Line], charWidth: CGFloat) -> String? {
        guard rows.count >= 2 else { return nil }
        let gap = charWidth * 2.5
        // Re-split each row into cells by large horizontal gaps.
        let split: [[TextFragment]] = rows.map { row in
            var cells: [TextFragment] = []
            for fragment in row.cells {
                if var last = cells.last, fragment.box.minX - last.box.maxX < gap {
                    last.text += " " + fragment.text
                    last.box = last.box.union(fragment.box)
                    cells[cells.count - 1] = last
                } else {
                    cells.append(fragment)
                }
            }
            return cells
        }
        let multi = split.filter { $0.count >= 2 }
        guard multi.count >= 2, Double(multi.count) >= Double(rows.count) * 0.6 else { return nil }
        let cellLengths = multi.flatMap { $0.map { CGFloat($0.text.count) } }
        guard Self.median(cellLengths) < 18 else { return nil }

        // Column anchors: left edges that recur across rows.
        var anchors: [CGFloat] = []
        for cell in multi.flatMap({ $0 }).sorted(by: { $0.box.minX < $1.box.minX }) {
            if let last = anchors.last, cell.box.minX - last < gap { continue }
            anchors.append(cell.box.minX)
        }
        guard anchors.count >= 2 else { return nil }
        let aligned = multi.flatMap { $0 }.filter { cell in anchors.contains { abs($0 - cell.box.minX) < gap } }.count
        guard Double(aligned) >= Double(cellLengths.count) * 0.8 else { return nil }

        let lines = split.map { cells -> String in
            var slots = Array(repeating: "", count: anchors.count)
            for cell in cells {
                // Nearest anchor at or left of the cell.
                let index = anchors.lastIndex { $0 <= cell.box.minX + gap * 0.5 } ?? 0
                slots[index] = slots[index].isEmpty ? cell.text : slots[index] + " " + cell.text
            }
            while slots.last == "" { slots.removeLast() }
            return slots.joined(separator: "\t")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Paragraphs

    func composeColumn(_ lines: [Line], charWidth: CGFloat) -> String {
        guard var output = lines.first?.text else { return "" }
        let medianHeight = Self.median(lines.map(\.box.height))
        let gaps = zip(lines, lines.dropFirst()).map { max($1.box.minY - $0.box.maxY, 0) }
        let medianGap = Self.median(gaps)
        let left = lines.map(\.box.minX).min()!
        let right = lines.map(\.box.maxX).max()!
        let width = right - left

        for (index, current) in lines.enumerated().dropFirst() {
            let previous = lines[index - 1]
            let gap = gaps[index - 1]
            let paragraphGap = lines.count >= 4
                ? gap > medianGap * 1.6 && gap > medianHeight * 0.5
                : gap > medianHeight * 1.2

            switch mode {
            case .keepLines:
                output += (paragraphGap ? "\n\n" : "\n") + current.text
            case .singleLine:
                output = join(output, current.text)
            case .paragraphs:
                if paragraphGap {
                    output += "\n\n" + current.text
                } else if hardBreak(previous: previous, current: current, left: left, width: width, charWidth: charWidth) {
                    output += "\n" + current.text
                } else {
                    output = join(output, current.text)
                }
            }
        }
        return output
    }

    /// Whether two consecutive lines in the same paragraph block should still stay on separate lines.
    func hardBreak(previous: Line, current: Line, left: CGFloat, width: CGFloat, charWidth: CGFloat) -> Bool {
        if Self.startsListItem(current.text) { return true }
        // A heading or caption: clearly different text size.
        // Box height alone is unreliable (ascenders and descenders change it), so the letter width must differ too.
        let ratio = previous.box.height / current.box.height
        let widthRatio = Self.letterWidth(previous) / Self.letterWidth(current)
        if (ratio < 0.7 && widthRatio < 0.78) || (ratio > 1.43 && widthRatio > 1.28) { return true }
        // The current line is indented: a new paragraph by indentation.
        if current.box.minX - previous.box.minX > charWidth * 2 && previous.box.minX - left < charWidth { return true }
        // The previous line stops well short of the right edge, and what follows doesn't continue the sentence.
        let endsShort = previous.box.maxX < left + width * 0.82
        if endsShort {
            let first = current.text.first
            let continues = first.map { $0.isLowercase } ?? false
            let endsSentence = previous.text.last.map { ".?!:;\"”)".contains($0) } ?? false
            if !continues || endsSentence { return true }
        }
        return false
    }

    static func letterWidth(_ line: Line) -> CGFloat {
        let letters = line.cells.reduce(0) { $0 + $1.text.count }
        let width = line.cells.reduce(0) { $0 + $1.box.width }
        return width / CGFloat(max(letters, 1))
    }

    static func startsListItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•◦▪‣·*–—-▸►✓✔☐☑".contains(first), text.dropFirst().first == " " { return true }
        // "1." "12)" "a)" "(3)"
        return text.range(of: #"^\(?([0-9]{1,3}|[A-Za-z])[.)]\s"#, options: .regularExpression) != nil
    }

    /// Joins two pieces of running text: repairs hyphenation, and leaves no space between CJK characters.
    func join(_ head: String, _ tail: String) -> String {
        guard let last = head.last, let first = tail.first else { return head + tail }
        if (last == "-" || last == "\u{00AD}" || last == "‐"), head.count >= 2, first.isLowercase,
           head[head.index(head.endIndex, offsetBy: -2)].isLetter {
            let stem = String(head.dropLast())
            let lastWord = stem.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
            let nextWord = tail.prefix { $0.isLetter }
            let merged = lastWord + nextWord
            if last == "\u{00AD}" || isWord?(merged) ?? true { return stem + tail }
            return head + tail // a real compound: keep the hyphen, no space
        }
        if Self.isCJK(last) && Self.isCJK(first) { return head + tail }
        return head + " " + tail
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(scalar)      // Hiragana, Katakana
            || (0x3400...0x4DBF).contains(scalar)      // CJK Extension A
            || (0x4E00...0x9FFF).contains(scalar)      // CJK Unified
            || (0xF900...0xFAFF).contains(scalar)      // Compatibility
            || (0x3000...0x303F).contains(scalar)      // CJK punctuation
            || (0xFF00...0xFFEF).contains(scalar)      // Full-width forms
    }

    // MARK: Helpers

    static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"[ \u{00A0}]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #" +\n"#, with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
