import Foundation
import Compression

/// A small, dependency-free ZIP reader (CBZ files are ZIPs).
/// Supports "stored" and "deflate" entries, which covers virtually every CBZ.
struct ZipEntry {
    let path: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    let isEncrypted: Bool

    var isDirectory: Bool { path.hasSuffix("/") }
    var fileName: String { (path as NSString).lastPathComponent }
}

enum ZipError: LocalizedError {
    case notAZip, corrupt, zip64, encrypted, unsupportedMethod(UInt16)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "This file isn't a valid CBZ/ZIP archive."
        case .corrupt: return "This archive looks damaged."
        case .zip64: return "This archive is over 4 GB (ZIP64), which isn't supported yet. Try splitting it into smaller volumes."
        case .encrypted: return "This archive is password-protected."
        case .unsupportedMethod(let m): return "This archive uses an unsupported compression method (\(m))."
        }
    }
}

final class ZipArchive {
    let data: Data
    let entries: [ZipEntry]

    init(url: URL) throws {
        // Memory-mapped: the file isn't loaded into RAM all at once.
        data = try Data(contentsOf: url, options: .alwaysMapped)
        entries = try ZipArchive.readCentralDirectory(data)
    }

    func extract(_ e: ZipEntry) throws -> Data {
        if e.isEncrypted { throw ZipError.encrypted }
        let o = e.localHeaderOffset
        try need(data, o, 30)
        guard try u32(data, o) == 0x04034b50 else { throw ZipError.corrupt }
        let nameLen = Int(try u16(data, o + 26))
        let extraLen = Int(try u16(data, o + 28))
        let start = o + 30 + nameLen + extraLen
        try need(data, start, e.compressedSize)
        let base = data.startIndex
        let comp = data.subdata(in: (base + start)..<(base + start + e.compressedSize))

        switch e.method {
        case 0:
            return comp
        case 8:
            guard e.uncompressedSize > 0 else { return Data() }
            var out = Data(count: e.uncompressedSize)
            let written: Int = out.withUnsafeMutableBytes { dst in
                comp.withUnsafeBytes { src in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    // COMPRESSION_ZLIB = raw DEFLATE, exactly what ZIP uses.
                    return compression_decode_buffer(d, e.uncompressedSize, s, e.compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == e.uncompressedSize else { throw ZipError.corrupt }
            return out
        default:
            throw ZipError.unsupportedMethod(e.method)
        }
    }

    // MARK: - Parsing

    private static func readCentralDirectory(_ d: Data) throws -> [ZipEntry] {
        let count = d.count
        guard count >= 22 else { throw ZipError.notAZip }

        // Find the End Of Central Directory record (scan backwards).
        var eocd = -1
        let lowest = max(0, count - 22 - 65_535)
        var i = count - 22
        while i >= lowest {
            if try u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let total = Int(try u16(d, eocd + 10))
        let cdOffset32 = try u32(d, eocd + 16)
        if total == 0xFFFF || cdOffset32 == 0xFFFF_FFFF { throw ZipError.zip64 }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(total)
        var p = Int(cdOffset32)
        for _ in 0..<total {
            try need(d, p, 46)
            guard try u32(d, p) == 0x02014b50 else { throw ZipError.corrupt }
            let flags = try u16(d, p + 8)
            let method = try u16(d, p + 10)
            let comp = try u32(d, p + 20)
            let uncomp = try u32(d, p + 24)
            let nameLen = Int(try u16(d, p + 28))
            let extraLen = Int(try u16(d, p + 30))
            let commentLen = Int(try u16(d, p + 32))
            let localOffset = try u32(d, p + 42)
            if comp == 0xFFFF_FFFF || uncomp == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF { throw ZipError.zip64 }

            try need(d, p + 46, nameLen)
            let base = d.startIndex
            let nameData = d.subdata(in: (base + p + 46)..<(base + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "page"

            entries.append(ZipEntry(path: name,
                                    method: method,
                                    compressedSize: Int(comp),
                                    uncompressedSize: Int(uncomp),
                                    localHeaderOffset: Int(localOffset),
                                    isEncrypted: flags & 1 != 0))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }
}

// MARK: - Little-endian readers with bounds checks

private func need(_ d: Data, _ offset: Int, _ length: Int) throws {
    guard offset >= 0, length >= 0, offset + length <= d.count else { throw ZipError.corrupt }
}

private func u16(_ d: Data, _ o: Int) throws -> UInt16 {
    try need(d, o, 2)
    let b = d.startIndex + o
    return UInt16(d[b]) | (UInt16(d[b + 1]) << 8)
}

private func u32(_ d: Data, _ o: Int) throws -> UInt32 {
    try need(d, o, 4)
    let b = d.startIndex + o
    return UInt32(d[b]) | (UInt32(d[b + 1]) << 8) | (UInt32(d[b + 2]) << 16) | (UInt32(d[b + 3]) << 24)
}
