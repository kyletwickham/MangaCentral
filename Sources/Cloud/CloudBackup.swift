import SwiftUI
import Network

/// One backed-up book, as recorded in library.json inside the backup folder.
struct CloudEntry: Codable, Identifiable, Hashable {
    var id: UUID { bookID }
    var bookID: UUID
    /// Path inside the backup folder, e.g. "Berserk/Berserk v01.cbz".
    var relativePath: String
    var fileName: String
    var bytes: Int64
    var backedUpAt: Date
    var title: String
    var seriesName: String
    var mode: ReadingMode
    var number: Double?
    var pageCount: Int
    var currentPage: Int
    var format: BookFormat
}

struct BackupManifest: Codable {
    var version = 1
    var savedAt: Date
    var entries: [CloudEntry]
}

/// File work for backups. Runs off the main thread.
enum BackupIO {
    /// Opens the chosen folder (with permission) and hands back its "MangaCentral" subfolder.
    static func withFolder<T>(_ bookmark: Data, _ body: (URL) throws -> T) throws -> T {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let root = url.appendingPathComponent("MangaCentral", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw MangaError.unreadable("MangaCentral can't write to the backup folder anymore. Choose it again in the Cloud tab.")
        }
        return try body(root)
    }

    /// Copies a file or folder, letting iCloud / Google Drive / Dropbox sync it.
    static func copy(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordError: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], writingItemAt: dest, options: .forReplacing, error: &coordError) { r, w in
            do {
                if fm.fileExists(atPath: w.path) { try fm.removeItem(at: w) }
                try fm.copyItem(at: r, to: w)
            } catch { inner = error }
        }
        if let e = coordError ?? inner { throw e }
    }

    static func remove(_ url: URL) {
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
            try? FileManager.default.removeItem(at: u)
        }
    }

    static func writeManifest(_ m: BackupManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(m)
        var coordError: NSError?
        var inner: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { inner = error }
        }
        if let e = coordError ?? inner { throw e }
    }

    static func readManifest(at url: URL) throws -> BackupManifest {
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(MangaError.noPages)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: result.get())
    }
}

/// Phase 3: copies the library to a folder you pick in iCloud Drive, Google Drive,
/// Dropbox or On My iPad, writes library.json, and lets you offload and restore books.
@MainActor
@Observable
final class CloudBackup {
    var folderName: String?
    var lastBackupAt: Date?
    var autoBackup = true { didSet { save() } }
    var wifiOnly = true { didSet { save() } }
    var entries: [CloudEntry] = []

    var isWorking = false
    var progress: Double = 0
    var status = ""
    var lastError: String?
    var onWiFi = true

    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored private var bookmark: Data?
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()

    private static let stateURL = LibraryPaths.documents.appendingPathComponent("backup.json")

