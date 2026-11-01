import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 0) {
                        stat("\(library.books.count)", "books on this device")
                        stat(FileSize.string(library.totalBytes), "storage used")
                    }
                    Text("Everything in your library reads offline. Removing a download from this list keeps the book.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if downloads.items.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("No downloads yet").font(.headline)
                            Text("In Browse, tap a CBZ, ZIP or PDF download link and it lands here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Open Browse") { app.tab = .browse }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section("Downloads") {
                        ForEach(downloads.items) { item in
                            DownloadRow(item: item)
                                .swipeActions {
                                    if item.status != .downloading && item.status != .saving {
                                        Button(role: .destructive) { downloads.remove(item.id) } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                        }
                    }
                }

                Section {
                    Text("Back up this library to iCloud Drive, Google Drive or Dropbox from the Cloud tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
                if downloads.hasFinished {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear Finished") { downloads.clearFinished() }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DownloadRow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.fileName.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.zipper")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    pill
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if item.status == .downloading {
                    ProgressView(value: item.progress)
                }
                if let error = item.error, item.status == .failed {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                actions
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if item.status == .done {
            return library.books.contains(where: { $0.id == item.bookID })
                ? "\(item.seriesName) · \(FileSize.string(item.bytes)) · available offline"
                : "Removed from library"
        }
        return item.host.isEmpty ? item.seriesName : "\(item.seriesName) · \(item.host)"
    }

    @ViewBuilder
    private var pill: some View {
        switch item.status {
        case .downloading: tag("\(Int(item.progress * 100))%", settings.accent.color)
        case .waiting: tag("Needs series", .yellow)
        case .saving: tag("Saving", settings.accent.color)
        case .done: tag("Saved", .green)
        case .failed: tag("Failed", .red)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var actions: some View {
        switch item.status {
        case .downloading:
            Button("Cancel", role: .destructive) { downloads.cancelActive(item.id) }
                .buttonStyle(.bordered).controlSize(.small)
        case .waiting:
            Button("Choose Series") { downloads.chooseSeries(item.id) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .failed:
            Button("Retry") { downloads.retry(item.id) }
                .buttonStyle(.bordered).controlSize(.small)
        case .done:
            if let id = item.bookID, library.books.contains(where: { $0.id == id }) {
                Button("Read") { app.read(id) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        case .saving:
            EmptyView()
        }
    }
}
