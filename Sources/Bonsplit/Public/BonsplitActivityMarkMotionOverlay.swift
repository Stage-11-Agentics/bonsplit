import AppKit
import QuartzCore
import SwiftUI

/// The moving part of an activity mark, drawn in Core Animation.
///
/// SwiftUI draws the mark's static geometry (cell, frame, lineage rules). This
/// overlay draws only what moves: the working dots, the waiting core and the
/// flagged alternate core. Each is a `CALayer` with a repeating keyframe
/// animation whose phase comes from `BonsplitActivityMarkAnimation`, so the
/// render server animates it and no tick ever writes SwiftUI state.
///
/// With no motion (Reduce Motion, static marks, an idle or cold mark) or while
/// `BonsplitActivityAnimationClock` is paused, the layers hold the static
/// state: every dot shown, the core opaque, the alternate core hidden.
public struct BonsplitActivityMarkMotionOverlay: NSViewRepresentable {
    public enum Part: Equatable {
        /// A grid of `rows` x 3 working dots, filled bottom-left first.
        case workingDots(rows: Int)
        /// A centered core of the given height (width is the core side).
        case waitingCore(height: CGFloat)
    }

    let part: Part
    let color: NSColor
    let alternateColor: NSColor?
    let motion: BonsplitActivityMarkMotion?
    let phaseId: UUID

    public init(part: Part, color: Color, alternateColor: Color? = nil,
                motion: BonsplitActivityMarkMotion?, phaseId: UUID) {
        self.part = part
        self.color = NSColor(color)
        self.alternateColor = alternateColor.map(NSColor.init)
        self.motion = motion
        self.phaseId = phaseId
    }

    public func makeNSView(context: Context) -> MotionView { MotionView() }

    public func updateNSView(_ view: MotionView, context: Context) {
        view.configure(.init(part: part, color: color, alternateColor: alternateColor,
                             motion: motion, phaseId: phaseId))
    }

    public final class MotionView: NSView {
        public struct Configuration: Equatable {
            public var part: Part
            public var color: NSColor
            public var alternateColor: NSColor?
            public var motion: BonsplitActivityMarkMotion?
            public var phaseId: UUID

            public init(part: Part, color: NSColor, alternateColor: NSColor?,
                        motion: BonsplitActivityMarkMotion?, phaseId: UUID) {
                self.part = part
                self.color = color
                self.alternateColor = alternateColor
                self.motion = motion
                self.phaseId = phaseId
            }
        }

        private var configuration: Configuration?
        private var partLayers: [CALayer] = []
        private var alternateLayer: CALayer?
        private var pauseToken: UUID?

        override public init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override public var isFlipped: Bool { true }
        override public func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let token = pauseToken {
                Task { @MainActor in BonsplitActivityAnimationClock.shared.removePauseObserver(token) }
            }
        }

        public func configure(_ next: Configuration) {
            if pauseToken == nil {
                pauseToken = BonsplitActivityAnimationClock.shared.observePause { [weak self] _ in
                    self?.applyMotion()
                }
            }
            guard next != configuration else { return }
            let rebuild = next.part != configuration?.part || (next.alternateColor == nil) != (configuration?.alternateColor == nil)
            configuration = next
            if rebuild { buildLayers() }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for part in partLayers { part.backgroundColor = next.color.cgColor }
            alternateLayer?.backgroundColor = next.alternateColor?.cgColor
            layoutParts()
            CATransaction.commit()
            applyMotion()
        }

