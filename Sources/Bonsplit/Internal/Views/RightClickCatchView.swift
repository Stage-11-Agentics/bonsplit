import AppKit
import SwiftUI

/// Transparent AppKit overlay that captures only context-click gestures —
/// right mouse, or ctrl+left mouse (macOS's equivalent) — and reports the
/// covered control's frame in screen coordinates. Every other event falls
/// through (`hitTest` returns nil for it), so the SwiftUI control underneath
/// keeps its click, hover, and tooltip behavior untouched.
///
/// Exists because SwiftUI (through macOS 15) has no right-click gesture, and
/// `.contextMenu`'s content builder is not guaranteed to run during the click
/// that summons it — a host that needs a deterministic "open my own UI on
/// right-click" trigger gets one real pointer event here instead.
struct RightClickCatchView: NSViewRepresentable {
    let onContextClick: (CGRect) -> Void

    func makeNSView(context: Context) -> RightClickCatchNSView {
        let view = RightClickCatchNSView()
        view.onContextClick = onContextClick
        return view
    }

    func updateNSView(_ nsView: RightClickCatchNSView, context: Context) {
        nsView.onContextClick = onContextClick
    }
}

final class RightClickCatchNSView: NSView {
    var onContextClick: ((CGRect) -> Void)?

    /// Claim the hit only for context-click events; everything else passes
    /// through to the SwiftUI control underneath. `NSApp.currentEvent` is
    /// reliable here: `hitTest` runs synchronously inside the dispatch of
    /// exactly the event being routed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)),
              let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return self
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control) ? self : nil
        default:
            return nil
        }
    }

    /// Fire even when the window isn't key — context menus open on inactive
    /// windows, and this trigger stands in for one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        fire()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            fire()
        } else {
            super.mouseDown(with: event)
        }
    }

    private func fire() {
        guard let window else { return }
        onContextClick?(window.convertToScreen(convert(bounds, to: nil)))
    }
}
