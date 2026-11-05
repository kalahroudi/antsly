// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns pasted or dropped text into page blocks. Runs locally and instantly, using the shapes people already write:
/// checkbox lines become to-dos, dashes and numbers become bullets, short lines ending in a colon become headings.
public enum ContentOrganizer {
    public static func blocks(from raw: String) -> [Block] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(Block(kind: .text, text: para.joined(separator: " "))); para = [] } }

        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("```") {
                flush()
                var body: [String] = []
                while i < lines.count, !lines[i].hasPrefix("```") { body.append(lines[i]); i += 1 }
                i += 1
                out.append(Block(kind: .code, text: body.joined(separator: "\n")))
                continue
            }
            if let (kind, text, checked) = marker(t) { flush(); out.append(Block(kind: kind, text: text, checked: checked)); continue }
            if t.hasPrefix("> ") { flush(); out.append(Block(kind: .callout, text: String(t.dropFirst(2)))); continue }
            if t.hasPrefix("#") {
                let text = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { flush(); out.append(Block(kind: .heading, text: text)); continue }
            }
            if t.count <= 60, t.hasSuffix(":"), !t.dropLast().contains(":") { flush(); out.append(Block(kind: .heading, text: String(t.dropLast()))); continue }
            // Lines that stop short are separate thoughts (an address, a subject). Long ones were wrapped by the sender, so they rejoin.
            if let last = para.last, last.count < 50 { flush() }
            para.append(t)
        }
        flush()
        return out
    }

    private static func marker(_ t: String) -> (Block.Kind, String, Bool)? {
        for p in ["- [ ] ", "* [ ] ", "[ ] ", "☐ ", "□ "] where t.hasPrefix(p) { return (.todo, String(t.dropFirst(p.count)), false) }
        for p in ["- [x] ", "- [X] ", "* [x] ", "[x] ", "[X] ", "☑ ", "✅ ", "✓ "] where t.hasPrefix(p) { return (.todo, String(t.dropFirst(p.count)), true) }
        for p in ["- ", "* ", "• ", "– ", "— "] where t.hasPrefix(p) { return (.bullet, String(t.dropFirst(p.count)), false) }
        if let r = t.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) { return (.bullet, String(t[r.upperBound...]), false) }
        return nil
    }
}

/// Asks the user's own `claude` command to sort a piece of text into blocks. Only runs when the user asks for it,
/// and the text goes to that tool and nowhere else.
public enum AIOrganizer {
    public static var available: Bool { Shell.find("claude") != nil }
    static let maxChars = 30_000

    public static func prompt(for text: String) -> String {
        """
        Organise the text below into page blocks that suit its content: a to-do list for tasks, bullets for lists, headings for sections, short paragraphs for prose, a callout for a key point. Keep the author's wording. Drop greetings, signatures and repeated quoted mail.
        Reply with only a JSON array and nothing else. Each item: {"kind": "text" | "heading" | "todo" | "bullet" | "callout" | "code", "text": "...", "checked": false}.

        TEXT:
        \(text.prefix(maxChars))
        """
    }

    /// Reads the JSON array out of a reply, even when it is wrapped in a code fence or a sentence.
    public static func parse(_ output: String) -> [Block]? {
        guard let a = output.firstIndex(of: "["), let b = output.lastIndex(of: "]"), a < b,
              let arr = try? JSONSerialization.jsonObject(with: Data(output[a...b].utf8)) as? [[String: Any]] else { return nil }
        let blocks = arr.compactMap { o -> Block? in
            guard let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let kind = (o["kind"] as? String).flatMap(Block.Kind.init(rawValue:)).flatMap { Block.Kind.writable.contains($0) ? $0 : nil } ?? .text
            return Block(kind: kind, text: text, checked: kind == .todo && (o["checked"] as? Bool ?? false))
        }
        return blocks.isEmpty ? nil : blocks
    }

    public static func organise(_ text: String) async throws -> [Block] {
        guard available else { throw ShellError.failed(command: "claude", status: 1, stderr: "Claude Code is not installed, so there is nothing to organise with. Install it, or keep the blocks Antsly made.") }
        let out = try await Shell.check("claude", ["-p", prompt(for: text)], cwd: FileManager.default.temporaryDirectory, timeout: 120)
        guard let blocks = parse(out) else { throw ShellError.failed(command: "claude", status: 1, stderr: "The reply could not be read as blocks. Your text was left as it was.") }
        return blocks
    }
}
