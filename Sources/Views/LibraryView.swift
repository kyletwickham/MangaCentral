import SwiftUI
import UniformTypeIdentifiers

enum SeriesSort: String, CaseIterable, Identifiable {
    case recent = "Recently read"
    case title = "Title"
    case added = "Recently added"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(SitesStore.self) private var sites
    @AppStorage("seriesSort") private var sort: SeriesSort = .recent
    @State private var showImporter = false
    @State private var search = ""
    @State private var filter: String?          // a tag, or LibraryView.favorites
    @State private var seriesToDelete: Series?
    @State private var editingWebRead: WebRead?
    @State private var addingWebRead = false
    @State private var path: [UUID] = []

    private static let favorites = "__favorites__"
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.books.isEmpty && store.webReads.isEmpty {
                    emptyState
                } else {
                    libraryContent
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: UUID.self) { id in
                SeriesDetailView(seriesID: id) { app.read($0.id) }
            }
            .searchable(text: $search, prompt: "Search titles or tags")
            .onChange(of: app.openSeries) { _, id in
                if let id { path = [id]; app.openSeries = nil }
            }
            .onAppear {
                if let id = app.openSeries { path = [id]; app.openSeries = nil }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    SettingsButton()
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(SeriesSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showImporter = true } label: { Label("Import Files or Folders", systemImage: "square.and.arrow.down") }
                        Button { addingWebRead = true } label: { Label("Track a Title You Read Online", systemImage: "globe") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(item: $editingWebRead) { w in
            WebReadEditor(webRead: w, isNew: false).environment(store).environment(sites)
        }
        .sheet(isPresented: $addingWebRead) {
            WebReadEditor(webRead: WebRead(title: "", siteName: "", chapter: 1), isNew: true).environment(store).environment(sites)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder, .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await store.importURLs(urls) }
            case .failure(let error):
                store.alertMessage = error.localizedDescription
            }
        }
        .overlay {
            if store.isImporting { importingHUD }
        }
        .alert("Import",
               isPresented: Binding(get: { store.alertMessage != nil },
                                    set: { if !$0 { store.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
        .confirmationDialog("Delete \(seriesToDelete?.name ?? "series")?",
                            isPresented: Binding(get: { seriesToDelete != nil },
                                                 set: { if !$0 { seriesToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete series and its files", role: .destructive) {
                if let s = seriesToDelete { store.deleteSeries(s.id) }
                seriesToDelete = nil
            }
        }
    }

    // MARK: - Sections

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let continuing = store.continueReading
                if search.isEmpty && !continuing.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continue Reading")
                            .font(.title3.bold())
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(continuing.prefix(15)) { book in
                                    Button { app.read(book.id) } label: {
                                        BookCard(book: book, seriesName: store.series(for: book)?.name ?? "")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                if search.isEmpty && !store.webReads.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reading on the Web")
                            .font(.title3.bold())
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(store.webReads.sorted { $0.updatedAt > $1.updatedAt }) { w in
                                    WebReadCard(webRead: w) { editingWebRead = w }
                                }
                                Button { addingWebRead = true } label: {
                                    Label("Track another", systemImage: "plus")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 150, height: 120)
                                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                filterChips

                let list = visibleSeries
                if list.isEmpty {
                    if !search.isEmpty { ContentUnavailableView.search(text: search) }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(list) { s in
                            NavigationLink(value: s.id) {
                                SeriesCard(series: s)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    store.updateSeries(s.id) { $0.isFavorite.toggle() }
                                } label: {
                                    Label(s.isFavorite ? "Unfavorite" : "Favorite",
                                          systemImage: s.isFavorite ? "star.slash" : "star")
                                }
                                Button(role: .destructive) { seriesToDelete = s } label: {
                                    Label("Delete Series", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", value: nil)
                if store.series.contains(where: \.isFavorite) {
                    chip("★ Favorites", value: Self.favorites)
                }
                ForEach(store.allTags, id: \.self) { tag in
                    chip(tag, value: tag)
                }
            }
            .padding(.horizontal)
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        let selected = filter == value
        return Button { filter = value } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
                .fontWeight(selected ? .semibold : .regular)
        }
        .buttonStyle(.plain)
    }

    private var visibleSeries: [Series] {
        var list = store.series
        if let f = filter {
            list = list.filter { f == Self.favorites ? $0.isFavorite : $0.tags.contains(f) }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { s in
                s.name.localizedCaseInsensitiveContains(q)
                    || s.tags.contains { $0.localizedCaseInsensitiveContains(q) }
                    || store.books(in: s.id).contains { $0.title.localizedCaseInsensitiveContains(q) }
            }
        }
        switch sort {
        case .recent: list.sort { store.lastActivity($0) > store.lastActivity($1) }
        case .title: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .added: list.sort { $0.addedAt > $1.addedAt }
        }
        return list.filter(\.isFavorite) + list.filter { !$0.isFavorite }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Your shelf is empty", systemImage: "books.vertical")
        } description: {
            Text("Import CBZ, ZIP or PDF files, or folders of page images, from Files, iCloud Drive, Google Drive or Dropbox. Or use Browse to download them straight into your library.")
        } actions: {
            Button("Import Manga") { showImporter = true }
                .buttonStyle(.borderedProminent)
            Button("Open Browse") { app.tab = .browse }
            Button("Track a Title You Read Online") { addingWebRead = true }
        }
    }

    private var importingHUD: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(store.importStatus ?? "Importing…")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(24)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
