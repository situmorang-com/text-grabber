import AppKit
import SwiftUI

/// What the small confirmations show: the "Copied" notice and the confirmation for a capture with a code.
///
/// Both are laid out on two columns: a coloured tile, and one text column that everything else lines up with
/// (what happened, what was copied, the footnote, and the buttons).
struct CardContent {
    enum Style {
        /// A preview of copied text: small, secondary, up to three lines.
        case preview
        /// A code's contents, in monospaced type.
        case code
        /// What to check before acting, in large type (the site a link goes to).
        case prominent
    }

    var symbol: String
    var tint: Color
    /// What happened: "Copied", "Barcode copied".
    var headline: String
    /// What was copied.
    var text: String?
    var style: Style = .preview
    /// A line under the text (the whole link under its site).
    var detail: String?
    /// A code shown as a small chip under the text (a capture with text and a code).
    var chip: String?
    var chipSymbol = "link"
    var footnote: String?

    /// The tile's colour for a symbol the app uses.
    static func tint(for symbol: String) -> Color {
        if symbol.hasPrefix("checkmark") { return .green }
        if symbol.hasPrefix("exclamationmark") { return .orange }
        if symbol.hasPrefix("hourglass") || symbol.contains("magnifyingglass") || symbol.contains("viewfinder") { return .gray }
        return .accentColor
    }
}

struct CardButton {
    var title: String
    /// Shown as a key hint: "⏎", "⎋", "⌘C".
    var key: String?
    var prominent = false
    var action: () -> Void
}

struct ConfirmationCardView: View {
    static let tileSize: CGFloat = 34
    static let columnSpacing: CGFloat = 12
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 440

    let content: CardContent
    var buttons: [CardButton] = []
    var keyHints = false
    /// nil: as wide as the content wants (to measure it); otherwise the card's width.
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: Self.columnSpacing) {
                tile
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let text = content.text, !text.isEmpty { copied(text) }
                    if let detail = content.detail {
                        wrapping(Text(detail).font(.system(size: 12)).foregroundStyle(.secondary), lines: 2, truncation: .middle)
                    }
                    if let chip = content.chip { self.chip(chip) }
                    if let footnote = content.footnote {
                        Text(footnote)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }
                .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
            }
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                        Button(action: button.action) { label(button) }
                            .buttonStyle(GlassButton(prominent: button.prominent))
                            .focusable(false)
                    }
                }
                // Under the text column, not under the tile.
                .padding(.leading, Self.tileSize + Self.columnSpacing)
            }
        }
        .padding(.vertical, 14)
        .padding(.leading, 14)
        .padding(.trailing, 20)
        .frame(width: width, alignment: .leading)
        .focusEffectDisabled()
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [content.tint, content.tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            .overlay(Image(systemName: content.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
            .frame(width: Self.tileSize, height: Self.tileSize)
    }

    @ViewBuilder
    private func copied(_ text: String) -> some View {
        switch content.style {
        case .preview:
            wrapping(Text(text).font(.system(size: 12)).foregroundStyle(.secondary), lines: 3, truncation: .tail)
        case .code:
            wrapping(Text(text).font(.system(size: 15, weight: .medium, design: .monospaced)), lines: 2, truncation: .middle)
        case .prominent:
            wrapping(Text(text).font(.system(size: 17, weight: .semibold)), lines: 2, truncation: .tail)
        }
    }

    /// Text that wraps within the card's width once it has one; while measuring, one line (its natural width).
    @ViewBuilder
    private func wrapping(_ text: some View, lines: Int, truncation: Text.TruncationMode) -> some View {
        if width == nil {
            text.lineLimit(1).fixedSize()
        } else {
            text.lineLimit(lines).truncationMode(truncation).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chip(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: content.chipSymbol)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .padding(.vertical, 3)
    }

    private func label(_ button: CardButton) -> some View {
        HStack(spacing: 6) {
            Text(button.title)
            if keyHints, let key = button.key {
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.22)))
            }
        }
    }
}

extension ConfirmationCardView {
    /// The card at the width its content wants, between `minWidth` and `maxWidth`, so a short code does not sit
    /// in a wide empty panel and a long text wraps.
    static func sized(_ content: CardContent, buttons: [CardButton] = [], keyHints: Bool = false) -> ConfirmationCardView {
        let natural = NSHostingView(rootView: ConfirmationCardView(content: content, buttons: buttons, keyHints: keyHints))
        let width = min(max(natural.fittingSize.width.rounded(.up), minWidth), maxWidth)
        return ConfirmationCardView(content: content, buttons: buttons, keyHints: keyHints, width: width)
    }
}

/// A capsule button for glass: translucent, with a fine light edge; the prominent one in the accent colour.
struct GlassButton: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.3 : 0.2), lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
