import SwiftUI

/// "Save to Library?" — shown as soon as a download starts.
struct SaveToLibrarySheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    let item: DownloadItem

    @State private var seriesName: String
    @State private var mode: ReadingMode = .rightToLeft
    @State private var userEdited = false

    init(item: DownloadItem) {
        self.item = item
        _seriesName = State(initialValue: item.seriesName)
        _mode = State(initialValue: item.mode)
    }

    /// Live copy, so the file name and progress update while the sheet is open.
    private var live: DownloadItem {
        downloads.items.first { $0.id == item.id } ?? item
    }

    private var isNew: Bool { library.isNewSeriesName(seriesName) }

    private var suggestions: [String] {
        let q = seriesName.trimmingCharacters(in: .whitespaces)
        let names = library.series.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let filtered = q.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(q) && $0.caseInsensitiveCompare(q) != .orderedSame }
        return Array(filtered.prefix(5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("File", value: live.fileName)
                    if !live.host.isEmpty {
                        LabeledContent("From", value: live.host)
                    }
                    switch live.status {
                    case .downloading:
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: live.progress)
                            Text("Downloading… \(Int(live.progress * 100))%")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    case .waiting:
                        Label("Downloaded. Choose a series to finish.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    case .failed:
                        Label(live.error ?? "Download failed.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                }

                Section {
                    TextField("Series name", text: Binding(
                        get: { seriesName },
                        set: { seriesName = $0; userEdited = true }
                    ))
                    .textInputAutocapitalization(.words)
                    ForEach(suggestions, id: \.self) { name in
                        Button {
                            seriesName = name
                            userEdited = true
                        } label: {
                            Label(name, systemImage: "books.vertical")
                        }
                    }
                } header: {
                    Text("Series")
                } footer: {
                    Text(isNew ? "A new series will be created." : "It will be added to this existing series.")
                }

                if isNew {
                    Section("Reading direction") {
                        Picker("Reading direction", selection: $mode) {
                            ForEach(ReadingMode.allCases) { m in
                                Label(m.label, systemImage: m.icon).tag(m)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("Save to Library?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { downloads.cancel(item.id) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = seriesName.trimmingCharacters(in: .whitespacesAndNewlines)
                        downloads.confirm(item.id, seriesName: name.isEmpty ? live.seriesName : name, mode: mode)
                    }
                    .disabled(live.status == .failed)
                }
            }
            .onChange(of: live.seriesName) { _, parsed in
                // The real file name often arrives a moment after the sheet opens.
                if !userEdited { seriesName = parsed }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium, .large])
    }
}
