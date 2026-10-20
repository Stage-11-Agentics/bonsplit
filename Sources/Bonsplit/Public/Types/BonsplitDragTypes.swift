import Foundation

/// Pasteboard type identifiers Bonsplit writes when a tab drag starts.
/// Hosts that accept tab drops outside Bonsplit's own views (a sidebar,
/// a terminal's drag routing) read these instead of copying the strings.
public enum BonsplitDragTypes {
    /// The `TabTransferData` payload written for every tab drag.
    public static let tabTransferIdentifier = "com.splittabbar.tabtransfer"
}
