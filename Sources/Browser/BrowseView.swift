import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowseView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(SitesStore.self) private var sites
    @Environment(AppState.self) private var app
    @FocusState private var addressFocused: Bool
    @State private var showList = false
    @State private var showSites = false

    var body: some View {
        @Bindable var browser = browser
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                if browser.isLoading && !browser.showingStartPage {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                        
                } else {
                    Divider()
                }
                if !browser.bookmarks.isEmpty {
                    bookmarkBar
                    Divider()
                }
                ZStack {
                    WebView(webView: browser.webView)
                        .opacity(browser.showingStartPage ? 0 : 1)
                    if browser.showingStartPage {
                        StartPageView { showSites = true }
                    } else if let error = browser.loadError {
                        errorBanner(error)
                    }
                }
                Divider()
                bottomBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showList) {
                BookmarksHistorySheet()
                    .environment(browser)
            }
            .sheet(isPresented: $showSites) {
                SitesView()
                    .environment(sites)
                    .environment(browser)
            }
            .onAppear {
                switch app.testAction {
                case "browse-sites": showSites = true
                case "browse-load": browser.go("example.com")
                default: break
                }
                app.testAction = nil
            }
            .onChange(of: addressFocused) { _, focused in
                browser.isEditingAddress = focused
                if !focused { browser.addressText = browser.currentURL?.absoluteString ?? "" }
            }
        }
    }

    private var addressBar: some View {
        @Bindable var browser = browser
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: browser.currentURL?.scheme == "https" && !browser.showingStartPage ? "lock.fill" : "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $browser.addressText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        browser.go(browser.addressText)
                        addressFocused = false
                    }
                if addressFocused && !browser.addressText.isEmpty {
                    Button { browser.addressText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear address")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())

            if addressFocused {
                Button("Cancel") { addressFocused = false }
            } else if browser.isLoading {
                Button { browser.stop() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Stop loading")
            } else {
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload")
                    .disabled(browser.showingStartPage)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bookmarkBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(browser.bookmarks) { b in
                    Button { browser.open(b.url) } label: {
                        Text(b.title)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!browser.canGoBackOrHome)
                .accessibilityLabel("Back")
            Spacer()
            Button { browser.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!(browser.canGoForward || (browser.showingStartPage && browser.webView.url != nil)))
                .accessibilityLabel("Forward")
            Spacer()
            if browser.isPDF && !browser.showingStartPage {
                Button { browser.saveCurrentPDF() } label: {
                    Label("Save PDF", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
            }
            Button { browser.toggleBookmark() } label: {
                Image(systemName: browser.isBookmarked ? "star.fill" : "star")
            }
            .disabled(browser.showingStartPage || browser.currentURL == nil)
            .accessibilityLabel(browser.isBookmarked ? "Remove bookmark" : "Bookmark this page")
            Spacer()
            Button { showList = true } label: { Image(systemName: "book") }
                .accessibilityLabel("Bookmarks and history")
            Spacer()
            Button { showSites = true } label: { Image(systemName: "square.grid.2x2") }
                .accessibilityLabel("Sites")
            Spacer()
            Button { browser.showStartPage() } label: { Image(systemName: "house") }
                .accessibilityLabel("Start page")
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle)
            Text("Couldn't load this page").font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try Again") { browser.reload() }.buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct StartPageView: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(SitesStore.self) private var sites
    var onOpenSites: () -> Void = {}
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Browse").font(.largeTitle.bold())
                    Spacer()
                    SettingsButton().font(.title3)
                }
                Button(action: onOpenSites) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sites").font(.headline)
                            Text("\(sites.sites.count) saved · \(sites.sites.count - sites.missingAddressCount) with addresses")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Label {
                    Text("Download links for CBZ, ZIP or PDF files ask where to file them, then save straight into your library for offline reading.")
                } icon: {
                    Image(systemName: "arrow.down.doc").foregroundStyle(.tint)
                }
                .font(.subheadline)
                .padding(12)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                section("Bookmarks", empty: "Tap the star on any page to bookmark it.",
                        items: browser.bookmarks.map { ($0.title, $0.url) })
                section("Recently Visited", empty: nil,
                        items: browser.history.prefix(8).map { ($0.title, $0.url) })
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func section(_ title: String, empty: String?, items: [(String, String)]) -> some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold())
                if items.isEmpty, let empty {
                    Text(empty).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            Button { browser.open(item.1) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.0).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(URL(string: item.1)?.host ?? item.1)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct BookmarksHistorySheet: View {
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Bookmarks") {
                    if browser.bookmarks.isEmpty {
                        Text("No bookmarks yet").foregroundStyle(.secondary)
                    }
                    ForEach(browser.bookmarks) { b in
                        row(b.title, b.url)
                    }
                    .onDelete { browser.removeBookmarks(at: $0) }
                }
                Section("History") {
                    if browser.history.isEmpty {
                        Text("Nothing here yet").foregroundStyle(.secondary)
                    }
                    ForEach(browser.history.prefix(100)) { h in
                        row(h.title, h.url)
                    }
                    if !browser.history.isEmpty {
                        Button("Clear History", role: .destructive) { browser.clearHistory() }
                    }
                }
            }
            .navigationTitle("Bookmarks & History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ title: String, _ url: String) -> some View {
        Button {
            browser.open(url)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}