    init() {
        load()
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied && !path.isExpensive
            Task { @MainActor in self?.onWiFi = wifi }
        }
        monitor.start(queue: DispatchQueue(label: "mangacentral.network"))
    }

    var isConnected: Bool { bookmark != nil }

    func entry(for book: Book) -> CloudEntry? { entries.first { $0.bookID == book.id } }

    /// Books on this device that aren't backed up yet.
    var pending: [Book] {
        (library?.books ?? []).filter { !$0.isOffloaded && entry(for: $0) == nil }
    }

    /// In the backup but not in the library (deleted here, or a new device).
    var orphans: [CloudEntry] {
        let ids = Set((library?.books ?? []).map(\.id))
        return entries.filter { !ids.contains($0.bookID) }
    }

    var backupBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    // MARK: - Connect

    func connect(to url: URL) async {
        lastError = nil
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        do {
            bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            lastError = "Couldn't remember that folder: \(error.localizedDescription)"
            return
        }
        folderName = url.lastPathComponent
        entries = []
        // An existing backup (e.g. from another device)? Read its library.json.
        if let bm = bookmark {
            let found = try? await Task.detached(priority: .userInitiated) { () throws -> BackupManifest in
                try BackupIO.withFolder(bm) { root in try BackupIO.readManifest(at: root.appendingPathComponent("library.json")) }
            }.value
            if let found { entries = found.entries; lastBackupAt = found.savedAt }
        }
        save()
    }

    /// Disconnecting is blocked while some books exist only in the backup.
    func disconnect() -> Bool {
        if library?.books.contains(where: { $0.isOffloaded }) == true {
            lastError = "Some books only exist in the backup. Download them to this device before disconnecting."
            return false
        }
        bookmark = nil
        folderName = nil
        entries = []
        lastBackupAt = nil
        save()
        return true
    }

    // MARK: - Back up

    func autoBackupSoon() {
        guard isConnected, autoBackup else { return }
        autoTask?.cancel()
        autoTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, !wifiOnly || onWiFi else { return }
            await backUpNow()
        }
    }

    func backUpNow(only: [Book]? = nil) async {
        guard let library, let bookmark, !isWorking else { return }
        isWorking = true
        progress = 0
        status = "Preparing…"
        lastError = nil
        defer { isWorking = false; status = "" }

        let todo = (only ?? library.books).filter { !$0.isOffloaded && entry(for: $0) == nil }
        let total = max(Int64(1), todo.reduce(Int64(0)) { $0 + max($1.fileSize ?? 1, 1) })
        var done: Int64 = 0

        for book in todo {
            status = "Uploading \(book.title)"
            let s = library.series(for: book)
            let seriesName = s?.name ?? "Unsorted"
            let src = LibraryPaths.url(for: book)
            let rel = NameParser.safeFolderName(seriesName) + "/" + src.lastPathComponent
            do {
                try await Task.detached(priority: .utility) {
                    try BackupIO.withFolder(bookmark) { root in
                        try BackupIO.copy(from: src, to: root.appendingPathComponent(rel))
                    }
                }.value
                entries.removeAll { $0.bookID == book.id || $0.relativePath == rel }
                entries.append(CloudEntry(bookID: book.id, relativePath: rel, fileName: src.lastPathComponent,
                                          bytes: book.fileSize ?? 0, backedUpAt: Date(), title: book.title,
                                          seriesName: seriesName, mode: s?.readingMode ?? .rightToLeft,
                                          number: book.number, pageCount: book.pageCount,
                                          currentPage: book.currentPage, format: book.format))
                save()
            } catch {
                lastError = "\(book.title): \(error.localizedDescription)"
            }
            done += max(book.fileSize ?? 1, 1)
            progress = Double(done) / Double(total)
        }
        await writeManifest()
    }

    /// library.json: series names, reading direction and progress for every backed-up book.
    private func writeManifest() async {
        guard let library, let bookmark else { return }
        status = "Saving library.json"
        for i in entries.indices {
            if let b = library.books.first(where: { $0.id == entries[i].bookID }) {
                entries[i].currentPage = b.currentPage
                entries[i].title = b.title
                if let s = library.series(for: b) {
                    entries[i].seriesName = s.name
                    entries[i].mode = s.readingMode
                }
            }
        }
        let manifest = BackupManifest(savedAt: Date(), entries: entries)
        do {
            try await Task.detached(priority: .utility) {
                try BackupIO.withFolder(bookmark) { root in
                    try BackupIO.writeManifest(manifest, to: root.appendingPathComponent("library.json"))
                }
            }.value
            lastBackupAt = Date()
        } catch {
            lastError = "Couldn't save library.json: \(error.localizedDescription)"
        }
        save()
    }

    // MARK: - Offload / download / restore

    func offload(_ books: [Book]) async {
        let need = books.filter { entry(for: $0) == nil && !$0.isOffloaded }
        if !need.isEmpty { await backUpNow(only: need) }
        for b in books where entry(for: b) != nil && !b.isOffloaded {
            library?.offload(b.id)
        }
    }

    func download(_ book: Book) async throws {
        guard let bookmark, let e = entry(for: book) else {
            throw MangaError.unreadable("This book isn't in your backup.")
        }
        isWorking = true
        status = "Downloading \(book.title)"
        defer { isWorking = false; status = "" }
        let dest = LibraryPaths.url(for: book)
        let rel = e.relativePath
        try await Task.detached(priority: .userInitiated) {
            try BackupIO.withFolder(bookmark) { root in
                try BackupIO.copy(from: root.appendingPathComponent(rel), to: dest)
            }
        }.value
        library?.setOffloaded(book.id, false)
    }

    func restore(_ e: CloudEntry) async throws {
        guard let bookmark, let library else { return }
        isWorking = true
        status = "Restoring \(e.title)"
        defer { isWorking = false; status = "" }
        let folder = NameParser.safeFolderName(e.seriesName)
        var name = e.fileName
        var dest = LibraryPaths.root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (e.fileName as NSString).deletingPathExtension
            let ext = (e.fileName as NSString).pathExtension
            name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            dest = dest.deletingLastPathComponent().appendingPathComponent(name)
            n += 1
        }
        let rel = e.relativePath
        let target = dest
        try await Task.detached(priority: .userInitiated) {
            try BackupIO.withFolder(bookmark) { root in
                try BackupIO.copy(from: root.appendingPathComponent(rel), to: target)
            }
        }.value
        library.restoreBook(from: e, relativePath: folder + "/" + name, fileSize: FileSize.of(dest))
    }

    /// Delete the backup copy too (used by "Delete everywhere").
    func deleteFromBackup(_ bookID: UUID) {
        guard let bookmark, let e = entries.first(where: { $0.bookID == bookID }) else { return }
        let rel = e.relativePath
        entries.removeAll { $0.bookID == bookID }
        save()
        Task.detached {
            try? BackupIO.withFolder(bookmark) { root in BackupIO.remove(root.appendingPathComponent(rel)) }
        }
        Task { await writeManifest() }
    }

    // MARK: - Persistence

    private struct State: Codable {
        var bookmark: Data?
        var folderName: String?
        var lastBackupAt: Date?
        var autoBackup: Bool
        var wifiOnly: Bool
        var entries: [CloudEntry]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        // Entries first: the two toggles below save the file when they change.
        bookmark = s.bookmark
        folderName = s.folderName
        lastBackupAt = s.lastBackupAt
        entries = s.entries
        autoBackup = s.autoBackup
        wifiOnly = s.wifiOnly
    }

    private func save() {
        let s = State(bookmark: bookmark, folderName: folderName, lastBackupAt: lastBackupAt,
                      autoBackup: autoBackup, wifiOnly: wifiOnly, entries: entries)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.stateURL, options: .atomic) }
    }
}
