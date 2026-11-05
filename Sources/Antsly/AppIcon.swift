// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The Antsly mark: an ant seen from above, built from three round segments like blocks stacked in a page.
/// Drawn in code so the build needs no image tools; `assets/icon.svg` holds the same drawing for the README and site.
enum AppIcon {
    /// - padded: leave the transparent margin macOS expects around Dock icons (824 of 1024).
    static func image(size: CGFloat, padded: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let s = size / 1024
            let inset: CGFloat = padded ? 100 : 0
            let tile = NSRect(x: inset * s, y: inset * s, width: (1024 - 2 * inset) * s, height: (1024 - 2 * inset) * s)
            let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2246, yRadius: tile.width * 0.2246)
            NSGradient(starting: NSColor(srgbRed: 0.204, green: 0.188, blue: 0.184, alpha: 1), ending: NSColor(srgbRed: 0.09, green: 0.082, blue: 0.082, alpha: 1))?.draw(in: shape, angle: -55)
            // Everything below is laid out on a 100-unit grid inside the tile.
            let u = tile.width / 100, ox = tile.minX, oy = tile.minY
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }
            let top = NSColor(srgbRed: 1, green: 0.54, blue: 0.42, alpha: 1), bottom = NSColor(srgbRed: 0.898, green: 0.263, blue: 0.169, alpha: 1)
            let legs = NSBezierPath(); legs.lineWidth = 3.6 * u; legs.lineCapStyle = .round
            for seg in [((44, 42), (28, 30)), ((43, 51), (24, 52)), ((44, 60), (28, 74)), ((56, 42), (72, 30)), ((57, 51), (76, 52)), ((56, 60), (72, 74)), ((47, 24), (40, 15)), ((53, 24), (60, 15))] {
                legs.move(to: pt(CGFloat(seg.0.0), CGFloat(seg.0.1))); legs.line(to: pt(CGFloat(seg.1.0), CGFloat(seg.1.1)))
            }
            top.blended(withFraction: 0.5, of: bottom)?.setStroke(); legs.stroke()
            for (cx, cy, rx, ry) in [(50.0, 26.0, 8.5, 8.5), (50.0, 48.0, 7.5, 10.0), (50.0, 73.0, 11.0, 14.0)] {
                let o = NSBezierPath(ovalIn: NSRect(x: ox + (CGFloat(cx - rx)) * u, y: oy + CGFloat(cy - ry) * u, width: CGFloat(rx * 2) * u, height: CGFloat(ry * 2) * u))
                NSGradient(starting: top, ending: bottom)?.draw(in: o, angle: 90)
            }
            NSColor(srgbRed: 0.09, green: 0.082, blue: 0.082, alpha: 0.55).setFill()
            for (y, w) in [(66.0, 12.0), (72.0, 12.0), (78.0, 9.0)] {
                NSBezierPath(roundedRect: NSRect(x: ox + (50 - CGFloat(w) / 2) * u, y: oy + CGFloat(y) * u, width: CGFloat(w) * u, height: 2.6 * u), xRadius: 1.3 * u, yRadius: 1.3 * u).fill()
            }
            return true
        }
    }

    /// Writes an .iconset folder for `iconutil -c icns`.
    static func writeIconset(to dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                                          ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in sizes {
            guard let tiff = image(size: px, padded: true).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("icon_\(name).png"))
        }
    }
}
