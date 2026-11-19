import XCTest
import CoreGraphics
@testable import TextGrabberCore

final class CaptureHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func picture() -> CGImage {
        let context = CGContext(data: nil, width: 1200, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
        return context.makeImage()!
    }

    func testPinnedEntriesStayFirstAndSurviveTheLimitAndClearing() {
        let history = CaptureHistory(folder: folder)
        history.limit = 3
        history.add("keep me", kind: "text")
        history.setPinned(history.entries[0], true)
        for index in 1...5 { history.add("capture \(index)", kind: "text") }
        XCTAssertEqual(history.entries.map(\.text), ["keep me", "capture 5", "capture 4", "capture 3"])
        history.clearUnpinned()
        XCTAssertEqual(history.entries.map(\.text), ["keep me"])
    }

    func testThumbnailIsSmallAndDeletedWithItsEntry() throws {
        let history = CaptureHistory(folder: folder)
        history.add("with picture", kind: "text", picture: picture())
        let url = try XCTUnwrap(history.thumbnailURL(history.entries[0]))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 480)
        history.remove(history.entries[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCapturingTheSameTextAgainMovesItUpAndKeepsItsPin() {
        let history = CaptureHistory(folder: folder)
        history.add("same", kind: "text")
        history.setPinned(history.entries[0], true)
        history.add("other", kind: "text")
        history.add("same", kind: "text")
        XCTAssertEqual(history.entries.map(\.text), ["same", "other"])
        XCTAssertTrue(history.entries[0].pinned)
    }

    func testHistoryFromAnEarlierVersionStillLoads() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = #"[{"id":"1F2E3D4C-5B6A-4798-8A9B-0C1D2E3F4A5B","date":700000000,"text":"old capture","kind":"text"}]"#
        try Data(old.utf8).write(to: folder.appendingPathComponent("history.json"))
        let history = CaptureHistory(folder: folder)
        XCTAssertEqual(history.entries.map(\.text), ["old capture"])
        XCTAssertFalse(history.entries[0].pinned)
    }

    func testReplacingTheTextKeepsThePictureAndPersists() {
        let history = CaptureHistory(folder: folder)
        history.add("Poster text\n\nhttps://example.org/r", kind: "text", picture: picture())
        history.replaceText("Poster text\n\nhttps://example.org/r", with: "https://example.org/r")
        XCTAssertEqual(history.entries.map(\.text), ["https://example.org/r"])
        XCTAssertNotNil(history.thumbnailURL(history.entries[0]))
        XCTAssertEqual(CaptureHistory(folder: folder).entries.map(\.text), ["https://example.org/r"])
    }
}
