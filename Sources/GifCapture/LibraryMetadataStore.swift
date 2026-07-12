import Foundation
import ImageIO

struct LibraryItemMetadata: Codable, Equatable {
    var favorite = false
    var tags: [String] = []
}

struct LibraryMediaInfo {
    let duration: Double
    let width: Int
    let height: Int
    let bytes: Int

    var displayText: String {
        let durationText = duration < 60
            ? String(format: "%.1fs", duration)
            : String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)
        return "\(durationText) · \(width)×\(height) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    static func load(from url: URL) -> LibraryMediaInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gif = frame[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { continue }
            duration += (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return LibraryMediaInfo(duration: duration, width: width, height: height, bytes: bytes)
    }
}

final class LibraryMetadataStore {
    static let shared = LibraryMetadataStore()

    private let root: URL
    private var entries: [String: LibraryItemMetadata] = [:]
    private var fileURL: URL { root.appendingPathComponent(".gifcapture-library.json") }

    init(root: URL = GifConverter.outputDirectory) {
        self.root = root.standardizedFileURL
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: LibraryItemMetadata].self, from: data)
        else { return }
        entries = decoded
    }

    func metadata(for url: URL) -> LibraryItemMetadata {
        entries[key(for: url)] ?? LibraryItemMetadata()
    }

    func setFavorite(_ favorite: Bool, for url: URL) {
        var value = metadata(for: url)
        value.favorite = favorite
        entries[key(for: url)] = value
        save()
    }

    func setTags(_ tags: [String], for url: URL) {
        var value = metadata(for: url)
        value.tags = Array(Set(tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        entries[key(for: url)] = value
        save()
    }

    func move(from oldURL: URL, to newURL: URL) {
        let oldKey = key(for: oldURL)
        let newKey = key(for: newURL)
        let affected = entries.filter { $0.key == oldKey || $0.key.hasPrefix(oldKey + "/") }
        for (key, value) in affected {
            entries.removeValue(forKey: key)
            entries[newKey + key.dropFirst(oldKey.count)] = value
        }
        save()
    }

    func remove(_ url: URL) {
        let prefix = key(for: url)
        entries = entries.filter { $0.key != prefix && !$0.key.hasPrefix(prefix + "/") }
        save()
    }

    private func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let prefix = root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
