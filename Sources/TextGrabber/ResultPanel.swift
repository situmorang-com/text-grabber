import AppKit
import SwiftUI
import NaturalLanguage
import Translation
import FoundationModels
import TextGrabberCore

/// Everything needed to lay a capture out again in another mode or format.
struct CaptureResult {
    var pages: [[TextFragment]]
    var structures: [DocumentStructure?]
    var options: RecognitionOptions
    var kind: ResultKind
    /// Set when the result is not from recognition (a barcode, or text from history): it cannot be laid out again.
    var fixedText: String?
    /// Added after the text whatever the layout: the content of QR codes and barcodes found beside it.
    var appendix: String?

    static func fixed(_ text: String, kind: ResultKind) -> CaptureResult {
        CaptureResult(pages: [], structures: [], options: RecognitionOptions(), kind: kind, fixedText: text)
    }

    func structured(lineMode: LineMode) -> StructuredText {
        if let fixedText { return StructuredText(plain: fixedText) }
        var options = options
        options.lineMode = lineMode
        var blocks = zip(pages, structures).flatMap { page, structure in
            Recognizer.compose(page, structure: structure, options: options).blocks
        }
        if let appendix, !appendix.isEmpty { blocks.append(.text(appendix, spaced: true)) }
        return StructuredText(blocks)
    }
}

/// Settings for how text goes onto the clipboard, shared by the quick path and the panel.
enum OutputFormat {
    static var format: StructuredText.Format {
        StructuredText.Format(rawValue: Prefs.defaults.string(forKey: Prefs.Key.outputFormat) ?? "") ?? .plain
    }
    static var tableStyle: StructuredText.TableStyle {
        StructuredText.TableStyle(rawValue: Prefs.defaults.string(forKey: Prefs.Key.tableStyle) ?? "") ?? .tabs
    }
}

// MARK: - Window

/// Called on the main thread only (from menu actions and delivery).
final class ResultPanelController {
    private var panel: NSPanel?
    private var model: ResultPanelModel?
    private var opened = false
    private let output: ResultHandler

    init(output: ResultHandler) {
        self.output = output
    }

    func show(_ result: CaptureResult) {
        MainActor.assumeIsolated { present(result) }
    }

    @MainActor
    private func present(_ result: CaptureResult) {
        let model = ResultPanelModel(result: result, output: output) { [weak self] in self?.close() }
        self.model = model
        let host = NSHostingController(rootView: ResultPanelView(model: model))
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                                styleMask: [.titled, .closable, .resizable],
                                backing: .buffered, defer: false)
            panel.title = "Captured Text"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        guard let panel else { return }
        let frame = panel.frame
        panel.contentViewController = host
        panel.minSize = NSSize(width: 520, height: 320)
        // Keep the size and place the user chose last time; a SwiftUI host would otherwise shrink it to its minimum.
        if !opened, !panel.setFrameUsingName("TextGrabberResultPanel") {
            panel.setContentSize(NSSize(width: 680, height: 460))
            panel.center()
        } else if opened {
            panel.setFrame(frame, display: false)
        }
        panel.setFrameAutosaveName("TextGrabberResultPanel")
        opened = true
        if WindowSnapshot.isTaking { panel.orderFrontRegardless(); return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }
}

// MARK: - Model

@MainActor
final class ResultPanelModel: ObservableObject {
    @Published var text: String
    @Published var lineMode: LineMode { didSet { relayout() } }
    @Published var format: StructuredText.Format { didSet { relayout() } }
    @Published var tableStyle: StructuredText.TableStyle { didSet { relayout() } }
    @Published var edited = false
    @Published var busy: String?
    @Published var note: String?
    @Published var translationTarget: String
    @Published var translation: AnyObject?   // TranslationSession.Configuration, boxed for older macOS

    let result: CaptureResult
    let hasTable: Bool
    private let output: ResultHandler
    private let close: () -> Void
    private var settingText = false

    init(result: CaptureResult, output: ResultHandler, close: @escaping () -> Void) {
        self.result = result
        self.output = output
        self.close = close
        lineMode = result.options.lineMode
        format = OutputFormat.format
        tableStyle = OutputFormat.tableStyle
        translationTarget = Prefs.defaults.string(forKey: Prefs.Key.translationTarget)
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        let structured = result.structured(lineMode: result.options.lineMode)
        hasTable = structured.hasTable
        text = structured.render(OutputFormat.format, tables: OutputFormat.tableStyle)
    }

    var canRelayout: Bool { result.fixedText == nil }

    func relayout() {
        guard canRelayout else { return }
        settingText = true
        text = result.structured(lineMode: lineMode).render(format, tables: tableStyle)
        settingText = false
        edited = false
        note = nil
    }

    func textChanged() {
        if !settingText { edited = true }
    }

    func copy(andClose: Bool) {
        output.write(text)
        output.notify(symbol: "doc.on.clipboard", title: "Copied")
        if andClose { close() }
    }

    func speak() {
        output.speak(text)
    }

    // MARK: Clean up

