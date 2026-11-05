// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inline formatting for page text: **bold**, *italic*, ~~strike~~, `code` and [links](https://example.com).
/// Pages keep the plain Markdown; this only decides how a block looks when it is not being edited.
public enum InlineMarkdown {
    /// Bare web addresses become links. Ones already inside a Markdown link or in `code` are left alone.
    static func linkify(_ s: String) -> String {
        guard s.contains("http") else { return s }
        let pattern = #"(?<![(\]`])\bhttps?://[^\s)<>\]`]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            var url = String(out[r])
            var tail = ""
            while let last = url.last, ".,;:!?".contains(last) { tail = String(last) + tail; url.removeLast() }
            out.replaceSubrange(r, with: "[\(url)](\(url))\(tail)")
        }
        return out
    }

    /// True when the text has anything worth rendering. Plain text skips the parser.
    public static func hasMarkup(_ s: String) -> Bool {
        s.contains("*") || s.contains("==") || s.contains("`") || s.contains("~~") || s.contains("](") || s.contains("http") || s.contains("_")
    }

    /// The words without the markup, for titles and notifications: no asterisks, backticks, highlight marks or link syntax.
    public static func plain(_ s: String) -> String {
        String(attributed(s).characters).replacingOccurrences(of: "==", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text that does not parse as Markdown comes back as it was written, never as an error.
    public static func attributed(_ s: String) -> AttributedString { highlighted(s).text }

    /// The formatted text plus the character ranges the author marked with ==double equals==, so the view can paint them.
    public static func highlighted(_ s: String) -> (text: AttributedString, marks: [Range<Int>]) {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        func parse(_ part: String) -> AttributedString { (try? AttributedString(markdown: linkify(part), options: opts)) ?? AttributedString(part) }
        guard s.contains("=="), let re = try? NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#) else { return (parse(s), []) }
        var out = AttributedString(), marks: [Range<Int>] = [], last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
            out += parse(String(s[last..<whole.lowerBound]))
            let start = out.characters.count
            out += parse(String(s[inner]))
            marks.append(start..<out.characters.count)
            last = whole.upperBound
        }
        out += parse(String(s[last...]))
        return (out, marks)
    }

    /// Wraps part of a block's text in highlight marks. `range` counts characters; taking the marks off again works the same way.
    public static func toggleHighlight(in text: String, range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= text.count, !range.isEmpty else { return text }
        let a = text.index(text.startIndex, offsetBy: range.lowerBound), b = text.index(text.startIndex, offsetBy: range.upperBound)
        let chosen = String(text[a..<b])
        if chosen.hasPrefix("=="), chosen.hasSuffix("=="), chosen.count > 4 { return text.replacingCharacters(in: a..<b, with: String(chosen.dropFirst(2).dropLast(2))) }
        if a >= text.index(text.startIndex, offsetBy: 2), b <= text.index(text.endIndex, offsetBy: -2), text[text.index(a, offsetBy: -2)..<a] == "==", text[b..<text.index(b, offsetBy: 2)] == "==" {
            return text.replacingCharacters(in: text.index(a, offsetBy: -2)..<text.index(b, offsetBy: 2), with: chosen)
        }
        return text.replacingCharacters(in: a..<b, with: "==\(chosen)==")
    }
}