        override public func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutParts()
            CATransaction.commit()
        }

        override public func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
            applyMotion()
        }

        private func buildLayers() {
            partLayers.forEach { $0.removeFromSuperlayer() }
            alternateLayer?.removeFromSuperlayer()
            partLayers = []
            alternateLayer = nil
            guard let configuration, let host = layer else { return }
            let count: Int
            switch configuration.part {
            case .workingDots(let rows): count = max(0, rows) * 3
            case .waitingCore: count = 1
            }
            for _ in 0..<count {
                let dot = CALayer()
                dot.actions = Self.noActions
                host.addSublayer(dot)
                partLayers.append(dot)
            }
            if case .waitingCore = configuration.part, configuration.alternateColor != nil {
                let alternate = CALayer()
                alternate.actions = Self.noActions
                alternate.opacity = 0
                host.addSublayer(alternate)
                alternateLayer = alternate
            }
        }

        private static let noActions: [String: CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull(),
        ]

        private func layoutParts() {
            guard let configuration else { return }
            let scale = window?.backingScaleFactor ?? 2
            for part in partLayers { part.contentsScale = scale }
            switch configuration.part {
            case .workingDots(let rows):
                let side = Metrics.workingDotSide, gap = Metrics.workingDotSpacing
                let gridWidth = 3 * side + 2 * gap
                let gridHeight = CGFloat(rows) * side + CGFloat(max(0, rows - 1)) * gap
                let originX = Self.pixelAligned((bounds.width - gridWidth) / 2, scale: scale)
                let originY = Self.pixelAligned((bounds.height - gridHeight) / 2, scale: scale)
                for (rank, dot) in partLayers.enumerated() {
                    let column = rank % 3
                    let row = rows - 1 - rank / 3
                    dot.frame = CGRect(x: originX + CGFloat(column) * (side + gap),
                                       y: originY + CGFloat(row) * (side + gap), width: side, height: side)
                }
            case .waitingCore(let height):
                let rect = CGRect(x: Self.pixelAligned((bounds.width - Metrics.waitingCoreSide) / 2, scale: scale),
                                  y: Self.pixelAligned((bounds.height - height) / 2, scale: scale),
                                  width: Metrics.waitingCoreSide, height: height)
                partLayers.first?.frame = rect
                alternateLayer?.frame = rect
            }
        }

        /// Centered SwiftUI layout lands on half points (a 9 pt cell, an 8 pt
        /// grid); keep that, snapped to backing pixels rather than whole points.
        static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
            guard scale > 0 else { return value }
            return (value * scale).rounded() / scale
        }

        /// Install or remove the animations for the current motion, attachment
        /// and pause state. Detached from a window, a mark animates nothing.
        func applyMotion() {
            guard let configuration else { return }
            let animate = configuration.motion != nil && (window != nil || attachedForTesting)
                && !BonsplitActivityAnimationClock.shared.isPaused
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for part in partLayers { part.removeAllAnimations(); part.opacity = 1 }
            alternateLayer?.removeAllAnimations()
            alternateLayer?.opacity = 0
            if animate, let motion = configuration.motion {
                install(motion, phaseId: configuration.phaseId)
            }
            CATransaction.commit()
        }

        private func install(_ motion: BonsplitActivityMarkMotion, phaseId: UUID) {
            installCountForTesting += 1
            switch motion {
            case .steppedFill:
                for (rank, dot) in partLayers.enumerated() {
                    dot.add(BonsplitActivityMarkKeyframes.workingDot(rank: rank, phaseId: phaseId, layer: dot),
                            forKey: "bonsplit.activity")
                }
            case .easedDip:
                if let core = partLayers.first {
                    core.add(BonsplitActivityMarkKeyframes.waitingCore(phaseId: phaseId, layer: core),
                             forKey: "bonsplit.activity")
                }
            case .binaryFlash:
                if let alternate = alternateLayer {
                    alternate.add(BonsplitActivityMarkKeyframes.flashAlternate(phaseId: phaseId, layer: alternate),
                                  forKey: "bonsplit.activity")
                }
            case .breathe:
                // Whole-mark motion is `BonsplitActivityMarkBreathe`'s layer.
                break
            }
        }

        /// Test seams: installs so far, and a stand-in for being in a window.
        public private(set) var installCountForTesting = 0
        public var attachedForTesting = false {
            didSet { applyMotion() }
        }

        /// Test seam: each moving layer's frame, after layout.
        public var partFramesForTesting: [CGRect] {
            layoutParts()
            return (partLayers + [alternateLayer].compactMap { $0 }).map(\.frame)
        }

        /// Test seam: the animation installed on each moving layer.
        public var installedAnimationsForTesting: [CAAnimation?] {
            (partLayers + [alternateLayer].compactMap { $0 }).map { $0.animation(forKey: "bonsplit.activity") }
        }
    }

    enum Metrics {
        static let workingDotSide: CGFloat = 2
        static let workingDotSpacing: CGFloat = 1
        static let waitingCoreSide: CGFloat = 4
    }
}

/// A flagged mark that is not waiting breathes as a whole: frame, cell, dots
/// and lineage rules together. The mark's SwiftUI shape is hosted in a
/// layer-backed view whose layer runs the 1.8 s breathe as a Core Animation
/// opacity animation, so no tick writes SwiftUI state. It pauses and resumes
/// with `BonsplitActivityAnimationClock` like the overlay.
public struct BonsplitActivityMarkBreathe<Content: View>: NSViewRepresentable {
    let phaseId: UUID
    let content: Content

    public init(phaseId: UUID, @ViewBuilder content: () -> Content) {
        self.phaseId = phaseId
        self.content = content()
    }

    public func makeNSView(context: Context) -> BreatheView<Content> {
        BreatheView(rootView: content, phaseId: phaseId)
    }

    public func updateNSView(_ view: BreatheView<Content>, context: Context) {
        view.update(rootView: content, phaseId: phaseId)
    }

    public final class BreatheView<Hosted: View>: NSView {
        private let host: NSHostingView<Hosted>
        private var phaseId: UUID
        private var pauseToken: UUID?
        public var attachedForTesting = false {
            didSet { applyMotion() }
        }

        public init(rootView: Hosted, phaseId: UUID) {
            host = NSHostingView(rootView: rootView)
            self.phaseId = phaseId
            super.init(frame: .zero)
            wantsLayer = true
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            pauseToken = BonsplitActivityAnimationClock.shared.observePause { [weak self] _ in self?.applyMotion() }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            if let token = pauseToken {
                Task { @MainActor in BonsplitActivityAnimationClock.shared.removePauseObserver(token) }
            }
        }

