import XCTest
@testable import TextGrabberCore

/// Runs real recognition on every image in Fixtures/captures and compares with the text file beside it.
final class CaptureCorpusTests: XCTestCase {
    private var folder: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/captures", isDirectory: true)
    }

    private var knownGaps: Set<String> {
        let text = (try? String(contentsOf: folder.appendingPathComponent("known-gaps.txt"), encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").compactMap { line in
            let name = line.split(separator: "#", omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        })
    }

    func testEveryCaptureProducesItsExpectedText() throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let images = files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(images.isEmpty, "No captures found in \(folder.path)")

        var checked = 0
        for image in images {
            let name = image.deletingPathExtension().lastPathComponent
            let cgImage = try XCTUnwrap(Recognizer.loadImages(from: image).first)
            for (suffix, mode) in [("txt", LineMode.paragraphs), ("keep.txt", LineMode.keepLines)] {
                let expectedFile = folder.appendingPathComponent("\(name).\(suffix)")
                guard let expected = try? String(contentsOf: expectedFile, encoding: .utf8) else { continue }
                var options = RecognitionOptions()
                options.lineMode = mode
                let actual = try Recognizer.recognizeText(in: cgImage, options: options).text
                checked += 1
                if knownGaps.contains(name) {
                    XCTExpectFailure("\(name) is a known gap") {
                        XCTAssertEqual(actual, expected.trimmingCharacters(in: .whitespacesAndNewlines), "\(name) (\(mode.rawValue))")
                    }
                } else {
                    XCTAssertEqual(actual, expected.trimmingCharacters(in: .whitespacesAndNewlines), "\(name) (\(mode.rawValue))")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "No expected-text files found")
    }

    func testSmallTextNeedsUpscaling() throws {
        let image = try XCTUnwrap(Recognizer.loadImages(from: folder.appendingPathComponent("small.png")).first)
        var options = RecognitionOptions()
        options.upscaleSmallImages = false
        let plain = try Recognizer.recognizeText(in: image, options: options).text
        options.upscaleSmallImages = true
        let upscaled = try Recognizer.recognizeText(in: image, options: options).text
        XCTAssertTrue(upscaled.contains("INV-20418"))
        XCTAssertFalse(plain.contains("INV-20418"), "Vision now reads this without upscaling; the upscale step may no longer earn its cost")
    }
}
