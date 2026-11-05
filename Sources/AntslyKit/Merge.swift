// SPDX-License-Identifier: Apache-2.0

import Foundation

/// First-release live merging: block level, last writer wins. Two people editing different blocks never conflict;
/// two people editing the same block keep the newest edit. Deleted blocks are remembered so they do not come back.
public enum PageMerge {
    public static func merge(local: Page, remote: Page, deleted: Set<String> = []) -> Page {
        var byID: [String: Block] = [:]
        var order: [String] = []
        func take(_ b: Block) {
            guard !deleted.contains(b.id) else { return }
            if let cur = byID[b.id] { if b.stamp > cur.stamp { byID[b.id] = b } } else { byID[b.id] = b; order.append(b.id) }
        }
        // Keep the remote order for blocks both sides know, then append local-only blocks at their local position.
        for b in remote.blocks { take(b) }
        for (i, b) in local.blocks.enumerated() where byID[b.id] == nil {
            take(b)
            let anchor = i > 0 ? local.blocks[i - 1].id : nil
            if let a = anchor, let at = order.firstIndex(of: a), let cur = order.firstIndex(of: b.id) {
                order.remove(at: cur); order.insert(b.id, at: min(at + 1, order.count))
            }
        }
        for b in local.blocks { take(b) }
        let newer = remote.updated > local.updated ? remote : local
        return Page(id: local.id, title: newer.title, blocks: order.compactMap { byID[$0] }, updated: max(local.updated, remote.updated))
    }
}

/// Messages exchanged between a host and its guests, one JSON object per line.
public enum CollabMessage: Codable, Equatable, Sendable {
    case hello(name: String, device: String)
    case approved(role: String)            // "edit" or "view"
    case denied(reason: String)
    case page(Page)                        // full page snapshot, merged on receipt
    case removed(pageID: String)
    case presence(pageID: String, name: String, blockID: String?)
    case pageList([PageInfo])

    public struct PageInfo: Codable, Equatable, Sendable { public var id: String; public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title } }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ line: Data) -> CollabMessage? { try? JSONDecoder().decode(CollabMessage.self, from: line) }
}

/// Splits a byte stream into newline-delimited messages.
public struct LineBuffer: Sendable {
    private var data = Data()
    public init() {}
    public mutating func feed(_ d: Data) -> [Data] {
        data.append(d)
        var out: [Data] = []
        while let i = data.firstIndex(of: 0x0A) { out.append(data[data.startIndex..<i]); data = Data(data[(i + 1)...]) }
        return out
    }
}
