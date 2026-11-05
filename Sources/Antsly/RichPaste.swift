// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Turns copied web or mail content (HTML) into the Markdown pages use, keeping bold, italic, code, links and lists.
@MainActor enum RichPaste {
    static func markdown(fromHTML html: String) -> String? {
        guard let data = html.data(using: .utf8),
              let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
              a.length > 0 else { return nil }
        let ns = a.string as NSString
        var out = ""
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { attrs, range, _ in
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let mono = font?.isFixedPitch ?? false
            let link = (attrs[.link] as? URL)?.absoluteString ?? (attrs[.link] as? String)
            let strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            // Markers wrap each line of the run on its own, so they never straddle a line break.
            let pieces = ns.substring(with: range).components(separatedBy: "\n").map { line -> String in
                let core = line.trimmingCharacters(in: .whitespaces)
                guard !core.isEmpty else { return line }
                var t = core
                if mono { t = "`\(t)`" }
                if traits.contains(.boldFontMask), !mono { t = "**\(t)**" }
                if traits.contains(.italicFontMask), !mono { t = "*\(t)*" }
                if strike { t = "~~\(t)~~" }
                if let link, link.hasPrefix("http") { t = "[\(core)](\(link))" }
                let lead = line.prefix { $0 == " " || $0 == "\t" }, trail = line.reversed().prefix { $0 == " " || $0 == "\t" }
                return lead + t + String(trail.reversed())
            }
            out += pieces.joined(separator: "\n")
        }
        // Lists come through as "\t•\titem" and non-breaking spaces; tidy both and collapse blank runs.
        var lines = out.replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("•") { return "- " + t.dropFirst().trimmingCharacters(in: .whitespaces) }
            return t
        }
        var cleaned: [String] = []
        for l in lines { if l.isEmpty, cleaned.last?.isEmpty ?? true { continue }; cleaned.append(l) }
        lines = cleaned
        let md = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return md.isEmpty ? nil : md
    }
}
