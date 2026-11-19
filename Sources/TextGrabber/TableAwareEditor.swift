import AppKit
import SwiftUI

/// A plain text editor whose tab stops follow the text: tab-separated table rows line up in columns, as wide as
/// their widest cell. The text itself keeps real tabs, so it pastes into a spreadsheet as before.
struct TableAwareEditor: NSViewRepresentable {
    @Binding var text: String
    var font = NSFont.systemFont(ofSize: 13)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = font
        view.textColor = .labelColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 2, height: 4)
        context.coordinator.apply(text, to: view, font: font)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        context.coordinator.apply(text, to: view, font: font)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            setTabStops(on: view, font: view.font ?? .systemFont(ofSize: 13))
        }

        func apply(_ string: String, to view: NSTextView, font: NSFont) {
            view.string = string
            setTabStops(on: view, font: font)
        }

        /// Each column as wide as its widest cell plus a gap, measured in the editor's font.
        private func setTabStops(on view: NSTextView, font: NSFont) {
            var widths: [CGFloat] = []
            for line in view.string.split(separator: "\n") where line.contains("\t") {
                for (column, cell) in line.split(separator: "\t", omittingEmptySubsequences: false).dropLast().enumerated() {
                    let width = (String(cell) as NSString).size(withAttributes: [.font: font]).width
                    if column < widths.count { widths[column] = max(widths[column], width) } else { widths.append(width) }
                }
            }
            let gap: CGFloat = 24
            var position: CGFloat = 0
            let style = NSMutableParagraphStyle()
            style.tabStops = widths.map { width in
                position += width + gap
                return NSTextTab(textAlignment: .left, location: position)
            }
            // Beyond the measured columns, the usual regular stops.
            style.defaultTabInterval = 28
            style.lineSpacing = 2
            view.defaultParagraphStyle = style
            view.typingAttributes[.paragraphStyle] = style
            if let storage = view.textStorage {
                storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
            }
        }
    }
}
