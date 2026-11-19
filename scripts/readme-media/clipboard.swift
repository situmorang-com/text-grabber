// Saves or restores the whole clipboard: every item, every type (text, HTML, images, file links), so a test
// that writes to the clipboard leaves the user's clipboard exactly as it was.
//   swift clipboard.swift save <file.plist>     then run the test
//   swift clipboard.swift restore <file.plist>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, ["save", "restore"].contains(arguments[1]) else {
    print("usage: clipboard.swift save|restore <file.plist>"); exit(2)
}
let file = URL(fileURLWithPath: arguments[2])
let pasteboard = NSPasteboard.general

if arguments[1] == "save" {
    let items: [[String: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
        var types: [String: Data] = [:]
        for type in item.types { if let data = item.data(forType: type) { types[type.rawValue] = data } }
        return types
    }
    try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0).write(to: file)
    print("saved \(items.count) item(s), \(items.reduce(0) { $0 + $1.count }) type(s)")
} else {
    let data = try Data(contentsOf: file)
    guard let items = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Data]] else {
        print("not a saved clipboard: \(file.path)"); exit(1)
    }
    pasteboard.clearContents()
    let restored = items.map { types -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, value) in types { item.setData(value, forType: NSPasteboard.PasteboardType(type)) }
        return item
    }
    pasteboard.writeObjects(restored)
    print("restored \(restored.count) item(s)")
}
