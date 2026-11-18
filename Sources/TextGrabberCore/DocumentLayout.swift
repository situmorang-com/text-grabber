import Foundation
import CoreGraphics

/// Where Apple's document recognition found paragraphs and tables. Boxes are normalised with a top-left origin,
/// like `TextFragment.box`.
public struct DocumentStructure: Equatable {
    public struct Table: Equatable {
        public var box: CGRect
        /// Cell boxes by row, then column. A merged cell appears once, in its first row and column.
        public var cells: [[CGRect]]

        public init(box: CGRect, cells: [[CGRect]]) {
            self.box = box
            self.cells = cells
        }
    }

    /// Paragraph boxes in Apple's reading order. List items are paragraphs of their own.
    public var paragraphs: [CGRect]
    public var tables: [Table]

    public init(paragraphs: [CGRect], tables: [Table]) {
        self.paragraphs = paragraphs
        self.tables = tables
    }
}

/// Lays out our recognised lines using Apple's grouping into paragraphs and table cells.
///
/// The words come from our own recognition (with its enlargement, retries and exact text from apps);
/// only the grouping comes from the document structure. Measured on a rendered page, this keeps table
/// cells that wrap over several lines together, which our own rules cannot do, while Apple's own text
/// dropped whole lines of small table cells.
public struct DocumentLayout {
    public var mode: LineMode
    public var isWord: ((String) -> Bool)?

    public init(mode: LineMode, isWord: ((String) -> Bool)? = nil) {
        self.mode = mode
        self.isWord = isWord
    }

