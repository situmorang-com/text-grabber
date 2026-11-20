import Foundation
import TextGrabberCore

/// Names of everything stored in UserDefaults, with typed access.
enum Prefs {
    enum Key {
        static let lineMode = "lineMode"
        static let preferredLanguage = "preferredLanguage"
        static let detectsLanguage = "detectsLanguage"
        static let customWords = "customWords"
        static let upscale = "upscaleSmallImages"
        static let detectColumns = "detectColumns"
        static let detectTables = "detectTables"
        static let additive = "additiveClipboard"
        static let speak = "speakAfterCapture"
        static let speechRate = "speechRate"
        static let openLinks = "openLinks"
        static let muteShutter = "muteShutter"
        static let showHUD = "showHUD"
        static let keepHistory = "keepHistory"
        static let lastRect = "lastCaptureRect"
        static let exactText = "useExactTextFromApps"
        static let outputFormat = "outputFormat"
        static let tableStyle = "tableStyle"
        static let translationTarget = "translationTarget"
        static let openEditor = "openEditorAfterCapture"
        static let historyPictures = "historyPictures"
        static let setupDone = "setupDone"
        static let readCodes = "readCodesInTextCaptures"
        static let settingsTab = "settingsTab"
    }

    static let defaults = UserDefaults.standard

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.lineMode: LineMode.paragraphs.rawValue,
            Key.preferredLanguage: "",
            Key.detectsLanguage: true,
            Key.customWords: "",
            Key.upscale: true,
            Key.detectColumns: true,
            Key.detectTables: true,
            Key.additive: false,
            Key.speak: false,
            Key.speechRate: 0.5,
            Key.openLinks: false,
            Key.muteShutter: true,
            Key.showHUD: true,
            Key.keepHistory: true,
            Key.exactText: true,
            Key.outputFormat: StructuredText.Format.plain.rawValue,
            Key.tableStyle: StructuredText.TableStyle.tabs.rawValue,
            Key.openEditor: false,
            Key.historyPictures: true,
            Key.setupDone: false,
            Key.readCodes: true,
        ])
    }

    static var lineMode: LineMode {
        get { LineMode(rawValue: defaults.string(forKey: Key.lineMode) ?? "") ?? .paragraphs }
        set { defaults.set(newValue.rawValue, forKey: Key.lineMode) }
    }

    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    static func toggle(_ key: String) { defaults.set(!defaults.bool(forKey: key), forKey: key) }

    /// Earlier versions kept added captures here instead of using the clipboard; that text is not needed now.
    static func removeOldKeys() {
        defaults.removeObject(forKey: "additiveBuffer")
    }

    /// "x,y,w,h" in global screen points, as `screencapture -R` expects.
    static var lastRect: String? {
        get { defaults.string(forKey: Key.lastRect) }
        set { defaults.set(newValue, forKey: Key.lastRect) }
    }

    static func recognitionOptions(lineMode override: LineMode? = nil) -> RecognitionOptions {
        var options = RecognitionOptions()
        let language = defaults.string(forKey: Key.preferredLanguage) ?? ""
        options.preferredLanguage = language.isEmpty ? nil : language
        options.detectsLanguage = bool(Key.detectsLanguage)
        options.customWords = RecognitionOptions.parseCustomWords(defaults.string(forKey: Key.customWords) ?? "")
        options.lineMode = override ?? lineMode
        options.upscaleSmallImages = bool(Key.upscale)
        options.detectColumns = bool(Key.detectColumns)
        options.detectTables = bool(Key.detectTables)
        return options
    }
}

extension CaptureSwitches {
    /// What the settings say, for a capture read with `lineMode` (nil: the line break setting).
    static func settings(lineMode: LineMode? = nil) -> CaptureSwitches {
        CaptureSwitches(additive: Prefs.bool(Prefs.Key.additive), lineMode: lineMode ?? Prefs.lineMode,
                        speak: Prefs.bool(Prefs.Key.speak))
    }
}
