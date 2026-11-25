import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision
import PDFKit
import AppKit

public struct RecognitionOptions {
    /// BCP-47 language put first in Vision's list, e.g. "en-US". `nil` leaves Vision's order.
    public var preferredLanguage: String?
    public var detectsLanguage = true
    /// Words or phrases Vision should favour (product names, jargon).
    public var customWords: [String] = []
    public var lineMode: LineMode = .paragraphs
    /// Enlarge small captures before recognition; helps small text on non-Retina displays.
    public var upscaleSmallImages = true
    public var detectColumns = true
    public var detectTables = true
    /// For experiments: enlarge by exactly this factor instead of deciding from the image size.
    public var forcedScale: CGFloat?
    /// Read uncertain lines a second time from an enlarged crop.
    public var retryUncertainLines = true
    /// Group lines into paragraphs and table cells with Apple's document recognition (macOS 26 and later).
    public var useDocumentStructure = true
    /// Also look for QR codes and barcodes, in parallel with the text (`RecognitionResult.codes`).
    public var readCodes = false
    /// Paint out pieces of letters the selection cut through at its edges (`ImagePrep.removingEdgeSlivers`).
    public var removeEdgeSlivers = true

    public init() {}

    /// "Acme Cloud, kubectl , " → ["Acme Cloud", "kubectl"]
    public static func parseCustomWords(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public struct RecognitionResult {
    public var text: String
    public var fragments: [TextFragment]
    /// "accurate" or "fast": which pass produced the text.
    public var pass: String
    public var upscaled: Bool
    /// Paragraphs and tables, when document recognition was available and found any.
    public var structure: DocumentStructure?
    /// QR codes and barcodes, when `RecognitionOptions.readCodes` was set.
    public var codes: [FoundCode] = []
}

public enum RecognitionError: LocalizedError {
    case unreadableImage
    case unreadablePDF

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The image could not be read."
        case .unreadablePDF: return "The PDF could not be read."
        }
    }
}

public enum Recognizer {

    // MARK: Text

    public static func recognizeText(in image: CGImage, options: RecognitionOptions = .init()) throws -> RecognitionResult {
        var result = try readFragments(in: image, options: options)
        result.text = compose(result.fragments, structure: result.structure, options: options).render()
        return result
    }

    /// Lays fragments out as text. Uses the system spelling dictionary, so call it on the main thread in an app.
    public static func compose(_ fragments: [TextFragment], structure: DocumentStructure? = nil, options: RecognitionOptions) -> StructuredText {
        if let structure, options.useDocumentStructure, !structure.paragraphs.isEmpty || !structure.tables.isEmpty {
            return DocumentLayout(mode: options.lineMode, isWord: Dictionary.isWord).compose(fragments, structure: structure)
        }
        var engine = LayoutEngine(mode: options.lineMode, isWord: Dictionary.isWord)
        engine.detectColumns = options.detectColumns
        engine.detectTables = options.detectTables
        return StructuredText(plain: engine.compose(fragments))
    }

