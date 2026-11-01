import SwiftUI
import WebKit

/// Owns the one in-app web view, plus bookmarks and history.
@MainActor
@Observable
final class BrowserModel {
    let webView: WKWebView

    var addressText = ""
    var isEditingAddress = false
    var currentURL: URL?
    var title = ""
    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var showingStartPage = true
    var currentMIMEType: String?
    var loadError: String?

    var bookmarks: [Bookmark] = []
    var history: [HistoryEntry] = []

    @ObservationIgnored weak var downloads: DownloadManager?
    @ObservationIgnored private let coordinator = BrowserCoordinator()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private static let storeURL = LibraryPaths.documents.appendingPathComponent("browser.json")

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default() // keeps cookies, so site logins persist
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        coordinator.model = self
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                let p = wv.estimatedProgress
                Task { @MainActor in self?.progress = p }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                let v = wv.isLoading
                Task { @MainActor in self?.isLoading = v }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                let v = wv.canGoBack
                Task { @MainActor in self?.canGoBack = v }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                let v = wv.canGoForward
                Task { @MainActor in self?.canGoForward = v }
            },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                let t = wv.title ?? ""
                Task { @MainActor in self?.title = t }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                let u = wv.url
                Task { @MainActor in self?.urlChanged(u) }
            }
        ]
        load()
    }

    // MARK: - Navigation

    /// Typed text → web address, or a web search if it doesn't look like one.
    func go(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var url: URL?
        if t.contains(" ") || !t.contains(".") {
            let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
            url = URL(string: "https://duckduckgo.com/?q=\(q)")
        } else if t.lowercased().hasPrefix("https://") {
            url = URL(string: t)
        } else if t.lowercased().hasPrefix("http://") {
            // iOS blocks plain http by default; try the secure version.
            url = URL(string: "https://" + t.dropFirst("http://".count))
        } else {
            url = URL(string: "https://" + t)
        }
        if let url { open(url) }
    }

    func open(_ url: URL) {
        loadError = nil
        showingStartPage = false
        webView.load(URLRequest(url: url))
    }

    func open(_ string: String) {
        if let url = URL(string: string) { open(url) }
    }

    var canGoBackOrHome: Bool { showingStartPage ? webView.url != nil : true }

    func goBack() {
        if showingStartPage {
            if webView.url != nil { showingStartPage = false }
        } else if webView.canGoBack {
            webView.goBack()
        } else {
            showingStartPage = true
        }
    }

    func goForward() {
        if showingStartPage, webView.url != nil { showingStartPage = false; return }
        webView.goForward()
    }

    func reload() { loadError = nil; webView.reload() }
    func stop() { webView.stopLoading() }
    func showStartPage() { showingStartPage = true }

    var isPDF: Bool { currentMIMEType?.lowercased().contains("pdf") == true }

    /// Save the PDF currently on screen into the library.
    func saveCurrentPDF() {
        guard let url = webView.url else { return }
        Task {
            let download = await webView.startDownload(using: URLRequest(url: url))
            downloads?.begin(download, sourceURL: url)
        }
    }

    // MARK: - Bookmarks & history

    var isBookmarked: Bool {
        guard let u = currentURL?.absoluteString else { return false }
        return bookmarks.contains { $0.url == u }
    }

    func toggleBookmark() {
        guard let u = currentURL?.absoluteString else { return }
        if let i = bookmarks.firstIndex(where: { $0.url == u }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.append(Bookmark(title: title.isEmpty ? (currentURL?.host ?? u) : title, url: u))
        }
        save()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // Called by the coordinator.
    func didFinishLoad() {
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        let u = url.absoluteString
        history.removeAll { $0.url == u }
        history.insert(HistoryEntry(title: webView.title?.isEmpty == false ? webView.title! : (url.host ?? u), url: u), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        save()
    }

    private func urlChanged(_ url: URL?) {
        currentURL = url
        if !isEditingAddress { addressText = url?.absoluteString ?? "" }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var bookmarks: [Bookmark]
        var history: [HistoryEntry]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        bookmarks = snap.bookmarks
        history = snap.history
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Snapshot(bookmarks: bookmarks, history: history)) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}

/// Decides which responses are downloads instead of pages.
enum DownloadRules {
    static let comicExtensions: Set<String> = ["cbz", "zip", "cbr", "rar", "cb7"]

    static func shouldDownload(_ response: URLResponse, canShow: Bool, isMainFrame: Bool) -> Bool {
        guard isMainFrame else { return false }
        let ext = response.url?.pathExtension.lowercased() ?? ""
        let suggestedExt = ((response.suggestedFilename ?? "") as NSString).pathExtension.lowercased()
        let mime = response.mimeType?.lowercased() ?? ""
        let disposition = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()

        if comicExtensions.contains(ext) || comicExtensions.contains(suggestedExt) { return true }
        if mime.contains("zip") || mime.contains("comicbook") || mime.contains("rar") { return true }
        if disposition.hasPrefix("attachment") { return true }
        if !canShow { return true }
        return false // PDFs and normal pages display; PDFs get a Save button.
    }
}

/// WebKit's delegate callbacks, forwarded to the model.
final class BrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var model: BrowserModel?

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            // mailto:, tel:, app links: hand off to iOS.
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let download = DownloadRules.shouldDownload(navigationResponse.response,
                                                    canShow: navigationResponse.canShowMIMEType,
                                                    isMainFrame: navigationResponse.isForMainFrame)
        if !download && navigationResponse.isForMainFrame {
            let mime = navigationResponse.response.mimeType
            MainActor.assumeIsolated { model?.currentMIMEType = mime }
        }
        decisionHandler(download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let url = navigationAction.request.url
        MainActor.assumeIsolated { model?.downloads?.begin(download, sourceURL: url) }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let url = navigationResponse.response.url
        MainActor.assumeIsolated { model?.downloads?.begin(download, sourceURL: url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { model?.didFinishLoad() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        // Ignore "cancelled" and "frame load interrupted" (normal when a link becomes a download).
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        let message = ns.localizedDescription
        MainActor.assumeIsolated { model?.loadError = message }
    }

    /// Links that open a new window (target="_blank") load in the same view.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
