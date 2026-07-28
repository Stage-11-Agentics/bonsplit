import SwiftUI

public struct BonsplitTabBarHoverKey: EnvironmentKey {
    public static let defaultValue: Bool = false
}

public struct BonsplitActivityAnimationEnabledKey: EnvironmentKey {
    public static let defaultValue: Bool = true
}

public struct BonsplitExplicitActivityAnimationEnabledKey: EnvironmentKey {
    public static let defaultValue: Bool = true
}

public extension EnvironmentValues {
    var bonsplitTabBarHover: Bool {
        get { self[BonsplitTabBarHoverKey.self] }
        set { self[BonsplitTabBarHoverKey.self] = newValue }
    }

    /// Host visibility gate for activity-mark motion. A host that keeps
    /// unselected workspaces mounted can disable their leaf subscriptions
    /// without changing Bonsplit's tab model.
    var bonsplitActivityAnimationEnabled: Bool {
        get { self[BonsplitActivityAnimationEnabledKey.self] }
        set { self[BonsplitActivityAnimationEnabledKey.self] = newValue }
    }

    /// Host gate for explicit per-tab motion. This is separate from the
    /// ordinary activity-animation setting so a host can keep a high-priority
    /// attention channel moving while disabling routine decoration.
    var bonsplitExplicitActivityAnimationEnabled: Bool {
        get { self[BonsplitExplicitActivityAnimationEnabledKey.self] }
        set { self[BonsplitExplicitActivityAnimationEnabledKey.self] = newValue }
    }
}
