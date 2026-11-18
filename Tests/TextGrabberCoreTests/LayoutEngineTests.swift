import XCTest
import CoreGraphics
@testable import TextGrabberCore

final class LayoutEngineTests: XCTestCase {
    /// A line of text at a row/column position, 10 units per character, 20 high, 30 between baselines.
    private func line(_ text: String, x: CGFloat = 0, row: CGFloat, height: CGFloat = 20) -> TextFragment {
        TextFragment(text, CGRect(x: x, y: row * 30, width: CGFloat(text.count) * 10, height: height))
    }

    private func engine(_ mode: LineMode, dictionary: Set<String>? = nil) -> LayoutEngine {
        LayoutEngine(mode: mode, isWord: dictionary.map { words in { words.contains($0.lowercased()) } })
    }

    func testReadingOrderIgnoresInputOrder() {
        let fragments = [
            line("third line of the text here", row: 2),
            line("first line of the text here", row: 0),
            line("second line of the text now", row: 1),
        ]
        XCTAssertEqual(engine(.keepLines).compose(fragments),
                       "first line of the text here\nsecond line of the text now\nthird line of the text here")
    }

    func testPiecesOnOneRowAreJoinedLeftToRight() {
        let fragments = [line("world", x: 70, row: 0), line("hello", x: 0, row: 0)]
        XCTAssertEqual(engine(.keepLines).compose(fragments), "hello world")
    }

    func testParagraphModeReflowsWrappedLines() {
        let fragments = [
            line("The quick brown fox jumps over the", row: 0),
            line("lazy dog and keeps running until it", row: 1),
            line("reaches the river.", row: 2),
        ]
        XCTAssertEqual(engine(.paragraphs).compose(fragments),
                       "The quick brown fox jumps over the lazy dog and keeps running until it reaches the river.")
    }

