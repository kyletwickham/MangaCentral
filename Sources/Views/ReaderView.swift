import SwiftUI
import Observation

/// Loads pages for one book and keeps a small cache.
@Observable
final class ReaderModel {
    let book: Book
    private(set) var pageCount = 0
    private(set) var error: String?

    @ObservationIgnored private var source: PageSource?
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 10
        return c
    }()

    init(book: Book) { self.book = book }

    @MainActor
    func open() async {
        guard source == nil, error == nil else { return }
        let url = LibraryPaths.url(for: book)
        let format = book.format
        do {
            let s = try await Task.detached(priority: .userInitiated) {
                try PageSourceFactory.open(url: url, format: format)
            }.value
            source = s
            pageCount = s.pageCount
            if s.pageCount == 0 { error = MangaError.noPages.localizedDescription }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// One page, or two joined side by side for a spread.
    @MainActor
    func image(pages: [Int], rtl: Bool, target: ImageTarget) async -> UIImage? {
        let key = "\(pages.map(String.init).joined(separator: ","))|\(rtl)|\(Int(target.width))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let s = source else { return nil }
        let result: UIImage? = await Task.detached(priority: .userInitiated) {
            if pages.count < 2 {
                return pages.first.flatMap { s.image(at: $0, target: target) }
            }
            let half = ImageTarget(width: target.width / 2, height: target.height)
            let a = s.image(at: pages[0], target: half)
            let b = s.image(at: pages[1], target: half)
            if let a, let b {
                // Manga: first page on the right.
                return rtl ? ImageCompositor.sideBySide(left: b, right: a)
                           : ImageCompositor.sideBySide(left: a, right: b)
            }
            return a ?? b
        }.value
        if let result { cache.setObject(result, forKey: key) }
        return result
    }
}

/// Full-screen reader. Can hop to the next volume without closing.
struct ReaderView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var bookID: UUID

    init(bookID: UUID) {
        _bookID = State(initialValue: bookID)
    }

    var body: some View {
        if let book = store.books.first(where: { $0.id == bookID }) {
            ReaderContent(book: book,
                          onClose: { dismiss() },
                          onOpenBook: { id in
                              if store.books.first(where: { $0.id == id })?.isOffloaded == true {
                                  // Next volume is only in the backup: close and offer to download it.
                                  dismiss()
                                  Task {
                                      try? await Task.sleep(nanoseconds: 600_000_000)
                                      app.pendingDownload = id
                                  }
                              } else {
                                  bookID = id
                              }
                          })
                .id(bookID)
        } else {
            Color.black.ignoresSafeArea().onAppear { dismiss() }
        }
    }
}

