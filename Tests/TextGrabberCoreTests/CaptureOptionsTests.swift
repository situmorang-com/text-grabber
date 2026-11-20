import XCTest
@testable import TextGrabberCore

final class CaptureOptionsTests: XCTestCase {
    // MARK: Adding to the clipboard

    func testAddedTextContinuesTheSameLine() {
        XCTAssertEqual(AdditiveText.append("second part", to: "First part", newLine: false), "First part second part")
    }

    func testKeepingLineBreaksStartsANewLine() {
        XCTAssertEqual(AdditiveText.append("second part", to: "First part", newLine: true), "First part\nsecond part")
    }

    func testTrailingBreaksOfTheClipboardAreNotDoubled() {
        XCTAssertEqual(AdditiveText.append("more", to: "Earlier text\n\n", newLine: false), "Earlier text more")
        XCTAssertEqual(AdditiveText.append("more", to: "Earlier text\n", newLine: true), "Earlier text\nmore")
        XCTAssertEqual(AdditiveText.append("  more", to: "Earlier text ", newLine: false), "Earlier text more")
    }

    func testAWordHyphenatedAcrossTwoCapturesIsRepaired() {
        let words: Set<String> = ["continuous"]
        let isWord = { (word: String) in words.contains(word.lowercased()) }
        XCTAssertEqual(AdditiveText.append("ous text", to: "a continu-", newLine: false, isWord: isWord), "a continuous text")
        // A real compound keeps its hyphen, with no space added.
        XCTAssertEqual(AdditiveText.append("known", to: "well-", newLine: false, isWord: isWord), "well-known")
    }

    func testNoSpaceBetweenJapaneseOrChineseCharacters() {
        XCTAssertEqual(AdditiveText.append("文字", to: "日本語の", newLine: false), "日本語の文字")
    }

    func testTableRowsAreNotRunTogether() {
        XCTAssertEqual(AdditiveText.append("Next line", to: "Name\tPrice\nTea\t3", newLine: false), "Name\tPrice\nTea\t3\nNext line")
        XCTAssertEqual(AdditiveText.append("Name\tPrice", to: "Intro", newLine: false), "Intro\nName\tPrice")
        // After a Markdown table, a blank line: a line right below one would be read as another row.
        XCTAssertEqual(AdditiveText.append("after", to: "| Name | Price |\n| Tea | 3 |", newLine: false), "| Name | Price |\n| Tea | 3 |\n\nafter")
        // A single pipe in prose is not a table.
        XCTAssertEqual(AdditiveText.append("b", to: "a |", newLine: false), "a | b")
    }

    func testEmptyCellsAtTheEdgeOfATableRowAreKept() {
        // A row whose last cell is empty ends in a tab; one whose first cell is empty starts with one.
        XCTAssertEqual(AdditiveText.append("\tLate\t5", to: "Name\tPrice\t", newLine: false), "Name\tPrice\t\n\tLate\t5")
    }

    func testATableCaptureStartsOnANewLineWhateverItsFormat() {
        // A CSV table looks like prose with commas: the capture says it is a table.
        XCTAssertEqual(AdditiveText.append("Name,Price\nTea,3", to: "Intro", newLine: false, textIsTable: true), "Intro\nName,Price\nTea,3")
    }

    func testACaptureThatStartsWithAListItemStartsANewLine() {
        XCTAssertEqual(AdditiveText.append("• Milk\n• Tea", to: "Shopping list", newLine: false), "Shopping list\n• Milk\n• Tea")
        XCTAssertEqual(AdditiveText.append("1. Plan", to: "Steps", newLine: false), "Steps\n1. Plan")
        XCTAssertEqual(AdditiveText.append("more items", to: "• Milk", newLine: false), "• Milk more items")
    }

    func testAnEmptyClipboardOrCaptureAddsNothingExtra() {
        XCTAssertEqual(AdditiveText.append("Only this", to: "", newLine: false), "Only this")
        XCTAssertEqual(AdditiveText.append("Only this", to: " \n ", newLine: true), "Only this")
        XCTAssertEqual(AdditiveText.append("", to: "Kept as it was\n", newLine: false), "Kept as it was\n")
    }

    func testMultiLineCapturesKeepTheirOwnLines() {
        XCTAssertEqual(AdditiveText.append("one\ntwo", to: "zero", newLine: false), "zero one\ntwo")
        XCTAssertEqual(AdditiveText.append("one\ntwo", to: "zero", newLine: true), "zero\none\ntwo")
    }

    // MARK: Switches

    func testSwitchesStartFromTheSettings() {
        let plain = CaptureSwitches(additive: false, lineMode: .paragraphs, speak: false)
        XCTAssertEqual(plain, CaptureSwitches())
        let keeping = CaptureSwitches(additive: true, lineMode: .keepLines, speak: true)
        XCTAssertEqual(keeping, CaptureSwitches(additive: true, keepLines: true, speak: true))
    }

    func testEachKeySwitchesItsOptionBackAndForth() {
        var switches = CaptureSwitches()
        switches.toggle(.additive)
        switches.toggle(.speak)
        XCTAssertEqual(switches, CaptureSwitches(additive: true, keepLines: false, speak: true))
        switches.toggle(.speak)
        XCTAssertFalse(switches[.speak])
        switches[.keepLines] = true
        XCTAssertTrue(switches.keepLines)
    }

    func testLineModeFollowsTheKeepLineBreaksSwitch() {
        var switches = CaptureSwitches(additive: false, lineMode: .paragraphs, speak: false)
        XCTAssertEqual(switches.lineMode(otherwise: .paragraphs), .paragraphs)
        switches.toggle(.keepLines)
        XCTAssertEqual(switches.lineMode(otherwise: .paragraphs), .keepLines)
        // Keeping lines as the setting, switched off for one capture: smart paragraphs.
        var keeping = CaptureSwitches(additive: false, lineMode: .keepLines, speak: false)
        XCTAssertEqual(keeping.lineMode(otherwise: .keepLines), .keepLines)
        keeping.toggle(.keepLines)
        XCTAssertEqual(keeping.lineMode(otherwise: .keepLines), .paragraphs)
        // A single-line setting stays single line unless line breaks are switched on.
        XCTAssertEqual(CaptureSwitches().lineMode(otherwise: .singleLine), .singleLine)
        XCTAssertEqual(CaptureSwitches(keepLines: true).lineMode(otherwise: .singleLine), .keepLines)
    }
}
