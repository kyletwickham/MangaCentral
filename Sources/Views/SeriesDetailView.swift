import SwiftUI

struct SeriesDetailView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(CloudBackup.self) private var cloud
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    let seriesID: UUID
    let onRead: (Book) -> Void

    private enum RenameTarget { case series, book(UUID) }

    @State private var renameTarget: RenameTarget = .series
    @State private var showRename = false
    @State private var renameText = ""
    @State private var newSeriesFor: Book?
    @State private var showNewSeries = false
    @State private var newSeriesName = ""
    @State private var newTag = ""
    @State private var confirmDelete = false

    var body: some View {
        if let s = store.series.first(where: { $0.id == seriesID }) {
            content(s)
        } else {
            ContentUnavailableView("Series removed", systemImage: "books.vertical")
        }
    }

    private func content(_ s: Series) -> some View {
        let books = store.books(in: s.id)
        let next = books.first { !$0.isFinished } ?? books.first
        return List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    CoverView(book: books.first)
                        .frame(width: 110)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.name).font(.title3.bold())
                        Text("\(books.count) items · \(books.filter(\.isFinished).count) read")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let next {
                            Button { onRead(next) } label: {
                                Label(continueLabel(next), systemImage: "book.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section("Volumes & Chapters") {
                ForEach(books) { b in
                    Button { onRead(b) } label: { BookRow(book: b) }
                        .buttonStyle(.plain)
                        .contextMenu { bookMenu(b, current: s) }
                        .swipeActions {
                            Button(role: .destructive) { store.deleteBook(b.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }

            Section("Reading") {
                Picker("Reading mode", selection: binding(\.readingMode, fallback: .rightToLeft)) {
                    ForEach(ReadingMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Two-page spreads in landscape", isOn: binding(\.twoPageSpreads, fallback: false))
                Toggle("Favorite", isOn: binding(\.isFavorite, fallback: false))
                if social.me != nil {
                    Toggle("Hide from friends", isOn: Binding(
                        get: { store.series.first { $0.id == seriesID }?.hiddenFromFriends ?? false },
                        set: { v in store.updateSeries(seriesID) { $0.hiddenFromFriends = v } }))
                }
            }

            SeriesFriendsSection(series: s)

            Section {
                ForEach(s.tags, id: \.self) { Text($0) }
                    .onDelete { offsets in
                        store.updateSeries(s.id) { $0.tags.remove(atOffsets: offsets) }
                    }
                HStack {
                    TextField("Add a tag (e.g. Owned, Romance)", text: $newTag)
                        .onSubmit { addTag(to: s) }
                    Button("Add") { addTag(to: s) }
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Tags")
            } footer: {
                Text("Tags work like shelves. Filter by them on the Library screen.")
            }

            Section {
                Button("Delete Series", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(s.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename") {
                    renameText = s.name
                    renameTarget = .series
                    showRename = true
                }
            }
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Move to New Series", isPresented: $showNewSeries) {
            TextField("Series name", text: $newSeriesName)
            Button("Move") {
                if let b = newSeriesFor { store.moveToNewSeries(b.id, name: newSeriesName) }
                newSeriesFor = nil
            }
            Button("Cancel", role: .cancel) { newSeriesFor = nil }
        }
        .confirmationDialog("Delete \(s.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete series and its files", role: .destructive) {
                store.deleteSeries(s.id)
                dismiss()
            }
        } message: {
            Text("This removes every file in this series from the app.")
        }
    }

    @ViewBuilder
    private func bookMenu(_ b: Book, current: Series) -> some View {
        Button { store.setFinished(b.id, !b.isFinished) } label: {
            Label(b.isFinished ? "Mark as Unread" : "Mark as Read",
                  systemImage: b.isFinished ? "circle" : "checkmark.circle")
        }
        Button {
            renameText = b.title
            renameTarget = .book(b.id)
            showRename = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Menu {
            ForEach(store.series
                .filter { $0.id != current.id }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { other in
                Button(other.name) { store.move(b.id, toSeries: other.id) }
            }
            Divider()
            Button {
                newSeriesName = ""
                newSeriesFor = b
                showNewSeries = true
            } label: {
                Label("New Series…", systemImage: "plus")
            }
        } label: {
            Label("Move to Series", systemImage: "folder")
        }
        if cloud.isConnected {
            if b.isOffloaded {
                Button {
                    Task { try? await cloud.download(b) }
                } label: { Label("Download from Backup", systemImage: "icloud.and.arrow.down") }
            } else if cloud.entry(for: b) != nil {
                Button {
                    Task { await cloud.offload([b]) }
                } label: { Label("Offload (Keep in Backup)", systemImage: "icloud.and.arrow.up") }
            } else {
                Button {
                    Task { await cloud.backUpNow(only: [b]) }
                } label: { Label("Back Up Now", systemImage: "arrow.clockwise.icloud") }
            }
        }
        Button(role: .destructive) { store.deleteBook(b.id) } label: {
            Label(cloud.entry(for: b) != nil ? "Delete from Device (Keep Backup)" : "Delete", systemImage: "trash")
        }
        if cloud.entry(for: b) != nil {
            Button(role: .destructive) {
                cloud.deleteFromBackup(b.id)
                store.deleteBook(b.id)
            } label: {
                Label("Delete Everywhere", systemImage: "trash.slash")
            }
        }
    }

    // MARK: - Helpers

    private func binding<T>(_ keyPath: WritableKeyPath<Series, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { store.series.first { $0.id == seriesID }?[keyPath: keyPath] ?? fallback },
            set: { value in store.updateSeries(seriesID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func addTag(to s: Series) {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        if !s.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            store.updateSeries(s.id) { $0.tags.append(tag) }
        }
        newTag = ""
    }

    private func applyRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch renameTarget {
        case .series: store.updateSeries(seriesID) { $0.name = name }
        case .book(let id): store.renameBook(id, to: name)
        }
    }

    private func continueLabel(_ b: Book) -> String {
        if b.isFinished { return "Read Again" }
        if b.lastReadAt != nil && b.currentPage > 0 { return "Continue · p. \(b.currentPage + 1)" }
        return "Start Reading"
    }
}
