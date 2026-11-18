import Foundation

/// Repairs OCR lines with the real text of the window they were captured from.
///
/// OCR cannot read emoji or symbols such as ⌘ and ⇧: it drops them or substitutes a lookalike. When the
/// app under the capture exposes its text (through the Accessibility API), each OCR line is located inside
/// that text by approximate matching, and the real characters are used instead.
public enum ExactText {
    public struct Outcome: Equatable {
        public var lines: [String]
        /// How many lines were replaced by text from a source.
        public var replaced: Int
    }

    /// - Parameters:
    ///   - lines: OCR text, one entry per recognised line.
    ///   - candidates: for each line, the indices of the `sources` found at its position on screen.
    ///   - sources: text read from the apps under the capture.
    ///   - tolerance: the share of a line's characters that may differ and still count as the same text.
    public static func refine(lines: [String], candidates: [[Int]], sources: [String], tolerance: Double = 0.3) -> Outcome {
        var encoder = Encoder()
        let sourceCharacters = sources.map { Array($0.prefix(maxSourceLength)) }
        let sourceCodes = sourceCharacters.map { encoder.encode($0) }

        struct Match { var source: Int; var range: Range<Int>; var distance: Int }
        var matches: [Match?] = Array(repeating: nil, count: lines.count)

        // A list number or bullet is drawn by the app and is often missing from its text: match what follows it.
        let split = lines.map { splitListMarker($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        for (index, parts) in split.enumerated() {
            let pattern = Array(parts.body)
            guard pattern.count >= 3, index < candidates.count else { continue }
            let codes = encoder.encode(pattern)
            let allowed = max(1, Int(Double(pattern.count) * tolerance))
            var best: Match?
            for source in candidates[index] where source < sourceCodes.count {
                guard let found = approximateMatch(of: codes, in: sourceCodes[source]), found.distance <= allowed else { continue }
                if best == nil || found.distance < best!.distance {
                    best = Match(source: source, range: found.range, distance: found.distance)
                }
            }
            matches[index] = best
        }

        // OCR may have dropped an emoji at either end of a line without leaving a trace.
        // Give such neighbours to the line they touch: first to the line before them, then to the line after.
        var claimed: [Int: [Range<Int>]] = [:]
        for match in matches.compactMap({ $0 }) { claimed[match.source, default: []].append(match.range) }
        func isFree(_ position: Int, in source: Int) -> Bool {
            !(claimed[source] ?? []).contains { $0.contains(position) }
        }
        for forward in [true, false] {
            for index in matches.indices {
                guard var match = matches[index] else { continue }
                let characters = sourceCharacters[match.source]
                var edge = forward ? match.range.upperBound : match.range.lowerBound
                var taken = 0
                while taken < 4 {
                    var probe = forward ? edge : edge - 1
                    // Allow one space between the text and the symbol.
                    if probe >= 0, probe < characters.count, characters[probe] == " " { probe += forward ? 1 : -1 }
                    guard probe >= 0, probe < characters.count, isUnreadable(characters[probe]), isFree(probe, in: match.source) else { break }
                    edge = forward ? probe + 1 : probe
                    taken += 1
                }
                guard taken > 0 else { continue }
                let grown = forward ? match.range.lowerBound..<edge : edge..<match.range.upperBound
                claimed[match.source, default: []].append(grown)
                match.range = grown
                matches[index] = match
            }
        }

        var output = lines
        var replaced = 0
        for (index, match) in matches.enumerated() {
            guard let match else { continue }
            let exact = String(sourceCharacters[match.source][match.range])
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Leave the line alone when the only difference is spacing: OCR is right about what is visible.
            // The app's text can be incomplete (a nested piece it did not report). Never trade recognised
            // words for nothing: if the swap would lose more than a few letters or digits, keep what OCR saw.
            let seen = split[index].body.filter { $0.isLetter || $0.isNumber }.count
            let offered = exact.filter { $0.isLetter || $0.isNumber }.count
            if seen - offered > max(4, seen / 10) { continue }

            // A bullet the app does not have is an icon that OCR mistook for one: drop it.
            // Numbers are kept either way; apps often draw them without putting them in their text.
            var marker = split[index].marker
            let isBullet = marker.first.map { !$0.isNumber && $0 != "(" } ?? false
            let characters = sourceCharacters[match.source]
            var before = match.range.lowerBound - 1
            while before >= 0, characters[before] == " " { before -= 1 }
            let sourceHasBullet = before >= 0 && "•◦▪‣*–-·".contains(characters[before])
            if isBullet, !sourceHasBullet { marker = "" }
            // And the other way round: a bullet OCR missed, when the app's text begins this item with one.
            if marker.isEmpty, sourceHasBullet, before == 0 || characters[before - 1] == "\n" {
                marker = String(characters[before]) + " "
            }
            if skeleton(exact) == skeleton(split[index].body) && marker == split[index].marker { continue }
            output[index] = marker + exact
            replaced += 1
        }
        return Outcome(lines: output, replaced: replaced)
    }

    public static let maxSourceLength = 8000

    /// "2. Click here" → ("2. ", "Click here"); text without a list marker comes back whole as the body.
    static func splitListMarker(_ line: String) -> (marker: String, body: String) {
        guard let range = line.range(of: #"^(\(?[0-9]{1,3}[.)]|[•◦▪‣*–-])\s+"#, options: .regularExpression) else { return ("", line) }
        return (String(line[range]), String(line[range.upperBound...]))
    }

    // MARK: Matching

    /// The stretch of `text` closest to `pattern` (Sellers' algorithm), with the number of edits between them.
    static func approximateMatch(of pattern: [Int32], in text: [Int32]) -> (range: Range<Int>, distance: Int)? {
        let m = pattern.count, n = text.count
        guard m > 0, n > 0 else { return nil }
        // Column by column; `starts` remembers where the best alignment ending here began.
        var previous = Array(0...m)
        var previousStarts = Array(repeating: 0, count: m + 1)
        var current = previous
        var currentStarts = previousStarts
        var best = (distance: Int.max, start: 0, end: 0)

        for j in 1...n {
            current[0] = 0
            currentStarts[0] = j
            let character = text[j - 1]
            for i in 1...m {
                let substitute = previous[i - 1] + (pattern[i - 1] == character ? 0 : 1)
                let skipText = current[i - 1] + 1      // pattern character with nothing in the text
                let skipPattern = previous[i] + 1      // text character the pattern lacks
                if substitute <= skipText && substitute <= skipPattern {
                    current[i] = substitute
                    currentStarts[i] = previousStarts[i - 1]
                } else if skipPattern <= skipText {
                    current[i] = skipPattern
                    currentStarts[i] = previousStarts[i]
                } else {
                    current[i] = skipText
                    currentStarts[i] = currentStarts[i - 1]
                }
            }
            if current[m] <= best.distance {
                best = (current[m], currentStarts[m], j)
            }
            swap(&previous, &current)
            swap(&previousStarts, &currentStarts)
            previousStarts[0] = j
        }
        guard best.distance != Int.max, best.start < best.end else { return nil }
        return (best.start..<best.end, best.distance)
    }

    /// Maps characters to small integers so comparing them is cheap. Case and typographic variants share a code.
    struct Encoder {
        private var codes: [String: Int32] = [:]

        mutating func encode(_ characters: [Character]) -> [Int32] {
            characters.map { character in
                let key = Self.fold(character)
                if let code = codes[key] { return code }
                let code = Int32(codes.count)
                codes[key] = code
                return code
            }
        }

        static func fold(_ character: Character) -> String {
            switch character {
            case "’", "‘", "ʼ": return "'"
            case "“", "”": return "\""
            case "–", "—", "‐", "‑": return "-"
            case "\u{00A0}", "\u{202F}", "\n", "\t": return " "
            default: return character.lowercased()
            }
        }
    }

    /// Characters OCR does not produce: emoji, pictographs, key symbols, private-use glyphs.
    static func isUnreadable(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .modifierSymbol, .privateUse: return scalar.value > 0x00FF
        default: return false
        }
    }

    /// The text without spaces and with typographic variants folded, but with its letter case:
    /// "WI-FI" against "Wi-Fi" is a misread worth correcting, "Wi - Fi" against "Wi-Fi" is not.
    private static func skeleton(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace }.map { character -> String in
            let folded = Encoder.fold(character)
            return folded == character.lowercased() ? String(character) : folded
        }.joined())
    }
}
