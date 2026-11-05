// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The menu bar glyph: a small ant. Always a template image so macOS tints it for light and dark bars.
/// State is carried by the shape, never by colour: active = solid body, idle = outlined body, busy = dashed outline.
enum StatusIcon {
    enum State { case active, idle, busy }

    static func image(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            let legs = NSBezierPath(); legs.lineWidth = 1.1; legs.lineCapStyle = .round
            for (a, b) in [((7.4, 7.2), (3.2, 4.6)), ((7.2, 9.2), (2.6, 9.4)), ((7.4, 11.2), (3.4, 14.4)), ((10.6, 7.2), (14.8, 4.6)), ((10.8, 9.2), (15.4, 9.4)), ((10.6, 11.2), (14.6, 14.4)), ((8.2, 3.6), (7, 1.6)), ((9.8, 3.6), (11, 1.6))] {
                legs.move(to: NSPoint(x: a.0, y: a.1)); legs.line(to: NSPoint(x: b.0, y: b.1))
            }
            legs.stroke()
            for r in [NSRect(x: 7.1, y: 1.9, width: 3.8, height: 3.8), NSRect(x: 7.4, y: 6.4, width: 3.2, height: 4.2), NSRect(x: 6.5, y: 10.4, width: 5, height: 6)] {
                let p = NSBezierPath(ovalIn: r)
                switch state {
                case .active: p.fill()
                case .idle: p.lineWidth = 1.2; p.stroke()
                case .busy: p.lineWidth = 1.2; p.setLineDash([2, 1.4], count: 2, phase: 0); p.stroke()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
