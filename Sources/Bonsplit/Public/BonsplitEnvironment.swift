import SwiftUI

public struct BonsplitTabBarHoverKey: EnvironmentKey {
    public static let defaultValue: Bool = false
}

public extension EnvironmentValues {
    var bonsplitTabBarHover: Bool {
        get { self[BonsplitTabBarHoverKey.self] }
        set { self[BonsplitTabBarHoverKey.self] = newValue }
    }
}
