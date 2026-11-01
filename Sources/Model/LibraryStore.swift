import Foundation
import Observation
import UIKit

/// The whole library: series, books, reading progress. Saved as JSON.
@MainActor
@Observable
final class LibraryStore {
    var series: [Series] = []
    var books: [Book] = []
    var webReads: [WebRead] = []

    /// Called after books are added (used for automatic backup).
    @ObservationIgnored var onBooksAdded: (() -> Void)?
    private static let webReadsURL = LibraryPaths.documents.appendingPathComponent("webreads.json")

    var isImporting = false
    var importStatus: String?
    var alertMessage: String?

    init() {
        load()
        if let data = try? Data(contentsOf: Self.webReadsURL),
           let saved = try? JSONDecoder().decode([WebRead].self, from: data) {
            webReads = saved
        }
    }

    private struct Snapshot: Codable {
        var series: [Series]
        var books: [Book]
    }

    private func load() {
        guard let data = try? Data(contentsOf: LibraryPaths.index) else { return }
        do {
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            series = snap.series
            books = snap.books
            // Backfill sizes for books imported before Phase 2.
            var changed = false
            for i in books.indices where books[i].fileSize == nil {
                books[i].fileSize = FileSize.of(LibraryPaths.url(for: books[i]))
                changed = true
            }
            if changed { save() }
        } catch {
            alertMessage = "Couldn't read the library index: \(error.localizedDescription)"
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(Snapshot(series: series, books: books))
            try data.write(to: LibraryPaths.index, options: .atomic)
        } catch {
            alertMessage = "Couldn't save the library: \(error.localizedDescription)"
        }
    }

    // MARK: - Queries

