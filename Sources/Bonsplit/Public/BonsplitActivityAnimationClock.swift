import Foundation

/// Policy-free motion channels supported by the activity-mark renderer.
///
/// Hosts decide whether a mark receives a channel at all. Bonsplit owns only
/// the generic sampling and drawing mechanics.
public enum BonsplitActivityMarkMotion: String, Codable, Equatable, Sendable {
    case steppedFill
    case easedDip
    case binaryFlash
    case breathe
}

/// Policy-free presentation supplied by a Bonsplit host for one activity mark.
///
/// Bonsplit interprets only colors and renderer motion. Product semantics such
/// as "flagged", "suppressed", accessibility, and user settings remain owned by
/// the host.
public struct BonsplitTabActivityPresentation: Codable, Equatable, Hashable, Sendable {
    public let colorOverrideHex: String?
    public let motion: BonsplitActivityMarkMotion?
    public let alternateCoreColorHex: String?
    public let alternatesWithBaseColor: Bool
    public let suppressesDefaultMotion: Bool
    public let accessibilityValue: String?

    public init(
        colorOverrideHex: String? = nil,
        motion: BonsplitActivityMarkMotion? = nil,
        alternateCoreColorHex: String? = nil,
        alternatesWithBaseColor: Bool = false,
        suppressesDefaultMotion: Bool = false,
        accessibilityValue: String? = nil
    ) {
        self.colorOverrideHex = colorOverrideHex
        self.motion = motion
        self.alternateCoreColorHex = alternateCoreColorHex
        self.alternatesWithBaseColor = alternatesWithBaseColor
        self.suppressesDefaultMotion = suppressesDefaultMotion
        self.accessibilityValue = accessibilityValue
    }
}

/// Pure animation sampling shared by Bonsplit and host-owned mark renderers.
public enum BonsplitActivityMarkAnimation {
    public static let clockInterval: TimeInterval = 0.2
    public static let workingCycle: TimeInterval = 4
    public static let waitingCycle: TimeInterval = 1.2
    public static let binaryFlashCycle: TimeInterval = 0.4
    public static let breatheCycle: TimeInterval = 1.8

    /// Stable FNV-1a hash over the UUID bytes.
    ///
    /// Swift's `Hasher` is deliberately randomized between processes, so it
    /// cannot provide the stable fleet staggering the mark contract requires.
    public static func stableUnitPhase(for id: UUID) -> Double {
        var uuid = id.uuid
        let hash = withUnsafeBytes(of: &uuid) { bytes -> UInt64 in
            var value: UInt64 = 14_695_981_039_346_656_037
            for byte in bytes {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
            return value
        }
        return Double(hash % 1_000_000) / 1_000_000
    }

    public static func phase(
        at elapsed: TimeInterval,
        id: UUID,
        cycle: TimeInterval
    ) -> Double {
        guard cycle > 0 else { return 0 }
        let offset = stableUnitPhase(for: id) * cycle
        let remainder = (elapsed + offset).truncatingRemainder(dividingBy: cycle)
        return max(0, remainder / cycle)
    }

    /// Number of typewriter-order dots currently present.
    ///
    /// Ranks zero through eight appear at 0.4-second beats. The ninth dot is
    /// therefore present by 3.6 seconds and the full grid holds until the hard
    /// reset at the four-second boundary.
    public static func visibleWorkingDots(at elapsed: TimeInterval, id: UUID) -> Int {
        let cyclePosition = phase(at: elapsed, id: id, cycle: workingCycle) * workingCycle
        return min(9, Int(cyclePosition / 0.4))
    }

    /// Ease-in-out waiting-core waveform: 1 -> 0.15 -> 1 over 1.2 seconds.
    public static func waitingCoreOpacity(at elapsed: TimeInterval, id: UUID) -> Double {
        let unit = phase(at: elapsed, id: id, cycle: waitingCycle)
        let triangle = unit <= 0.5 ? unit * 2 : (1 - unit) * 2
        let eased = 0.5 - 0.5 * cos(.pi * triangle)
        return 1 - 0.85 * eased
    }

    /// Hard half-cycle used with a host-supplied alternate core color.
    public static func binaryFlashShowsAlternate(at elapsed: TimeInterval, id: UUID) -> Bool {
        phase(at: elapsed, id: id, cycle: binaryFlashCycle) >= 0.5
    }

    /// Gentle whole-mark waveform for host-emphasized non-waiting states.
    public static func breatheOpacity(at elapsed: TimeInterval, id: UUID) -> Double {
        let unit = phase(at: elapsed, id: id, cycle: breatheCycle)
        return 0.65 + 0.35 * (0.5 - 0.5 * cos(2 * .pi * unit))
    }
}

/// The one process-wide activity-mark clock.
///
/// Leaves register callbacks only while their host considers them eligible.
/// The clock owns the sole timer and stops it when no leaves are registered.
/// Application lifecycle, accessibility, and settings policy remain entirely
/// host-owned. A callback receives system uptime so every renderer samples the
/// same timebase.
@MainActor
public final class BonsplitActivityAnimationClock {
    public static let shared = BonsplitActivityAnimationClock()

    public typealias Handler = @MainActor (TimeInterval) -> Void

    private var handlers: [UUID: Handler] = [:]
    private var timer: Timer?

    private init() {}

    deinit {
        timer?.invalidate()
    }

    @discardableResult
    public func subscribe(_ handler: @escaping Handler) -> UUID {
        let token = UUID()
        handlers[token] = handler
        handler(ProcessInfo.processInfo.systemUptime)
        startTimerIfNeeded()
        return token
    }

    public func unsubscribe(_ token: UUID) {
        handlers.removeValue(forKey: token)
        if handlers.isEmpty {
            stopTimer()
        }
    }

    private func startTimerIfNeeded() {
        guard !handlers.isEmpty, timer == nil else { return }
        let timer = Timer(
            timeInterval: BonsplitActivityMarkAnimation.clockInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.publish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func publish() {
        let elapsed = ProcessInfo.processInfo.systemUptime
        for handler in handlers.values {
            handler(elapsed)
        }
    }
}
