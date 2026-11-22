import Foundation

/// One entry in the playlist. Stored on disk as JSON, so only the file
/// path and a display title are kept; duration is resolved at play time.
struct PlaylistItem: Codable, Equatable {
    var path: String
    var title: String

    var url: URL { URL(fileURLWithPath: path) }

    init(url: URL) {
        self.path = url.path
        self.title = url.deletingPathExtension().lastPathComponent
    }

    init(path: String, title: String) {
        self.path = path
        self.title = title
    }

    static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.path == rhs.path
    }
}

/// Media file extensions MacPlayer accepts, in open panels, drag and drop
/// and recursive folder scans.
enum MediaTypes {
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm", "mpg", "mpeg",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "aif",
    ]
    static let allExtensions: Set<String> = videoExtensions.union(audioExtensions)

    static func isMediaFile(url: URL) -> Bool {
        allExtensions.contains(url.pathExtension.lowercased())
    }

    /// All media files under a folder, in sorted order, recursing into
    /// subfolders and skipping hidden files and packages.
    static func mediaFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if isMediaFile(url: url) { found.append(url) }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Owns the playlist: in-memory list plus JSON persistence under
/// ~/Library/Application Support/MacPlayer/playlist.json
final class PlaylistStore {
    private(set) var items: [PlaylistItem] = []

    static let shared = PlaylistStore()

    var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MacPlayer", isDirectory: true)
        return dir.appendingPathComponent("playlist.json")
    }

    init() {
        load()
    }

    /// Load the persisted list. Missing or unreadable files leave an empty list.
    func load() {
        let url = storageURL
        guard let data = try? Data(contentsOf: url) else { items = []; return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([PlaylistItem].self, from: data) {
            // Drop entries whose file no longer exists.
            items = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        } else {
            items = []
        }
    }

    /// Write the current list to disk, creating the folder when needed.
    func save() {
        let url = storageURL
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("MacPlayer: failed to save playlist: \(error)")
        }
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    func item(at index: Int) -> PlaylistItem? {
        guard items.indices.contains(index) else { return nil }
        return items[index]
    }

    func index(of item: PlaylistItem) -> Int? {
        items.firstIndex(of: item)
    }

    /// Append media files from a mixed list of file and folder URLs.
    /// Returns the URLs actually added.
    @discardableResult
    func add(urls: [URL]) -> [URL] {
        var added: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                for file in MediaTypes.mediaFiles(in: url) {
                    if addFile(file) { added.append(file) }
                }
            } else if MediaTypes.isMediaFile(url: url) {
                if addFile(url) { added.append(url) }
            }
        }
        if !added.isEmpty { save() }
        return added
    }

    /// Append one file, skipping duplicates. Returns true when it was added.
    @discardableResult
    func addFile(_ url: URL) -> Bool {
        let item = PlaylistItem(url: url)
        guard !items.contains(item) else { return false }
        items.append(item)
        return true
    }

    /// Append one file and persist immediately. Returns the new item.
    @discardableResult
    func addFileAndSave(_ url: URL) -> PlaylistItem? {
        guard addFile(url) else { return item(at: items.firstIndex(of: PlaylistItem(url: url)) ?? -1) }
        save()
        return items.last
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
    }

    func remove(itemsAt indexes: IndexSet) {
        for index in indexes.sorted(by: >) {
            guard items.indices.contains(index) else { continue }
            items.remove(at: index)
        }
        save()
    }

    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source), destination >= 0, destination <= items.count else { return }
        let item = items.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        items.insert(item, at: min(target, items.count))
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    /// Index of the item after the given one, wrapping to the start.
    func nextIndex(after index: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        return (index + 1) % items.count
    }

    /// Index of the item before the given one, wrapping to the end.
    func previousIndex(before index: Int) -> Int? {
        guard !items.isEmpty else { return nil }
        return (index - 1 + items.count) % items.count
    }
}
