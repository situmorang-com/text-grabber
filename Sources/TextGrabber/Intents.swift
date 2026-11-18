import AppIntents
import AppKit
import Foundation
import TextGrabberCore

/// Shortcuts actions. Their metadata is produced by scripts/build-app.sh (Xcode would do it automatically).

enum IntentLineMode: String, AppEnum {
    case smart, keep, single

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Line Breaks"
    static let caseDisplayRepresentations: [IntentLineMode: DisplayRepresentation] = [
        .smart: "Smart paragraphs",
        .keep: "Keep every line break",
        .single: "Single line",
    ]

    var lineMode: LineMode {
        switch self {
        case .smart: return .paragraphs
        case .keep: return .keepLines
        case .single: return .singleLine
        }
    }
}

enum IntentFormat: String, AppEnum {
    case plain, markdown, csvTables

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Text Format"
    static let caseDisplayRepresentations: [IntentFormat: DisplayRepresentation] = [
        .plain: "Plain text",
        .markdown: "Markdown",
        .csvTables: "Plain text, tables as CSV",
    ]
}

struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text from Screen"
    static let description = IntentDescription("Lets you select an area of the screen and returns the text in it. The text is also copied to the clipboard.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app = NSApp.delegate as? AppDelegate else { throw IntentError.appNotReady }
        guard let text = await app.captureForShortcut(kind: .text(nil)) else { throw IntentError.cancelled }
        return .result(value: text)
    }
}

struct ExtractTextFromImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Text from Image"
    static let description = IntentDescription("Reads the text in images or PDFs, on this Mac. Tables, lists and paragraphs are kept.")

    @Parameter(title: "Images or PDFs", supportedTypeIdentifiers: ["public.image", "com.adobe.pdf"])
    var files: [IntentFile]

    @Parameter(title: "Line Breaks", default: .smart)
    var lineBreaks: IntentLineMode

    @Parameter(title: "Format", default: .plain)
    var format: IntentFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Extract text from \(\.$files)") {
            \.$lineBreaks
            \.$format
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let options = Prefs.recognitionOptions(lineMode: lineBreaks.lineMode)
        var texts: [String] = []
        for file in files {
            let images: [CGImage]
            if let url = file.fileURL {
                images = try Recognizer.loadImages(from: url)
            } else if let image = ImagePrep.image(from: file.data) {
                images = [image]
            } else {
                throw IntentError.unreadable(file.filename)
            }
            for image in images {
                let result = try Recognizer.readFragments(in: image, options: options)
                let structured = await MainActor.run { Recognizer.compose(result.fragments, structure: result.structure, options: options) }
                let text: String
                switch format {
                case .plain: text = structured.render(.plain, tables: .tabs)
                case .markdown: text = structured.render(.markdown)
                case .csvTables: text = structured.render(.plain, tables: .csv)
                }
                if !text.isEmpty { texts.append(text) }
            }
        }
        return .result(value: texts.joined(separator: "\n\n"))
    }
}

struct ReadCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Read QR Code from Screen"
    static let description = IntentDescription("Lets you select an area of the screen and returns what its QR codes or barcodes contain.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let app = NSApp.delegate as? AppDelegate else { throw IntentError.appNotReady }
        guard let text = await app.captureForShortcut(kind: .barcode) else { throw IntentError.cancelled }
        return .result(value: text)
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady, cancelled, unreadable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: return "TextGrabber is not ready yet. Try again in a moment."
        case .cancelled: return "No area was captured."
        case .unreadable(let name): return "\(name) could not be read as an image."
        }
    }
}

struct TextGrabberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureTextIntent(), phrases: ["Capture text with \(.applicationName)", "Grab text with \(.applicationName)"],
                    shortTitle: "Capture Text", systemImageName: "text.viewfinder")
        AppShortcut(intent: ReadCodeIntent(), phrases: ["Read a QR code with \(.applicationName)"],
                    shortTitle: "Read QR Code", systemImageName: "qrcode.viewfinder")
    }
}
