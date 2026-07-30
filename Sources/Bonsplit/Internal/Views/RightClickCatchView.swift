import AppKit
import SwiftUI

/// Transparent AppKit overlay that captures pointer gestures a SwiftUI control
/// can't express deterministically (through macOS 15 SwiftUI has no right-click
/// gesture, and `.contextMenu`'s content builder is not guaranteed to run
/// during the click that summons it).
///
/// Two modes:
/// - **Context-only** (`onPrimaryClick == nil`): claims right-mouse and
///   ctrl+left events; plain left clicks, hover, and tooltips fall through to
///   the SwiftUI control underneath.
/// - **Full ownership** (`onPrimaryClick != nil`): also claims plain left
///   clicks — a quick click fires `onPrimaryClick` on mouse-up inside, a press
///   held past `longPressDelay` fires `onContextClick` instead (the macOS
///   split-button idiom: hold for the menu). The SwiftUI control underneath
///   becomes visual-only (hover still reaches it; its action never fires).
///
/// `onContextClick` receives the covered control's frame in screen coordinates
/// so hosts can anchor their own UI (menu, popover) to the control.
struct RightClickCatchView: NSViewRepresentable {
    let onContextClick: (CGRect) -> Void
    var onPrimaryClick: ((CGRect) -> Void)?
    var longPressDelay: TimeInterval = 0.4

    func makeNSView(context: Context) -> RightClickCatchNSView {
        let view = RightClickCatchNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: RightClickCatchNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: RightClickCatchNSView) {
        view.onContextClick = onContextClick
        view.onPrimaryClick = onPrimaryClick
        view.longPressDelay = longPressDelay
    }
}

final class RightClickCatchNSView: NSView {
    var onContextClick: ((CGRect) -> Void)?
    var onPrimaryClick: ((CGRect) -> Void)?
    var longPressDelay: TimeInterval = 0.4

    private var longPressTimer: Timer?
    private var longPressFired = false

    /// Claim only the events this view owns; everything else passes through to
    /// the SwiftUI control underneath. `NSApp.currentEvent` is reliable here:
    /// `hitTest` runs synchronously inside the dispatch of the event being
    /// routed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)),
              let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return self
        case .leftMouseDown, .leftMouseUp:
            if event.modifierFlags.contains(.control) { return self }
            return onPrimaryClick != nil ? self : nil
        default:
            return nil
        }
    }

    /// Fire even when the window isn't key — context menus open on inactive
    /// windows, and this trigger stands in for one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        fireContext()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            fireContext()
            return
        }
        guard onPrimaryClick != nil else {
            super.mouseDown(with: event)
            return
        }
        longPressFired = false
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.longPressFired = true
            self.fireContext()
        }
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        guard let onPrimaryClick else {
            super.mouseUp(with: event)
            return
        }
        // Long press already opened the context UI; swallow the release.
        if longPressFired {
            longPressFired = false
            return
        }
        // Real-button semantics: releasing outside cancels the click.
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local), let window {
            onPrimaryClick(window.convertToScreen(convert(bounds, to: nil)))
        }
    }

    private func fireContext() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        guard let window else { return }
        onContextClick?(window.convertToScreen(convert(bounds, to: nil)))
    }
}
