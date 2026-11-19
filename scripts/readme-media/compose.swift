// Composes the README animation from the demo desktops (scenes.swift), the real app's screenshots
// (capture-ui.sh) and the text the real app read from the demo selection. Writes PNG frames; make.sh turns
// them into a GIF.
//   swift scripts/readme-media/compose.swift <scenes folder>
import AppKit
import CoreImage

let src = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/readme-media")
let framesFolder = src.appendingPathComponent("frames")
try? FileManager.default.removeItem(at: framesFolder)
try! FileManager.default.createDirectory(at: framesFolder, withIntermediateDirectories: true)

let size = CGSize(width: 1000, height: 625)
let fps = 15.0

func image(_ name: String) -> NSImage { NSImage(contentsOf: src.appendingPathComponent(name))! }
let deskArticle = image("desktop-article.png"), deskPoster = image("desktop-poster.png")
let hud = image("ui/confirmation.png"), codePanel = image("ui/code-confirmation.png"), editor = image("ui/editor.png")
let pasted = (try? String(contentsOf: src.appendingPathComponent("article.txt"), encoding: .utf8)) ?? ""
let selections = try! JSONSerialization.jsonObject(with: Data(contentsOf: src.appendingPathComponent("selections.json"))) as! [String: [Double]]
func selection(_ name: String) -> CGRect { let v = selections[name]!; return CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }

// MARK: Timing helpers

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
/// 0 before `start`, 1 after `end`, eased in between.
func ease(_ t: Double, _ start: Double, _ end: Double) -> CGFloat {
    let x = clamp((t - start) / (end - start))
    return CGFloat(x * x * (3 - 2 * x))
}
func mix(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k) }
/// Fades in over 0.2 s from `start`, out over 0.25 s before `end`.
func visible(_ t: Double, _ start: Double, _ end: Double) -> CGFloat { ease(t, start, start + 0.2) * (1 - ease(t, end - 0.25, end)) }

// MARK: Drawing helpers (top-left origin)

func draw(_ image: NSImage, in rect: CGRect, alpha: CGFloat = 1) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

func roundedText(_ string: String, center: CGPoint, size: CGFloat, alpha: CGFloat, weight: NSFont.Weight = .semibold,
                 padding: CGSize = CGSize(width: 16, height: 9), scale: CGFloat = 1) {
    guard alpha > 0.01 else { return }
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                     .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
    let text = NSAttributedString(string: string, attributes: attributes)
    let textSize = text.size()
    let box = CGRect(x: center.x - (textSize.width / 2 + padding.width) * scale, y: center.y - (textSize.height / 2 + padding.height) * scale,
                     width: (textSize.width + padding.width * 2) * scale, height: (textSize.height + padding.height * 2) * scale)
    NSColor(white: 0.08, alpha: 0.62 * alpha).setFill()
    NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
    NSColor.white.withAlphaComponent(0.22 * alpha).setStroke()
    let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: box.height / 2, yRadius: box.height / 2)
    edge.lineWidth = 1
    edge.stroke()
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.scale(by: scale)
    transform.concat()
    text.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()
}

func arrowCursor(at p: CGPoint) {
    let path = NSBezierPath()
    path.move(to: p)
    path.line(to: CGPoint(x: p.x, y: p.y + 21))
    path.line(to: CGPoint(x: p.x + 5, y: p.y + 16))
    path.line(to: CGPoint(x: p.x + 9, y: p.y + 25))
    path.line(to: CGPoint(x: p.x + 12.5, y: p.y + 23.5))
    path.line(to: CGPoint(x: p.x + 8.5, y: p.y + 15))
    path.line(to: CGPoint(x: p.x + 15, y: p.y + 15))
    path.close()
    NSColor.black.setFill(); path.fill()
    NSColor.white.setStroke(); path.lineWidth = 1.4; path.stroke()
}

func crosshair(at p: CGPoint) {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: p.x - 11, y: p.y)); path.line(to: CGPoint(x: p.x + 11, y: p.y))
    path.move(to: CGPoint(x: p.x, y: p.y - 11)); path.line(to: CGPoint(x: p.x, y: p.y + 11))
    NSColor.white.setStroke(); path.lineWidth = 3.2; path.stroke()
    NSColor.black.setStroke(); path.lineWidth = 1.2; path.stroke()
}

/// The area being selected, as macOS shows it: the rest of the screen dimmed, a light edge.
func selectionOverlay(_ rect: CGRect, alpha: CGFloat) {
    guard alpha > 0.01 else { return }
    let outside = NSBezierPath(rect: CGRect(origin: .zero, size: size))
    outside.append(NSBezierPath(rect: rect).reversed)
    NSColor.black.withAlphaComponent(0.32 * alpha).setFill()
    outside.fill()
    NSColor.white.withAlphaComponent(0.06 * alpha).setFill()
    NSBezierPath(rect: rect).fill()
    let edge = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
    edge.lineWidth = 1
    NSColor.white.withAlphaComponent(0.85 * alpha).setStroke()
    edge.stroke()
}

