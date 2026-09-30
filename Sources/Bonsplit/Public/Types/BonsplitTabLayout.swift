import Foundation

/// How a pane presents its tabs.
public enum BonsplitTabLayout: String, Codable, CaseIterable, Sendable {
    /// Browser-style horizontal tabs, with the count cell opening the sheet.
    case tabs
    /// A vertical rail docked on the area's left edge, toggled by the count cell.
    case rail
}
