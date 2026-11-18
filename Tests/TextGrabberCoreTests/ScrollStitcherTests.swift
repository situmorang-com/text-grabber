import XCTest
import CoreGraphics
@testable import TextGrabberCore

final class ScrollStitcherTests: XCTestCase {
    /// A long page of numbered lines, 30 px apart, seen through a 600 × 300 window scrolled to `scroll` pixels.
    private func frame(_ lines: [String], scroll: CGFloat, height: CGFloat = 300) -> ScrollStitcher.Frame {
        var fragments: [TextFragment] = []
        for (index, text) in lines.enumerated() {
            let top = CGFloat(index) * 30 + 10 - scroll
            guard top >= 0, top + 20 <= height else { continue }   // fully visible lines only
            fragments.append(TextFragment(text, CGRect(x: 20 / 600, y: top / height, width: CGFloat(text.count) * 8 / 600, height: 20 / height)))
        }
        return ScrollStitcher.Frame(fragments: fragments, size: CGSize(width: 600, height: height))
    }

    private let page = (1...40).map { "Line number \($0) of the long article" }

    /// Indices of the lines fully visible at a scroll position (same rule as `frame`).
    private func visible(_ scroll: CGFloat, count: Int = 40) -> [Int] {
        (0..<count).filter { let top = CGFloat($0) * 30 + 10 - scroll; return top >= 0 && top + 20 <= 300 }
    }

    /// Lines from the top of the first frame to the bottom of the furthest frame.
    private func expected(_ lines: [String], _ scrolls: [CGFloat]) -> [String] {
        let last = scrolls.map { visible($0, count: lines.count).last ?? 0 }.max() ?? 0
        return Array(lines[(visible(scrolls[0], count: lines.count).first ?? 0)...last])
    }

    private func texts(_ result: ScrollStitcher.Result) -> [String] {
        result.fragments.sorted { $0.box.minY < $1.box.minY }.map(\.text)
    }

    func testOverlappingFramesBecomeOnePageInOrder() {
        let scrolls: [CGFloat] = [0, 120, 250, 400, 610]
        let result = ScrollStitcher.stitch(scrolls.map { frame(page, scroll: $0) })
        XCTAssertEqual(texts(result), expected(page, scrolls))
        XCTAssertEqual(result.gaps, 0)
    }

    func testFramesThatDidNotScrollAddNothing() {
        let scrolls: [CGFloat] = [0, 0, 150, 150, 300]
        let result = ScrollStitcher.stitch(scrolls.map { frame(page, scroll: $0) })
        XCTAssertEqual(texts(result), expected(page, scrolls))
        XCTAssertEqual(result.unchanged, 2)
    }

    func testScrollingBackDoesNotRepeatLines() {
        let scrolls: [CGFloat] = [0, 200, 100, 300]
        XCTAssertEqual(texts(ScrollStitcher.stitch(scrolls.map { frame(page, scroll: $0) })), expected(page, scrolls))
    }

    func testSmallRecognitionDifferencesStillMatch() {
        var second = frame(page, scroll: 150)
        second.fragments[0].text = "Line number 6 of the long article."      // a stray full stop
        second.fragments[1].text = "line  number 7 of the long article"       // case and spacing
        let result = ScrollStitcher.stitch([frame(page, scroll: 0), second])
        XCTAssertEqual(texts(result), expected(page, [0, 150]))
    }

    func testAJumpWithNoSharedLineIsAppendedAndCounted() {
        let result = ScrollStitcher.stitch([frame(page, scroll: 0), frame(page, scroll: 600)])
        // The first frame's bottom line touches the edge, so it counts as cut off; nothing later shows it whole.
        let firstFrame = visible(0).filter { CGFloat($0) * 30 + 10 + 20 < 300 - 5 }
        XCTAssertEqual(texts(result), firstFrame.map { page[$0] } + visible(600).map { page[$0] })
        XCTAssertEqual(result.gaps, 1)
    }

    func testRepeatedLabelsDoNotMisleadTheMatch() {
        let feed = (1...30).flatMap { ["Reply", "Comment \($0) has its own text"] }
        let scrolls: [CGFloat] = [0, 180, 360]
        let result = ScrollStitcher.stitch(scrolls.map { frame(feed, scroll: $0) })
        XCTAssertEqual(texts(result), expected(feed, scrolls))
    }
}

/// Real recognition on overlapping crops of a long rendered page, as a scrolling capture would see it.
final class ScrollStitcherRecognitionTests: XCTestCase {
    func testStitchedFramesReadLikeTheWholePage() throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/scroll-page.png")
        let page = try XCTUnwrap(Recognizer.loadImages(from: url).first)
        var options = RecognitionOptions()
        options.useDocumentStructure = false
        let frameHeight = 260
        let offsets = [0, 130, 270, 400, page.height - frameHeight]
        var frames: [ScrollStitcher.Frame] = []
        for offset in offsets {
            let crop = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: frameHeight)))
            let fragments = try Recognizer.readFragments(in: crop, options: options).fragments
            frames.append(ScrollStitcher.Frame(fragments: fragments, size: CGSize(width: crop.width, height: crop.height)))
        }
        let stitched = ScrollStitcher.stitch(frames)
        XCTAssertEqual(stitched.gaps, 0)

        let words = { (text: String) in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
        let whole = words(try Recognizer.recognizeText(in: page, options: options).text)
        let joined = words(Recognizer.compose(stitched.fragments, options: options).render())
        // Every word of the page, in order, and nothing twice. (A word read slightly differently in one frame may differ.)
        let same = zip(whole, joined).filter { $0 == $1 }.count

        XCTAssertEqual(joined.count, whole.count, "stitched text has a different number of words")
        XCTAssertGreaterThanOrEqual(Double(same) / Double(whole.count), 0.97)
    }
}