/// Blurs what is already drawn under `rect`, in a rounded shape: the frosted glass behind a panel.
func frost(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, amount: CGFloat) {
    guard amount > 0.01, let drawn = ctx.makeImage() else { return }
    let scale = CGFloat(drawn.width) / size.width
    let ci = CIImage(cgImage: drawn).clampedToExtent().applyingGaussianBlur(sigma: 14 * scale)
    let flippedRect = CGRect(x: rect.minX * scale, y: (size.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale)
    guard let blurred = CIContext().createCGImage(ci, from: flippedRect) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    NSImage(cgImage: blurred, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: amount,
                                                    respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

/// The pasted result in a simple notes window, with the table in columns.
func notesCard(origin: CGPoint, alpha: CGFloat) {
    guard alpha > 0.01 else { return }
    let frame = CGRect(x: origin.x, y: origin.y, width: 400, height: 290)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4 * alpha)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(white: 0.99, alpha: alpha).setFill()
    NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 1, green: 0.84, blue: 0.3, alpha: alpha).setFill()
    NSBezierPath(roundedRect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 34), xRadius: 12, yRadius: 12).fill()
    NSRect(x: frame.minX, y: frame.minY + 22, width: frame.width, height: 12).fill()
    NSAttributedString(string: "Notes", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                     .foregroundColor: NSColor(white: 0.2, alpha: alpha)])
        .draw(at: CGPoint(x: frame.minX + 16, y: frame.minY + 9))
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 3
    style.tabStops = [NSTextTab(textAlignment: .left, location: 70), NSTextTab(textAlignment: .left, location: 180)]
    NSAttributedString(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.12, alpha: alpha), .paragraphStyle: style,
    ]).draw(with: CGRect(x: frame.minX + 18, y: frame.minY + 50, width: frame.width - 36, height: frame.height - 60),
            options: [.usesLineFragmentOrigin])
}

// MARK: Scenes

let sceneLength = [6.4, 5.8, 4.2]
let total = sceneLength.reduce(0, +)

