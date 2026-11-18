import AppKit
import TextGrabberCore

// With arguments this is a command-line OCR tool; without, the menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
if arguments.isEmpty || arguments == ["YES"] || arguments == ["NO"] {
    AppMain.run()
} else {
    exit(CommandLineTool.run(arguments))
}
