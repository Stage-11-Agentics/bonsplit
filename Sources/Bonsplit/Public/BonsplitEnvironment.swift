import SwiftUI

public struct BonsplitTabBarHoverKey: EnvironmentKey {
    public static let defaultValue: Bool = false
}

public struct BonsplitActivityAnimationEnabledKey: EnvironmentKey {
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
}