    /// Paragraphs and table cells as Apple's document recognition sees them, or nil where it is not available.
    public static func readStructure(in image: CGImage) -> DocumentStructure? {
        guard #available(macOS 26.0, *) else { return nil }
        let box: (NormalizedRect) -> CGRect = { rect in
            let b = rect.cgRect
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: DocumentStructure?
        Task.detached {
            defer { done.signal() }
            guard let observations = try? await RecognizeDocumentsRequest().perform(on: image, orientation: nil),
                  let document = observations.first?.document else { return }
            let tables = document.tables.map { table in
                DocumentStructure.Table(box: box(table.boundingRegion.boundingBox),
                                        cells: table.rows.map { row in row.map { box($0.content.boundingRegion.boundingBox) } })
            }
            result = DocumentStructure(paragraphs: document.paragraphs.map { box($0.boundingRegion.boundingBox) }, tables: tables)
        }
        // Structure is an improvement, never a requirement: give up rather than hold the capture.
        return done.wait(timeout: .now() + 8) == .success ? result : nil
    }

    /// The Vision part only: safe to run off the main thread. `text` is left empty.
    public static func readFragments(in image: CGImage, options: RecognitionOptions = .init()) throws -> RecognitionResult {
        // Codes are read from the original image while the text is read: about 0.15 s, so it adds no wait.
        final class Found: @unchecked Sendable { var codes: [FoundCode] = [] }   // written once, read after wait()
        let found = Found()
        let codesRead = DispatchGroup()
        if options.readCodes {
            DispatchQueue.global(qos: .userInitiated).async(group: codesRead) {
                found.codes = (try? readCodes(in: image)) ?? []
            }
        }
        // Codes are read from the capture as it is; text from the capture without letters cut at its edges.
        let image = options.removeEdgeSlivers ? ImagePrep.removingEdgeSlivers(image).image : image
        var working = image
        var upscaled = false
        // A small capture is enlarged before the first pass: at its own size, isolated characters go missing.
        var appliedScale = options.forcedScale ?? (options.upscaleSmallImages ? ImagePrep.initialScale(width: image.width, height: image.height) : 1)
        if appliedScale != 1, let scaled = ImagePrep.scaled(image, by: appliedScale) {
            working = scaled
            upscaled = appliedScale > 1
        } else {
            appliedScale = 1
        }

        var pass = "accurate"
        var fragments = try fragmentsOrNil(in: working, level: .accurate, options: options) ?? []

        // Small text reads much better enlarged. What matters is the height of the letters, not the size of
        // the image: on a real 1x window capture with 13 px lines, exact phrases went from 10 of 25 to 18 of 25 at 3x.
        if options.forcedScale == nil, options.upscaleSmallImages,
           let extra = ImagePrep.scaleForSmallText(lineHeights: fragments.map { $0.box.height * CGFloat(working.height) },
                                                   imageWidth: working.width, imageHeight: working.height),
           let larger = ImagePrep.scaled(image, by: appliedScale * extra),
           let again = try? fragmentsOrNil(in: larger, level: .accurate, options: options), !again.isEmpty {
            working = larger
            fragments = again
            upscaled = true
        }
        if fragments.isEmpty {
            // Second chance: the fast model sometimes reads what the accurate one rejects (and survives its failures).
            pass = "fast"
            fragments = (try? fragmentsOrNil(in: working, level: .fast, options: options)) ?? []
        }

        codesRead.wait()
        let codes = found.codes
        if options.retryUncertainLines {
            // What was read inside a code is its squares, not text: not worth a second reading.
            fragments = retryUncertain(fragments, in: working, options: options,
                                       skip: { box in codes.contains { CodeTriage.share(of: box, inside: $0.box) > 0.5 } })
            fragments = retryGarbledTails(fragments, in: working, options: options)
        }
        let structure = options.useDocumentStructure && !fragments.isEmpty ? readStructure(in: working) : nil
        if let structure, !structure.tables.isEmpty {
            fragments += readEmptyCells(fragments, structure: structure, in: working, options: options)
        }
        return RecognitionResult(text: "", fragments: fragments, pass: pass, upscaled: upscaled, structure: structure, codes: codes)
    }

    /// A table cell with nothing read in it, read again on its own. Measured: Vision skipped a lone "5" in a
    /// table (the "2" above it was read), and read the cell alone at every scale from 1x to 4x.
    static func readEmptyCells(_ fragments: [TextFragment], structure: DocumentStructure, in image: CGImage,
                               options: RecognitionOptions) -> [TextFragment] {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var found: [TextFragment] = []
        var budget = 24   // a large, mostly empty grid should not cost seconds
        for cell in structure.tables.flatMap({ $0.cells.flatMap { $0 } }) where budget > 0 {
            // By word: one recognised line can run across two cells ("Basic Free for everyone"), and both are taken.
            let occupied = fragments.contains { fragment in
                (fragment.wordBoxes.isEmpty ? [fragment.box] : fragment.wordBoxes)
                    .contains { cell.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            }
            guard !occupied else { continue }
            budget -= 1
            let pixels = CGRect(x: cell.minX * width, y: cell.minY * height, width: cell.width * width, height: cell.height * height)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            guard pixels.width >= 8, pixels.height >= 8, let crop = image.cropping(to: pixels) else { continue }
            var lines = (try? fragmentsOrNil(in: crop, level: .accurate, options: options)) ?? []
            // A lone digit ("3" in a Seats column) is skipped by the accurate model at every size, alone or padded;
            // the fast model reads it from the ink alone, cropped tight and enlarged, best without language
            // correction. Which size works varies, so a few are tried.
            if lines.isEmpty, let ink = ImagePrep.inkBounds(crop),
               let tight = crop.cropping(to: ink.insetBy(dx: -3, dy: -3).intersection(CGRect(x: 0, y: 0, width: crop.width, height: crop.height))) {
                for targetHeight in [90.0, 60, 130] where lines.isEmpty {
                    guard let enlarged = ImagePrep.scaled(tight, by: min(max(targetHeight / CGFloat(tight.height), 0.5), 8)) else { continue }
                    let read = ((try? fragmentsOrNil(in: enlarged, level: .fast, options: options, languageCorrection: false)) ?? [])
                        .filter { $0.confidence >= 0.5 }
                    // Back from the tight crop's coordinates to the cell's.
                    lines = read.map { line in
                        var line = line
                        let map = { (box: CGRect) in
                            CGRect(x: (ink.minX - 3 + box.minX * CGFloat(tight.width)) / CGFloat(crop.width),
                                   y: (ink.minY - 3 + box.minY * CGFloat(tight.height)) / CGFloat(crop.height),
                                   width: box.width * CGFloat(tight.width) / CGFloat(crop.width),
                                   height: box.height * CGFloat(tight.height) / CGFloat(crop.height))
                        }
                        line.box = map(line.box)
                        line.wordBoxes = line.wordBoxes.map(map)
                        return line
                    }
                }
            }
            for var line in lines where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                // From the cell's coordinates back to the whole picture's.
                let map = { (box: CGRect) in
                    CGRect(x: (pixels.minX + box.minX * pixels.width) / width, y: (pixels.minY + box.minY * pixels.height) / height,
                           width: box.width * pixels.width / width, height: box.height * pixels.height / height)
                }
                line.box = map(line.box)
                line.wordBoxes = line.wordBoxes.map(map)
                found.append(line)
            }
        }
        return found
    }

    /// Vision marks a line it struggled with (small or faint text, sometimes read upside-down) with low confidence.
    /// Such a line usually reads correctly on its own, enlarged; keep whichever reading Vision trusts more.
    static func retryUncertain(_ fragments: [TextFragment], in image: CGImage, options: RecognitionOptions,
                               skip: (CGRect) -> Bool = { _ in false }) -> [TextFragment] {
        var result = fragments
        var retries = 0
        for index in result.indices where result[index].confidence <= 0.5 && retries < 12 && !skip(result[index].box) {
            retries += 1
            let box = result[index].box
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let pad = box.height * height * 0.35
            let crop = CGRect(x: box.minX * width - pad, y: box.minY * height - pad,
                              width: box.width * width + pad * 2, height: box.height * height + pad * 2)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            guard crop.height >= 4, let cropped = image.cropping(to: crop) else { continue }
            let scale = min(max(96 / crop.height, 2), 6)
            guard let enlarged = ImagePrep.scaled(cropped, by: scale),
                  let lines = try? fragmentsOrNil(in: enlarged, level: .accurate, options: options), !lines.isEmpty else { continue }
            let confidence = lines.map(\.confidence).min() ?? 0
            if confidence > result[index].confidence {
                result[index].text = lines.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
                result[index].confidence = confidence
                result[index].wordBoxes = []
            }
        }
        return result
    }

    /// Small underlined text (a phone number in a chat) sometimes comes back with made-up accented letters after
    /// its last digit, with full confidence: "+62 812-555-0199Řšź" for "+62 812-555-0199.", "…-425Ś" for "…-425".
    /// The same line read at another size is clean; failing that, the made-up letters are dropped.
    static func retryGarbledTails(_ fragments: [TextFragment], in image: CGImage, options: RecognitionOptions) -> [TextFragment] {
        var result = fragments
        var retries = 0
        for index in result.indices {
            guard let tail = garbledTail(result[index].text), retries < 6 else { continue }
            retries += 1
            let kept = String(result[index].text[..<tail.lowerBound])
            let box = result[index].box
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let pad = box.height * height * 0.35
            let crop = CGRect(x: box.minX * width - pad, y: box.minY * height - pad,
                              width: box.width * width + pad * 2, height: box.height * height + pad * 2)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            var replacement = kept
            if crop.height >= 4, let cropped = image.cropping(to: crop) {
                for scale: CGFloat in [1, 1.5, 0.75] {
                    guard let sized = scale == 1 ? cropped : ImagePrep.scaled(cropped, by: scale),
                          let lines = try? fragmentsOrNil(in: sized, level: .accurate, options: options), !lines.isEmpty else { continue }
                    let text = lines.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
                    // Only a reading of the same words, now without the made-up ending.
                    if garbledTail(text) == nil, text.hasPrefix(kept), text.count <= kept.count + 2 { replacement = text; break }
                }
            }
            result[index].text = replacement
            result[index].wordBoxes = []
        }
        return result
    }

    /// The made-up ending of a line: one to four accented Latin letters straight after a digit, in a line that
    /// has no other accented letters. Nil when the line has no such ending.
    static func garbledTail(_ text: String) -> Range<String.Index>? {
        func accented(_ character: Character) -> Bool {
            character.isLetter && character.unicodeScalars.allSatisfy { (0xC0...0x24F).contains($0.value) && $0.value != 0xD7 && $0.value != 0xF7 }
        }
        var start = text.endIndex
        var count = 0
        while start > text.startIndex, count < 5 {
            let previous = text.index(before: start)
            guard accented(text[previous]) else { break }
            start = previous
            count += 1
        }
        guard (1...4).contains(count), start > text.startIndex, text[text.index(before: start)].isNumber,
              !text[..<start].contains(where: accented) else { return nil }
        return start..<text.endIndex
    }

    private static func fragmentsOrNil(in image: CGImage, level: VNRequestTextRecognitionLevel, options: RecognitionOptions,
                                       languageCorrection: Bool = true) throws -> [TextFragment]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = options.detectsLanguage
        request.customWords = options.customWords
        if let preferred = options.preferredLanguage,
           let supported = try? request.supportedRecognitionLanguages() {
            var ordered = supported
            if let index = ordered.firstIndex(of: preferred) {
                ordered.remove(at: index)
                ordered.insert(preferred, at: 0)
                request.recognitionLanguages = ordered
            }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            var fragment = TextFragment(text: best.string, visionBox: observation.boundingBox, confidence: best.confidence)
            // Word positions, so a line that runs across two table cells can be split between them.
            var boxes: [CGRect] = []
            for word in best.string.split(separator: " ", omittingEmptySubsequences: true) {
                guard let box = try? best.boundingBox(for: word.startIndex..<word.endIndex)?.boundingBox else { boxes = []; break }
                boxes.append(CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
            fragment.wordBoxes = boxes
            return fragment
        }
    }

    /// Loads Vision's text models ahead of the first capture. The first recognition in a new process
    /// identity can take close to a minute while macOS compiles them; later ones take a fraction of a second.
    public static func warmUp() {
        let size = NSSize(width: 240, height: 60)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 120, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Warm up 123" as NSString).draw(at: NSPoint(x: 12, y: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return }
        var options = RecognitionOptions()
        options.upscaleSmallImages = false
        // Also loads the document-structure model, which takes the same long first run.
        _ = try? readFragments(in: image, options: options)
    }

    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }

    // MARK: Barcodes

    /// Payloads of every QR code and barcode, in reading order, without duplicates.
    public static func readBarcodes(in image: CGImage) throws -> [String] {
        try readCodes(in: image).map(\.payload)
    }

    /// Every QR code and barcode with where it is, in reading order, without duplicate payloads.
    public static func readCodes(in image: CGImage) throws -> [FoundCode] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let found = (request.results ?? []).compactMap { observation -> FoundCode? in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            let box = observation.boundingBox   // bottom-left origin
            return FoundCode(payload: payload, box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                             kind: FoundCode.name(of: observation.symbology))
        }
        .sorted { a, b in
            abs(a.box.midY - b.box.midY) > 0.02 ? a.box.midY < b.box.midY : a.box.minX < b.box.minX
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.payload).inserted }
    }

    // MARK: Files

    /// Loads every page of an image or PDF file as images ready for recognition.
    public static func loadImages(from url: URL) throws -> [CGImage] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw RecognitionError.unreadablePDF }
            let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }.compactMap(ImagePrep.render)
            guard !pages.isEmpty else { throw RecognitionError.unreadablePDF }
            return pages
        }
        guard let image = ImagePrep.image(from: try Data(contentsOf: url)) else { throw RecognitionError.unreadableImage }
        return [image]
    }
}

