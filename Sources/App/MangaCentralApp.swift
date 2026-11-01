import SwiftUI

@main
struct MangaCentralApp: App {
    @State private var library: LibraryStore
    @State private var app: AppState
    @State private var downloads: DownloadManager
    @State private var browser: BrowserModel
    @State private var settings: AppSettings
    @State private var sites: SitesStore
    @State private var cloud: CloudBackup
    @State private var social: SocialStore

    init() {
        let library = LibraryStore()
        let app = AppState()
        let downloads = DownloadManager()
        let browser = BrowserModel()
        let cloud = CloudBackup()
        let social = SocialStore()

        app.library = library
        downloads.library = library
        downloads.browser = browser
        browser.downloads = downloads
        cloud.library = library
        social.library = library
        library.onBooksAdded = { [weak cloud] in cloud?.autoBackupSoon() }

        _library = State(initialValue: library)
        _app = State(initialValue: app)
        _downloads = State(initialValue: downloads)
        _browser = State(initialValue: browser)
        _settings = State(initialValue: AppSettings())
        _sites = State(initialValue: SitesStore())
        _cloud = State(initialValue: cloud)
        _social = State(initialValue: social)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(app)
                .environment(downloads)
                .environment(browser)
                .environment(settings)
                .environment(sites)
                .environment(cloud)
                .environment(social)
                .tint(settings.accent.color)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}

enum AppTab: Hashable {
    case library, browse, downloads, cloud, friends
}

struct ReaderRequest: Identifiable {
    let id: UUID
}

/// App-wide navigation: which tab is showing and which book is open.
@MainActor
@Observable
final class AppState {
    var tab: AppTab = .library
    var reader: ReaderRequest?
    /// A series to show in the Library tab (set from other tabs).
    var openSeries: UUID?
    /// An offloaded book waiting on "Download from backup?".
    var pendingDownload: UUID?

    @ObservationIgnored weak var library: LibraryStore?

    func read(_ bookID: UUID) {
        if library?.books.first(where: { $0.id == bookID })?.isOffloaded == true {
            pendingDownload = bookID
        } else {
            reader = ReaderRequest(id: bookID)
        }
    }
}

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads
    @Environment(CloudBackup.self) private var cloud
    @Environment(SitesStore.self) private var sites
    @Environment(AppSettings.self) private var settings
    @State private var downloadError: String?

    var body: some View {
        @Bindable var app = app
        @Bindable var downloads = downloads
        TabView(selection: $app.tab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            BrowseView()
                .tabItem { Label("Browse", systemImage: "globe") }
                .tag(AppTab.browse)
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(downloads.activeCount)
                .tag(AppTab.downloads)
            CloudView()
                .tabItem { Label("Cloud", systemImage: "icloud") }
                .badge(cloud.isConnected && !cloud.isWorking ? cloud.pending.count : 0)
                .tag(AppTab.cloud)
            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2") }
                .tag(AppTab.friends)
        }
        .fullScreenCover(item: $app.reader) { request in
            ReaderView(bookID: request.id)
                .environment(library)
                .environment(app)
                .tint(settings.accent.color)
        }
        .sheet(item: $downloads.pendingSave) { item in
            SaveToLibrarySheet(item: item)
                .environment(library)
                .environment(downloads)
                .tint(settings.accent.color)
        }
        .alert(pendingTitle, isPresented: Binding(get: { app.pendingDownload != nil }, set: { if !$0 { app.pendingDownload = nil } })) {
            Button("Download") {
                guard let id = app.pendingDownload, let book = library.books.first(where: { $0.id == id }) else { return }
                app.pendingDownload = nil
                Task {
                    do {
                        try await cloud.download(book)
                        app.reader = ReaderRequest(id: id)
                    } catch {
                        downloadError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { app.pendingDownload = nil }
        } message: {
            Text(cloud.isConnected
                 ? "This book is stored in your backup folder. Download it to this device to read."
                 : "This book was offloaded, but no backup folder is connected. Connect it in the Cloud tab first.")
        }
        .alert("Couldn't download", isPresented: Binding(get: { downloadError != nil }, set: { if !$0 { downloadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    private var pendingTitle: String {
        let title = app.pendingDownload.flatMap { id in library.books.first { $0.id == id }?.title } ?? "this book"
        return "Download \(title)?"
    }
}
