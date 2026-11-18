import Foundation
import TextGrabberCore

enum CommandLineTool {
    static let usage = """
    Usage: TextGrabber [options] <image-or-pdf>...
      --mode keep|paragraphs|single   How lines are joined (default: paragraphs)
      --lang <code>                   Preferred language, e.g. en-US, id-ID, ja-JP
      --words "a, b c"                Custom words, comma-separated
      --barcode                       Read QR codes and barcodes instead of text
      --no-upscale                    Do not enlarge small images first
      --debug                         Print each recognised fragment and its box to stderr
      --languages                     List supported languages
      --ax-at <x,y>                   Print the text the Accessibility API gives at a screen point (diagnostic)
    """

    static func run(_ arguments: [String]) -> Int32 {
        var options = RecognitionOptions()
        var files: [String] = []
        var barcode = false, debug = false
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
                        let result = try Recognizer.recognizeText(in: image, options: options)
                        if debug {
                            FileHandle.standardError.write(Data("pass=\(result.pass) upscaled=\(result.upscaled) fragments=\(result.fragments.count)\n".utf8))
                            for fragment in result.fragments {
                                let box = fragment.box
                                FileHandle.standardError.write(Data(String(format: "  [%.3f %.3f %.3f %.3f] %@\n", box.minX, box.minY, box.width, box.height, fragment.text).utf8))
                            }
                        }
                        if !result.text.isEmpty { outputs.append(result.text) }
                    }
                }
            } catch {
                return fail("\(file): \(error.localizedDescription)")
            }
        }
        print(outputs.joined(separator: "\n\n"))
        return outputs.isEmpty ? 2 : 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
        return 64
    }
}
