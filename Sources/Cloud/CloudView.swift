import SwiftUI

struct CloudView: View {
    @Environment(CloudBackup.self) private var cloud
    @Environment(LibraryStore.self) private var library
    @State private var picking = false
    @State private var confirmDisconnect = false
    @State private var offloadTarget: Series?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if cloud.isConnected { connected } else { intro }
            }
            .navigationTitle("Cloud")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task {
                        await cloud.connect(to: url)
                        if !library.books.isEmpty { await cloud.backUpNow() }
                    }
                }
            }
            .alert("Disconnect backup folder?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive) { _ = cloud.disconnect() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Files already in the folder stay there. MangaCentral stops backing up to it.")
            }
            .alert("Offload \(offloadTarget?.name ?? "")?", isPresented: Binding(get: { offloadTarget != nil }, set: { if !$0 { offloadTarget = nil } })) {
                Button("Offload") {
                    if let s = offloadTarget {
                        let books = library.books(in: s.id).filter { !$0.isOffloaded }
                        Task { await cloud.offload(books) }
                    }
                    offloadTarget = nil
                }
                Button("Cancel", role: .cancel) { offloadTarget = nil }
            } message: {
                Text("The files leave this device but stay in your backup. Covers, progress and tags stay. Tap a book later to download it again.")
            }
            .alert("Couldn't finish", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Not connected

    private var intro: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Back up your library").font(.title2.bold())
                    Text("Pick a folder in a cloud service. MangaCentral copies every book there, plus a small library.json file with your series, reading direction and progress. Then you can offload books to free up space and restore them on any device.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Button {
                    picking = true
                } label: {
                    Label("Choose Backup Folder", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Section("Works with") {
                provider("icloud", "iCloud Drive", "Built into iOS. Syncs across your iPhone, iPad and Mac.")
                provider("folder", "Google Drive", "Install the Google Drive app, then turn it on under Locations in the Files picker.")
                provider("folder", "Dropbox", "Install the Dropbox app, then turn it on under Locations in the Files picker.")
                provider("ipad", "On My iPad / iPhone", "A local folder. Good for exporting, but not an off-device backup.")
            }
            Section {
                Text("Tip: make a folder named Manga in the picker and choose it. MangaCentral keeps everything in a MangaCentral subfolder, sorted by series, so it's easy to browse in the Files app too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func provider(_ icon: String, _ name: String, _ note: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon == "icloud" ? "icloud.fill" : icon == "ipad" ? "ipad" : "folder.fill")
                .foregroundStyle(.tint)
        }
    }

    // MARK: - Connected

    private var connected: some View {
        @Bindable var cloud = cloud
        let rows = library.series
            .map { s -> (Series, [Book]) in (s, library.books(in: s.id)) }
            .sorted { a, b in
                a.1.filter { !$0.isOffloaded }.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) } >
                b.1.filter { !$0.isOffloaded }.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
            }
        return List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(cloud.folderName ?? "Folder") › MangaCentral").font(.headline)
                        Text(cloud.lastBackupAt.map { "Last backup \($0.formatted(.relative(presentation: .named)))" } ?? "Not backed up yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if cloud.isWorking {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: cloud.progress)
                        Text(cloud.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if !cloud.pending.isEmpty {
                    Label("\(cloud.pending.count) item\(cloud.pending.count == 1 ? "" : "s") not backed up yet", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.yellow)
                } else {
                    Label("Everything is backed up", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                HStack {
                    stat("\(cloud.entries.count)", "in backup · \(FileSize.string(cloud.backupBytes))")
                    stat(FileSize.string(library.totalBytes), "on this device")
                }
                Button {
                    Task { await cloud.backUpNow() }
                } label: {
                    Text("Back Up Now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(cloud.isWorking)
                if let err = cloud.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Back up new downloads and imports automatically", isOn: $cloud.autoBackup)
                Toggle("Only back up on Wi-Fi", isOn: $cloud.wifiOnly)
                Button("Change Folder") { picking = true }
                Button("Disconnect", role: .destructive) {
                    if library.books.contains(where: { $0.isOffloaded }) {
                        errorMessage = "Some books only exist in the backup. Download them to this device before disconnecting."
                    } else {
                        confirmDisconnect = true
                    }
                }
            } header: {
                Text("Settings")
            } footer: {
                Text("Manual backups run on any connection. Wi-Fi only applies to automatic ones.")
            }

            Section {
                ForEach(rows, id: \.0.id) { pair in
                    let s = pair.0
                    let books = pair.1
                    let onDevice = books.filter { !$0.isOffloaded }
                    HStack(spacing: 12) {
                        CoverView(book: books.first)
                            .frame(width: 36)
                            .opacity(onDevice.isEmpty ? 0.45 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(onDevice.isEmpty
                                 ? "All \(books.count) in backup"
                                 : "\(onDevice.count) of \(books.count) on device · \(FileSize.string(onDevice.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if onDevice.isEmpty {
                            Button("Download") {
                                Task {
                                    for b in books where b.isOffloaded {
                                        do { try await cloud.download(b) } catch { errorMessage = error.localizedDescription; break }
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button("Offload") { offloadTarget = s }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .disabled(cloud.isWorking)
                }
            } header: {
                Text("Free Up Space")
            } footer: {
                Text("Offloading removes files from this device but keeps covers, progress and tags. Tap an offloaded book to download it again.")
            }

            if !cloud.orphans.isEmpty {
                Section {
                    ForEach(cloud.orphans) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(e.seriesName) · \(FileSize.string(e.bytes))\(e.currentPage > 0 ? " · was on p. \(e.currentPage + 1)" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                Task {
                                    do { try await cloud.restore(e) } catch { errorMessage = error.localizedDescription }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    if cloud.orphans.count > 1 {
                        Button("Restore All \(cloud.orphans.count)") {
                            Task {
                                for e in cloud.orphans {
                                    do { try await cloud.restore(e) } catch { errorMessage = error.localizedDescription; break }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Restore")
                } footer: {
                    Text("These are in your backup but not in this library, for example after deleting them or on a new device.")
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
