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
        result.text = compose(result.fragments, options: options)
        return result
    }

    /// Lays fragments out as text. Uses the system spelling dictionary, so call it on the main thread in an app.
    public static func compose(_ fragments: [TextFragment], options: RecognitionOptions) -> String {
        var engine = LayoutEngine(mode: options.lineMode, isWord: Dictionary.isWord)
        engine.detectColumns = options.detectColumns
        engine.detectTables = options.detectTables
        return engine.compose(fragments)
    }

    /// The Vision part only: safe to run off the main thread. `text` is left empty.
    public static func readFragments(in image: CGImage, options: RecognitionOptions = .init()) throws -> RecognitionResult {
        var working = image
        var upscaled = false
        if options.upscaleSmallImages, let larger = ImagePrep.upscaledIfSmall(image) {
            working = larger
            upscaled = true
        }

        var pass = "accurate"
        var fragments = try fragmentsOrNil(in: working, level: .accurate, options: options) ?? []
        if fragments.isEmpty {
            // Second chance: the fast model sometimes reads what the accurate one rejects (and survives its failures).
            pass = "fast"
            fragments = (try? fragmentsOrNil(in: working, level: .fast, options: options)) ?? []
        }

        return RecognitionResult(text: "", fragments: fragments, pass: pass, upscaled: upscaled)
    }

    private static func fragmentsOrNil(in image: CGImage, level: VNRequestTextRecognitionLevel, options: RecognitionOptions) throws -> [TextFragment]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
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
            return TextFragment(text: best.string, visionBox: observation.boundingBox)
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
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let found = (request.results ?? [])
            .sorted { a, b in
                // Vision's origin is bottom-left: larger y is higher on screen.
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02
                    ? a.boundingBox.midY > b.boundingBox.midY
                    : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap(\.payloadStringValue)
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
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

    /// Doubles (or triples) captures whose longest side is short, using Lanczos resampling.
    public static func upscaledIfSmall(_ image: CGImage, threshold: Int = 1400) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0, longest < threshold else { return nil }
        let scale: CGFloat = longest < 500 ? 3 : 2
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
