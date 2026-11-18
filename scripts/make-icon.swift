// Draws the app icon: swift scripts/make-icon.swift <output.png>
import AppKit

let side: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.16, green: 0.20, blue: 0.33, alpha: 1), NSColor(red: 0.07, green: 0.09, blue: 0.16, alpha: 1)])!
    .draw(in: shape, angle: -90)

// Viewfinder corners.
let accent = NSColor(red: 0.40, green: 0.85, blue: 0.75, alpha: 1)
accent.setStroke()
let frame = tile.insetBy(dx: 170, dy: 170)
let arm: CGFloat = 120
for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                       (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
    let corner = NSBezierPath()
    corner.lineWidth = 44
    corner.lineCapStyle = .round
    corner.lineJoinStyle = .round
    corner.move(to: NSPoint(x: x + dx * arm, y: y))
    corner.line(to: NSPoint(x: x, y: y))
    corner.line(to: NSPoint(x: x, y: y + dy * arm))
    corner.stroke()
}

// Lines of text inside it.
NSColor.white.setFill()
for (index, width) in [300.0, 380.0, 220.0].enumerated() {
    let y = frame.midY + 92 - CGFloat(index) * 104
    NSBezierPath(roundedRect: NSRect(x: frame.minX + 52, y: y, width: width, height: 40), xRadius: 20, yRadius: 20).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