    public func compose(_ input: [TextFragment], structure: DocumentStructure) -> StructuredText {
        let fragments = Self.splitAcrossCells(input
            .map { var f = $0; let trimmed = f.text.trimmingCharacters(in: .whitespacesAndNewlines); if trimmed != f.text { f.text = trimmed; f.wordBoxes = [] }; return f }
            .filter { !$0.text.isEmpty && $0.box.width > 0 && $0.box.height > 0 }, structure: structure)
        guard !fragments.isEmpty else { return StructuredText([]) }

        enum Owner: Hashable { case cell(table: Int, row: Int, column: Int), paragraph(Int), none }
        var owners: [Owner] = []
        for fragment in fragments {
            let centre = CGPoint(x: fragment.box.midX, y: fragment.box.midY)
            var owner = Owner.none
            search: for (t, table) in structure.tables.enumerated() where table.box.insetBy(dx: -0.002, dy: -0.002).contains(centre) {
                for (r, row) in table.cells.enumerated() {
                    for (c, cell) in row.enumerated() where cell.insetBy(dx: -0.003, dy: -0.003).contains(centre) {
                        owner = .cell(table: t, row: r, column: c)
                        break search
                    }
                }
            }
            if owner == .none {
                // The paragraph that covers most of the line.
                var best = (index: -1, area: CGFloat(0))
                for (p, box) in structure.paragraphs.enumerated() {
                    let overlap = box.intersection(fragment.box)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    if area > best.area { best = (p, area) }
                }
                if best.index >= 0, best.area >= fragment.box.width * fragment.box.height * 0.3 { owner = .paragraph(best.index) }
            }
            owners.append(owner)
        }

        // Units in Apple's reading order: paragraphs, and each table where its first paragraph is. Lines Apple did not
        // place become paragraphs of their own, inserted by position. A unit's box is the union of its own lines,
        // so gaps are measured between text, not between Apple's looser paragraph boxes.
        struct Unit { var box: CGRect; var kind: Kind; enum Kind { case paragraph(Int), table(Int), orphan(Int), lines([Int]) } }
        func linesBox(_ indices: [Int]) -> CGRect? {
            var box: CGRect?
            for index in indices { box = box.map { $0.union(fragments[index].box) } ?? fragments[index].box }
            return box
        }
        func tableIndices(_ t: Int) -> [Int] {
            fragments.indices.filter { if case .cell(t, _, _) = owners[$0] { return true } else { return false } }
        }
        let tableOf: (CGRect) -> Int? = { box in
            structure.tables.firstIndex { $0.box.insetBy(dx: -0.002, dy: -0.002).contains(CGPoint(x: box.midX, y: box.midY)) }
        }
        var units: [Unit] = []
        for (p, paragraph) in structure.paragraphs.enumerated() where tableOf(paragraph) == nil {
            if let box = linesBox(fragments.indices.filter { owners[$0] == .paragraph(p) }) {
                units.append(Unit(box: box, kind: .paragraph(p)))
            }
        }
        for t in structure.tables.indices {
            guard let box = linesBox(tableIndices(t)) else { continue }
            if let columns = proseColumns(structure.tables[t], table: t, fragments: fragments, owners: owners.map { owner -> (Int, Int, Int)? in
                if case .cell(let tt, let r, let c) = owner { return (tt, r, c) } else { return nil }
            }) {
                // Two columns of running text that happen to line up: each column is a paragraph.
                for column in columns { if let box = linesBox(column) { units.append(Unit(box: box, kind: .lines(column))) } }
            } else {
                units.append(Unit(box: box, kind: .table(t)))
            }
        }
        for (index, owner) in owners.enumerated() where owner == .none {
            units.append(Unit(box: fragments[index].box, kind: .orphan(index)))
        }
        // Apple's paragraph order is not reliable (measured: a page title came after the table below it), so the
        // order comes from the layout: side-by-side regions left to right, then top to bottom within each.
        // Boxes are normalised per axis, so a horizontal gap is measured in character widths, not line heights.
        let charWidth = LayoutEngine.median(fragments.map { $0.box.width / CGFloat(max($0.text.count, 1)) })
        units = Self.readingOrder(units, box: \.box, gutter: charWidth * 1.5,
                                  rowGap: LayoutEngine.median(fragments.map(\.box.height)) * 0.5)

        // A blank line goes where the space between two blocks is clearly more than the usual line spacing.
        let lineHeight = LayoutEngine.median(fragments.map(\.box.height))
        // The usual space between lines, measured inside paragraphs that have more than one line.
        var lineGaps: [CGFloat] = []
        for p in structure.paragraphs.indices {
            let lines = fragments.indices.filter { owners[$0] == .paragraph(p) }.map { fragments[$0].box }.sorted { $0.minY < $1.minY }
            for (a, b) in zip(lines, lines.dropFirst()) where b.minY > a.midY { lineGaps.append(max(b.minY - a.maxY, 0)) }
        }
        let leading = lineGaps.isEmpty ? lineHeight * 0.3 : LayoutEngine.median(lineGaps)
        var blocks: [StructuredText.Block] = []
        var previous: CGRect?
        for unit in units {
            let spaced: Bool = {
                guard let previous else { return false }
                if unit.box.minY < previous.minY - lineHeight * 0.5 || !Self.sameColumn(unit.box, previous) { return true }
                return unit.box.minY - previous.maxY > leading + lineHeight * 0.45
            }()
            switch unit.kind {
            case .paragraph(let p):
                let lines = fragments.indices.filter { owners[$0] == .paragraph(p) }.map { fragments[$0] }
                blocks.append(.text(joinLines(lines), spaced: spaced))
            case .orphan(let index):
                blocks.append(.text(fragments[index].text, spaced: spaced))
            case .lines(let indices):
                blocks.append(.text(joinLines(indices.map { fragments[$0] }), spaced: spaced))
            case .table(let t):
                let rows = structure.tables[t].cells.indices.map { r in
                    structure.tables[t].cells[r].indices.map { c in
                        let lines = fragments.indices.filter { owners[$0] == .cell(table: t, row: r, column: c) }.map { fragments[$0] }
                        return joinLines(lines, forceSingleLine: true)
                    }
                }.filter { row in row.contains { !$0.isEmpty } }
                let columns = rows.map { $0.filter { !$0.isEmpty }.count }.max() ?? 0
                if rows.count >= 2, columns >= 2 {
                    blocks.append(.table(rows))
                } else {
                    // A "table" of one column is a list of lines, such as a sidebar.
                    blocks.append(.text(rows.map { $0.filter { !$0.isEmpty }.joined(separator: " ") }.joined(separator: "\n"), spaced: spaced))
                }
            }
            previous = unit.box
        }

        if mode == .singleLine {
            return StructuredText([.text(StructuredText(blocks).render().replacingOccurrences(of: "\n\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " "), spaced: false)])
        }
        return StructuredText(blocks)
    }

    /// The fragments of each column, when a two-or-more-column "table" is really columns of prose: long cells,
    /// and rows that continue the sentence of the row above (measured: Apple reports side-by-side text columns
    /// whose lines happen to align as a table).
    func proseColumns(_ table: DocumentStructure.Table, table t: Int, fragments: [TextFragment], owners: [(Int, Int, Int)?]) -> [[Int]]? {
        let columnCount = table.cells.map(\.count).max() ?? 0
        guard columnCount >= 2, table.cells.count >= 3 else { return nil }
        var columns = Array(repeating: [Int](), count: columnCount)
        var cellTexts = Array(repeating: [String](), count: columnCount)
        for row in table.cells.indices {
            for column in 0..<columnCount {
                let members = owners.indices.filter { owners[$0].map { $0 == (t, row, column) } ?? false }
                columns[column] += members
                let text = members.map { fragments[$0].text }.joined(separator: " ")
                if !text.isEmpty { cellTexts[column].append(text) }
            }
        }
        let all = cellTexts.flatMap { $0 }
        guard !all.isEmpty, LayoutEngine.median(all.map { CGFloat($0.count) }) >= 18 else { return nil }
        let continuations = cellTexts.flatMap { $0.dropFirst() }
        let lowercase = continuations.filter { $0.first?.isLowercase == true }.count
        guard !continuations.isEmpty, Double(lowercase) / Double(continuations.count) >= 0.5 else { return nil }
        return columns.filter { !$0.isEmpty }
    }

    /// Lines of one paragraph or cell, top to bottom, joined according to the mode.
    func joinLines(_ lines: [TextFragment], forceSingleLine: Bool = false) -> String {
        let engine = LayoutEngine(mode: forceSingleLine ? .singleLine : mode, isWord: isWord)
        let rows = LayoutEngine.rows(from: lines, charWidth: LayoutEngine.median(lines.map { $0.box.width / CGFloat(max($0.text.count, 1)) }))
        guard var output = rows.first?.text else { return "" }
        for row in rows.dropFirst() {
            output = (forceSingleLine ? .singleLine : mode) == .keepLines ? output + "\n" + row.text : engine.join(output, row.text)
        }
        return LayoutEngine.tidy(output)
    }

    /// Recursive XY cut: split at a vertical gap that no item crosses (left, then right); failing that, split at
    /// horizontal gaps (top to bottom); failing both, sort by position.
    static func readingOrder<T>(_ items: [T], box: KeyPath<T, CGRect>, gutter: CGFloat, rowGap: CGFloat) -> [T] {
        guard items.count > 1 else { return items }
        let byX = items.sorted { $0[keyPath: box].minX < $1[keyPath: box].minX }
        var reach = byX[0][keyPath: box].maxX
        var best: (index: Int, width: CGFloat)?
        for index in 1..<byX.count {
            let gap = byX[index][keyPath: box].minX - reach
            if gap >= gutter, gap > (best?.width ?? 0) { best = (index, gap) }
            reach = max(reach, byX[index][keyPath: box].maxX)
        }
        if let best {
            return readingOrder(Array(byX[..<best.index]), box: box, gutter: gutter, rowGap: rowGap)
                + readingOrder(Array(byX[best.index...]), box: box, gutter: gutter, rowGap: rowGap)
        }
        let byY = items.sorted { $0[keyPath: box].minY < $1[keyPath: box].minY }
        var bands: [[T]] = [[byY[0]]]
        var bottom = byY[0][keyPath: box].maxY
        for item in byY.dropFirst() {
            if item[keyPath: box].minY >= bottom { bands.append([item]) } else { bands[bands.count - 1].append(item) }
            bottom = max(bottom, item[keyPath: box].maxY)
        }
        if bands.count > 1 { return bands.flatMap { readingOrder($0, box: box, gutter: gutter, rowGap: rowGap) } }
        return byY.sorted { abs($0[keyPath: box].minY - $1[keyPath: box].minY) > rowGap ? $0[keyPath: box].minY < $1[keyPath: box].minY : $0[keyPath: box].minX < $1[keyPath: box].minX }
    }

    /// Recognition sometimes reads two neighbouring table cells as one line ("Basic Free for everyone").
    /// Such a line is cut where the cell boundary falls, using word positions, or character positions when
    /// recognition gave none.
    static func splitAcrossCells(_ fragments: [TextFragment], structure: DocumentStructure) -> [TextFragment] {
        var result: [TextFragment] = []
        for fragment in fragments {
            let centreY = fragment.box.midY
            var cells: [CGRect] = []
            for table in structure.tables {
                for row in table.cells {
                    for cell in row where cell.minY <= centreY && centreY <= cell.maxY {
                        let overlap = cell.intersection(fragment.box)
                        // Overlap measured in character widths of this line.
                        let charWidth: CGFloat = fragment.box.width / CGFloat(max(fragment.text.count, 1))
                        if !overlap.isNull, overlap.width > charWidth * 2 { cells.append(cell) }
                    }
                }
            }
            cells.sort { $0.minX < $1.minX }
            let words = fragment.words
            guard cells.count >= 2, words.count >= 2 else { result.append(fragment); continue }
            let wordBoxes: [CGRect] = fragment.wordBoxes.count == words.count ? fragment.wordBoxes : {
                // Estimate from character positions along the line.
                var boxes: [CGRect] = []
                let total = CGFloat(max(fragment.text.count, 1))
                var offset = 0
                for word in words {
                    let start = fragment.text.distance(from: fragment.text.startIndex, to: word.startIndex)
                    offset = start
                    let x = fragment.box.minX + fragment.box.width * CGFloat(offset) / total
                    boxes.append(CGRect(x: x, y: fragment.box.minY, width: fragment.box.width * CGFloat(word.count) / total, height: fragment.box.height))
                }
                return boxes
            }()
            var groups: [Int: [Int]] = [:]
            for (index, box) in wordBoxes.enumerated() {
                let cell = cells.firstIndex { $0.minX <= box.midX && box.midX <= $0.maxX } ?? (box.midX < cells[0].minX ? 0 : cells.count - 1)
                groups[cell, default: []].append(index)
            }
            guard groups.count >= 2 else { result.append(fragment); continue }
            for cell in groups.keys.sorted() {
                let indices = groups[cell]!
                var part = TextFragment(indices.map { String(words[$0]) }.joined(separator: " "),
                                        indices.dropFirst().reduce(wordBoxes[indices[0]]) { $0.union(wordBoxes[$1]) })
                part.confidence = fragment.confidence
                part.wordBoxes = indices.map { wordBoxes[$0] }
                result.append(part)
            }
        }
        return result
    }

    static func sameColumn(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0
    }
}
