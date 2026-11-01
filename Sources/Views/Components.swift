import SwiftUI

/// A 2:3 cover thumbnail that loads lazily.
struct CoverView: View {
    let book: Book?
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "book.closed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .task(id: book?.id) {
                if let book { image = await CoverCache.cover(for: book) }
            }
    }
}

struct SeriesCard: View {
    @Environment(LibraryStore.self) private var store
    let series: Series

    var body: some View {
        let books = store.books(in: series.id)
        let finished = books.filter(\.isFinished).count
        VStack(alignment: .leading, spacing: 6) {
            CoverView(book: books.first)
                .overlay(alignment: .topTrailing) {
                    if series.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                    }
                }
            Text(series.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(books.count) \(books.count == 1 ? "item" : "items") · \(finished) read")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct BookCard: View {
    let book: Book
    let seriesName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverView(book: book)
                .overlay(alignment: .bottom) {
                    ProgressView(value: min(book.progress, 1))
                        
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            Text(seriesName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(book.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 110)
    }
}

struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            CoverView(book: book)
                .frame(width: 46)
                .opacity(book.isOffloaded ? 0.5 : 1)
                .overlay(alignment: .bottomLeading) {
                    if book.isOffloaded {
                        Image(systemName: "icloud.fill")
                            .font(.caption2)
                            .padding(3)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(2)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .lineLimit(2)
                if book.lastReadAt != nil && !book.isFinished && book.pageCount > 0 {
                    ProgressView(value: min(book.progress, 1))
                        
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if book.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }

    private var status: String {
        if book.isOffloaded { return "In your backup · tap to download" }
        if book.isFinished { return "Finished · \(book.pageCount) pages" }
        if book.lastReadAt != nil { return "Page \(book.currentPage + 1) of \(book.pageCount)" }
        let origin = book.sourceURL.flatMap { URL(string: $0)?.host }.map { " · from \($0)" } ?? ""
        return "Unread · \(book.pageCount) pages · \(book.format.label)\(origin)"
    }
}
