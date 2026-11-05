// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// A slim rounded knob on a transparent track, shown only while scrolling. Replaces the stock scroller.
final class SlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 9 }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let r = rect(for: .knob).insetBy(dx: 2.5, dy: 2)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor.white.withAlphaComponent(0.34) : NSColor.black.withAlphaComponent(0.3)).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2).fill()
    }
}

private struct ScrollStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let sv = v.enclosingScrollView ?? v.superview?.firstDescendant(of: NSScrollView.self) else { return }
            sv.scrollerStyle = .overlay
            sv.autohidesScrollers = true
            sv.hasHorizontalScroller = false
            if !(sv.verticalScroller is SlimScroller) { sv.verticalScroller = SlimScroller() }
        }
    }
}
private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for s in subviews { if let t = s as? T { return t }; if let t = s.firstDescendant(of: type) { return t } }
        return nil
    }
}

/// The app's only scroll container: a slim overlay knob, and a soft fade at the edges so content never ends abruptly.
/// Panes are laid out to fit the window; this appears only when content is genuinely longer than the space.
struct StyledScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) { content }
            .background(ScrollStyler())
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
            })
    }
}