func drawFrame(_ t: Double, _ ctx: CGContext) {
    let hudSize = hud.size, codeSize = codePanel.size, editorSize = editor.size
    let bottomCenter = { (s: CGSize) in CGPoint(x: (size.width - s.width) / 2, y: size.height - s.height - 40) }

    if t < sceneLength[0] {
        // 1. Text: shortcut, select, copied, pasted.
        draw(deskArticle, in: CGRect(origin: .zero, size: size))
        let area = selection("article")
        let grow = ease(t, 1.2, 2.4)
        let current = CGRect(x: area.minX, y: area.minY, width: max(1, area.width * grow), height: max(1, area.height * grow))
        selectionOverlay(current, alpha: ease(t, 1.1, 1.2) * (1 - ease(t, 2.45, 2.6)))
        // A short flash when the area is taken.
        if t > 2.45 && t < 2.8 {
            NSColor.white.withAlphaComponent(0.25 * (1 - ease(t, 2.45, 2.8))).setFill()
            NSBezierPath(rect: area).fill()
        }
        let hudOrigin = bottomCenter(hudSize)
        draw(hud, in: CGRect(origin: hudOrigin, size: hudSize), alpha: visible(t, 2.7, 4.6))
        notesCard(origin: mix(CGPoint(x: size.width + 20, y: 150), CGPoint(x: 560, y: 150), ease(t, 4.0, 4.6)), alpha: ease(t, 4.0, 4.3))
        roundedText("⌘V", center: CGPoint(x: 760, y: 118), size: 18, alpha: visible(t, 4.3, 5.6))
        roundedText("⇧⌘1", center: CGPoint(x: size.width / 2, y: 40), size: 22, alpha: visible(t, 0.6, 2.5), scale: 0.9 + 0.1 * ease(t, 0.6, 0.8))
        roundedText("Select any area: the text, tables included, is on your clipboard", center: CGPoint(x: size.width / 2, y: size.height - 24),
                    size: 15, alpha: visible(t, 0.2, sceneLength[0]), weight: .medium)
        if t < 1.1 {
            arrowCursor(at: mix(CGPoint(x: 760, y: 560), area.origin, ease(t, 0.1, 1.0)))
        } else if t < 2.6 {
            crosshair(at: CGPoint(x: area.minX + current.width, y: area.minY + current.height))
        } else if t < 4.0 {
            arrowCursor(at: CGPoint(x: area.maxX, y: area.maxY))
        }
        fadeFromBlack(t, 0)
        return
    }
    let t2 = t - sceneLength[0]
    if t2 < sceneLength[1] {
        // 2. A QR code: the link, and the glass confirmation that opens it.
        draw(deskPoster, in: CGRect(origin: .zero, size: size))
        let area = selection("poster")
        let grow = ease(t2, 0.9, 1.8)
        let current = CGRect(x: area.minX, y: area.minY, width: max(1, area.width * grow), height: max(1, area.height * grow))
        selectionOverlay(current, alpha: ease(t2, 0.8, 0.9) * (1 - ease(t2, 1.85, 2.0)))
        if t2 > 1.85 && t2 < 2.2 {
            NSColor.white.withAlphaComponent(0.25 * (1 - ease(t2, 1.85, 2.2))).setFill()
            NSBezierPath(rect: area).fill()
        }
        let panelOrigin = bottomCenter(codeSize)
        let panelAlpha = visible(t2, 2.1, 5.3)
        // The panel's glass: blur what is behind it, then draw the real panel over it.
        let inset: CGFloat = 22   // the screenshot's transparent shadow margin
        frost(ctx, CGRect(origin: panelOrigin, size: codeSize).insetBy(dx: inset, dy: inset), radius: 20, amount: panelAlpha)
        draw(codePanel, in: CGRect(origin: panelOrigin, size: codeSize), alpha: panelAlpha)
        // The pointer goes to Open Link and clicks it.
        let button = CGPoint(x: panelOrigin.x + codeSize.width * 0.80, y: panelOrigin.y + codeSize.height * 0.66)
        if t2 > 3.0 && t2 < 5.0 {
            let p = mix(CGPoint(x: 820, y: 420), button, ease(t2, 3.0, 3.8))
            if t2 > 3.95 && t2 < 4.25 {
                NSColor.white.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: CGRect(x: button.x - 16, y: button.y - 16, width: 32, height: 32)).fill()
            }
            arrowCursor(at: p)
        }
        roundedText("Opening example.org", center: CGPoint(x: size.width / 2, y: 120), size: 15, alpha: visible(t2, 4.2, 5.5), weight: .medium)
        roundedText("⇧⌘1", center: CGPoint(x: size.width / 2, y: 40), size: 22, alpha: visible(t2, 0.4, 1.9), scale: 0.9 + 0.1 * ease(t2, 0.4, 0.6))
        roundedText("QR codes too: open the link with ⏎, or keep the text with it", center: CGPoint(x: size.width / 2, y: size.height - 24),
                    size: 15, alpha: visible(t2, 0.2, sceneLength[1]), weight: .medium)
        if t2 < 0.9 { arrowCursor(at: mix(CGPoint(x: 400, y: 520), area.origin, ease(t2, 0.0, 0.85))) }
        else if t2 < 2.0 { crosshair(at: CGPoint(x: area.minX + current.width, y: area.minY + current.height)) }
        fadeFromBlack(t2, 0)
        return
    }
    // 3. The editor: line breaks, Markdown and CSV, translation, clean-up.
    let t3 = t2 - sceneLength[1]
    draw(deskArticle, in: CGRect(origin: .zero, size: size))
    NSColor.black.withAlphaComponent(0.25 * ease(t3, 0, 0.4)).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    let origin = mix(CGPoint(x: (size.width - editorSize.width) / 2, y: size.height),
                     CGPoint(x: (size.width - editorSize.width) / 2, y: 30), ease(t3, 0.1, 0.7))
    draw(editor, in: CGRect(origin: origin, size: editorSize), alpha: ease(t3, 0.1, 0.4))
    roundedText("Edit, translate on this Mac, export tables as Markdown or CSV", center: CGPoint(x: size.width / 2, y: size.height - 24),
                size: 15, alpha: visible(t3, 0.3, sceneLength[2]), weight: .medium)
    // To black, so the loop restarts cleanly.
    NSColor.black.withAlphaComponent(ease(t3, sceneLength[2] - 0.35, sceneLength[2])).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
}

func fadeFromBlack(_ t: Double, _ start: Double) {
    let k = 1 - ease(t, start, start + 0.35)
    guard k > 0.01 else { return }
    NSColor.black.withAlphaComponent(k).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
}

let count = Int(total * fps)
for index in 0..<count {
    let t = Double(index) / fps
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = base.cgContext
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    drawFrame(t, ctx)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: framesFolder.appendingPathComponent(String(format: "f%04d.png", index)))
}
print("\(count) frames at \(Int(fps)) fps in \(framesFolder.path)")
