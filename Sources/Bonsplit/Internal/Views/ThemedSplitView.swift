import AppKit

/// `NSSplitView` subclass used by Bonsplit to render pane dividers with a customizable
/// color and thickness. The structural `dividerStyle = .thin` hint is preserved by the
/// caller so AppKit's hit-test region stays reasonable; this subclass only customizes the
/// *rendered* thickness when `overrideThickness` is set.
///
/// The `mouseDownCanMoveWindow = false` override is load-bearing for split panes hosted
/// inside non-titlebar windows (`presentationMode == "minimal"`) — see the long comment
/// below for context.
class ThemedSplitView: NSSplitView {
    var customDividerColor: NSColor?

    /// When non-nil, overrides `NSSplitView.dividerThickness`. `nil` falls through to
    /// AppKit's default thickness for the current `dividerStyle`.
    var overrideThickness: CGFloat?

    override var dividerColor: NSColor {
        customDividerColor ?? super.dividerColor
    }

    override var dividerThickness: CGFloat {
        overrideThickness ?? super.dividerThickness
    }

    override var isOpaque: Bool { false }

    // NSSplitView's default `mouseDownCanMoveWindow` reports `true` whenever it
    // appears opaque to AppKit, and even with `isOpaque=false` AppKit can
    // promote it back to draggable when nested inside a non-titlebar window.
    // In `presentationMode == "minimal"` (no titlebar drag region), AppKit was
    // treating mouseDowns inside the LEFT pane of a horizontal split as window
    // drag intents and consuming the mouseUp before SwiftUI's tap gesture
    // could fire on tab items. Forcing `false` here keeps the entire pane
    // hosting chain non-draggable so SwiftUI gestures get every click.
    // See `NonDraggableHostingView` in SplitNodeView.swift for the rest of
    // the chain.
    override var mouseDownCanMoveWindow: Bool { false }
}
