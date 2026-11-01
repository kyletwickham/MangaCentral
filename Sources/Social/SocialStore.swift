import SwiftUI

struct Profile: Codable, Hashable {
    var name: String
    var code: String
}

struct Friend: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var code: String
    var isDemo: Bool
    var since = Date()
}

struct ListItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var addedAt = Date()
}

struct SharedList: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var details: String
    var memberIDs: [UUID]
    var items: [ListItem] = []
    var createdAt = Date()
}

/// Where a friend is in a title.
struct FriendProgress: Codable, Hashable {
    enum Unit: String, Codable { case volume, chapter }
    var title: String
    var unit: Unit
    var volume = 1
    var volumes = 1
    var page = 1
    var pages = 30
    var chapter = 1
    var chapters = 1
    var at: Date

    var label: String {
        switch unit {
        case .volume: return volume >= volumes && page >= pages ? "Finished" : "Vol \(volume) · p. \(page)"
        case .chapter: return chapter >= chapters ? "Caught up" : "Ch. \(chapter)"
        }
    }

    var fraction: Double {
        switch unit {
        case .volume: return min(1, (Double(volume - 1) + Double(page) / Double(pages)) / Double(max(volumes, 1)))
        case .chapter: return min(1, Double(chapter) / Double(max(chapters, 1)))
        }
    }
}

/// Your own position, worked out from the library or your web reads.
struct MyProgress {
    var label: String
    var fraction: Double
    var at: Date?
    var hidden: Bool
    var tracked: Bool
}

/// Phase 4: friends, shared lists and progress.
///
/// This version runs on this device with demo friends, so every screen can be tried now.
/// The sync layer (CloudKit sharing, or Firebase) replaces the parts marked DEMO.
@MainActor
@Observable
final class SocialStore {
    var me: Profile?
    var shareActivity = true { didSet { save() } }
    var friends: [Friend] = []
    var lists: [SharedList] = []
    /// Key: "friendID|title" (lowercased title).
    var progress: [String: FriendProgress] = [:]

    @ObservationIgnored weak var library: LibraryStore?
    private static let fileURL = LibraryPaths.documents.appendingPathComponent("social.json")

    static let demoNames = ["Jordan", "Sam", "Riley", "Avery", "Morgan", "Casey", "Quinn", "Drew", "Rowan", "Skyler"]
    static let demoWebTitles: [(String, Int)] = [("Starfall Academy", 142), ("The Ninth Gate Courier", 88), ("Moonlit Bakery", 61)]

    init() { load() }

    // MARK: - Profile

