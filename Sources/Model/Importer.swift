import Foundation

/// Something found in the user's selection that we'll try to import.
struct ImportCandidate {
    let source: URL
    let format: BookFormat
    /// Name of the folder it was found in (used as the series name).
    let seriesHint: String?
    /// Exact series name chosen by the user (downloads).
    var seriesOverride: String? = nil
}

struct ImportedFile {
    let relativePath: String
    let format: BookFormat
    let seriesName: String
    let title: String
    let number: Double?
    let pageCount: Int
    let fileSize: Int64
}

/// File work for importing. Runs off the main thread.
enum Importer {
    static let archiveExtensions: Set<String> = ["cbz", "zip"]

    /// Walks a selection. Picking a folder like "One Piece/" full of CBZs
    /// imports each file into the "One Piece" series.
    static func collect(_ url: URL, seriesHint: String?, into out: inout [ImportCandidate], skipped: inout [String]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            skipped.append("\(url.lastPathComponent): not found (if it's in iCloud, open it in Files once to download it)")
            return
        }

        guard isDir.boolValue else {
            let ext = url.pathExtension.lowercased()
            if archiveExtensions.contains(ext) {
                out.append(ImportCandidate(source: url, format: .cbz, seriesHint: seriesHint))
            } else if ext == "pdf" {
                out.append(ImportCandidate(source: url, format: .pdf, seriesHint: seriesHint))
            } else if ext == "cbr" || ext == "rar" {
                skipped.append("\(url.lastPathComponent): CBR/RAR isn't supported yet (planned for a later phase)")
            } else if !ImageTypes.isImage(url.lastPathComponent) {
                skipped.append("\(url.lastPathComponent): not a supported file type")
            }
            return
        }

        let raw = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        var children: [URL] = []
        for child in raw {
            let name = child.lastPathComponent
            if name.hasPrefix(".") {
                // Older iCloud placeholders look like ".Vol 1.cbz.icloud"
                if name.hasSuffix(".icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    children.append(url.appendingPathComponent(real))
                }
                continue
            }
            children.append(child)
        }

        if children.contains(where: { ImageTypes.isImage($0.lastPathComponent) }) {
            // A folder of page images = one book.
            out.append(ImportCandidate(source: url, format: .folder, seriesHint: seriesHint))
        } else {
            let sorted = children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for child in sorted {
                collect(child, seriesHint: url.lastPathComponent, into: &out, skipped: &skipped)
            }
        }
    }

    /// Copies one candidate into the library and checks it opens.
    static func process(_ c: ImportCandidate) throws -> ImportedFile {
        let fm = FileManager.default
        let parsed = NameParser.parse(c.source.lastPathComponent, isFolder: c.format == .folder)
        let seriesName = c.seriesOverride ?? c.seriesHint.map(NameParser.cleanSeries) ?? parsed.series
        let folderName = NameParser.safeFolderName(seriesName)
        let destDir = LibraryPaths.root.appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        var dest = destDir.appendingPathComponent(c.source.lastPathComponent)
        if c.format != .folder, fm.fileExists(atPath: dest.path),
           let a = fileSize(c.source), let b = fileSize(dest), a == b {
            throw MangaError.alreadyInLibrary
        }
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = c.format == .folder ? "" : dest.pathExtension
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            dest = destDir.appendingPathComponent(newName)
            n += 1
        }

        // File coordination makes iCloud / Google Drive / Dropbox download the file first.
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: c.source, options: [], error: &coordError) { readURL in
            do { try fm.copyItem(at: readURL, to: dest) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }

        do {
            let src = try PageSourceFactory.open(url: dest, format: c.format)
            guard src.pageCount > 0 else { throw MangaError.noPages }
            return ImportedFile(relativePath: folderName + "/" + dest.lastPathComponent,
                                format: c.format,
                                seriesName: seriesName,
                                title: parsed.title,
                                number: parsed.number,
                                pageCount: src.pageCount,
                                fileSize: FileSize.of(dest))
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
