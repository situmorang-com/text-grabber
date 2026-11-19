// Prints the id of TextGrabber's frontmost on-screen window whose title contains the argument ("" = any,
// including untitled panels such as confirmations).
import Foundation
import CoreGraphics
let wanted = (CommandLine.arguments.dropFirst().first ?? "").lowercased()
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where window[kCGWindowOwnerName as String] as? String == "TextGrabber" {
    let title = (window[kCGWindowName as String] as? String ?? "").lowercased()
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    guard (bounds["Width"] ?? 0) > 100, wanted.isEmpty ? title.isEmpty : title.contains(wanted) else { continue }
    print(window[kCGWindowNumber as String]!)
    exit(0)
}
exit(1)
