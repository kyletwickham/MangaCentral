import SwiftUI
import WebKit

/// Tracks browser downloads and files finished ones into the library.
///
/// Flow: a link becomes a download → it starts right away and the
/// "Save to Library?" sheet opens → you pick a series → when the bytes
/// finish, the file is imported. Cancel in the sheet stops it and deletes it.
@MainActor
@Observable
final class DownloadManager {
    var items: [DownloadItem] = []
    /// Drives the Save to Library sheet.
    var pendingSave: DownloadItem?

    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored weak var browser: BrowserModel?

    @ObservationIgnored private let proxy = DownloadDelegateProxy()
    @ObservationIgnored private var itemForDownload: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var active: [UUID: WKDownload] = [:]
    @ObservationIgnored private var progressObservers: [UUID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var confirmQueue: [UUID] = []

    private static let storeURL = LibraryPaths.documents.appendingPathComponent("downloads.json")
    private static let tempRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        proxy.manager = self
        load()
    }

    var activeCount: Int {
        items.filter { $0.status == .downloading || $0.status == .saving || $0.status == .waiting }.count
    }

    var hasFinished: Bool {
        items.contains { $0.status == .done || $0.status == .failed }
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    // MARK: - Starting

    func begin(_ download: WKDownload, sourceURL: URL?, existingID: UUID? = nil) {
        download.delegate = proxy
        let id: UUID
        if let existingID, let i = index(existingID) {
            id = existingID
            items[i].status = .downloading
            items[i].progress = 0
            items[i].error = nil
        } else {
            let name = sourceURL?.lastPathComponent.removingPercentEncoding ?? sourceURL?.lastPathComponent ?? "download"
            let item = DownloadItem(url: sourceURL?.absoluteString ?? "",
                                    fileName: name.isEmpty ? "download" : name,
                                    seriesName: NameParser.parse(name, isFolder: false).series)
            items.insert(item, at: 0)
            id = item.id
            confirmQueue.append(id)
            presentNextIfNeeded()
        }
        itemForDownload[ObjectIdentifier(download)] = id
        active[id] = download
        progressObservers[id] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in self?.setProgress(id, f) }
        }
        save()
    }

    private func setProgress(_ id: UUID, _ value: Double) {
        guard let i = index(id), items[i].status == .downloading else { return }
        items[i].progress = value
    }

    // MARK: - Save sheet

    private func presentNextIfNeeded() {
        guard pendingSave == nil else { return }
        while let id = confirmQueue.first {
            confirmQueue.removeFirst()
            if let i = index(id), !items[i].confirmed {
                pendingSave = items[i]
                return
            }
        }
    }

    /// Re-open the sheet for a finished download still waiting on a series.
    func chooseSeries(_ id: UUID) {
        if pendingSave == nil, let i = index(id) { pendingSave = items[i] }
    }

    func confirm(_ id: UUID, seriesName: String, mode: ReadingMode) {
        pendingSave = nil
        if let i = index(id) {
            items[i].confirmed = true
            items[i].seriesName = seriesName
            items[i].mode = mode
            if items[i].status == .waiting { Task { await finalize(id) } }
            save()
        }
        scheduleNext()
    }

    func cancel(_ id: UUID) {
        pendingSave = nil
        if let d = active[id] { d.cancel { _ in } }
        cleanup(id)
        items.removeAll { $0.id == id }
        save()
        scheduleNext()
    }

    private func scheduleNext() {
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000) // let the sheet finish closing
            presentNextIfNeeded()
        }
    }

    // MARK: - WKDownload callbacks (via proxy)

    func destination(for download: WKDownload, response: URLResponse, suggestedFilename: String) -> URL? {
        guard let id = itemForDownload[ObjectIdentifier(download)], let i = index(id) else { return nil }
        var name = suggestedFilename.isEmpty ? (response.url?.lastPathComponent ?? "download") : suggestedFilename
        name = name.replacingOccurrences(of: "/", with: "-")
        if (name as NSString).pathExtension.isEmpty {
            let mime = response.mimeType?.lowercased() ?? ""
            if mime.contains("pdf") { name += ".pdf" }
            else if mime.contains("rar") { name += ".cbr" }
            else if mime.contains("zip") || mime.contains("comicbook") { name += ".cbz" }
        }
        let dir = Self.tempRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        items[i].fileName = name
        items[i].tempPath = dest.path
        if !items[i].confirmed {
            items[i].seriesName = NameParser.parse(name, isFolder: false).series
            if pendingSave?.id == id { pendingSave = items[i] }
        }
        return dest
    }

    func didFinish(_ download: WKDownload) {
        guard let id = itemForDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        active[id] = nil
        progressObservers[id] = nil
        guard let i = index(id) else { return }
        items[i].progress = 1
        if items[i].confirmed {
            Task { await finalize(id) }
        } else {
            items[i].status = .waiting
            save()
        }
    }

    func didFail(_ download: WKDownload, error: Error) {
        guard let id = itemForDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        active[id] = nil
        progressObservers[id] = nil
        guard let i = index(id) else { return }
        items[i].status = .failed
        items[i].error = error.localizedDescription
        save()
    }

    // MARK: - Filing into the library

    private func finalize(_ id: UUID) async {
        guard let i = index(id) else { return }
        items[i].status = .saving
        let item = items[i]
        guard let library, let path = item.tempPath, FileManager.default.fileExists(atPath: path) else {
            fail(id, "The downloaded file is missing. Tap Retry to download it again.")
            return
        }
        do {
            let book = try await library.importDownloaded(tempURL: URL(fileURLWithPath: path),
                                                          seriesName: item.seriesName,
                                                          mode: item.mode,
                                                          sourceURL: item.url)
            if let j = index(id) {
                items[j].status = .done
                items[j].bookID = book.id
                items[j].bytes = book.fileSize ?? 0
                items[j].error = nil
            }
            cleanup(id)
        } catch {
            fail(id, error.localizedDescription)
        }
        save()
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let i = index(id) else { return }
        items[i].status = .failed
        items[i].error = message
        save()
    }

    // MARK: - List actions

    func retry(_ id: UUID) {
        guard let i = index(id) else { return }
        // Downloaded fine but filing failed? Try filing again.
        if let path = items[i].tempPath, FileManager.default.fileExists(atPath: path), items[i].progress >= 1 {
            Task { await finalize(id) }
            return
        }
        guard let webView = browser?.webView, let url = URL(string: items[i].url) else {
            fail(id, "This download can't be retried. Open the page in Browse and tap the link again.")
            return
        }
        items[i].status = .downloading
        items[i].progress = 0
        items[i].error = nil
        Task {
            let download = await webView.startDownload(using: URLRequest(url: url))
            begin(download, sourceURL: url, existingID: id)
        }
    }

    func cancelActive(_ id: UUID) {
        if let d = active[id] { d.cancel { _ in } }
        cleanup(id)
        items.removeAll { $0.id == id }
        save()
    }

    func remove(_ id: UUID) {
        cleanup(id)
        items.removeAll { $0.id == id }
        save()
    }

    func clearFinished() {
        for item in items where item.status == .done || item.status == .failed { cleanup(item.id) }
        items.removeAll { $0.status == .done || $0.status == .failed }
        save()
    }

    private func cleanup(_ id: UUID) {
        active[id] = nil
        progressObservers[id] = nil
        try? FileManager.default.removeItem(at: Self.tempRoot.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = saved.map { item in
            var item = item
            if item.status == .downloading || item.status == .saving {
                item.status = .failed
                item.error = "Interrupted when the app closed. Tap Retry."
            }
            return item
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(items.prefix(300))) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}

/// WKDownloadDelegate needs an NSObject; this forwards to the manager.
final class DownloadDelegateProxy: NSObject, WKDownloadDelegate {
    weak var manager: DownloadManager?

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        if Thread.isMainThread {
            let url = MainActor.assumeIsolated {
                manager?.destination(for: download, response: response, suggestedFilename: suggestedFilename)
            }
            completionHandler(url)
        } else {
            DispatchQueue.main.async { [weak self] in
                let url = MainActor.assumeIsolated {
                    self?.manager?.destination(for: download, response: response, suggestedFilename: suggestedFilename)
                }
                completionHandler(url)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        onMain { [weak self] in self?.manager?.didFinish(download) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        onMain { [weak self] in self?.manager?.didFail(download, error: error) }
    }
}