struct ReaderContent: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.displayScale) private var displayScale

    let book: Book
    let onClose: () -> Void
    let onOpenBook: (UUID) -> Void

    @State private var model: ReaderModel
    @State private var currentPage: Int
    @State private var showControls = false
    @State private var showEndCard = false
    @State private var scrub: Double?

    init(book: Book, onClose: @escaping () -> Void, onOpenBook: @escaping (UUID) -> Void) {
        self.book = book
        self.onClose = onClose
        self.onOpenBook = onOpenBook
        _model = State(initialValue: ReaderModel(book: book))
        _currentPage = State(initialValue: book.currentPage)
    }

    private var series: Series? { store.series(for: book) }
    private var mode: ReadingMode { series?.readingMode ?? .rightToLeft }

    private struct Layout {
        let spreads: [[Int]]
        let target: ImageTarget
        let paired: Bool
    }

    private func layout(for size: CGSize) -> Layout {
        let landscape = size.width > size.height
        let paired = (series?.twoPageSpreads ?? false) && landscape && mode != .vertical
        let w = max(size.width, 100) * displayScale
        let h = max(size.height, 100) * displayScale
        let target = mode == .vertical
            ? ImageTarget(width: w, height: nil)
            : ImageTarget(width: min(w * 1.5, 4096), height: min(h * 1.5, 4096)) // headroom for zoom
        return Layout(spreads: Spreads.make(count: model.pageCount, paired: paired),
                      target: target,
                      paired: paired)
    }

    var body: some View {
        GeometryReader { geo in
            let lay = layout(for: geo.size)
            ZStack {
                Color.black.ignoresSafeArea()
                pages(lay).ignoresSafeArea()
                if showControls {
                    controls(lay).transition(.opacity)
                }
                if showEndCard {
                    endCard.transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        .task { @MainActor in
            store.markOpened(book.id)
            await model.open()
            if model.pageCount > 0 {
                currentPage = min(max(currentPage, 0), model.pageCount - 1)
                store.updateProgress(book.id, page: currentPage, pageCount: model.pageCount)
            }
        }
        .onChange(of: currentPage) { _, page in
            guard model.pageCount > 0 else { return }
            store.updateProgress(book.id, page: page, pageCount: model.pageCount)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func pages(_ lay: Layout) -> some View {
        if let error = model.error {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Couldn't open this book").font(.headline)
                Text(error).font(.caption).multilineTextAlignment(.center)
                Button("Close", action: onClose).buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding()
        } else if model.pageCount == 0 {
            ProgressView().tint(.white)
        } else if mode == .vertical {
            VerticalReader(model: model, currentPage: $currentPage, target: lay.target) {
                handleTap(0.5, lay)
            }
        } else {
            PagedReader(model: model,
                        spreads: lay.spreads,
                        rtl: mode == .rightToLeft,
                        target: lay.target,
                        selection: spreadBinding(lay)) { x in
                handleTap(x, lay)
            }
            .id("\(lay.paired)-\(mode.rawValue)")
        }
    }

    private func spreadBinding(_ lay: Layout) -> Binding<Int> {
        Binding(
            get: { Spreads.index(of: currentPage, in: lay.spreads) },
            set: { i in
                if lay.spreads.indices.contains(i) { currentPage = lay.spreads[i].last ?? 0 }
            }
        )
    }

    /// Left/right thirds turn pages; the middle shows/hides controls.
    private func handleTap(_ x: CGFloat, _ lay: Layout) {
        if showEndCard {
            withAnimation { showEndCard = false }
            return
        }
        let left = x < 0.3
        let right = x > 0.7
        guard mode != .vertical, left || right else {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
            return
        }
        let forward = mode == .rightToLeft ? left : right
        step(forward ? 1 : -1, lay)
    }

    private func step(_ delta: Int, _ lay: Layout) {
        let i = Spreads.index(of: currentPage, in: lay.spreads) + delta
        if i >= lay.spreads.count {
            withAnimation {
                showControls = false
                showEndCard = true
            }
            return
        }
        guard i >= 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            currentPage = lay.spreads[i].last ?? 0
        }
    }

    // MARK: - Overlays

    private func controls(_ lay: Layout) -> some View {
        let count = model.pageCount
        let atEnd = count > 0 && Spreads.index(of: currentPage, in: lay.spreads) >= lay.spreads.count - 1
        let shown = scrub.map { Int($0) } ?? currentPage
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                settingsMenu
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 10) {
                if atEnd, let next = store.nextBook(after: book) {
                    Button { onOpenBook(next.id) } label: {
                        Label("Next: \(next.title)", systemImage: "forward.end.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Page \(min(shown, max(count - 1, 0)) + 1) of \(count)")
                    .font(.caption.monospacedDigit())
                if count > 1 {
                    Slider(value: Binding(get: { scrub ?? Double(currentPage) },
                                          set: { scrub = $0 }),
                           in: 0...Double(count - 1),
                           step: 1,
                           onEditingChanged: { editing in
                               if !editing, let s = scrub {
                                   currentPage = Int(s)
                                   scrub = nil
                               }
                           })
                    // Manga slider runs right-to-left, like the pages.
                    .environment(\.layoutDirection, mode == .rightToLeft ? .rightToLeft : .leftToRight)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Reading mode", selection: Binding(get: { mode },
                                                      set: { m in updateSeries { $0.readingMode = m } })) {
                ForEach(ReadingMode.allCases) { m in
                    Label(m.label, systemImage: m.icon).tag(m)
                }
            }
            Toggle("Two-page spreads (landscape)",
                   isOn: Binding(get: { series?.twoPageSpreads ?? false },
                                 set: { v in updateSeries { $0.twoPageSpreads = v } }))
        } label: {
            Image(systemName: "slider.horizontal.3").font(.headline)
        }
    }

    private func updateSeries(_ change: (inout Series) -> Void) {
        if let id = series?.id { store.updateSeries(id, change) }
    }

    private var endCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Finished").font(.title3.bold())
            Text(book.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let next = store.nextBook(after: book) {
                Button { onOpenBook(next.id) } label: {
                    Text("Start \(next.title)").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button(action: onClose) {
                Text("Back to Library").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button("Keep Reading") { withAnimation { showEndCard = false } }
                .font(.footnote)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }
}

// MARK: - Paged (manga / comics)

struct PagedReader: View {
    let model: ReaderModel
    let spreads: [[Int]]
    let rtl: Bool
    let target: ImageTarget
    @Binding var selection: Int
    let onTap: (CGFloat) -> Void

    var body: some View {
        // For right-to-left, lay the pages out reversed so swiping right moves forward.
        let order = rtl ? Array(spreads.indices.reversed()) : Array(spreads.indices)
        TabView(selection: $selection) {
            ForEach(order, id: \.self) { i in
                SpreadPage(model: model, pages: spreads[i], rtl: rtl, target: target, onTap: onTap)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

struct SpreadPage: View {
    let model: ReaderModel
    let pages: [Int]
    let rtl: Bool
    let target: ImageTarget
    let onTap: (CGFloat) -> Void

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image, onTap: onTap)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Couldn't load page \(pages.map { String($0 + 1) }.joined(separator: "–"))")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task(id: pages) {
            let img = await model.image(pages: pages, rtl: rtl, target: target)
            image = img
            failed = img == nil
        }
    }
}

// MARK: - Vertical (webtoon)

struct VerticalReader: View {
    let model: ReaderModel
    @Binding var currentPage: Int
    let target: ImageTarget
    let onTap: () -> Void

    @State private var position: Int?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<model.pageCount, id: \.self) { i in
                    VerticalPage(model: model, index: i, target: target)
                        .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $position, anchor: .top)
        .onTapGesture { onTap() }
        .onAppear { position = currentPage }
        .onChange(of: position) { _, new in
            if let new, new != currentPage { currentPage = new }
        }
        .onChange(of: currentPage) { _, new in
            if position != new { position = new } // slider jumps
        }
    }
}

struct VerticalPage: View {
    let model: ReaderModel
    let index: Int
    let target: ImageTarget

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.black
                    .aspectRatio(0.7, contentMode: .fit)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .frame(maxWidth: .infinity)
        .task { image = await model.image(pages: [index], rtl: false, target: target) }
        .onDisappear { image = nil } // free memory on long strips
    }
}
