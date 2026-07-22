import Foundation

public enum BonsplitTabActivityState: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case idle
    case cold
    case waiting
}
