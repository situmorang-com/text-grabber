import CoreGraphics

extension ImagePrep {
    /// Paints out pieces of letters that the selection cut through. A selection dragged across a word leaves a
    /// stroke at its edge, and recognition reads it as a character: the stem of a "d" became "1" in front of a
    /// phone number, a descender of the line above became an accent ("5" read as "Ś").
    ///
    /// Removed: a group of connected ink pixels that touches the edge and is much thinner, across that edge, than
    /// the letters inside the capture. Whole letters lie inside the selection, so they are left alone.
    /// - Returns: the cleaned image and how many pieces were removed (0 returns the image unchanged).
    public static func removingEdgeSlivers(_ image: CGImage) -> (image: CGImage, removed: Int) {
        let width = image.width, height = image.height
        // Big captures would cost a noticeable moment; a cut letter matters most in a small capture anyway.
        guard width >= 12, height >= 8, width * height <= 4_000_000 else { return (image, 0) }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, let background = edgeBackground(pixels, width: width, height: height) else { return (image, 0) }

        // Ink: anything clearly unlike the background (dark on light, light on dark, coloured links).
        var ink = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let difference = max(abs(Int(pixels[offset]) - background.0), abs(Int(pixels[offset + 1]) - background.1),
                                 abs(Int(pixels[offset + 2]) - background.2))
            ink[index] = difference > 64
        }

        // Connected pieces of ink (8-connected), with their bounds and the edges they touch.
        struct Piece { var minX: Int, minY: Int, maxX: Int, maxY: Int, pixels: [Int] }
        var label = [Int32](repeating: -1, count: width * height)
        var pieces: [Piece] = []
        var stack: [Int] = []
        for start in 0..<(width * height) where ink[start] && label[start] < 0 {
            let id = Int32(pieces.count)
            var piece = Piece(minX: width, minY: height, maxX: -1, maxY: -1, pixels: [])
            label[start] = id
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                piece.pixels.append(index)
                piece.minX = min(piece.minX, x); piece.maxX = max(piece.maxX, x)
                piece.minY = min(piece.minY, y); piece.maxY = max(piece.maxY, y)
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < width else { continue }
                        let next = ny * width + nx
                        if ink[next] && label[next] < 0 { label[next] = id; stack.append(next) }
                    }
                }
            }
            pieces.append(piece)
            if pieces.count > 20_000 { return (image, 0) }   // noise or a photo, not text
        }

        // The height of a letter inside the capture: the median of the pieces that touch no edge.
        let inside = pieces.filter { $0.minX > 0 && $0.minY > 0 && $0.maxX < width - 1 && $0.maxY < height - 1 && $0.maxY - $0.minY >= 2 }
        guard inside.count >= 2 else { return (image, 0) }
        let letterHeight = CGFloat(inside.map { $0.maxY - $0.minY + 1 }.sorted()[inside.count / 2])
        let thin = max(2, letterHeight * 0.5)

        var removed = 0
        for piece in pieces {
            let pieceWidth = CGFloat(piece.maxX - piece.minX + 1), pieceHeight = CGFloat(piece.maxY - piece.minY + 1)
            let left = piece.minX == 0, right = piece.maxX == width - 1, top = piece.minY == 0, bottom = piece.maxY == height - 1
            // Spanning the capture (a frame, a rule across it) is not a cut letter, and recognition ignores it anyway.
            if (left && right) || (top && bottom) { continue }
            let cutSideways = (left || right) && pieceWidth <= thin && pieceHeight <= letterHeight * 1.6
            let cutAcross = (top || bottom) && pieceHeight <= thin
            guard cutSideways || cutAcross else { continue }
            // The piece and its faint, anti-aliased fringe, which alone still reads as ")" or "'".
            let id = label[piece.pixels[0]]
            for y in max(piece.minY - 2, 0)...min(piece.maxY + 2, height - 1) {
                for x in max(piece.minX - 2, 0)...min(piece.maxX + 2, width - 1) {
                    let index = y * width + x
                    guard label[index] < 0 || label[index] == id else { continue }
                    let offset = index * 4
                    pixels[offset] = UInt8(background.0); pixels[offset + 1] = UInt8(background.1)
                    pixels[offset + 2] = UInt8(background.2); pixels[offset + 3] = 255
                }
            }
            removed += 1
        }
        guard removed > 0 else { return (image, 0) }
        let cleaned = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: info)?.makeImage()
        }
        return cleaned.map { ($0, removed) } ?? (image, 0)
    }

    /// The colour most of the capture's border has, or nil when the border has no main colour (a photo).
    private static func edgeBackground(_ pixels: [UInt8], width: Int, height: Int) -> (Int, Int, Int)? {
        var counts: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        var total = 0
        func add(_ x: Int, _ y: Int) {
            let offset = (y * width + x) * 4
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let sum = counts[key] ?? (0, 0, 0, 0)
            counts[key] = (sum.count + 1, sum.r + r, sum.g + g, sum.b + b)
            total += 1
        }
        for x in 0..<width { add(x, 0); add(x, height - 1) }
        for y in 1..<(height - 1) { add(0, y); add(width - 1, y) }
        guard let best = counts.values.max(by: { $0.count < $1.count }), best.count * 2 >= total else { return nil }
        return (best.r / best.count, best.g / best.count, best.b / best.count)
    }
}