    func testParagraphGapBecomesBlankLine() {
        let fragments = [
            line("First paragraph starts here and it", row: 0),
            line("wraps onto a second line right here", row: 1),
            line("and a third line to set the rhythm.", row: 2),
            line("Second paragraph begins after a gap", row: 4),
            line("and also wraps onto another line ok.", row: 5),
        ]
        let text = engine(.paragraphs).compose(fragments)
        XCTAssertEqual(text.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(text.hasPrefix("First paragraph starts here and it wraps"))
    }

    func testBulletsKeepTheirOwnLines() {
        let fragments = [
            line("Shopping list for the weekend:", row: 0),
            line("• apples and some pears", row: 1),
            line("• oat milk", row: 2),
            line("3. bread", row: 3),
        ]
        XCTAssertEqual(engine(.paragraphs).compose(fragments),
                       "Shopping list for the weekend:\n• apples and some pears\n• oat milk\n3. bread")
    }

    func testShortLineEndingASentenceBreaks() {
        let fragments = [
            line("This line runs the full width of the box", row: 0),
            line("and ends early.", row: 1),
            line("Next sentence starts on its own line and", row: 2),
        ]
        XCTAssertEqual(engine(.paragraphs).compose(fragments),
                       "This line runs the full width of the box and ends early.\nNext sentence starts on its own line and")
    }

    func testHeadingStaysSeparate() {
        let fragments = [
            TextFragment("Big Heading", CGRect(x: 0, y: 0, width: 220, height: 40)),
            TextFragment("body text that follows the heading above", CGRect(x: 0, y: 50, width: 400, height: 20)),
        ]
        XCTAssertEqual(engine(.paragraphs).compose(fragments), "Big Heading\nbody text that follows the heading above")
    }

    func testTallerBoxFromDescendersIsNotAHeading() {
        let fragments = [
            line("The left column talks about it", row: 0, height: 14),
            line("capturing a page of grey type", row: 1, height: 22),
        ]
        XCTAssertEqual(engine(.paragraphs).compose(fragments), "The left column talks about it capturing a page of grey type")
    }

    func testHyphenatedWordIsRepairedWhenItIsAWord() {
        let fragments = [line("This is an exam-", row: 0), line("ple of wrapping.", row: 1)]
        XCTAssertEqual(engine(.paragraphs, dictionary: ["example"]).compose(fragments), "This is an example of wrapping.")
    }

    func testRealCompoundKeepsItsHyphen() {
        let fragments = [line("She is very self-", row: 0), line("aware about that.", row: 1)]
        XCTAssertEqual(engine(.paragraphs, dictionary: ["example"]).compose(fragments), "She is very self-aware about that.")
    }

    func testKeepLinesDoesNotTouchHyphens() {
        let fragments = [line("This is an exam-", row: 0), line("ple of wrapping.", row: 1)]
        XCTAssertEqual(engine(.keepLines).compose(fragments), "This is an exam-\nple of wrapping.")
    }

    func testChineseLinesJoinWithoutSpace() {
        let fragments = [line("这是第一行文字内容", row: 0), line("这是第二行文字内容", row: 1)]
        XCTAssertEqual(engine(.singleLine).compose(fragments), "这是第一行文字内容这是第二行文字内容")
    }

    func testSingleLineFlattensEverything() {
        let fragments = [line("alpha beta gamma delta", row: 0), line("• epsilon", row: 1), line("zeta", row: 5)]
        XCTAssertEqual(engine(.singleLine).compose(fragments), "alpha beta gamma delta • epsilon zeta")
    }

    func testTwoColumnsAreReadOneAfterTheOther() {
        var fragments: [TextFragment] = []
        for row in 0..<4 {
            fragments.append(line("left column line number \(row) text", x: 0, row: CGFloat(row)))
            fragments.append(line("right column line number \(row) txt", x: 400, row: CGFloat(row)))
        }
        let text = engine(.keepLines).compose(fragments)
        let blocks = text.components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].contains("left column line number 3"))
        XCTAssertFalse(blocks[0].contains("right"))
        XCTAssertTrue(blocks[1].hasPrefix("right column line number 0"))
    }

    /// A sidebar beside a content pane: line heights are unrelated, as measured on a real window.
    func testSidebarAndContentAreReadOneAfterTheOther() {
        var fragments: [TextFragment] = []
        for (index, name) in ["Account", "Usage", "Appearance", "Capabilities", "Notifications", "Privacy"].enumerated() {
            fragments.append(TextFragment(name, CGRect(x: 0, y: CGFloat(index) * 26, width: CGFloat(name.count) * 10, height: 16)))
        }
        for (index, text) in ["Your usage limits", "Current session resets tonight", "Weekly limits", "Learn more about usage limits"].enumerated() {
            fragments.append(TextFragment(text, CGRect(x: 300, y: 11 + CGFloat(index) * 37, width: CGFloat(text.count) * 10, height: 16)))
        }
        let text = engine(.keepLines).compose(fragments)
        XCTAssertEqual(text, "Account\nUsage\nAppearance\nCapabilities\nNotifications\nPrivacy\n\nYour usage limits\nCurrent session resets tonight\nWeekly limits\nLearn more about usage limits")
    }

    func testLabelsAndValuesOnTheSameRowsStayTogether() {
        var fragments: [TextFragment] = []
        for (index, pair) in [("Name", "TextGrabber"), ("Version", "0.2.2"), ("Licence", "Personal"), ("Size", "4 MB")].enumerated() {
            fragments.append(line(pair.0, x: 0, row: CGFloat(index)))
            fragments.append(line(pair.1, x: 400, row: CGFloat(index)))
        }
        XCTAssertEqual(engine(.paragraphs).compose(fragments), "Name\tTextGrabber\nVersion\t0.2.2\nLicence\tPersonal\nSize\t4 MB")
    }

    func testOneWideGapOnASingleRowDoesNotSplit() {
        let fragments = [line("Inbox", x: 0, row: 0), line("12:30", x: 500, row: 0), line("Lunch on Friday?", x: 0, row: 1)]
        XCTAssertEqual(engine(.keepLines).compose(fragments), "Inbox 12:30\nLunch on Friday?")
    }

    func testTableBecomesTabSeparated() {
        let fragments = [
            line("Name", x: 0, row: 0), line("Qty", x: 200, row: 0), line("Price", x: 320, row: 0),
            line("Apple", x: 0, row: 1), line("3", x: 200, row: 1), line("1.20", x: 320, row: 1),
            line("Pear", x: 0, row: 2), line("12", x: 200, row: 2), line("0.80", x: 320, row: 2),
        ]
        XCTAssertEqual(engine(.paragraphs).compose(fragments), "Name\tQty\tPrice\nApple\t3\t1.20\nPear\t12\t0.80")
    }

    func testTableKeepsEmptyCellsInPlace() {
        let fragments = [
            line("Name", x: 0, row: 0), line("Qty", x: 200, row: 0), line("Price", x: 320, row: 0),
            line("Apple", x: 0, row: 1), line("1.20", x: 320, row: 1),
            line("Pear", x: 0, row: 2), line("12", x: 200, row: 2), line("0.80", x: 320, row: 2),
        ]
        XCTAssertEqual(engine(.paragraphs).compose(fragments), "Name\tQty\tPrice\nApple\t\t1.20\nPear\t12\t0.80")
    }

    func testEmptyAndWhitespaceInput() {
        XCTAssertEqual(engine(.paragraphs).compose([]), "")
        XCTAssertEqual(engine(.paragraphs).compose([line("   ", row: 0)]), "")
    }

    func testVisionBoxIsFlipped() {
        let top = TextFragment(text: "top", visionBox: CGRect(x: 0, y: 0.8, width: 0.3, height: 0.1))
        let bottom = TextFragment(text: "bottom", visionBox: CGRect(x: 0, y: 0.1, width: 0.6, height: 0.1))
        XCTAssertLessThan(top.box.minY, bottom.box.minY)
    }

    func testCustomWordsKeepPhrases() {
        XCTAssertEqual(RecognitionOptions.parseCustomWords("Acme Cloud, kubectl ,, \n Fabric"), ["Acme Cloud", "kubectl", "Fabric"])
    }

    func testLinksAreFoundInOrder() {
        let urls = Links.find(in: "see https://example.com/a and www.example.org today")
        XCTAssertEqual(urls.map(\.host), ["example.com", "www.example.org"])
    }
}