    var canCleanUp: Bool {
        guard #available(macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func cleanUp() {
        guard #available(macOS 26.0, *), busy == nil else { return }
        let original = text
        busy = "Cleaning up…"
        Task {
            do {
                let cleaned = try await TextCleaner.clean(original)
                self.settingText = true
                self.text = cleaned
                self.settingText = false
                self.edited = true
                self.note = "Cleaned up on this Mac. Check it before you use it: the model can change meaning."
            } catch {
                self.note = "Clean-up failed: \(error.localizedDescription)"
            }
            self.busy = nil
        }
    }

    // MARK: Translate

    func translate() {
        guard #available(macOS 15.0, *), busy == nil else { return }
        Prefs.defaults.set(translationTarget, forKey: Prefs.Key.translationTarget)
        busy = "Translating…"
        // Setting a new configuration starts the translation task attached to the view.
        let configuration = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: translationTarget))
        translation = ConfigurationBox(configuration)
    }

    @available(macOS 15.0, *)
    func runTranslation(_ session: TranslationSession) async {
        do {
            text = try await Translator.translate(text, with: session)
            edited = true
            note = "Translated on this Mac."
        } catch {
            note = "Translation failed: \(error.localizedDescription)"
        }
        busy = nil
        translation = nil
    }
}

final class ConfigurationBox: NSObject {
    let value: Any
    init(_ value: Any) { self.value = value }
}

// MARK: - Language work

@available(macOS 15.0, *)
enum Translator {
    /// Translates line by line and cell by cell, so line breaks and table columns survive.
    static func translate(_ text: String, with session: TranslationSession) async throws -> String {
        let pieces = TextPieces(text)
        guard !pieces.pieces.isEmpty else { return text }
        let requests = pieces.pieces.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var translated = [String?](repeating: nil, count: requests.count)
        for response in try await session.translations(from: requests) {
            if let id = response.clientIdentifier.flatMap(Int.init), id < translated.count { translated[id] = response.targetText }
        }
        return pieces.reassemble(translated)
    }
}

@available(macOS 26.0, *)
enum TextCleaner {
    static let instructions = """
    You correct text that was read from a screen by text recognition. Fix only clear recognition mistakes: \
    wrong or swapped letters, words broken by stray spaces or hyphens, symbols that should be letters. \
    Keep everything else exactly as it is: the wording, the language, the order, every line break and every tab. \
    Do not add, remove, summarise or explain anything. Reply with the corrected text only.
    """

    /// Cleans the text in pieces small enough for the on-device model, keeping the blank lines between them.
    static func clean(_ text: String) async throws -> String {
        var cleaned: [String] = []
        for chunk in TextPieces.chunks(text, limit: 1500) {
            let session = LanguageModelSession(instructions: instructions)
            let answer = try await session.respond(to: chunk).content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Do no harm: a reply that changed many words is a rewrite, not a correction.
            cleaned.append(TextPieces.wordOverlap(chunk, answer) >= 0.7 ? answer : chunk)
        }
        return cleaned.joined(separator: "\n\n")
    }
}

// MARK: - View

struct ResultPanelView: View {
    @ObservedObject var model: ResultPanelModel

    private static let languages: [(String, String)] = {
        let codes = ["ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko", "ms", "nl", "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]
        return codes.map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }.sorted { $0.1 < $1.1 }
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.canRelayout {
                    Picker("Lines", selection: $model.lineMode) {
                        Text("Smart").tag(LineMode.paragraphs)
                        Text("Keep breaks").tag(LineMode.keepLines)
                        Text("Single line").tag(LineMode.singleLine)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                Picker("Format", selection: $model.format) {
                    Text("Plain text").tag(StructuredText.Format.plain)
                    Text("Markdown").tag(StructuredText.Format.markdown)
                }
                .labelsHidden()
                .frame(maxWidth: 130)
                .disabled(!model.canRelayout)
                if model.hasTable && model.format == .plain {
                    Picker("Tables", selection: $model.tableStyle) {
                        Text("Tables: tabs").tag(StructuredText.TableStyle.tabs)
                        Text("Tables: CSV").tag(StructuredText.TableStyle.csv)
                        Text("Tables: Markdown").tag(StructuredText.TableStyle.markdown)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            TableAwareEditor(text: $model.text)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.text) { _, _ in model.textChanged() }

            if let note = model.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {
                if #available(macOS 15.0, *) {
                    Picker("Translate to", selection: $model.translationTarget) {
                        ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    Button("Translate") { model.translate() }
                        .disabled(model.busy != nil)
                }
                if model.canCleanUp {
                    Button("Clean Up") { model.cleanUp() }
                        .disabled(model.busy != nil)
                        .help("Fix recognition mistakes with Apple's on-device model. Nothing leaves this Mac.")
                }
                Button {
                    model.speak()
                } label: { Image(systemName: "speaker.wave.2") }
                    .help("Speak")
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.edited && model.canRelayout {
                    Button("Revert") { model.relayout() }
                }
                Button("Copy") { model.copy(andClose: false) }
                Button("Copy and Close") { model.copy(andClose: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 460, minHeight: 300)
        .modifier(TranslationRunner(model: model))
    }
}

/// Attaches Apple's translation task, which can also ask to download a missing language.
private struct TranslationRunner: ViewModifier {
    @ObservedObject var model: ResultPanelModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.translationTask((model.translation as? ConfigurationBox)?.value as? TranslationSession.Configuration) { session in
                await model.runTranslation(session)
            }
        } else {
            content
        }
    }
}
