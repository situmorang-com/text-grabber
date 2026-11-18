import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct HistoryEntry: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var date = Date()
    public var text: String
    /// "text" or "barcode".
    public var kind: String
    public var pinned = false
    /// File name of a small picture of what was captured, inside the history folder.
    public var thumbnail: String?

    public init(text: String, kind: String) {
        self.text = text
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, date, text, kind, pinned, thumbnail }

    // Entries saved by earlier versions have no `pinned` or `thumbnail`.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        date = try values.decode(Date.self, forKey: .date)
        text = try values.decode(String.self, forKey: .text)
        kind = try values.decode(String.self, forKey: .kind)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        thumbnail = try values.decodeIfPresent(String.self, forKey: .thumbnail)
    }
}

/// Past captures, kept on this Mac only. Pinned entries first, then newest first. Pinned entries are never
/// dropped when the history is full, nor by "clear".
public final class CaptureHistory: ObservableObject {
    @Published public private(set) var entries: [HistoryEntry] = []
    public let folder: URL
    public var limit = 200
    private var file: URL { folder.appendingPathComponent("history.json") }
    private var thumbnails: URL { folder.appendingPathComponent("thumbnails", isDirectory: true) }

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = Self.ordered(saved)
        }
    }

    public func add(_ text: String, kind: String, picture: CGImage? = nil) {
        var entry = HistoryEntry(text: text, kind: kind)
        if let existing = entries.first(where: { $0.text == text }) {
            entry.pinned = existing.pinned
            discard(existing)
        }
        if let picture, let name = saveThumbnail(picture, id: entry.id) { entry.thumbnail = name }
        entries = Self.ordered([entry] + entries)
        trim()
        save()
    }

    public func setPinned(_ entry: HistoryEntry, _ pinned: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].pinned = pinned
        entries = Self.ordered(entries)
        trim()
        save()
    }

    public func remove(_ entry: HistoryEntry) {
        discard(entry)
        save()
    }

    /// Removes everything that is not pinned.
    public func clearUnpinned() {
        for entry in entries where !entry.pinned { deleteThumbnail(entry) }
        entries.removeAll { !$0.pinned }
        save()
    }

    public func thumbnailURL(_ entry: HistoryEntry) -> URL? {
        entry.thumbnail.map { thumbnails.appendingPathComponent($0) }
    }

    // MARK: Private

    private func discard(_ entry: HistoryEntry) {
        deleteThumbnail(entry)
        entries.removeAll { $0.id == entry.id }
    }

    private func trim() {
        var unpinned = 0
        var kept: [HistoryEntry] = []
        for entry in entries {
            if entry.pinned { kept.append(entry); continue }
            unpinned += 1
            if unpinned <= limit { kept.append(entry) } else { deleteThumbnail(entry) }
        }
        entries = kept
    }

    static func ordered(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.filter(\.pinned).sorted { $0.date > $1.date } + entries.filter { !$0.pinned }.sorted { $0.date > $1.date }
    }

    private func deleteThumbnail(_ entry: HistoryEntry) {
        if let url = thumbnailURL(entry) { try? FileManager.default.removeItem(at: url) }
    }

    /// A JPEG at most 480 pixels on its longest side: enough to recognise the capture, small on disk.
    private func saveThumbnail(_ image: CGImage, id: UUID) -> String? {
        let name = id.uuidString + ".jpg"
        let url = thumbnails.appendingPathComponent(name)
        let longest = max(image.width, image.height)
        let scale = longest > 480 ? 480 / Double(longest) : 1
        let width = max(Int(Double(image.width) * scale), 1), height = max(Int(Double(image.height) * scale), 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? name : nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
