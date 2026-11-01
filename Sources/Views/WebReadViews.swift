import SwiftUI

/// Card in Library › Reading on the Web: title, site, and a +1 chapter button.
struct WebReadCard: View {
    @Environment(LibraryStore.self) private var store
    @Environment(SitesStore.self) private var sites
    @Environment(BrowserModel.self) private var browser
    @Environment(AppState.self) private var app
    let webRead: WebRead
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onEdit) {
                HStack(spacing: 10) {
                    Monogram(text: webRead.siteName.isEmpty ? webRead.title : webRead.siteName, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(webRead.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button { store.stepWebRead(webRead.id, by: -1) } label: {
                    Image(systemName: "minus").frame(width: 28, height: 22)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Previous chapter")
                Text("Ch. \(webRead.chapter)")
                    .font(.headline.monospacedDigit())
                    .frame(maxWidth: .infinity)
                Button { store.stepWebRead(webRead.id, by: 1) } label: {
                    Text("+1").frame(width: 28, height: 22)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Next chapter")
            }
            .controlSize(.small)

            if let site = sites.site(named: webRead.siteName), let url = site.openURL {
                Button {
                    app.tab = .browse
                    browser.open(url)
                } label: {
                    Text("Open \(site.name)").font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 210)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var subtitle: String {
        let site = webRead.siteName.isEmpty ? "No site" : webRead.siteName
        if let t = webRead.total { return "\(site) · of \(t)" }
        return site
    }
}

struct WebReadEditor: View {
    @Environment(LibraryStore.self) private var store
    @Environment(SitesStore.self) private var sites
    @Environment(\.dismiss) private var dismiss
    @State var webRead: WebRead
    let isNew: Bool
    @State private var totalText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Series title", text: $webRead.title)
                    TextField("Site", text: $webRead.siteName)
                    if !sites.sites.isEmpty {
                        Picker("Pick from your Sites", selection: $webRead.siteName) {
                            Text("None").tag("")
                            ForEach(sites.sites.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { s in
                                Text(s.name).tag(s.name)
                            }
                        }
                    }
                }
                Section("Progress") {
                    Stepper("Chapter \(webRead.chapter)", value: $webRead.chapter, in: 0...9999)
                    TextField("Total chapters (optional)", text: $totalText)
                        .keyboardType(.numberPad)
                }
                if !isNew {
                    Section {
                        Button("Stop Tracking", role: .destructive) {
                            store.deleteWebRead(webRead.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Track a Web Title" : webRead.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var w = webRead
                        w.title = w.title.trimmingCharacters(in: .whitespaces)
                        w.total = Int(totalText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
                        if let t = w.total { w.chapter = min(w.chapter, t) }
                        store.saveWebRead(w)
                        dismiss()
                    }
                    .disabled(webRead.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { totalText = webRead.total.map(String.init) ?? "" }
        }
    }
}
