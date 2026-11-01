import SwiftUI

struct FriendsView: View {
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library

    @State private var nameDraft = ""
    @State private var addDemo = true
    @State private var addingFriend = false
    @State private var friendCode = ""
    @State private var renaming = false
    @State private var newList = false
    @State private var shownFriend: Friend?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if social.me == nil { setup } else { main }
            }
            .navigationTitle("Friends")
            .navigationDestination(for: UUID.self) { id in
                SharedListView(listID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
                if social.me != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { message = syncMessage(social.sync()) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .accessibilityLabel("Sync with friends")
                        Button { friendCode = ""; addingFriend = true } label: { Image(systemName: "person.badge.plus") }
                            .accessibilityLabel("Add friend")
                    }
                }
            }
            .onAppear { social.fillDemoProgress() }
            .alert("Add a Friend", isPresented: $addingFriend) {
                TextField("MS-XXXX-XX", text: $friendCode)
                    .textInputAutocapitalization(.characters)
                Button("Add") { message = social.addFriend(code: friendCode) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter their invite code. It's on their Friends tab.")
            }
            .alert("Display Name", isPresented: $renaming) {
                TextField("Name", text: $nameDraft)
                Button("Save") {
                    let n = nameDraft.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { social.rename(n) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .sheet(isPresented: $newList) {
                ListEditor(list: nil).environment(social)
            }
            .sheet(item: $shownFriend) { f in
                FriendSheet(friend: f).environment(social)
            }
        }
    }

    private func syncMessage(_ n: Int) -> String {
        n == 0 ? "You're up to date." : "Synced \(n) update\(n == 1 ? "" : "s") from friends."
    }

    // MARK: - First run

    private var setup: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Read together").font(.title2.bold())
                    Text("Make shared lists with friends, see where everyone is in the titles you share, and follow what they finish. Friends only see titles on lists you share with them.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                TextField("Your display name", text: $nameDraft)
                    .textContentType(.nickname)
                Toggle(isOn: $addDemo) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add 3 demo friends to try it")
                        Text("Labelled Demo; their reading is simulated").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Get Started") {
                    social.setUp(name: nameDraft.trimmingCharacters(in: .whitespaces), addDemoFriends: addDemo)
                }
                .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("This test build keeps friends on this device. Real syncing between phones comes with the next step: Apple's iCloud sharing (CloudKit), where friends join from an invite link in Messages.")
            }
        }
    }

    // MARK: - Main

    private var main: some View {
        List {
            if let me = social.me {
                Section {
                    HStack(spacing: 12) {
                        Monogram(text: me.name, size: 48, circle: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.name).font(.headline)
                            Text("Invite code \(me.code)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { nameDraft = me.name; renaming = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    if let url = social.inviteURL {
                        ShareLink(item: url, message: Text("Join me on MangaCentral. My invite code is \(me.code).")) {
                            Label("Invite Friends", systemImage: "square.and.arrow.up")
                        }
                    }
                    Toggle(isOn: Binding(get: { social.shareActivity }, set: { social.shareActivity = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share my reading progress")
                            Text("Hide a single series from its series screen").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Activity") {
                let feed = social.feed.prefix(10)
                if feed.isEmpty {
                    Text("No activity yet. Once friends read something you share, it shows up here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(feed)) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Monogram(text: e.friend.name, size: 30, circle: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feedText(e)).font(.subheadline)
                            Text(e.progress.at.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if social.lists.isEmpty {
                    Text("No shared lists yet.").foregroundStyle(.secondary)
                }
                ForEach(social.lists) { l in
                    NavigationLink(value: l.id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.name).font(.body.weight(.semibold))
                                Text("\(l.items.count) title\(l.items.count == 1 ? "" : "s") · you and \(l.memberIDs.count) friend\(l.memberIDs.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            AvatarStack(names: [social.me?.name ?? "Me"] + social.friends.filter { l.memberIDs.contains($0.id) }.map(\.name))
                        }
                    }
                }
                Button { newList = true } label: { Label("New Shared List", systemImage: "plus") }
            } header: {
                Text("Shared Lists")
            }

            Section("Friends") {
                if social.friends.isEmpty {
                    Text("Add friends with their invite code.").foregroundStyle(.secondary)
                }
                ForEach(social.friends) { f in
                    Button { shownFriend = f } label: {
                        HStack(spacing: 12) {
                            Monogram(text: f.name, size: 38, circle: true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(f.name).font(.body.weight(.semibold))
                                    if f.isDemo { DemoBadge() }
                                }
                                if let cur = social.reads(of: f).first {
                                    Text("\(cur.title) · \(cur.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    Text("Nothing shared yet").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func feedText(_ e: SocialStore.FeedEvent) -> AttributedString {
        var name = AttributedString(e.friend.name)
        name.inlinePresentationIntent = .stronglyEmphasized
        var title = AttributedString(e.progress.title)
        title.inlinePresentationIntent = .stronglyEmphasized
        switch e.progress.label {
        case "Finished": return name + AttributedString(" finished ") + title
        case "Caught up": return name + AttributedString(" caught up on ") + title
        default: return name + AttributedString(" read ") + title + AttributedString(" · \(e.progress.label)")
        }
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.yellow)
    }
}

struct AvatarStack: View {
    let names: [String]
    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(names.prefix(5).enumerated()), id: \.offset) { _, n in
                Monogram(text: n, size: 26, circle: true)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
        }
    }
}

/// One person's position in a title.
struct ProgressRow: View {
    let name: String
    let label: String?
    let fraction: Double
    var note: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Monogram(text: name == "You" ? "Me" : name, size: 22, circle: true)
            Text(name).font(.caption).frame(width: 60, alignment: .leading).lineLimit(1)
            if let label {
                ProgressView(value: fraction)
                Text(label + (note.map { " · \($0)" } ?? ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("Not started").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

struct SharedListView: View {
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library
    @Environment(SitesStore.self) private var sites
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let listID: UUID

    @State private var adding = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var trackingTitle: String?

    var body: some View {
        if let list = social.lists.first(where: { $0.id == listID }) {
            content(list)
        } else {
            ContentUnavailableView("List deleted", systemImage: "list.bullet")
        }
    }

    private func content(_ list: SharedList) -> some View {
        let members = social.friends.filter { list.memberIDs.contains($0.id) }
        let items = list.items.sorted { a, b in lastActivity(a.title, members) > lastActivity(b.title, members) }
        return List {
            Section {
                if !list.details.isEmpty { Text(list.details).foregroundStyle(.secondary) }
                HStack {
                    AvatarStack(names: [social.me?.name ?? "Me"] + members.map(\.name))
                    Text((["You"] + members.map(\.name)).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button { adding = true } label: { Label("Add a Title", systemImage: "plus") }
            }
            ForEach(items) { item in
                Section {
                    let mine = social.myProgress(on: item.title)
                    let series = library.series.first { $0.name.caseInsensitiveCompare(item.title) == .orderedSame }
                    HStack(spacing: 12) {
                        if let series {
                            CoverView(book: library.books(in: series.id).first).frame(width: 40)
                        } else {
                            Monogram(text: item.title, size: 40)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.headline)
                            Text(series != nil ? "In your library" : mine.tracked ? "You track it on the web" : "Not in your library")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let series {
                            Button("Open") {
                                app.tab = .library
                                app.openSeries = series.id
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else if !mine.tracked {
                            Button("Track") { trackingTitle = item.title }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    ProgressRow(name: "You", label: mine.tracked ? mine.label : nil, fraction: mine.fraction,
                                note: mine.hidden ? "hidden" : nil)
                    ForEach(members) { f in
                        let p = social.progress(of: f, on: item.title)
                        ProgressRow(name: f.name, label: p?.label, fraction: p?.fraction ?? 0)
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { social.remove(itemID: item.id, from: list.id) }
                }
                .contextMenu {
                    Button(role: .destructive) { social.remove(itemID: item.id, from: list.id) } label: {
                        Label("Remove from List", systemImage: "minus.circle")
                    }
                }
            }
        }
        .navigationTitle(list.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { editing = true } label: { Label("Edit List", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete List", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $adding) {
            AddTitleSheet(listID: list.id).environment(social).environment(library)
        }
        .sheet(isPresented: $editing) {
            ListEditor(list: list).environment(social)
        }
        .sheet(item: Binding(get: { trackingTitle.map { TitleBox(title: $0) } }, set: { trackingTitle = $0?.title })) { box in
            WebReadEditor(webRead: WebRead(title: box.title, siteName: "", chapter: 1), isNew: true)
                .environment(library)
                .environment(sites)
        }
        .alert("Delete \(list.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { social.deleteList(list.id); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It disappears for everyone it's shared with. Your books aren't affected.")
        }
    }

    private func lastActivity(_ title: String, _ members: [Friend]) -> Date {
        let mine = social.myProgress(on: title).at ?? .distantPast
        let theirs = members.compactMap { social.progress(of: $0, on: title)?.at }.max() ?? .distantPast
        return max(mine, theirs)
    }
}

private struct TitleBox: Identifiable {
    let title: String
    var id: String { title }
}

struct AddTitleSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let listID: UUID
    @State private var typed = ""

    private var candidates: [(String, String)] {
        let have = Set((social.lists.first { $0.id == listID }?.items ?? []).map { $0.title.lowercased() })
        let fromLibrary = library.series.map { ($0.name, "Library") }
        let fromWeb = library.webReads.map { ($0.title, "Web") }
        return (fromLibrary + fromWeb).filter { !have.contains($0.0.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Type any title") {
                    HStack {
                        TextField("Series name", text: $typed)
                        Button("Add") { add(typed) }
                            .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !candidates.isEmpty {
                    Section("From your library and web reads") {
                        ForEach(candidates, id: \.0) { c in
                            Button { add(c.0) } label: {
                                HStack {
                                    Text(c.0)
                                    Spacer()
                                    Text(c.1).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add a Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func add(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        social.add(t, to: listID)
        dismiss()
    }
}

/// Create a list (list == nil) or edit one.
struct ListEditor: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    let list: SharedList?
    @State private var name = ""
    @State private var details = ""
    @State private var members: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Romance picks)", text: $name)
                    TextField("Description (optional)", text: $details)
                }
                Section("Shared with") {
                    if social.friends.isEmpty {
                        Text("Add friends first, or make a list just for you.").foregroundStyle(.secondary)
                    }
                    ForEach(social.friends) { f in
                        Toggle(isOn: Binding(get: { members.contains(f.id) },
                                             set: { if $0 { members.insert(f.id) } else { members.remove(f.id) } })) {
                            HStack(spacing: 10) {
                                Monogram(text: f.name, size: 26, circle: true)
                                Text(f.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle(list == nil ? "New Shared List" : "Edit List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(list == nil ? "Create" : "Save") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        if var l = list {
                            l.name = n
                            l.details = details
                            l.memberIDs = Array(members)
                            social.updateList(l)
                        } else {
                            _ = social.createList(name: n, details: details, members: Array(members))
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let list {
                    name = list.name
                    details = list.details
                    members = Set(list.memberIDs)
                } else {
                    members = Set(social.friends.map(\.id))
                }
            }
        }
    }
}

struct FriendSheet: View {
    @Environment(SocialStore.self) private var social
    @Environment(\.dismiss) private var dismiss
    let friend: Friend
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Monogram(text: friend.name, size: 56, circle: true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(friend.name).font(.title3.bold())
                                if friend.isDemo { DemoBadge() }
                            }
                            Text("Friends since \(friend.since.formatted(date: .abbreviated, time: .omitted)) · \(social.lists.filter { $0.memberIDs.contains(friend.id) }.count) shared lists")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Reading") {
                    let reads = social.reads(of: friend)
                    if reads.isEmpty { Text("Nothing shared with you yet.").foregroundStyle(.secondary) }
                    ForEach(reads, id: \.self) { p in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).font(.subheadline.weight(.semibold))
                                Text(p.at.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(p.label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Remove Friend", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle(friend.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Remove \(friend.name)?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { social.removeFriend(friend.id); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They'll be taken off your shared lists and stop seeing your progress.")
            }
        }
    }
}

/// Friends section on a series screen.
struct SeriesFriendsSection: View {
    @Environment(SocialStore.self) private var social
    let series: Series

    var body: some View {
        if social.me != nil {
            Section {
                let rows = social.friends.compactMap { f in social.progress(of: f, on: series.name).map { (f, $0) } }
                if rows.isEmpty {
                    Text("None of your friends are reading this yet.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.0.id) { pair in
                    ProgressRow(name: pair.0.name, label: pair.1.label, fraction: pair.1.fraction)
                }
                if !social.lists.isEmpty {
                    Menu {
                        ForEach(social.lists) { l in
                            Button(l.name) { social.add(series.name, to: l.id) }
                        }
                    } label: {
                        Label("Add to a Shared List", systemImage: "person.2.badge.plus")
                    }
                }
            } header: {
                Text("Friends")
            } footer: {
                if social.lists.isEmpty { Text("Make a shared list in the Friends tab to share this series.") }
            }
        }
    }
}
