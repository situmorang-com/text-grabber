import Foundation
import Translation
import NaturalLanguage
import TextGrabberCore

enum CommandLineTool {
    static let usage = """
    Usage: TextGrabber [options] <image-or-pdf>...
      --mode keep|paragraphs|single   How lines are joined (default: paragraphs)
      --lang <code>                   Preferred language, e.g. en-US, id-ID, ja-JP
      --words "a, b c"                Custom words, comma-separated
      --barcode                       Read QR codes and barcodes instead of text
      --no-upscale                    Do not enlarge small images first
      --scale <n>                     Enlarge by exactly n before reading (experiments)
      --no-retry                      Do not re-read uncertain lines from an enlarged crop
      --no-structure                  Do not use Apple's document recognition for paragraphs and tables
      --markdown                      Write Markdown (tables as Markdown tables)
      --csv                           Write tables as CSV
      --translate <code>              Translate the result on this Mac, e.g. --translate id
      --clean-up                      Fix recognition mistakes with Apple's on-device model
      --debug                         Print each recognised fragment and its box to stderr
      --languages                     List supported languages
      --ax-at <x,y>                   Print the text the Accessibility API gives at a screen point (diagnostic)
    """

    static func run(_ arguments: [String]) async -> Int32 {
        var options = RecognitionOptions()
        var files: [String] = []
        var barcode = false, debug = false
        var format = StructuredText.Format.plain
        var translateTo: String?
        var cleanUp = false
        var tableStyle = StructuredText.TableStyle.tabs
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--mode":
                switch iterator.next() {
                case "keep": options.lineMode = .keepLines
                case "single": options.lineMode = .singleLine
                case "paragraphs": options.lineMode = .paragraphs
                default: return fail("--mode needs keep, paragraphs or single")
                }
            case "--lang": options.preferredLanguage = iterator.next()
            case "--words": options.customWords = RecognitionOptions.parseCustomWords(iterator.next() ?? "")
            case "--barcode": barcode = true
            case "--no-upscale": options.upscaleSmallImages = false
            case "--scale": options.forcedScale = Double(iterator.next() ?? "").map { CGFloat($0) }
            case "--no-retry": options.retryUncertainLines = false
            case "--no-structure": options.useDocumentStructure = false
            case "--markdown": format = .markdown
            case "--csv": tableStyle = .csv
            case "--translate": translateTo = iterator.next()
            case "--clean-up": cleanUp = true
            case "--debug": debug = true
            case "--ax-at":
                let parts = (iterator.next() ?? "").split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { return fail("--ax-at needs x,y in screen points") }
                guard AccessibilityText.isTrusted else {
                    FileHandle.standardError.write(Data("This terminal has no Accessibility access (System Settings → Privacy & Security → Accessibility).\n".utf8))
                    return 77
                }
                let collector = AccessibilityText.Collector(budget: 2)
                let found = collector.sources(at: CGPoint(x: parts[0], y: parts[1]))
                for index in found { print("[\(index)] \(collector.texts[index].prefix(400))") }
                return found.isEmpty ? 2 : 0
            case "--languages":
                print(Recognizer.supportedLanguages().joined(separator: "\n"))
                return 0
            case "-h", "--help":
                print(usage)
                return 0
            default:
                if argument.hasPrefix("--") { return fail("Unknown option \(argument)") }
                files.append(argument)
            }
        }
        guard !files.isEmpty else { return fail("No input file.") }

        var outputs: [String] = []
        for file in files {
            do {
                for image in try Recognizer.loadImages(from: URL(fileURLWithPath: file)) {
                    if barcode {
                        outputs.append(contentsOf: try Recognizer.readBarcodes(in: image))
                    } else {
                        var result = try Recognizer.readFragments(in: image, options: options)
                        result.text = Recognizer.compose(result.fragments, structure: result.structure, options: options)
                            .render(format, tables: tableStyle)
                        if debug {
                            FileHandle.standardError.write(Data("pass=\(result.pass) upscaled=\(result.upscaled) fragments=\(result.fragments.count) structure=\(result.structure.map { "\($0.paragraphs.count) paragraphs, \($0.tables.count) tables" } ?? "none")\n".utf8))
                            if let structure = result.structure {
                                for p in structure.paragraphs { FileHandle.standardError.write(Data(String(format: "  paragraph [%.3f %.3f %.3f %.3f]\n", p.minX, p.minY, p.width, p.height).utf8)) }
                                for t in structure.tables { FileHandle.standardError.write(Data(String(format: "  table [%.3f %.3f %.3f %.3f] %d rows\n", t.box.minX, t.box.minY, t.box.width, t.box.height, t.cells.count).utf8)) }
                            }
                            for fragment in result.fragments {
                                let box = fragment.box
                                FileHandle.standardError.write(Data(String(format: "  [%.3f %.3f %.3f %.3f] conf %.2f  %@\n", box.minX, box.minY, box.width, box.height, fragment.confidence, fragment.text).utf8))
                            }
                        }
                        if !result.text.isEmpty { outputs.append(result.text) }
                    }
                }
            } catch {
                return fail("\(file): \(error.localizedDescription)")
            }
        }
        var text = outputs.joined(separator: "\n\n")
        if cleanUp {
            guard #available(macOS 26.0, *) else { return fail("--clean-up needs macOS 26") }
            do { text = try await TextCleaner.clean(text) } catch {
                FileHandle.standardError.write(Data("Clean-up failed: \(error.localizedDescription)\n".utf8))
            }
        }
        if let translateTo {
            guard #available(macOS 26.0, *) else { return fail("--translate needs macOS 26") }
            let source = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
            if debug { FileHandle.standardError.write(Data("translating from \(source)\n".utf8)) }
            let translated: String
            let input = text
            do {
                // Translation sessions work only from the main actor (measured: elsewhere they fail as "not installed").
                translated = try await Task { @MainActor in
                    let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: translateTo))
                    return try await Translator.translate(input, with: session)
                }.value
            } catch {
                return fail("Translation failed (\(error.localizedDescription)). Is that language pair downloaded? System Settings → General → Language & Region → Translation Languages.")
            }
            text = translated
        }
        print(text)
        return outputs.isEmpty ? 2 : 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
        return 64
    }
}
