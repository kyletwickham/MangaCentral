import Foundation

/// How pages flow in the reader.
enum ReadingMode: String, Codable, CaseIterable, Identifiable {
    case rightToLeft, leftToRight, vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightToLeft: return "Right to left (manga)"
        case .leftToRight: return "Left to right (comics)"
        case .vertical: return "Vertical scroll (webtoon)"
        }
    }

    var icon: String {
        switch self {
        case .rightToLeft: return "arrow.left"
        case .leftToRight: return "arrow.right"
        case .vertical: return "arrow.down"
        }
    }
}

/// The kind of file a book lives in.
enum BookFormat: String, Codable {
    case cbz      // .cbz or .zip full of page images
    case pdf
    case folder   // a plain folder of images

    var label: String {
        switch self {
        case .cbz: return "CBZ"
        case .pdf: return "PDF"
        case .folder: return "Images"
        }
    }
}

/// A series groups volumes/chapters, e.g. "One Piece".
struct Series: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var tags: [String] = []
    var readingMode: ReadingMode = .rightToLeft
    var twoPageSpreads: Bool = false
    var isFavorite: Bool = false
    var addedAt = Date()
    /// Phase 4: keep this series' progress private from friends.
    var hiddenFromFriends: Bool?
}

/// One readable file: a volume or chapter.
struct Book: Codable, Identifiable, Hashable {
    var id = UUID()
    var seriesID: UUID
    var title: String
    /// Path relative to the app's Library folder.
    var relativePath: String
    var format: BookFormat
    /// Volume/chapter number parsed from the file name, used for sorting.
    var number: Double?
    var pageCount: Int = 0
    var currentPage: Int = 0
    var addedAt = Date()
    var lastReadAt: Date?
    /// Size on disk (added in Phase 2; nil for older entries until backfilled).
    var fileSize: Int64?
    /// Web address it was downloaded from, if any.
    var sourceURL: String?
    /// Phase 3: the file lives only in the backup folder until it's downloaded again.
    var offloaded: Bool?

    var isOffloaded: Bool { offloaded ?? false }

    var progress: Double {
        pageCount > 0 ? Double(currentPage + 1) / Double(pageCount) : 0
    }

    var isFinished: Bool {
        pageCount > 0 && currentPage >= pageCount - 1
    }
}

/// A series you read on a website, tracked by chapter.
struct WebRead: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var siteName: String
    var chapter: Int
    var total: Int?
    var updatedAt = Date()
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var visitedAt = Date()
}

/// One entry in the Downloads tab.
struct DownloadItem: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case downloading   // bytes coming in
        case waiting       // finished, waiting for you to pick a series
        case saving        // being added to the library
        case done
        case failed
    }

    var id = UUID()
    var url: String
    var fileName: String
    var seriesName: String
    var mode: ReadingMode = .rightToLeft
    var confirmed = false
    var status: Status = .downloading
    var progress: Double = 0
    var bytes: Int64 = 0
    var bookID: UUID?
    var error: String?
    var tempPath: String?
    var createdAt = Date()

    var host: String { URL(string: url)?.host ?? "" }
}

enum FileSize {
    static func of(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return total
    }

    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum MangaError: LocalizedError {
    case noPages
    case unreadable(String)
    case alreadyInLibrary

    var errorDescription: String? {
        switch self {
        case .noPages: return "No pages were found in this file."
        case .unreadable(let why): return why
        case .alreadyInLibrary: return "Already in your library."
        }
    }
}

/// Where everything is stored on the device.
enum LibraryPaths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static let root: URL = {
        let url = documents.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let index = documents.appendingPathComponent("library.json")

    static let covers: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(for book: Book) -> URL {
        root.appendingPathComponent(book.relativePath)
    }
}

enum ImageTypes {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif"]

    static func isImage(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// Groups pages into what's shown on screen at once (1 page, or 2 for spreads).
enum Spreads {
    static func make(count: Int, paired: Bool) -> [[Int]] {
        guard count > 0 else { return [] }
        guard paired else { return (0..<count).map { [$0] } }
        // Cover stands alone, then pages pair up: [1,2], [3,4], ...
        var out: [[Int]] = [[0]]
        var i = 1
        while i < count {
            if i + 1 < count {
                out.append([i, i + 1])
                i += 2
            } else {
                out.append([i])
                i += 1
            }
        }
        return out
    }

    static func index(of page: Int, in spreads: [[Int]]) -> Int {
        if let i = spreads.firstIndex(where: { $0.contains(page) }) { return i }
        return page <= 0 ? 0 : max(0, spreads.count - 1)
    }
}
