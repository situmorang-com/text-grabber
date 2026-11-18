import XCTest
@testable import TextGrabberCore

final class TextPiecesTests: XCTestCase {
    func testTableCellsAndLinesAreTranslatedSeparatelyAndPutBack() {
        let pieces = TextPieces("Plan\tPrice\n\nBasic\t\tFree\nLast line")
        XCTAssertEqual(pieces.pieces, ["Plan", "Price", "Basic", "Free", "Last line"])
        XCTAssertEqual(pieces.reassemble(["Rencana", "Harga", "Dasar", "Gratis", "Baris terakhir"]),
                       "Rencana\tHarga\n\nDasar\t\tGratis\nBaris terakhir")
    }

    func testAMissingTranslationKeepsTheOriginal() {
        XCTAssertEqual(TextPieces("One\nTwo").reassemble(["Satu", nil]), "Satu\nTwo")
    }

    func testRewritesAreTellableFromCorrections() {
        let read = "Settings let vou choose the language and the format of the copica texa"
        XCTAssertGreaterThan(TextPieces.wordOverlap(read, "Settings let you choose the language and the format of the copied text"), 0.7)
        XCTAssertLessThan(TextPieces.wordOverlap(read, "You can pick a language and an output format in the preferences."), 0.7)
    }

    func testChunksBreakAtBlankLines() {
        let text = String(repeating: "a", count: 900) + "\n\n" + String(repeating: "b", count: 900) + "\n\nshort"
        let chunks = TextPieces.chunks(text, limit: 1500)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
    }
}
