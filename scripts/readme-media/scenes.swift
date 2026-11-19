// Draws the demo desktops for the README animation, at 2x like a Retina screen, and cuts out the areas the demo
// selects, so the real app can read them. All content is made up for the demo.
//   swift scripts/readme-media/scenes.swift <out folder>
import AppKit
import CoreImage

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/readme-media")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The desktop in points; frames are drawn at this size, scenes at 2x.
let desk = CGSize(width: 1000, height: 625)
let scale: CGFloat = 2

/// Where each scene's selection goes, in desktop points (top-left origin). Shared with compose.swift.
let selections: [String: CGRect] = [
    "article": CGRect(x: 118, y: 196, width: 560, height: 254),
    "poster": CGRect(x: 600, y: 160, width: 250, height: 278),
]

func render(_ name: String, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(desk.width * scale), pixelsHigh: Int(desk.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = desk
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: desk.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let image = rep.cgImage!
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("desktop-\(name).png"))
    if let selection = selections[name] {
        let crop = image.cropping(to: CGRect(x: selection.minX * scale, y: selection.minY * scale,
                                             width: selection.width * scale, height: selection.height * scale))!
        try! NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])!
            .write(to: out.appendingPathComponent("crop-\(name).png"))
    }
}

// MARK: Drawing helpers (top-left origin)

func wallpaper(_ ctx: CGContext) {
    let colors = [NSColor(srgbRed: 0.18, green: 0.22, blue: 0.45, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.42, green: 0.27, blue: 0.55, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.93, green: 0.55, blue: 0.45, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: desk.width, y: desk.height), options: [])
}

func window(_ ctx: CGContext, frame: CGRect, title: String) {
    let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Title bar
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSColor(white: 0.96, alpha: 1).setFill()
    NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 38).fill()
    NSColor(white: 0.86, alpha: 1).setFill()
    NSRect(x: frame.minX, y: frame.minY + 38, width: frame.width, height: 1).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: frame.minX + 16 + CGFloat(index) * 20, y: frame.minY + 13, width: 12, height: 12)).fill()
    }
    text(title, at: CGPoint(x: frame.midX - 120, y: frame.minY + 11), size: 13, weight: .semibold,
         color: NSColor(white: 0.35, alpha: 1), width: 240, alignment: .center)
}

func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = NSColor(white: 0.12, alpha: 1), width: CGFloat = 800, alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = size * 0.3
    paragraph.alignment = alignment
    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: paragraph])
        .draw(with: NSRect(x: point.x, y: point.y, width: width, height: 1000), options: [.usesLineFragmentOrigin])
}

func qr(_ payload: String, in rect: CGRect, ctx: CGContext) {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(payload.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let image = CIContext().createCGImage(filter.outputImage!, from: filter.outputImage!.extent)!
    ctx.saveGState()
    ctx.interpolationQuality = .none
    // The context is flipped; draw the code upright.
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

// MARK: Scenes

render("article") { ctx in
    wallpaper(ctx)
    let frame = CGRect(x: 90, y: 70, width: 820, height: 470)
    window(ctx, frame: frame, title: "Release Notes")
    text("Northwind 4.2", at: CGPoint(x: 130, y: 130), size: 30, weight: .bold)
    text("Sync is now twice as fast, and shared folders keep their colours on every device. Offline edits are merged the moment you reconnect.",
         at: CGPoint(x: 130, y: 206), size: 17, width: 520)
    // A small table
    let rows = [("Plan", "Price", "Devices"), ("Basic", "Free", "2"), ("Plus", "€4 / month", "5"), ("Team", "€9 / user", "Unlimited")]
    for (index, row) in rows.enumerated() {
        let y = 318 + CGFloat(index) * 30
        let weight: NSFont.Weight = index == 0 ? .semibold : .regular
        if index > 0 {
            NSColor(white: 0.9, alpha: 1).setFill()
            NSRect(x: 130, y: y - 6, width: 520, height: 1).fill()
        }
        text(row.0, at: CGPoint(x: 130, y: y), size: 16, weight: weight)
        text(row.1, at: CGPoint(x: 300, y: y), size: 16, weight: weight)
        text(row.2, at: CGPoint(x: 480, y: y), size: 16, weight: weight)
    }
    text("Updated 18 November 2026", at: CGPoint(x: 130, y: 490), size: 13, color: NSColor(white: 0.55, alpha: 1))
}

render("poster") { ctx in
    wallpaper(ctx)
    let frame = CGRect(x: 90, y: 70, width: 820, height: 470)
    window(ctx, frame: frame, title: "Community Board")
    text("Community Garden Open Day", at: CGPoint(x: 130, y: 130), size: 30, weight: .bold, width: 440)
    text("Bring your own gloves and a water bottle. We will plant the herb beds, repair the compost bins and share lunch at noon.",
         at: CGPoint(x: 130, y: 220), size: 17, width: 420)
    text("Saturday 7 December · 9:00 to 14:00", at: CGPoint(x: 130, y: 340), size: 16, weight: .medium)
    NSColor(white: 0.97, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 620, y: 175, width: 210, height: 245), xRadius: 14, yRadius: 14).fill()
    qr("https://example.org/garden/register", in: CGRect(x: 645, y: 195, width: 160, height: 160), ctx: ctx)
    text("Scan to register", at: CGPoint(x: 620, y: 378), size: 15, weight: .medium, width: 210, alignment: .center)
}

let json = try! JSONSerialization.data(withJSONObject: selections.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
                                       options: [.prettyPrinted, .sortedKeys])
try! json.write(to: out.appendingPathComponent("selections.json"))
print("scenes written to \(out.path)")
