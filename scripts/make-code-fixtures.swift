// Draws the capture corpus for QR codes and barcodes: Tests/TextGrabberCoreTests/Fixtures/codes/*.png.
// Each scene is a piece of screen (text in system fonts, codes drawn pixel-exact) at 2x, cut to the area a
// person would select. Re-run after changing a scene:  swift scripts/make-code-fixtures.swift
import AppKit
import CoreImage

enum Item {
    case text(String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat = 1000)
    case qr(String, x: CGFloat, y: CGFloat, side: CGFloat)
    case barcode(String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
}

struct Scene {
    var name: String
    var size: CGSize                 // points, top-left origin
    var dark = false
    var items: [Item]
    var selection: CGRect? = nil     // the area "selected" (points); nil = all of it
}

let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Tests/TextGrabberCoreTests/Fixtures/codes")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let context = CIContext()

func codeImage(_ filter: String, _ payload: String) -> CGImage {
    let f = CIFilter(name: filter)!
    f.setValue(payload.data(using: .utf8), forKey: "inputMessage")
    if filter == "CIQRCodeGenerator" { f.setValue("M", forKey: "inputCorrectionLevel") }
    if filter == "CICode128BarcodeGenerator" { f.setValue(0, forKey: "inputQuietSpace") }
    let image = f.outputImage!
    return context.createCGImage(image, from: image.extent)!
}

func draw(_ scene: Scene) {
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(scene.size.width * scale), pixelsHigh: Int(scene.size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = scene.size
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    // Top-left origin, like the screen.
    graphics.cgContext.translateBy(x: 0, y: scene.size.height)
    graphics.cgContext.scaleBy(x: 1, y: -1)
    let background = scene.dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white
    let ink = scene.dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    background.setFill()
    NSRect(origin: .zero, size: scene.size).fill()
    graphics.cgContext.interpolationQuality = .none

    for item in scene.items {
        switch item {
        case let .text(string, x, y, size, weight, width):
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = size * 0.25
            let attributed = NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink, .paragraphStyle: paragraph,
            ])
            NSGraphicsContext.saveGraphicsState()
            // Text draws upright in a flipped context.
            let flipped = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
            NSGraphicsContext.current = flipped
            attributed.draw(with: NSRect(x: x, y: y, width: width, height: 2000), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        case let .qr(payload, x, y, side):
            // QR codes on screen sit on white with a margin, also in dark mode.
            NSColor.white.setFill()
            NSRect(x: x - side * 0.08, y: y - side * 0.08, width: side * 1.16, height: side * 1.16).fill()
            graphics.cgContext.draw(codeImage("CIQRCodeGenerator", payload), in: CGRect(x: x, y: y, width: side, height: side))
        case let .barcode(payload, x, y, width, height):
            NSColor.white.setFill()
            NSRect(x: x - 12, y: y - 8, width: width + 24, height: height + 16).fill()
            graphics.cgContext.draw(codeImage("CICode128BarcodeGenerator", payload), in: CGRect(x: x, y: y, width: width, height: height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    var image = rep.cgImage!
    if let selection = scene.selection {
        image = image.cropping(to: CGRect(x: selection.minX * scale, y: selection.minY * scale,
                                          width: selection.width * scale, height: selection.height * scale))!
    }
    let out = NSBitmapImageRep(cgImage: image)
    try! out.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(scene.name + ".png"))
    print(scene.name, image.width, "x", image.height)
}

let paragraph = "Bring your own gloves and a water bottle. We will plant the herb beds, repair the compost bins and share lunch at noon. Children are welcome with an adult."

let scenes: [Scene] = [
    // Only a code, with the usual call to action under it.
    Scene(name: "code-caption", size: CGSize(width: 260, height: 300), items: [
        .qr("https://example.com/menu?table=12", x: 40, y: 30, side: 180),
        .text("Scan me", x: 98, y: 240, size: 18, weight: .semibold),
    ]),
    // The link printed under the code, shorter than the code's payload.
    Scene(name: "code-url-below", size: CGSize(width: 280, height: 300), items: [
        .qr("https://example.com/menu?table=12", x: 50, y: 30, side: 180),
        .text("example.com/menu", x: 70, y: 242, size: 16),
    ]),
    // A code on a poster, selected a little too generously: pieces of the text around it are cut by the selection.
    Scene(name: "code-clipped-text", size: CGSize(width: 900, height: 600), items: [
        .text("Community Garden Open Day", x: 40, y: 30, size: 34, weight: .bold),
        .text(paragraph, x: 40, y: 90, size: 20, width: 520),
        .text("Saturday 7 December, 9:00 to 14:00", x: 40, y: 260, size: 20, weight: .medium),
        .qr("https://example.org/garden/register", x: 620, y: 110, side: 200),
        .text("Scan to register", x: 652, y: 330, size: 18),
    ], selection: CGRect(x: 500, y: 75, width: 360, height: 300)),
    // The same poster, selected whole: the text is wanted too.
    Scene(name: "code-poster", size: CGSize(width: 900, height: 400), items: [
        .text("Community Garden Open Day", x: 40, y: 30, size: 34, weight: .bold),
        .text(paragraph, x: 40, y: 90, size: 20, width: 520),
        .text("Saturday 7 December, 9:00 to 14:00", x: 40, y: 260, size: 20, weight: .medium),
        .qr("https://example.org/garden/register", x: 620, y: 110, side: 200),
        .text("Scan to register", x: 652, y: 330, size: 18),
    ]),
    // A product barcode with its digits printed under it.
    Scene(name: "code-product-barcode", size: CGSize(width: 360, height: 180), items: [
        .barcode("4006381333931", x: 40, y: 30, width: 280, height: 90),
        .text("4006381333931", x: 112, y: 132, size: 18),
    ]),
    // A Wi-Fi code with a short label.
    Scene(name: "code-wifi", size: CGSize(width: 280, height: 320), items: [
        .text("Guest Wi-Fi", x: 88, y: 20, size: 20, weight: .semibold),
        .qr("WIFI:T:WPA;S:Guest;P:sunflower42;;", x: 50, y: 60, side: 180),
        .text("Scan to join", x: 96, y: 270, size: 16),
    ]),
    // An invoice with a small payment code in a corner: the document is the point.
    Scene(name: "code-invoice", size: CGSize(width: 700, height: 420), items: [
        .text("Invoice INV-20418", x: 40, y: 30, size: 28, weight: .bold),
        .text("Billed to: Northwind Traders\nIssued: 18 November 2026\nDue: 2 December 2026", x: 40, y: 85, size: 18),
        .text("Design workshop, two days\nTravel and materials\nTotal due: EUR 2,450.00", x: 40, y: 205, size: 18),
        .text("Pay online with the code or by bank transfer to the account on page two.", x: 40, y: 330, size: 15),
        .qr("https://pay.example.com/i/20418", x: 540, y: 40, side: 120),
    ]),
    // Dark sign-in card: a title and one instruction above the code.
    Scene(name: "code-dark-pairing", size: CGSize(width: 420, height: 420), dark: true, items: [
        .text("Pair your phone", x: 40, y: 30, size: 24, weight: .bold),
        .text("Open the app on your phone and scan this code to sign in.", x: 40, y: 72, size: 16, width: 340),
        .qr("https://example.com/pair/7F3K9Q", x: 120, y: 150, side: 180),
    ]),
    // Two codes side by side with platform labels.
    Scene(name: "code-two-stores", size: CGSize(width: 520, height: 300), items: [
        .qr("https://example.com/app/ios", x: 40, y: 30, side: 180),
        .qr("https://example.com/app/android", x: 300, y: 30, side: 180),
        .text("iPhone", x: 104, y: 240, size: 18), .text("Android", x: 356, y: 240, size: 18),
    ]),
]
scenes.forEach(draw)
