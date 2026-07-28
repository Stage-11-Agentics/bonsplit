import Foundation

/// Represents a tab's metadata (read-only snapshot for library consumers)
public struct Tab: Identifiable, Hashable, Sendable {
    public let id: TabID
    public let title: String
    public let hasCustomTitle: Bool
    public let icon: String?
    /// Optional image data (PNG recommended) for the tab icon. When present, this takes precedence over `icon`.
    public let iconImageData: Data?
    /// Consumer-defined tab kind identifier (for example, "terminal" or "browser").
    public let kind: String?
    public let isDirty: Bool
    /// Whether the tab should show an "unread/activity" badge (library consumer-defined meaning).
    public let showsNotificationBadge: Bool
    /// Whether the tab should show an activity/loading indicator (e.g. spinning icon).
    public let isLoading: Bool
    /// Whether the tab is pinned in its pane.
    public let isPinned: Bool
    /// Optional per-tab accent color expressed as `#RRGGBB`. Rendering
    /// applies a restrained accent indicator (top rail + small leading
    /// dot) without otherwise altering the tab chrome.
    public let customColorHex: String?
    /// Optional host-assigned tab number, rendered as an "N: " title prefix
    /// when `Appearance.showTabOrdinals` is on.
    public let displayOrdinal: Int?
    public let activityState: BonsplitTabActivityState?
    public let activityPresentation: BonsplitTabActivityPresentation?

    public init(
        id: TabID = TabID(),
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = nil,
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        customColorHex: String? = nil,
        displayOrdinal: Int? = nil,
        activityState: BonsplitTabActivityState? = nil,
        activityPresentation: BonsplitTabActivityPresentation? = nil
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.icon = icon
        self.iconImageData = iconImageData
        self.kind = kind
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.isLoading = isLoading
        self.isPinned = isPinned
        self.customColorHex = customColorHex
        self.displayOrdinal = displayOrdinal
        self.activityState = activityState
        self.activityPresentation = activityPresentation
    }

    internal init(from tabItem: TabItem) {
        self.id = TabID(id: tabItem.id)
        self.title = tabItem.title
        self.hasCustomTitle = tabItem.hasCustomTitle
        self.icon = tabItem.icon
        self.iconImageData = tabItem.iconImageData
        self.kind = tabItem.kind
        self.isDirty = tabItem.isDirty
        self.showsNotificationBadge = tabItem.showsNotificationBadge
        self.isLoading = tabItem.isLoading
        self.isPinned = tabItem.isPinned
        self.customColorHex = tabItem.customColorHex
        self.displayOrdinal = tabItem.displayOrdinal
        self.activityState = tabItem.activityState
        self.activityPresentation = tabItem.activityPresentation
    }
}