    func books(in seriesID: UUID) -> [Book] {
        books.filter { $0.seriesID == seriesID }.sorted { a, b in
            if let x = a.number, let y = b.number, x != y { return x < y }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    func series(for book: Book) -> Series? {
        series.first { $0.id == book.seriesID }
    }

    func nextBook(after book: Book) -> Book? {
        let list = books(in: book.seriesID)
        guard let i = list.firstIndex(where: { $0.id == book.id }), i + 1 < list.count else { return nil }
        return list[i + 1]
    }

    var continueReading: [Book] {
        books.filter { $0.lastReadAt != nil && !$0.isFinished }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
    }

    /// Bytes stored on this device (offloaded books don't count).
    var totalBytes: Int64 {
        books.filter { !$0.isOffloaded }.reduce(0) { $0 + ($1.fileSize ?? 0) }
    }

    // MARK: - Reading on the web

    func saveWebRead(_ w: WebRead) {
        var w = w
        w.updatedAt = Date()
        if let i = webReads.firstIndex(where: { $0.id == w.id }) { webReads[i] = w } else { webReads.append(w) }
        saveWebReads()
    }

    func stepWebRead(_ id: UUID, by delta: Int) {
        guard let i = webReads.firstIndex(where: { $0.id == id }) else { return }
        var c = max(0, webReads[i].chapter + delta)
        if let t = webReads[i].total { c = min(t, c) }
        webReads[i].chapter = c
        webReads[i].updatedAt = Date()
        saveWebReads()
    }

    func deleteWebRead(_ id: UUID) {
        webReads.removeAll { $0.id == id }
        saveWebReads()
    }

    private func saveWebReads() {
        if let data = try? JSONEncoder().encode(webReads) { try? data.write(to: Self.webReadsURL, options: .atomic) }
    }

    // MARK: - Backup support (Phase 3)

    /// Removes the local file but keeps the entry, cover and progress.
    func offload(_ id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: LibraryPaths.url(for: books[i]))
        books[i].offloaded = true
        save()
    }

    func setOffloaded(_ id: UUID, _ value: Bool) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].offloaded = value
        save()
    }

    /// Re-creates a book from a backup entry after its file was copied back.
    func restoreBook(from e: CloudEntry, relativePath: String, fileSize: Int64) {
        guard !books.contains(where: { $0.id == e.bookID }) else { return }
        let sid = seriesID(named: e.seriesName, mode: e.mode)
        books.append(Book(id: e.bookID, seriesID: sid, title: e.title, relativePath: relativePath,
                          format: e.format, number: e.number, pageCount: e.pageCount,
                          currentPage: e.currentPage, addedAt: Date(),
                          lastReadAt: e.currentPage > 0 ? Date() : nil, fileSize: fileSize))
        save()
    }

    var allTags: [String] {
        Array(Set(series.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func lastActivity(_ s: Series) -> Date {
        let reads = books.filter { $0.seriesID == s.id }.compactMap(\.lastReadAt)
        return reads.max() ?? s.addedAt
    }

    // MARK: - Reading progress

    func markOpened(_ id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].lastReadAt = Date()
        save()
    }

    func updateProgress(_ id: UUID, page: Int, pageCount: Int) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        if pageCount > 0 { books[i].pageCount = pageCount }
        books[i].currentPage = max(0, page)
        books[i].lastReadAt = Date()
        save()
    }

    func setFinished(_ id: UUID, _ finished: Bool) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        if finished {
            books[i].currentPage = max(0, books[i].pageCount - 1)
            books[i].lastReadAt = Date()
        } else {
            books[i].currentPage = 0
            books[i].lastReadAt = nil
        }
        save()
    }

    // MARK: - Organising

    func renameBook(_ id: UUID, to title: String) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].title = title
        save()
    }

    func updateSeries(_ id: UUID, _ change: (inout Series) -> Void) {
        guard let i = series.firstIndex(where: { $0.id == id }) else { return }
        change(&series[i])
        save()
    }

    func move(_ bookID: UUID, toSeries seriesID: UUID) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].seriesID = seriesID
        pruneEmptySeries()
        save()
    }

    func moveToNewSeries(_ bookID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        move(bookID, toSeries: seriesID(named: trimmed))
    }

    func deleteBook(_ id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: LibraryPaths.url(for: books[i]))
        CoverCache.remove(id)
        books.remove(at: i)
        pruneEmptySeries()
        save()
    }

    func deleteSeries(_ id: UUID) {
        for b in books where b.seriesID == id {
            try? FileManager.default.removeItem(at: LibraryPaths.url(for: b))
            CoverCache.remove(b.id)
        }
        books.removeAll { $0.seriesID == id }
        series.removeAll { $0.id == id }
        save()
    }

    private func pruneEmptySeries() {
        let used = Set(books.map(\.seriesID))
        series.removeAll { !used.contains($0.id) }
    }

    func seriesID(named name: String, mode: ReadingMode = .rightToLeft) -> UUID {
        if let existing = series.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            return existing.id
        }
        let s = Series(name: name, readingMode: mode)
        series.append(s)
        return s.id
    }

    // MARK: - Import

    /// Adds a file the browser downloaded. Throws with a readable message on failure.
    func importDownloaded(tempURL: URL, seriesName: String, mode: ReadingMode, sourceURL: String) async throws -> Book {
        let ext = tempURL.pathExtension.lowercased()
        let format: BookFormat
        switch ext {
        case "pdf": format = .pdf
        case "cbz", "zip": format = .cbz
        case "cbr", "rar", "cb7":
            throw MangaError.unreadable("CBR/RAR files aren't supported yet, so this download can't be opened.")
        default:
            throw MangaError.unreadable("This file type (.\(ext.isEmpty ? "unknown" : ext)) can't be read. MangaCentral reads CBZ, ZIP and PDF.")
        }
        let name = seriesName.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = ImportCandidate(source: tempURL, format: format, seriesHint: nil,
                                        seriesOverride: name.isEmpty ? nil : name)
        let file = try await Task.detached(priority: .userInitiated) {
            try Importer.process(candidate)
        }.value
        let sid = seriesID(named: file.seriesName, mode: mode)
        let book = Book(seriesID: sid,
                        title: file.title,
                        relativePath: file.relativePath,
                        format: file.format,
                        number: file.number,
                        pageCount: file.pageCount,
                        fileSize: file.fileSize,
                        sourceURL: sourceURL)
        books.append(book)
        save()
        onBooksAdded?()
        return book
    }

    func isNewSeriesName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !series.contains { $0.name.compare(n, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        importStatus = "Preparing…"

        let (imported, problems): ([ImportedFile], [String]) = await Task.detached(priority: .userInitiated) {
            var accessed: [URL] = []
            for u in urls where u.startAccessingSecurityScopedResource() { accessed.append(u) }
            defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }

            var candidates: [ImportCandidate] = []
            var problems: [String] = []
            for u in urls {
                Importer.collect(u, seriesHint: nil, into: &candidates, skipped: &problems)
            }

            var done: [ImportedFile] = []
            for (n, c) in candidates.enumerated() {
                let status = "Importing \(n + 1) of \(candidates.count)…\n\(c.source.lastPathComponent)"
                await MainActor.run { self.importStatus = status }
                do {
                    done.append(try Importer.process(c))
                } catch {
                    problems.append("\(c.source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (done, problems)
        }.value

        defer { if !imported.isEmpty { onBooksAdded?() } }
        for f in imported {
            let sid = seriesID(named: f.seriesName)
            books.append(Book(seriesID: sid,
                              title: f.title,
                              relativePath: f.relativePath,
                              format: f.format,
                              number: f.number,
                              pageCount: f.pageCount,
                              fileSize: f.fileSize))
        }
        save()
        isImporting = false
        importStatus = nil

        if !problems.isEmpty || imported.isEmpty {
            var msg = "Imported \(imported.count) item\(imported.count == 1 ? "" : "s")."
            if !problems.isEmpty {
                msg += "\n\nSkipped:\n" + problems.prefix(12).joined(separator: "\n")
                if problems.count > 12 { msg += "\n…and \(problems.count - 12) more" }
            }
            alertMessage = msg
        }
    }
}

/// Small cover thumbnails, cached in memory and on disk.
enum CoverCache {
    private static let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    static func cover(for book: Book) async -> UIImage? {
        let key = book.id.uuidString as NSString
        if let hit = memory.object(forKey: key) { return hit }
        let file = LibraryPaths.covers.appendingPathComponent(book.id.uuidString + ".jpg")
        let url = LibraryPaths.url(for: book)
        let format = book.format
        let image: UIImage? = await Task.detached(priority: .utility) {
            if let d = try? Data(contentsOf: file), let img = UIImage(data: d) { return img }
            guard let src = try? PageSourceFactory.open(url: url, format: format),
                  let img = src.image(at: 0, target: ImageTarget(width: 360, height: 540)) else { return nil }
            if let jpg = img.jpegData(compressionQuality: 0.8) { try? jpg.write(to: file) }
            return img
        }.value
        if let image { memory.setObject(image, forKey: key) }
        return image
    }

    static func remove(_ id: UUID) {
        memory.removeObject(forKey: id.uuidString as NSString)
        try? FileManager.default.removeItem(at: LibraryPaths.covers.appendingPathComponent(id.uuidString + ".jpg"))
    }
}
