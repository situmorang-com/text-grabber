import XCTest
import AppKit
@testable import TextGrabberCore

/// A selection dragged across a word leaves a cut stroke at its edge. Drawn at 1x, like a 4K screen at native size.
final class EdgeSliversTests: XCTestCase {
    private var font = NSFont.systemFont(ofSize: 12)

    /// "added +62 812-555-0199." in white and green on a dark chat background. With `cutIntoD`, the selection
    /// starts that many points before the end of "added", so only a stroke of its last "d" is inside.
    private func chatLine(cutIntoD cut: CGFloat?) -> CGImage {
        let lead = NSAttributedString(string: "added", attributes: [.font: font])
        let width = 220, height = 28
        let start = cut.map { -lead.size().width + $0 } ?? 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let line = NSMutableAttributedString(string: "added ", attributes: [.font: font, .foregroundColor: NSColor.white])
        line.append(NSAttributedString(string: "+62 812-555-0199", attributes: [
            .font: font, .foregroundColor: NSColor(srgbRed: 0.33, green: 0.8, blue: 0.5, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue]))
        line.append(NSAttributedString(string: ".", attributes: [.font: font, .foregroundColor: NSColor.white]))
        line.draw(at: NSPoint(x: start, y: 8))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    func testACutStrokeAtTheEdgeIsRemoved() throws {
        // Without the trim this read "1+62 812-555-0199." (macOS 27.3).
        let cut = chatLine(cutIntoD: 4)
        XCTAssertEqual(ImagePrep.removingEdgeSlivers(cut).removed, 1)
        let text = try Recognizer.readFragments(in: cut).fragments.map(\.text).joined(separator: " ")
        XCTAssertEqual(text, "+62 812-555-0199.")
    }

    func testMadeUpAccentedLettersAfterTheLastDigitAreReadAgain() throws {
        // At 13 pt this line read "+62 812-555-0199Řšź" (macOS 27.3, 3x enlargement).
        font = NSFont.systemFont(ofSize: 13)
        let text = try Recognizer.readFragments(in: chatLine(cutIntoD: 2.5)).fragments.map(\.text).joined(separator: " ")
        XCTAssertEqual(text, "+62 812-555-0199.")
    }

    func testGarbledTailIsOnlyAccentsAfterADigit() {
        func tail(_ text: String) -> String? { Recognizer.garbledTail(text).map { String(text[$0]) } }
        XCTAssertEqual(tail("+62 856-2037-425Ś"), "Ś")
        XCTAssertEqual(tail("+62 812-555-0199Řšź"), "Řšź")
        XCTAssertNil(tail("+62 812-555-0199."))
        XCTAssertNil(tail("Zürich 8001 Zürich"))   // a language with accents keeps them
        XCTAssertNil(tail("Café 2é"))
        XCTAssertNil(tail("Room 12B"))
        XCTAssertNil(tail("1Éabcde"))
    }

    func testWholeLettersAreKept() {
        XCTAssertEqual(ImagePrep.removingEdgeSlivers(chatLine(cutIntoD: nil)).removed, 0)
    }
}
