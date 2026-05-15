import Foundation

/// Context menu actions that can be triggered from a tab item.
public enum TabContextAction: String, CaseIterable, Sendable {
    case rename
    case clearName
    /// Close just this tab. Equivalent to the close-X button on the tab,
    /// surfaced as a menu entry so right-click drives it without aiming
    /// at the X target.
    case closeTab
    /// Close the entire pane that contains this tab. Equivalent to the
    /// pane-close button in the tab bar's trailing toolbar.
    case closePane
    case closeToLeft
    case closeToRight
    case closeOthers
    case move
    case moveToLeftPane
    case moveToRightPane
    case newTerminalToRight
    case newBrowserToRight
    case reload
    case duplicate
    case togglePin
    case markAsRead
    case markAsUnread
    case toggleZoom
    /// Clear the tab's customColorHex back to nil. Raised from the
    /// "Tab Color" submenu when a color is currently set.
    case clearColor
    /// Open a host-supplied prompt for the user to enter a custom hex
    /// color for the tab. The host typically presents an input dialog
    /// and then calls `BonsplitController.requestSetTabColor` (or
    /// directly mutates state) once the user commits.
    case chooseCustomColor
}
