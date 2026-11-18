import Foundation

/// Recognised text as a sequence of blocks, so it can be written out in different formats.
public struct StructuredText: Equatable {
    public enum Block: Equatable {
        /// One or more lines of running text. `spaced` puts a blank line before it.
        case text(String, spaced: Bool)
        case table([[String]])
    }

    public var blocks: [Block]

    public init(_ blocks: [Block]) {
        self.blocks = blocks
    }

    /// Splits plain text into blocks, treating runs of tab-separated lines as tables.
    public init(plain: String) {
        var blocks: [Block] = []
        for (index, chunk) in plain.components(separatedBy: "\n\n").enumerated() {
            let lines = chunk.components(separatedBy: "\n")
            var textLines: [String] = []
            var tableRows: [[String]] = []
            func flushText() {
                if !textLines.isEmpty { blocks.append(.text(textLines.joined(separator: "\n"), spaced: index > 0 || !blocks.isEmpty)) }
                textLines = []
            }
            func flushTable() {
                if tableRows.count >= 2 { blocks.append(.table(tableRows)) } else { textLines += tableRows.map { $0.joined(separator: "\t") } }
                tableRows = []
            }
            for line in lines {
                if line.contains("\t") {
                    flushText()
                    tableRows.append(line.components(separatedBy: "\t"))
                } else {
                    flushTable()
                    textLines.append(line)
                }
            }
            flushTable()
            flushText()
        }
        self.blocks = blocks
    }

    public enum TableStyle: String, CaseIterable, Codable {
        case tabs, markdown, csv
    }

    public enum Format: String, CaseIterable, Codable {
        /// Plain text; tables in the chosen table style.
        case plain
        /// Markdown: tables as Markdown tables, lists and paragraphs unchanged.
        case markdown
    }

    public var hasTable: Bool {
        blocks.contains { if case .table = $0 { return true } else { return false } }
    }

    public func render(_ format: Format = .plain, tables: TableStyle = .tabs) -> String {
        var output = ""
        for block in blocks {
            switch block {
            case .text(let text, let spaced):
                if !output.isEmpty { output += spaced ? "\n\n" : "\n" }
                output += text
            case .table(let rows):
                if !output.isEmpty { output += "\n\n" }
                output += Self.render(rows, style: format == .markdown ? .markdown : tables)
            }
        }
        return output
    }

    static func render(_ rows: [[String]], style: TableStyle) -> String {
        let width = rows.map(\.count).max() ?? 0
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        switch style {
        case .tabs:
            return padded.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .csv:
            return padded.map { row in
                row.map { cell in
                    cell.contains(where: { ",\"\n".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
                }.joined(separator: ",")
            }.joined(separator: "\n")
        case .markdown:
            guard let header = padded.first else { return "" }
            let escape = { (cell: String) in cell.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
            var lines = ["| " + header.map(escape).joined(separator: " | ") + " |",
                         "|" + Array(repeating: " --- |", count: width).joined()]
            lines += padded.dropFirst().map { "| " + $0.map(escape).joined(separator: " | ") + " |" }
            return lines.joined(separator: "\n")
        }
    }
}