        override public func hitTest(_ point: NSPoint) -> NSView? { nil }

        override public func layout() {
            super.layout()
            host.frame = bounds
        }

        override public func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMotion()
        }

        func update(rootView: Hosted, phaseId: UUID) {
            host.rootView = rootView
            guard phaseId != self.phaseId else { return }
            self.phaseId = phaseId
            applyMotion()
        }

        func applyMotion() {
            guard let layer else { return }
            let animate = (window != nil || attachedForTesting) && !BonsplitActivityAnimationClock.shared.isPaused
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "bonsplit.breathe")
            layer.opacity = 1
            if animate {
                layer.add(BonsplitActivityMarkKeyframes.breathe(phaseId: phaseId, layer: layer),
                          forKey: "bonsplit.breathe")
            }
            CATransaction.commit()
        }

        /// Test seam: the breathe animation on the mark's layer, if running.
        public var breatheAnimationForTesting: CAAnimation? { layer?.animation(forKey: "bonsplit.breathe") }
    }
}

/// The keyframe animations, built from `BonsplitActivityMarkAnimation` so the
/// layer marks keep the clock's look, timing and per-panel phase.
public enum BonsplitActivityMarkKeyframes {
    /// Samples per cycle for the eased waiting core (linear between samples,
    /// as the clock interpolated linearly between its 0.2 s ticks).
    static let waitingSamples = 24

    /// The `beginTime` that puts a repeating animation of `cycle` at the same
    /// phase as `BonsplitActivityMarkAnimation.phase(at: now, id:, cycle:)`.
    /// Media time and `systemUptime` share the mach clock.
    static func beginTime(cycle: TimeInterval, phaseId: UUID, layer: CALayer?) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        let progress = BonsplitActivityMarkAnimation.phase(at: now, id: phaseId, cycle: cycle) * cycle
        let local = layer?.convertTime(now, from: nil) ?? now
        return local - progress
    }

    static func repeating(_ animation: CAKeyframeAnimation, cycle: TimeInterval, phaseId: UUID,
                          layer: CALayer?) -> CAKeyframeAnimation {
        animation.duration = cycle
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = beginTime(cycle: cycle, phaseId: phaseId, layer: layer)
        return animation
    }

    /// Dot `rank` (0...8, typewriter order) is present from (rank + 1) x 0.4 s
    /// to the 4 s reset: `visibleWorkingDots` > rank.
    public static func workingDot(rank: Int, phaseId: UUID, layer: CALayer? = nil) -> CAKeyframeAnimation {
        let cycle = BonsplitActivityMarkAnimation.workingCycle
        let appears = min(1, Double(rank + 1) * 0.4 / cycle)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.calculationMode = .discrete
        animation.values = [0, 1]
        animation.keyTimes = [0, NSNumber(value: appears), 1]
        return repeating(animation, cycle: cycle, phaseId: phaseId, layer: layer)
    }

    public static func waitingCore(phaseId: UUID, layer: CALayer? = nil) -> CAKeyframeAnimation {
        let cycle = BonsplitActivityMarkAnimation.waitingCycle
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.calculationMode = .linear
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        for step in 0...waitingSamples {
            let unit = Double(step) / Double(waitingSamples)
            values.append(NSNumber(value: waitingOpacity(unit: unit)))
            keyTimes.append(NSNumber(value: unit))
        }
        animation.values = values
        animation.keyTimes = keyTimes
        return repeating(animation, cycle: cycle, phaseId: phaseId, layer: layer)
    }

    /// The flagged waiting mark shows its alternate core on the second half.
    public static func flashAlternate(phaseId: UUID, layer: CALayer? = nil) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.calculationMode = .discrete
        animation.values = [0, 1]
        animation.keyTimes = [0, 0.5, 1]
        return repeating(animation, cycle: BonsplitActivityMarkAnimation.binaryFlashCycle, phaseId: phaseId,
                         layer: layer)
    }

    /// The whole-mark breathe: 0.65 -> 1 -> 0.65 over 1.8 s.
    public static func breathe(phaseId: UUID, layer: CALayer? = nil) -> CAKeyframeAnimation {
        let cycle = BonsplitActivityMarkAnimation.breatheCycle
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.calculationMode = .linear
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        for step in 0...waitingSamples {
            let unit = Double(step) / Double(waitingSamples)
            values.append(NSNumber(value: 0.65 + 0.35 * (0.5 - 0.5 * cos(2 * .pi * unit))))
            keyTimes.append(NSNumber(value: unit))
        }
        animation.values = values
        animation.keyTimes = keyTimes
        return repeating(animation, cycle: cycle, phaseId: phaseId, layer: layer)
    }

    /// `waitingCoreOpacity` as a function of the unit phase.
    static func waitingOpacity(unit: Double) -> Double {
        let triangle = unit <= 0.5 ? unit * 2 : (1 - unit) * 2
        let eased = 0.5 - 0.5 * cos(.pi * triangle)
        return 1 - 0.85 * eased
    }
}