    static func makeCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func part(_ n: Int) -> String { String((0..<n).map { _ in chars.randomElement()! }) }
        return "MS-\(part(4))-\(part(2))"
    }

    func setUp(name: String, addDemoFriends: Bool) {
        me = Profile(name: name, code: Self.makeCode())
        if addDemoFriends { seedDemo() }
        save()
    }

    func rename(_ name: String) {
        me?.name = name
        save()
    }

    var inviteURL: URL? {
        me.flatMap { URL(string: "mangacentral://invite/\($0.code)") }
    }

    // MARK: - Titles & progress

    private func key(_ friend: Friend, _ title: String) -> String {
        friend.id.uuidString + "|" + title.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    func isShared(_ friend: Friend, _ title: String) -> Bool {
        lists.contains { $0.memberIDs.contains(friend.id) && $0.items.contains { same($0.title, title) } }
    }

    func progress(of friend: Friend, on title: String) -> FriendProgress? {
        progress[key(friend, title)]
    }

    /// DEMO: demo friends on a shared list with a title usually start reading it.
    /// Call after lists change (never from inside a view's body).
    func fillDemoProgress() {
        var changed = false
        for l in lists {
            for f in friends where f.isDemo && l.memberIDs.contains(f.id) {
                for item in l.items where progress[key(f, item.title)] == nil && StableHash.of(key(f, item.title)) % 5 != 0 {
                    makeDemoProgress(f, item.title, saving: false)
                    changed = true
                }
            }
        }
        if changed { save() }
    }

    @discardableResult
    private func makeDemoProgress(_ friend: Friend, _ title: String, saving: Bool = true) -> FriendProgress {
        let k = key(friend, title)
        let h = StableHash.of(k)
        var p: FriendProgress
        if let s = library?.series.first(where: { same($0.name, title) }) {
            let vols = max(1, library?.books(in: s.id).count ?? 1)
            p = FriendProgress(title: title, unit: .volume, at: Date())
            p.volumes = vols
            p.volume = 1 + Int(h % UInt32(vols))
            p.page = 1 + Int((h >> 4) % 28)
        } else {
            let known = Self.demoWebTitles.first { same($0.0, title) }?.1
            let mine = library?.webReads.first { same($0.title, title) }?.total
            let total = mine ?? known ?? 40 + Int(h % 140)
            p = FriendProgress(title: title, unit: .chapter, at: Date())
            p.chapters = total
            p.chapter = 1 + Int((h >> 3) % UInt32(total))
        }
        p.at = Date().addingTimeInterval(-Double((h >> 6) % 4320) * 60)
        progress[k] = p
        if saving { save() }
        return p
    }

    func myProgress(on title: String) -> MyProgress {
        if let library, let s = library.series.first(where: { same($0.name, title) }) {
            let books = library.books(in: s.id)
            let hidden = s.hiddenFromFriends ?? false
            guard let cur = books.filter({ $0.lastReadAt != nil }).max(by: { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }),
                  let vi = books.firstIndex(of: cur) else {
                return MyProgress(label: "Not started", fraction: 0, at: nil, hidden: hidden, tracked: true)
            }
            let done = cur.isFinished && vi == books.count - 1
            let short = cur.title.replacingOccurrences(of: s.name, with: "").trimmingCharacters(in: .whitespaces)
            let label = done ? "Finished" : "\(short.isEmpty ? "Vol \(vi + 1)" : short) · p. \(cur.currentPage + 1)"
            return MyProgress(label: label, fraction: (Double(vi) + cur.progress) / Double(max(1, books.count)),
                              at: cur.lastReadAt, hidden: hidden, tracked: true)
        }
        if let w = library?.webReads.first(where: { same($0.title, title) }) {
            let total = w.total ?? Self.demoWebTitles.first { same($0.0, title) }?.1
            return MyProgress(label: "Ch. \(w.chapter)", fraction: total.map { min(1, Double(w.chapter) / Double($0)) } ?? 0,
                              at: w.updatedAt, hidden: false, tracked: true)
        }
        return MyProgress(label: "Not tracking", fraction: 0, at: nil, hidden: false, tracked: false)
    }

    struct FeedEvent: Identifiable {
        let id = UUID()
        let friend: Friend
        let progress: FriendProgress
    }

    var feed: [FeedEvent] {
        progress.compactMap { k, p in
            guard let f = friends.first(where: { k.hasPrefix($0.id.uuidString + "|") }) else { return nil }
            return FeedEvent(friend: f, progress: p)
        }
        .sorted { $0.progress.at > $1.progress.at }
    }

    func reads(of friend: Friend) -> [FriendProgress] {
        progress.filter { $0.key.hasPrefix(friend.id.uuidString + "|") }.map(\.value).sorted { $0.at > $1.at }
    }

    // MARK: - DEMO sync

    func seedDemo() {
        let names = Self.demoNames.shuffled().prefix(3)
        let new = names.enumerated().map { i, n in
            Friend(name: n, code: Self.makeCode(), isDemo: true, since: Date().addingTimeInterval(-Double(i + 1) * 86400 * 9))
        }
        friends.append(contentsOf: new)
        let titles = (library?.series.prefix(2).map(\.name) ?? []) + Self.demoWebTitles.map(\.0)
        lists.append(SharedList(name: "Weekend reads", details: "Stuff we're all reading. Keep up!",
                                memberIDs: new.map(\.id), items: titles.prefix(4).map { ListItem(title: $0) }))
        for (i, f) in new.enumerated() {
            for (j, t) in titles.enumerated() where (i + j) % 3 != 2 { makeDemoProgress(f, t) }
        }
        save()
    }

    /// DEMO: friends move ahead a bit, as if new progress synced in.
    @discardableResult
    func sync() -> Int {
        var n = 0
        for (k, var p) in progress {
            guard let f = friends.first(where: { k.hasPrefix($0.id.uuidString + "|") }), f.isDemo, Bool.random() else { continue }
            switch p.unit {
            case .volume:
                p.page += Int.random(in: 4...13)
                if p.page >= p.pages {
                    if p.volume < p.volumes { p.volume += 1; p.page = 1 } else { p.page = p.pages }
                }
            case .chapter:
                p.chapter = min(p.chapters, p.chapter + Int.random(in: 1...3))
            }
            p.at = Date().addingTimeInterval(-Double(Int.random(in: 0...20)) * 60)
            progress[k] = p
            n += 1
        }
        save()
        return n
    }

    /// DEMO: any code adds a simulated friend.
    func addFriend(code: String) -> String {
        let c = code.uppercased().replacingOccurrences(of: " ", with: "")
        guard !c.isEmpty else { return "Enter a code." }
        if c == me?.code { return "That's your own code." }
        if friends.contains(where: { $0.code == c }) { return "You're already friends." }
        let used = Set(friends.map(\.name))
        let free = Self.demoNames.filter { !used.contains($0) }
        let name = free.isEmpty ? "Friend \(friends.count + 1)" : free[Int(StableHash.of(c) % UInt32(free.count))]
        let f = Friend(name: name, code: c, isDemo: true)
        friends.append(f)
        let titles = Self.demoWebTitles.map(\.0) + (library?.series.prefix(2).map(\.name) ?? [])
        for (j, t) in titles.enumerated() where (Int(StableHash.of(c) % 7) + j) % 2 == 0 { makeDemoProgress(f, t) }
        save()
        return "\(name) added (demo)."
    }

    func removeFriend(_ id: UUID) {
        friends.removeAll { $0.id == id }
        for i in lists.indices { lists[i].memberIDs.removeAll { $0 == id } }
        progress = progress.filter { !$0.key.hasPrefix(id.uuidString + "|") }
        save()
    }

    // MARK: - Lists

    func createList(name: String, details: String, members: [UUID]) -> SharedList {
        let l = SharedList(name: name, details: details, memberIDs: members)
        lists.append(l)
        save()
        fillDemoProgress()
        return l
    }

    func updateList(_ l: SharedList) {
        if let i = lists.firstIndex(where: { $0.id == l.id }) { lists[i] = l; save(); fillDemoProgress() }
    }

    func deleteList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        save()
    }

    func add(_ title: String, to listID: UUID) {
        guard let i = lists.firstIndex(where: { $0.id == listID }),
              !lists[i].items.contains(where: { same($0.title, title) }) else { return }
        lists[i].items.append(ListItem(title: title))
        save()
        fillDemoProgress()
    }

    func remove(itemID: UUID, from listID: UUID) {
        guard let i = lists.firstIndex(where: { $0.id == listID }) else { return }
        lists[i].items.removeAll { $0.id == itemID }
        save()
    }

    // MARK: - Persistence

    private struct State: Codable {
        var me: Profile?
        var shareActivity: Bool
        var friends: [Friend]
        var lists: [SharedList]
        var progress: [String: FriendProgress]
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        me = s.me
        friends = s.friends
        lists = s.lists
        progress = s.progress
        shareActivity = s.shareActivity // last: its didSet saves
    }

    func save() {
        let s = State(me: me, shareActivity: shareActivity, friends: friends, lists: lists, progress: progress)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}
