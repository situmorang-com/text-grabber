import XCTest
@testable import TextGrabberCore

final class ExactTextTests: XCTestCase {
    /// Every line may look in every source.
    private func refine(_ lines: [String], _ sources: [String]) -> ExactText.Outcome {
        ExactText.refine(lines: lines, candidates: lines.map { _ in Array(sources.indices) }, sources: sources)
    }

    // The OCR strings below are what Apple's Vision actually returned for these lines.

    func testKeySymbolsAreRestored() {
        let outcome = refine(["1. Press 921. macOS will ask for permission."],
                             ["Try it\n1. Press ⌘⇧1. macOS will ask for permission.\n2. Grant it."])
        XCTAssertEqual(outcome.lines, ["1. Press ⌘⇧1. macOS will ask for permission."])
        XCTAssertEqual(outcome.replaced, 1)
    }

    func testEmojiAreRestoredIncludingTheOneAtTheEnd() {
        let outcome = refine(["Great job de see you at 5 → room B V"],
                             ["Great job 👍 see you 🎉 at 5 → room B ✅"])
        XCTAssertEqual(outcome.lines, ["Great job 👍 see you 🎉 at 5 → room B ✅"])
    }

    func testEmojiThatOCRDroppedCompletelyAtBothEnds() {
        let outcome = refine(["Party at my place tonight"], ["🎉 Party at my place tonight 🥳 bring snacks"])
        XCTAssertEqual(outcome.lines, ["🎉 Party at my place tonight 🥳"])
    }

    func testAnEmojiBetweenTwoLinesGoesToOnlyOneOfThem() {
        let outcome = refine(["We shipped the release", "and everyone is happy"],
                             ["We shipped the release 🚀 and everyone is happy"])
        XCTAssertEqual(outcome.lines.joined(separator: " "), "We shipped the release 🚀 and everyone is happy")
    }

    func testCorrectLinesAreLeftAlone() {
        let outcome = refine(["Price: €25 • 30°C • ©2026"], ["Header\nPrice: €25 • 30°C • ©2026\nFooter"])
        XCTAssertEqual(outcome.lines, ["Price: €25 • 30°C • ©2026"])
        XCTAssertEqual(outcome.replaced, 0)
    }

    func testSpacingOnlyDifferencesKeepTheOCRText() {
        // Labels joined without spaces by the source must not glue the words together.
        let outcome = refine(["File Edit View"], ["FileEditView"])
        XCTAssertEqual(outcome.lines, ["File Edit View"])
        XCTAssertEqual(outcome.replaced, 0)
    }

    func testUnrelatedSourceIsIgnored() {
        let outcome = refine(["Completely different sentence here"], ["Nothing in this window looks like that line at all."])
        XCTAssertEqual(outcome.lines, ["Completely different sentence here"])
        XCTAssertEqual(outcome.replaced, 0)
    }

    func testMisreadLettersAreCorrectedFromTheSource() {
        let outcome = refine(["lnvoice INV-2O418 is due"], ["Invoice INV-20418 is due on Monday"])
        XCTAssertEqual(outcome.lines, ["Invoice INV-20418 is due"])
    }

    func testOnlyThePartOfALongParagraphThatWasCapturedIsUsed() {
        let paragraph = "Before the line. The meeting moved to 3pm 🕒 in the big room. After the line."
        let outcome = refine(["The meeting moved to 3pm in the big room."], [paragraph])
        XCTAssertEqual(outcome.lines, ["The meeting moved to 3pm 🕒 in the big room."])
    }

    func testLinesOnlyUseTheirOwnCandidates() {
        let outcome = ExactText.refine(lines: ["Great job de"], candidates: [[1]],
                                       sources: ["Great job 👍", "Something else entirely"])
        XCTAssertEqual(outcome.lines, ["Great job de"])
    }

    func testVeryShortLinesAndEmptyInputAreUntouched() {
        XCTAssertEqual(refine(["OK"], ["OK ✅"]).lines, ["OK"])
        XCTAssertEqual(refine([], ["anything"]).lines, [])
        XCTAssertEqual(refine(["Some text here"], []).lines, ["Some text here"])
    }

    func testTypographicQuotesMatchStraightOnes() {
        let outcome = refine(["She said \"don't\" and left de"], ["She said “don’t” and left 👋"])
        XCTAssertEqual(outcome.lines, ["She said “don’t” and left 👋"])
    }
}
