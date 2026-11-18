import XCTest
import CoreGraphics
@testable import TextGrabberCore

final class DocumentLayoutTests: XCTestCase {
    /// A line at a position on a 1000 × 1000 page, 8 units per character, 20 high.
    private func line(_ text: String, x: CGFloat, y: CGFloat) -> TextFragment {
        TextFragment(text, CGRect(x: x / 1000, y: y / 1000, width: CGFloat(text.count) * 8 / 1000, height: 20.0 / 1000))
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x / 1000, y: y / 1000, width: w / 1000, height: h / 1000)
    }

    private let layout = DocumentLayout(mode: .paragraphs, isWord: { _ in true })

    func testWrappedTableCellsStayInTheirCell() {
        let fragments = [
            line("Plan", x: 10, y: 10), line("Includes", x: 300, y: 10),
            line("Plus", x: 10, y: 50), line("Tables, translation and a", x: 300, y: 50), line("searchable history.", x: 300, y: 74),
            line("Basic", x: 10, y: 110), line("Capture and copy.", x: 300, y: 110),
        ]
        let table = DocumentStructure.Table(box: rect(0, 0, 700, 140), cells: [
            [rect(0, 0, 290, 40), rect(290, 0, 410, 40)],
            [rect(0, 40, 290, 60), rect(290, 40, 410, 60)],
            [rect(0, 100, 290, 40), rect(290, 100, 410, 40)],
        ])
        let text = layout.compose(fragments, structure: DocumentStructure(paragraphs: [], tables: [table]))
        XCTAssertEqual(text.render(), "Plan\tIncludes\nPlus\tTables, translation and a searchable history.\nBasic\tCapture and copy.")
        XCTAssertEqual(text.render(.markdown), "| Plan | Includes |\n| --- | --- |\n| Plus | Tables, translation and a searchable history. |\n| Basic | Capture and copy. |")
    }

    /// Recognition read two neighbouring cells as one line; it is cut at the cell boundary.
    func testALineRunningAcrossTwoCellsIsSplit() {
        var merged = line("Basic Free for everyone", x: 10, y: 50)
        merged.wordBoxes = [rect(10, 50, 40, 20), rect(120, 50, 32, 20), rect(156, 50, 24, 20), rect(184, 50, 64, 20)]
        let fragments = [line("Plan", x: 10, y: 10), line("Price", x: 120, y: 10), merged]
        let table = DocumentStructure.Table(box: rect(0, 0, 300, 80), cells: [
            [rect(0, 0, 110, 40), rect(110, 0, 190, 40)],
            [rect(0, 40, 110, 40), rect(110, 40, 190, 40)],
        ])
        XCTAssertEqual(layout.compose(fragments, structure: DocumentStructure(paragraphs: [], tables: [table])).render(),
                       "Plan\tPrice\nBasic\tFree for everyone")
    }

    func testParagraphLinesAreJoinedAndParagraphsSpaced() {
        let fragments = [
            line("Release notes", x: 10, y: 10),
            line("The first paragraph wraps onto", x: 10, y: 60), line("a second line here.", x: 10, y: 84),
            line("A second paragraph follows.", x: 10, y: 140),
        ]
        let structure = DocumentStructure(paragraphs: [rect(10, 10, 200, 20), rect(10, 60, 300, 44), rect(10, 140, 300, 20)], tables: [])
        XCTAssertEqual(layout.compose(fragments, structure: structure).render(),
                       "Release notes\n\nThe first paragraph wraps onto a second line here.\n\nA second paragraph follows.")
    }

    func testListItemsStayOnTightLines() {
        let fragments = [
            line("Wrapped intro paragraph that goes", x: 10, y: 10), line("onto a second line.", x: 10, y: 34),
            line("• first item", x: 20, y: 70), line("• second item", x: 20, y: 94),
        ]
        let structure = DocumentStructure(paragraphs: [rect(10, 10, 300, 44), rect(20, 70, 200, 20), rect(20, 94, 200, 20)], tables: [])
        XCTAssertEqual(layout.compose(fragments, structure: structure).render(),
                       "Wrapped intro paragraph that goes onto a second line.\n\n• first item\n• second item")
    }

    func testSidebarIsReadBeforeTheContentBesideIt() {
        let fragments = [
            line("Heading", x: 300, y: 10), line("Account", x: 10, y: 20), line("Body text of the page.", x: 300, y: 60),
            line("Usage", x: 10, y: 50), line("Privacy", x: 10, y: 80),
        ]
        let structure = DocumentStructure(paragraphs: fragments.map(\.box), tables: [])
        XCTAssertEqual(layout.compose(fragments, structure: structure).render(.plain).components(separatedBy: "\n").filter { !$0.isEmpty },
                       ["Account", "Usage", "Privacy", "Heading", "Body text of the page."])
    }

    /// From a real capture: Apple made two paragraphs of one line split by an emoji's gap.
    func testOneLineSplitByAWideGapIsNotTwoColumns() {
        let fragments = [line("Press it to capture", x: 10, y: 10), line("Great job", x: 10, y: 40), line("see you at 5", x: 140, y: 40),
                         line("Invoice due on Monday", x: 10, y: 70)]
        let structure = DocumentStructure(paragraphs: fragments.map(\.box), tables: [])
        XCTAssertEqual(layout.compose(fragments, structure: structure).render().components(separatedBy: "\n").filter { !$0.isEmpty },
                       ["Press it to capture", "Great job see you at 5", "Invoice due on Monday"])
    }

    /// From a real capture: two stacked labels, the first ending in an emoji, grouped by Apple as one paragraph.
    func testALineAfterAnEmojiThatStartsWithACapitalIsANewLine() {
        let fragments = [line("Press it to search 🔍", x: 10, y: 10), line("Great job today", x: 10, y: 34)]
        let structure = DocumentStructure(paragraphs: [rect(10, 10, 300, 44)], tables: [])
        XCTAssertEqual(layout.compose(fragments, structure: structure).render(), "Press it to search 🔍\nGreat job today")
    }

    func testWrappedProseStillJoins() {
        let fragments = [line("The quick brown fox jumps over the", x: 10, y: 10), line("Lazy Dog Inn, as the sign says.", x: 10, y: 34)]
        let structure = DocumentStructure(paragraphs: [rect(10, 10, 300, 44)], tables: [])
        XCTAssertEqual(layout.compose(fragments, structure: structure).render(), "The quick brown fox jumps over the Lazy Dog Inn, as the sign says.")
    }

    func testLinesApplePlacedNowhereAreKeptInPosition() {
        let fragments = [line("Top line", x: 10, y: 10), line("Missed by Apple", x: 10, y: 60), line("Bottom line", x: 10, y: 110)]
        let structure = DocumentStructure(paragraphs: [fragments[0].box, fragments[2].box], tables: [])
        XCTAssertEqual(layout.compose(fragments, structure: structure).render().components(separatedBy: "\n").filter { !$0.isEmpty },
                       ["Top line", "Missed by Apple", "Bottom line"])
    }

    func testOneColumnTableIsPlainLines() {
        let fragments = [line("Account", x: 10, y: 10), line("Usage", x: 10, y: 40), line("Privacy", x: 10, y: 70)]
        let table = DocumentStructure.Table(box: rect(0, 0, 200, 100), cells: [[rect(0, 0, 200, 30)], [rect(0, 30, 200, 30)], [rect(0, 60, 200, 40)]])
        XCTAssertEqual(layout.compose(fragments, structure: DocumentStructure(paragraphs: [], tables: [table])).render(), "Account\nUsage\nPrivacy")
    }

    func testCSVQuotesCellsThatNeedIt() {
        let text = StructuredText([.table([["Name", "Note"], ["Ann", "says \"hi\", then leaves"]])])
        XCTAssertEqual(text.render(tables: .csv), "Name,Note\nAnn,\"says \"\"hi\"\", then leaves\"")
    }

    func testPlainTextWithTabsBecomesATable() {
        let text = StructuredText(plain: "Intro line\n\nA\tB\n1\t2\n\nOutro")
        XCTAssertTrue(text.hasTable)
        XCTAssertEqual(text.render(.markdown), "Intro line\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nOutro")
    }
}
