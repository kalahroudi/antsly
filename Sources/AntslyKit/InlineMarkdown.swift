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
        s.contains("*") || s.contains("`") || s.contains("~~") || s.contains("](") || s.contains("http") || s.contains("_")
    }

    /// Text that does not parse as Markdown comes back as it was written, never as an error.
    public static func attributed(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: linkify(s), options: opts)) ?? AttributedString(s)
    }
}
