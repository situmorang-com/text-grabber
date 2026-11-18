import Foundation
import CoreGraphics

/// Joins the recognised lines of successive screenshots of one area, taken while its content scrolled,
/// into the lines of one tall page.
///
/// Frames are matched by their text, not their pixels: lines that appear in both frames give the scroll
/// distance, and only the lines below the overlap are added. This works with any background and ignores
/// small rendering differences between frames.
public enum ScrollStitcher {
    public struct Frame {
        public var fragments: [TextFragment]
        /// Size of the screenshot in pixels; boxes in `fragments` are normalised to it.
        public var size: CGSize

        public init(fragments: [TextFragment], size: CGSize) {
            self.fragments = fragments
            self.size = size
        }
    }

    public struct Result {
        /// Lines of the whole page, boxes normalised to `size`.
        public var fragments: [TextFragment]
        public var size: CGSize
        /// Frames that shared no line with the frame before (scrolled too far between two screenshots).
        public var gaps: Int
        /// Frames that added nothing (not scrolled, or scrolled back).
        public var unchanged: Int
    }

    public static func stitch(_ frames: [Frame]) -> Result {
        guard let first = frames.first else { return Result(fragments: [], size: .zero, gaps: 0, unchanged: 0) }
        let width = first.size.width
        // Page lines in pixels, top of the first frame = 0.
        // A line cut by the edge of a screenshot is read badly; it is taken from a frame where it is whole.
        func whole(_ lines: [TextFragment], _ frame: Frame, isFirst: Bool, isLast: Bool) -> [TextFragment] {
            let lineHeight = median(lines.map(\.box.height))
            return lines.filter { line in
                (isFirst || line.box.minY > lineHeight * 0.25) && (isLast || line.box.maxY < frame.size.height - lineHeight * 0.25)
            }
        }
        var page: [(text: String, key: String, box: CGRect, confidence: Float)] =
            whole(pixels(first), first, isFirst: true, isLast: frames.count == 1).map { ($0.text, key($0.text), $0.box, $0.confidence) }
        var previous = pixels(first)
        var previousOffset: CGFloat = 0
        var gaps = 0, unchanged = 0

        for (number, frame) in frames.enumerated().dropFirst() {
            let current = pixels(frame)
            guard !current.isEmpty else { unchanged += 1; continue }
            // Distance the content moved up between the two frames, from lines with the same text.
            var shifts: [CGFloat] = []
            for line in current where line.text.count >= 3 {
                let k = key(line.text)
                let matches = previous.filter { key($0.text) == k }
                // A line that occurs several times (a repeated label) says nothing reliable.
                if matches.count == 1 { shifts.append(matches[0].box.minY - line.box.minY) }
            }
            let lineHeight = median(current.map(\.box.height))
            let shift: CGFloat
            if let consensus = mostCommon(shifts, tolerance: max(lineHeight * 0.4, 2)) {
                shift = consensus
            } else {
                // No shared line: the content moved more than a whole frame. Continue below, with a gap.
                gaps += 1
                shift = (previous.map(\.box.maxY).max() ?? 0) + lineHeight * 1.5
            }
            guard shift > lineHeight * 0.5 else { unchanged += 1; continue }   // not scrolled, or scrolled back

            let offset = previousOffset + shift
            let pageBottom = page.map(\.box.maxY).max() ?? 0
            var added = 0
            for line in whole(current, frame, isFirst: false, isLast: number == frames.count - 1) {
                let placed = line.box.offsetBy(dx: 0, dy: offset)
                if placed.midY > pageBottom + lineHeight * 0.3 {
                    // Only what lies below what the page already has.
                    page.append((line.text, key(line.text), placed, line.confidence))
                    added += 1
                } else if let index = page.firstIndex(where: { abs($0.box.midY - placed.midY) < lineHeight * 0.5 && $0.box.intersects(placed.insetBy(dx: 0, dy: -2)) }),
                          line.confidence > page[index].confidence {
                    // The same line, read with more confidence this time.
                    page[index] = (line.text, key(line.text), placed, line.confidence)
                }
            }
            if added == 0 { unchanged += 1 }
            previous = current
            previousOffset = offset
        }

        let height = max(page.map(\.box.maxY).max() ?? 1, 1)
        let fragments = page.map { line in
            TextFragment(line.text, CGRect(x: line.box.minX / width, y: line.box.minY / height,
                                           width: line.box.width / width, height: line.box.height / height))
        }
        return Result(fragments: fragments, size: CGSize(width: width, height: height), gaps: gaps, unchanged: unchanged)
    }

    /// Fragments in pixels, top to bottom.
    static func pixels(_ frame: Frame) -> [TextFragment] {
        frame.fragments.map { fragment in
            var copy = fragment
            copy.box = CGRect(x: fragment.box.minX * frame.size.width, y: fragment.box.minY * frame.size.height,
                              width: fragment.box.width * frame.size.width, height: fragment.box.height * frame.size.height)
            return copy
        }.sorted { $0.box.minY < $1.box.minY }
    }

    /// Text compared loosely: case, spaces and punctuation ignored, so small recognition differences still match.
    static func key(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The value most of the samples agree on, within a tolerance; nil when there are no samples.
    static func mostCommon(_ values: [CGFloat], tolerance: CGFloat) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        var best: (value: CGFloat, count: Int) = (0, 0)
        for value in values {
            let near = values.filter { abs($0 - value) <= tolerance }
            if near.count > best.count { best = (median(near), near.count) }
        }
        return best.value
    }

    static func median(_ values: [CGFloat]) -> CGFloat {
        LayoutEngine.median(values)
    }
}
