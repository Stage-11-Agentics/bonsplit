import AppKit
import Foundation

/// Shared user-default contract for activity-mark motion.
///
/// Animation is the default, so the persisted value describes the opt-out.
/// Hosts can bind this key directly in their Settings UI.
public enum BonsplitActivityMarkSettings {
    public static let staticMarksKey = "staticActivityMarks"
    public static let defaultStaticMarks = false
}

/// The three motion channels supported by the shape vocabulary.
///
/// `flaggedWaiting` is separate because its hard core flash replaces the
/// ordinary waiting dip. Flagged working deliberately uses `working`.
public enum BonsplitActivityMarkMotion: Sendable {
    case working
    case waiting
    case flaggedWaiting
}

/// Pure animation sampling shared by Bonsplit and host-owned mark renderers.
public enum BonsplitActivityMarkAnimation {
    public static let clockInterval: TimeInterval = 0.2
    public static let workingCycle: TimeInterval = 4
    public static let waitingCycle: TimeInterval = 1.2
    public static let flaggedWaitingCycle: TimeInterval = 0.4

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
    /// therefore present by 3.2 seconds and the full grid holds until the hard
    /// reset at the four-second boundary.
    public static func visibleWorkingDots(at elapsed: TimeInterval, id: UUID) -> Int {
        let cyclePosition = phase(at: elapsed, id: id, cycle: workingCycle) * workingCycle
        return min(9, Int(cyclePosition / 0.4) + 1)
    }

    /// Ease-in-out waiting-core waveform: 1 -> 0.15 -> 1 over 1.2 seconds.
    public static func waitingCoreOpacity(at elapsed: TimeInterval, id: UUID) -> Double {
        let unit = phase(at: elapsed, id: id, cycle: waitingCycle)
        let triangle = unit <= 0.5 ? unit * 2 : (1 - unit) * 2
        let eased = 0.5 - 0.5 * cos(.pi * triangle)
        return 1 - 0.85 * eased
    }

    /// Hard violet/white half-cycle for the flagged-waiting core.
    public static func flaggedWaitingShowsWhite(at elapsed: TimeInterval, id: UUID) -> Bool {
        phase(at: elapsed, id: id, cycle: flaggedWaitingCycle) >= 0.5
    }
}

/// The one process-wide activity-mark clock.
///
/// Leaves register callbacks only while they are visible and eligible. The
/// clock owns the sole timer, stops it when no leaves are registered, and
/// pauses it while the application is inactive. A callback receives system
/// uptime so every renderer samples the same timebase.
@MainActor
public final class BonsplitActivityAnimationClock {
    public static let shared = BonsplitActivityAnimationClock()

    public typealias Handler = @MainActor (TimeInterval) -> Void

    private var handlers: [UUID: Handler] = [:]
    private var timer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isApplicationActive: Bool

    private init(notificationCenter: NotificationCenter = .default) {
        isApplicationActive = NSApp?.isActive ?? true
        notificationTokens = [
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isApplicationActive = true
                    self?.startTimerIfNeeded()
                    self?.publish()
                }
            },
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isApplicationActive = false
                    self?.stopTimer()
                }
            },
        ]
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
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
        guard isApplicationActive, !handlers.isEmpty, timer == nil else { return }
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
        guard isApplicationActive else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime
        for handler in handlers.values {
            handler(elapsed)
        }
    }
}