public enum ImagePrep {
    public static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Enlargement applied to a small capture before anything is read.
    public static func initialScale(width: Int, height: Int) -> CGFloat {
        let longest = max(width, height)
        return longest >= 1400 ? 1 : (longest < 500 ? 3 : 2)
    }

    /// How much more to enlarge an image whose text lines turned out short, or nil when it reads fine as it is.
    /// - Parameter lineHeights: height in pixels of each recognised line.
    public static func scaleForSmallText(lineHeights: [CGFloat], imageWidth: Int, imageHeight: Int) -> CGFloat? {
        let longest = CGFloat(max(imageWidth, imageHeight))
        guard longest > 0, !lineHeights.isEmpty else { return nil }
        let sorted = lineHeights.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0, median < 20 else { return nil }
        var scale = min(max((36 / median).rounded(), 2), 4)
        // Keep the enlarged image within what Vision handles comfortably.
        while scale > 1, longest * scale > 12000 { scale -= 1 }
        return scale > 1 ? scale : nil
    }

    public static func scaled(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: nil).createCGImage(output, from: output.extent)
    }

    /// Rasterises a PDF page at 200 dpi on white.
    public static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 200.0 / 72.0
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

public enum Dictionary {
    /// Like `isWord`, but short pieces are checked too: "nt" (from "plant", cut by a selection) is not a word.
    public static func isWholeWord(_ word: String) -> Bool {
        guard word.count > 1 else { return true }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }

    /// True when the system spelling dictionary knows the word.
    public static func isWord(_ word: String) -> Bool {
        guard word.count > 2 else { return true }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}

public enum Links {
    /// Every web or mail link found in the text, in order.
    public static func find(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url)
    }
}
