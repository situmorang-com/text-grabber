import XCTest
import CoreGraphics
@testable import TextGrabberCore

final class CodeTriageTests: XCTestCase {
    /// Words the tests treat as non-words: pieces of words cut by a selection.
    private let triage = CodeTriage(isWord: { !["nt", "ter", "gis"].contains($0.lowercased()) })

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 0.3, confidence: Float = 1) -> TextFragment {
        var fragment = TextFragment(text, CGRect(x: x, y: y, width: width, height: 0.05))
        fragment.confidence = confidence
        return fragment
    }

    private let qr = FoundCode(payload: "https://example.com/menu?table=12", box: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.6))

    func testNoCodeLeavesTheTextAlone() {
        let decision = triage.decide(fragments: [line("Hello there", 0.1, 0.1)], codes: [])
        XCTAssertEqual(decision.choice, .textOnly)
        XCTAssertEqual(CodeTriage.clipboard(text: "Hello there", decision: decision), "Hello there")
    }

    func testTextReadInsideTheCodeIsDropped() {
        let decision = triage.decide(fragments: [line("+口", 0.25, 0.2, width: 0.1, confidence: 0.3), line("Scan me", 0.35, 0.8)], codes: [qr])
        XCTAssertEqual(decision.fragments.map(\.text), ["Scan me"])
        XCTAssertEqual(decision.choice, .codesOnly)
        XCTAssertEqual(CodeTriage.clipboard(text: "Scan me", decision: decision), qr.payload)
    }

    func testLinesCutByTheSelectionDoNotCount() {
        let fragments = [
            line("nt the compost bins and share lunch", 0, 0.75, width: 0.5),
            line("lunch at noon with everyone who came ter", 0.5, 0.85, width: 0.5),
            line("Scan to register", 0.3, 0.92),
        ]
        let decision = triage.decide(fragments: fragments, codes: [qr])
        XCTAssertEqual(decision.choice, .codesOnly, decision.report)
    }

    /// A tight selection around real text touches the edge too; whole words there are wanted text.
    func testATightSelectionAroundRealTextIsNotCut() {
        let fragments = [
            line("Bring your own gloves and a water bottle", 0, 0.75, width: 1),
            line("We will plant the herb beds at noon", 0, 0.82, width: 1),
        ]
        let decision = triage.decide(fragments: fragments, codes: [FoundCode(payload: "https://example.org/r", box: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.3))])
        XCTAssertEqual(decision.choice, .textAndCodes, decision.report)
    }

    func testTextThatRepeatsTheCodeDoesNotCount() {
        let decision = triage.decide(fragments: [line("example.com/menu", 0.3, 0.8)], codes: [qr])
        XCTAssertEqual(decision.wantedWords, 0)
        XCTAssertEqual(decision.choice, .codesOnly)
    }

    func testAPageWithACodeKeepsBothAndAddsTheCodeLast() {
        let fragments = [line("Community Garden Open Day", 0.05, 0.05), line("Bring your own gloves and a water bottle.", 0.05, 0.15)]
        let code = FoundCode(payload: "https://example.org/garden", box: CGRect(x: 0.7, y: 0.3, width: 0.2, height: 0.4))
        let decision = triage.decide(fragments: fragments, codes: [code])
        XCTAssertEqual(decision.choice, .textAndCodes)
        let text = "Community Garden Open Day\n\nBring your own gloves and a water bottle."
        XCTAssertEqual(CodeTriage.clipboard(text: text, decision: decision), text + "\n\nhttps://example.org/garden")
    }

    func testACodeAlreadyPrintedInTheTextIsNotAddedTwice() {
        let code = FoundCode(payload: "https://example.org/garden", box: CGRect(x: 0.7, y: 0.3, width: 0.2, height: 0.4))
        let fragments = [line("Register for the open day at example.org/garden before Friday please", 0.05, 0.05)]
        let decision = triage.decide(fragments: fragments, codes: [code])
        XCTAssertEqual(decision.choice, .textAndCodes)
        let text = "Register for the open day at https://example.org/garden before Friday please"
        XCTAssertEqual(CodeTriage.clipboard(text: text, decision: decision), text)
    }

    func testLinksAreRecognised() {
        XCTAssertEqual(qr.link?.host, "example.com")
        XCTAssertNil(FoundCode(payload: "WIFI:T:WPA;S:Guest;P:x;;", box: .zero).link)
        XCTAssertNil(FoundCode(payload: "4006381333931", box: .zero).link)
    }

    /// Real recognition on every capture in Fixtures/codes, compared with the clipboard text beside it.
    func testEveryCodeCaptureGivesItsExpectedClipboard() throws {
        let folder = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/codes", isDirectory: true)
        let images = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(images.count, 9)
        var options = RecognitionOptions()
        options.readCodes = true
        let triage = CodeTriage(isWord: Dictionary.isWholeWord)
        for image in images {
            let expected = try String(contentsOf: image.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            let result = try Recognizer.readFragments(in: XCTUnwrap(Recognizer.loadImages(from: image).first), options: options)
            let decision = triage.decide(fragments: result.fragments, codes: result.codes)
            let text = Recognizer.compose(decision.fragments, structure: result.structure, options: options).render()
            XCTAssertEqual(CodeTriage.clipboard(text: text, decision: decision), expected.trimmingCharacters(in: .whitespacesAndNewlines),
                           "\(image.lastPathComponent)\n\(decision.report)")
        }
    }
}
