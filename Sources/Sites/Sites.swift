import SwiftUI

struct Site: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var folder: String
    var tags: [String]
    var order: Int

    var host: String {
        guard !url.isEmpty else { return "" }
        let withScheme = url.lowercased().hasPrefix("http") ? url : "https://" + url
        return URL(string: withScheme)?.host ?? url
    }

    var openURL: URL? {
        guard !url.isEmpty else { return nil }
        return URL(string: url.lowercased().hasPrefix("http") ? url : "https://" + url)
    }
}

/// Your saved reading sites. Seeded once from Kyle's two lists.
@MainActor
@Observable
final class SitesStore {
    var sites: [Site] = []
    private static let fileURL = LibraryPaths.documents.appendingPathComponent("sites.json")

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Site].self, from: data) {
            sites = saved
        } else if !UserDefaults.standard.bool(forKey: "sitesSeeded") {
            sites = SiteSeed.make()
            UserDefaults.standard.set(true, forKey: "sitesSeeded")
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(sites) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    var folders: [String] {
        var seen: [String] = []
        for s in sites where !seen.contains(s.folder) { seen.append(s.folder) }
        return seen
    }

    var tags: [String] {
        Array(Set(sites.flatMap(\.tags))).sorted { a, b in
            if a == "Licensed" { return true }
            if b == "Licensed" { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    var missingAddressCount: Int { sites.filter { $0.url.isEmpty }.count }

    func site(named name: String) -> Site? {
        sites.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func upsert(_ site: Site) {
        if let i = sites.firstIndex(where: { $0.id == site.id }) { sites[i] = site } else { sites.append(site) }
        save()
    }

    func delete(_ id: UUID) {
        sites.removeAll { $0.id == id }
        save()
    }

    /// Lines like "Name address" or just "address". Matching names get the address filled in.
    func paste(_ text: String, folder: String) -> (updated: Int, added: Int) {
        guard let re = try? NSRegularExpression(pattern: #"(https?://\S+|(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/\S*)?)"#, options: [.caseInsensitive]) else { return (0, 0) }
        var updated = 0, added = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line) else { continue }
            let address = String(line[r])
            let name = line.replacingCharacters(in: r, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|,").union(.whitespaces))
            if !name.isEmpty, let i = sites.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                sites[i].url = address
                updated += 1
            } else {
                var s = Site(name: name, url: address, folder: folder, tags: [], order: sites.count)
                if s.name.isEmpty { s.name = s.host }
                sites.append(s)
                added += 1
            }
        }
        save()
        return (updated, added)
    }
}

enum SiteSeed {
    /// Licensed services come with their addresses. The rest are added by name only.
    static let licensed: [String: String] = [
        "Bookwalker": "https://global.bookwalker.jp", "Rakuten Kobo": "https://www.kobo.com",
        "MANGA Plus": "https://mangaplus.shueisha.co.jp", "Coolmic": "https://coolmic.me",
        "K MANGA": "https://kmanga.kodansha.com", "Pixiv Comics": "https://comic.pixiv.net",
        "INKR": "https://comics.inkr.com", "MangaPlaza": "https://mangaplaza.com",
        "Webtoons": "https://www.webtoons.com", "Tapas": "https://tapas.io",
        "Tappytoon": "https://www.tappytoon.com", "Toomics": "https://toomics.com",
        "Lezhin": "https://www.lezhinus.com", "Manta": "https://manta.net"
    ]

    static let manga = "Comix|HUB;Mangadot|HUB;Atsumaru;Mangaball|HUB;MangaFire;Weeb Central;Mangago;Toonkotsu|NEW;yaoi.me|NEW;OniSaga;MKissa Manga;Bookwalker;Rakuten Kobo;MangaTaro;MangaK;XComic|NEW;chikari.moe|NEW;Swarm|NEW;MangaKatana;MangaCloud;Cubari Proxy|MULT;VyManga;LikeManga;MANGA Plus;Toonz|NEW;MangaHub;Dynasty Reader|HUB;Manganato.gg;Mangastash|NEW;Coolmic;Omoi;comico.moe|MULT,NEW;Webnex|NEW;Zinmanga;Mangafox;MangaFreak;MangaDE;Komix|NEW;MangaTown;MangaHome;ReiManga;YomiManga;Ninekon;ManhuaPlus|MANHUA;Mangapill;Mangakawaii|HUB;OriYami;mangageko;Mangalink;MangaDex;GodaComic;JP Book Store|PHYSICAL;K MANGA;Pixiv Comics|RAW;INKR;Lunar - Manga|MULT;JustManga|MULT;Yaoiscan;MangaBay|LOGIN;Manhwanex|MANHUA;RawOtaku|RAW;KT9|RAW;Hachiraw|RAW;MangaRaw4u|RAW;Nicomanga|RAW;Rawdevart|RAW;RawSakura|RAW;NihonKuni|RAW;Raw Manga|RAW;Rawkuma|RAW;漫画 raw|RAW;WeLoMa|RAW;Spoilerplus|RAW;RawLazy|RAW;raw1001|RAW;Baozi Manhua|RAW;Twmanga|RAW,MANHUA;SenManga|RAW;RawFree|RAW;MangaPlaza;Manga Mirai;MangaMikan;MangaBerri;MangaCherri;Danke fürs Lesen|SCAN;Hachirumi|SCAN;KDT Scans|SCAN;Mangasushi|SCAN;ManhuaBuddy;ReadManga;Lilymanga;MangaDoom;MangaRead;Aqua manga;Todaymanga;Manhua Hot"

    static let manhwa = "Kagane;WebtoonClub;BaeToon;Webtoons;Tapas;Tappytoon;Toomics;Manhwatop;Toonily;KuraManga;Projectsuki|HUB;TopManhua;Cocomic;MangaGG;Mangazin;Lezhin;Manta;nicelink (wolftoon)|RAW;GoodToon|RAW;ToonKor|RAW;Blacktoon|RAW;TOONFLIX (ntk01)|RAW;PandaToons|RAW,NEW;jjaptoon|RAW;Funbe|RAW;Manhwatoon;ManhuaRMTL|MTL;Kingofshojo;Lua Comic|SCAN;Asura Scans|SCAN;Flame Comics|SCAN;Hive Scans|SCAN;TempleScan|SCAN;rokari comics|SCAN;Diva Scans|SCAN;Nyx Scans|SCAN;Fropi;Manhuaus;mangack"

    static func make() -> [Site] {
        var out: [Site] = []
        func add(_ list: String, _ folder: String) {
            for (i, row) in list.split(separator: ";").enumerated() {
                let parts = row.split(separator: "|", maxSplits: 1).map(String.init)
                let name = parts[0]
                var tags = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
                let url = licensed[name] ?? ""
                if !url.isEmpty { tags.append("Licensed") }
                out.append(Site(name: name, url: url, folder: folder, tags: tags, order: i))
            }
        }
        add(manga, "Manga Reading")
        add(manhwa, "Manhwa Reading")
        return out
    }
}

// MARK: - Views

struct SitesView: View {
    @Environment(SitesStore.self) private var store
    @Environment(BrowserModel.self) private var browser
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var folder = "All"
    @State private var tag: String?
    @State private var editing: Site?
    @State private var creating = false
    @State private var pasting = false

    private var filtered: [Site] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.sites.filter { s in
            (folder == "All" || s.folder == folder)
                && (tag == nil || s.tags.contains(tag!))
                && (q.isEmpty || s.name.localizedCaseInsensitiveContains(q) || s.url.localizedCaseInsensitiveContains(q))
        }
        .sorted { $0.order < $1.order }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Section", selection: $folder) {
                        Text("All").tag("All")
                        ForEach(store.folders, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if store.missingAddressCount > 0 {
                        Text("\(store.missingAddressCount) sites still need an address. Tap one to add it, or use Paste List to fill in many at once.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(folder == "All" ? store.folders : [folder], id: \.self) { f in
                    let items = filtered.filter { $0.folder == f }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { site in
                                SiteRow(site: site)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(site) }
                                    .swipeActions {
                                        Button("Delete", role: .destructive) { store.delete(site.id) }
                                        Button("Edit") { editing = site }.tint(.gray)
                                    }
                                    .contextMenu {
                                        Button { editing = site } label: { Label("Edit", systemImage: "pencil") }
                                        Button(role: .destructive) { store.delete(site.id) } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        } header: {
                            Text("\(f) · \(items.count)")
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search \(store.sites.count) sites")
            .navigationTitle("Sites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { creating = true } label: { Label("Add Site", systemImage: "plus") }
                        Button { pasting = true } label: { Label("Paste List", systemImage: "doc.on.clipboard") }
                        Divider()
                        Picker("Tag", selection: $tag) {
                            Text("All Tags").tag(String?.none)
                            ForEach(store.tags, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } label: {
                        Image(systemName: tag == nil ? "ellipsis.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Site options")
                }
            }
            .sheet(item: $editing) { site in
                SiteEditor(site: site, isNew: false).environment(store)
            }
            .sheet(isPresented: $creating) {
                SiteEditor(site: Site(name: "", url: "", folder: folder == "All" ? (store.folders.first ?? "Sites") : folder, tags: [], order: store.sites.count), isNew: true)
                    .environment(store)
            }
            .sheet(isPresented: $pasting) {
                PasteSitesSheet(defaultFolder: folder == "All" ? (store.folders.first ?? "Sites") : folder)
                    .environment(store)
            }
        }
    }

    private func open(_ site: Site) {
        guard let url = site.openURL else { editing = site; return }
        browser.open(url)
        dismiss()
    }
}

struct SiteRow: View {
    let site: Site

    var body: some View {
        HStack(spacing: 12) {
            Monogram(text: site.name, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(site.name).font(.body.weight(.semibold)).lineLimit(1)
                if site.url.isEmpty {
                    Text("Add address").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                } else {
                    Text(site.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !site.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(site.tags, id: \.self) { t in
                            Text(t)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background((t == "Licensed" ? Color.green : Color.secondary).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(t == "Licensed" ? Color.green : Color.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct SiteEditor: View {
    @Environment(SitesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var site: Site
    let isNew: Bool
    @State private var tagsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $site.name)
                    TextField("Address (example.com)", text: $site.url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Section") {
                    TextField("Section", text: $site.folder)
                    if !store.folders.isEmpty {
                        Picker("Existing sections", selection: $site.folder) {
                            ForEach(store.folders, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Section {
                    TextField("RAW, SCAN, Licensed", text: $tagsText)
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Separate tags with commas.")
                }
                if !isNew {
                    Section {
                        Button("Delete Site", role: .destructive) {
                            store.delete(site.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Site" : site.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var s = site
                        s.name = s.name.trimmingCharacters(in: .whitespaces)
                        s.url = s.url.trimmingCharacters(in: .whitespaces)
                        if !s.url.isEmpty && !s.url.lowercased().hasPrefix("http") { s.url = "https://" + s.url }
                        if s.name.isEmpty { s.name = s.host }
                        s.folder = s.folder.trimmingCharacters(in: .whitespaces).isEmpty ? "Sites" : s.folder
                        s.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        store.upsert(s)
                        dismiss()
                    }
                    .disabled(site.name.trimmingCharacters(in: .whitespaces).isEmpty && site.url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { tagsText = site.tags.joined(separator: ", ") }
        }
    }
}

struct PasteSitesSheet: View {
    @Environment(SitesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let defaultFolder: String
    @State private var text = ""
    @State private var folder = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("One site per line")
                } footer: {
                    Text("Write \"Name address\" or just an address. A name that matches a saved site fills in its address. Anything new is added.")
                }
                Section("Section for new sites") {
                    TextField("Section", text: $folder)
                }
                if let result {
                    Section { Text(result).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Paste List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let r = store.paste(text, folder: folder.isEmpty ? defaultFolder : folder)
                        result = "\(r.updated) updated · \(r.added) added"
                        text = ""
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { folder = defaultFolder }
        }
    }
}
