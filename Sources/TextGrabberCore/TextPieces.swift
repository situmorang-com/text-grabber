import Foundation

/// Text cut into the pieces a translator should see, so line breaks and table columns survive translation.
public struct TextPieces {
    private let lines: [[String]]
    /// Non-blank cells, in order: what gets translated.
    public let pieces: [String]

    public init(_ text: String) {
        lines = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        pieces = lines.flatMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Puts translated pieces back where their originals were. Missing translations keep the original.
    public func reassemble(_ translated: [String?]) -> String {
        var next = 0
        return lines.map { cells in
            cells.map { cell -> String in
                guard !cell.trimmingCharacters(in: .whitespaces).isEmpty else { return cell }
                defer { next += 1 }
                return (next < translated.count ? translated[next] : nil) ?? cell
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Share of the first text's words that also appear in the second. Used to refuse a "correction" that
    /// rewrote the text instead of fixing it.
    public static func wordOverlap(_ a: String, _ b: String) -> Double {
        let wordsA = a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let wordsB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !wordsA.isEmpty else { return 1 }
        return Double(wordsA.filter { wordsB.contains($0) }.count) / Double(wordsA.count)
    }

    /// Splits text into chunks of at most about `limit` characters at blank lines, for models with a small context.
    public static func chunks(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for block in text.components(separatedBy: "\n\n") {
            if !current.isEmpty, current.count + block.count > limit {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + block
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
