import Foundation

/// Turns file names like "[Group] Berserk v03 (2019).cbz" into
/// series "Berserk", number 3, title "Berserk v03".
enum NameParser {
    struct Result {
        var series: String
        var number: Double?
        var title: String
    }

    static func parse(_ fileName: String, isFolder: Bool) -> Result {
        var name = isFolder ? fileName : (fileName as NSString).deletingPathExtension
        name = clean(name)
        let title = name.isEmpty ? fileName : name

        // "Vol 3", "Volume 3", "v03", "Ch. 12", "Chapter 12", "c012", "#5", "Ep 4"
        let marker = #"(?i)(?:\b(?:vol(?:ume)?|ch(?:apter)?|ep(?:isode)?)\.?\s*|\b[vc](?=\d)|#\s*)(\d+(?:\.\d+)?)"#
        if let m = firstMatch(marker, in: name),
           let whole = Range(m.range, in: name),
           let num = Range(m.range(at: 1), in: name) {
            let series = trimSeparators(String(name[..<whole.lowerBound]))
            return Result(series: series.isEmpty ? title : series,
                          number: Double(name[num]),
                          title: title)
        }

        // Trailing number: "Akira 02"
        if let m = firstMatch(#"^(.*?)[\s\-]+(\d+(?:\.\d+)?)$"#, in: name),
           let pre = Range(m.range(at: 1), in: name),
           let num = Range(m.range(at: 2), in: name) {
            let series = trimSeparators(String(name[pre]))
            if !series.isEmpty {
                return Result(series: series, number: Double(name[num]), title: title)
            }
        }

        return Result(series: title, number: nil, title: title)
    }

    /// Cleans a folder name used as a series name.
    static func cleanSeries(_ raw: String) -> String {
        let c = trimSeparators(clean(raw))
        return c.isEmpty ? raw : c
    }

    /// Safe on-disk folder name for a series.
    static func safeFolderName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 80 { s = String(s.prefix(80)) }
        return s.isEmpty ? "Unsorted" : s
    }

    // MARK: helpers

    private static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        // Drop [scan group], (year), {tags}
        s = replace(#"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}"#, in: s, with: " ")
        s = replace(#"\s+"#, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimSeparators(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.,:").union(.whitespacesAndNewlines))
    }

    private static func firstMatch(_ pattern: String, in s: String) -> NSTextCheckingResult? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func replace(_ pattern: String, in s: String, with r: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r)
    }
}
