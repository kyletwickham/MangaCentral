import UIKit
import PDFKit

/// Anything that can hand the reader page images.
protocol PageSource: AnyObject {
    var pageCount: Int { get }
    func image(at index: Int, target: ImageTarget) -> UIImage?
}

enum PageSourceFactory {
    static func open(url: URL, format: BookFormat) throws -> PageSource {
        switch format {
        case .cbz: return try CBZSource(url: url)
        case .pdf: return try PDFSource(url: url)
        case .folder: return try FolderSource(url: url)
        }
    }
}

/// CBZ / ZIP: pages are image files inside the archive, sorted naturally
/// (so "page2" comes before "page10").
final class CBZSource: PageSource {
    private let zip: ZipArchive
    private let pages: [ZipEntry]

    init(url: URL) throws {
        zip = try ZipArchive(url: url)
        pages = zip.entries
            .filter { e in
                !e.isDirectory
                    && !e.path.hasPrefix("__MACOSX")
                    && !e.fileName.hasPrefix(".")
                    && ImageTypes.isImage(e.path)
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if pages.isEmpty { throw MangaError.noPages }
    }

    var pageCount: Int { pages.count }

    func image(at index: Int, target: ImageTarget) -> UIImage? {
        guard pages.indices.contains(index),
              let data = try? zip.extract(pages[index]) else { return nil }
        return ImageDecoder.decode(data: data, target: target)
    }
}

/// PDF: each PDF page is rendered to an image at screen resolution.
final class PDFSource: PageSource {
    private let doc: PDFDocument
    private let lock = NSLock()

    init(url: URL) throws {
        guard let d = PDFDocument(url: url) else {
            throw MangaError.unreadable("This PDF couldn't be opened.")
        }
        if d.isLocked { throw MangaError.unreadable("This PDF is password-protected.") }
        if d.pageCount == 0 { throw MangaError.noPages }
        doc = d
    }

    var pageCount: Int { doc.pageCount }

    func image(at index: Int, target: ImageTarget) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let page = doc.page(at: index) else { return nil }
        let b = page.bounds(for: .mediaBox)
        guard b.width > 0, b.height > 0 else { return nil }
        // Allow rendering up to 4x the PDF's nominal size for sharp text.
        let long = target.longSide(pixelWidth: b.width * 4, pixelHeight: b.height * 4)
        let scale = long / max(b.width, b.height)
        let size = CGSize(width: (b.width * scale).rounded(), height: (b.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            cg.translateBy(x: -b.minX, y: -b.minY)
            page.draw(with: .mediaBox, to: cg)
        }
    }
}

/// A plain folder of image files.
final class FolderSource: PageSource {
    private let files: [URL]

    init(url: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        files = items
            .filter { ImageTypes.isImage($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if files.isEmpty { throw MangaError.noPages }
    }

    var pageCount: Int { files.count }

    func image(at index: Int, target: ImageTarget) -> UIImage? {
        guard files.indices.contains(index) else { return nil }
        return ImageDecoder.decode(url: files[index], target: target)
    }
}
