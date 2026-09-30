import SwiftUI
import AppKit

// MARK: - Pure scroll math

/// The strip's scroll rules, free of AppKit and SwiftUI so they can be tested.
/// All x values are in the strip viewport's own space (0 is its leading edge).
enum TabStripScroll {
    /// The strip masks 24pt fades at its ends.
    static let fadeWidth: CGFloat = 24

    /// How far to scroll (positive toward the end, negative toward the start) to
    /// bring a tab spanning `minX...maxX` clear of the fades and of the
    /// count cell and controls that cover the strip's right end. Zero when it
    /// is already clear. A tab wider than the clear area is aligned to its
    /// leading side.
    static func revealDelta(
        frameMinX: CGFloat,
        frameMaxX: CGFloat,
        viewportWidth: CGFloat,
        trailingObscured: CGFloat,
        fade: CGFloat = fadeWidth
    ) -> CGFloat {
        let clearMin = fade
        let clearMax = viewportWidth - trailingObscured - fade
        guard clearMax > clearMin else { return frameMinX - clearMin }
        if frameMaxX - frameMinX > clearMax - clearMin { return frameMinX - clearMin }
        if frameMinX < clearMin { return frameMinX - clearMin }
        if frameMaxX > clearMax { return frameMaxX - clearMax }
        return 0
    }

    /// The tab is wholly outside the part of the strip the operator can see.
    static func isFullyOutOfView(
        frameMinX: CGFloat,
        frameMaxX: CGFloat,
        viewportWidth: CGFloat,
        trailingObscured: CGFloat
    ) -> Bool {
        frameMaxX <= 0 || frameMinX >= viewportWidth - trailingObscured
    }

    /// A content or viewport width change (a title growing, a status appearing,
    /// a window resize) must not fight the operator: re-reveal the selected tab
    /// only when it is wholly out of view and nothing has scrolled the strip
    /// since the selection changed.
    static func shouldRevealAfterGeometryChange(
        selectedMinX: CGFloat,
        selectedMaxX: CGFloat,
        viewportWidth: CGFloat,
        trailingObscured: CGFloat,
        userScrolledSinceSelection: Bool
    ) -> Bool {
        guard !userScrolledSinceSelection else { return false }
        return isFullyOutOfView(
            frameMinX: selectedMinX,
            frameMaxX: selectedMaxX,
            viewportWidth: viewportWidth,
            trailingObscured: trailingObscured
        )
    }

    static func clampedOffset(_ offset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, contentWidth - viewportWidth))
    }

    /// The `ScrollViewProxy.scrollTo` anchor (x) that puts a tab where `delta`
    /// would have put it: the proxy aligns the anchor point of the tab with the
    /// same point of the viewport, so the tab's leading edge ends at
    /// `a * (viewport - width)`.
    static func proxyAnchor(frameMinX: CGFloat, frameWidth: CGFloat, viewportWidth: CGFloat, delta: CGFloat) -> CGFloat {
        let travel = viewportWidth - frameWidth
        guard travel > 0 else { return 0 }
        return min(1, max(0, (frameMinX - delta) / travel))
    }
}

// MARK: - Wheel routing

/// One scroll-wheel event, reduced to what routing needs.
struct TabStripWheelInput: Equatable {
    var phase: NSEvent.Phase
    var momentumPhase: NSEvent.Phase
    var deltaX: CGFloat
    var deltaY: CGFloat
}

enum TabStripWheelAction: Equatable {
    /// Leave the event alone.
    case pass
    /// Scroll the strip sideways by this much (already sign-adjusted: positive
    /// scrolls toward the end) and consume the event.
    case remap(CGFloat)
}

/// Decides, once per gesture, whether the strip takes a vertical scroll and
/// keeps that decision through momentum. A scroll that started over a terminal
/// and drifts onto the strip stays the terminal's; one that started on the strip
/// stays the strip's even when the pointer wanders off it. A gesture with no
/// phases (a notched mouse wheel) is decided event by event.
struct TabStripWheelRouter {
    private var latched: Bool?
    /// This router saw the current gesture begin. A gesture it did not see begin
    /// (it started in another view, or before routing was on) is never the strip's.
    private var sawBegin = false
    /// The finger lifted (`phase` ended) and no momentum has followed yet.
    private var fingerLifted = false

    mutating func reset() { latched = nil; sawBegin = false; fingerLifted = false }

    /// `eligible` is asked at most once per gesture, at its first event that
    /// carries movement: it answers whether the strip may take this gesture
    /// (visible, interactive, pointer really over the strip, content
    /// overflowing).
    mutating func route(_ input: TabStripWheelInput, eligible: () -> Bool) -> TabStripWheelAction {
        let hasPhases = !input.phase.isEmpty || !input.momentumPhase.isEmpty
        let moves = input.deltaX != 0 || input.deltaY != 0

        guard hasPhases else {
            // Discrete wheel: decide every event on its own.
            latched = nil
            guard moves, abs(input.deltaY) > abs(input.deltaX), eligible() else { return .pass }
            return .remap(-input.deltaY)
        }

        if input.phase.contains(.began) || input.phase.contains(.mayBegin) {
            latched = nil
            sawBegin = true
            fingerLifted = false
        } else if fingerLifted, !input.phase.isEmpty {
            // A new touch sequence whose start was never seen here.
            latched = false
            sawBegin = false
            fingerLifted = false
        }
        if latched == nil, input.momentumPhase.isEmpty, moves {
            // First moving event of a gesture: seen from its start, vertical-dominant
            // and eligible.
            latched = sawBegin && abs(input.deltaY) > abs(input.deltaX) && eligible()
        }

        let takes = latched == true
        if input.phase.contains(.ended) || input.phase.contains(.cancelled) {
            fingerLifted = true
        }
        if !input.momentumPhase.isEmpty { fingerLifted = false }
        if input.momentumPhase.contains(.ended) || input.momentumPhase.contains(.cancelled) {
            latched = nil
            sawBegin = false
        }
        guard takes, moves else { return .pass }
        return .remap(-input.deltaY)
    }
}

// MARK: - Scroll bridge

/// Everything the tab bar needs to drive, and listen to, its horizontal strip:
/// wheel remap, drag auto-scroll, reveal-a-tab, automation offsets. SwiftUI's
/// scroll view is not always reachable as an `NSScrollView`, so the bar mirrors
/// SwiftUI's own offset and widths here and offsets are written through one of
/// two drivers: `ScrollPosition` (macOS 15+) or, where the `NSScrollView` is
/// reachable, its clip view. With neither, nothing is written and nothing is
/// consumed.
@MainActor
final class TabBarScrollViewBridge: ObservableObject {
    struct ScrollMetrics {
        let offset: CGFloat
        let documentWidth: CGFloat
        let viewportWidth: CGFloat
    }

    enum RevealReason { case selection, geometry, flash, hover }

    weak var scrollView: NSScrollView?
    /// SwiftUI's own view of the strip (offset, content and viewport width).
    struct Mirror {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
    }
    var mirror = Mirror()
    /// The bar's background view (the whole bar, chrome included).
    weak var barView: NSView?
    /// Width of the chrome that covers the strip's right end.
    var chromeInset: CGFloat = 0
    /// Whether the bar's workspace is live; set by the bar.
    var isInteractiveProvider: (() -> Bool)?

    /// `ScrollPosition`-backed absolute scroll (macOS 15+).
    var scrollToOffset: ((CGFloat) -> Void)?
    /// `ScrollViewProxy.scrollTo` for a tab id: the last-resort driver.
    var scrollToID: ((UUID, UnitPoint) -> Void)?

    /// Frames of the few tabs the bar is measuring (selected, hovered, flashed),
    /// in the strip viewport's space.
    var tabFrames: [UUID: CGRect] = [:]

    private var wheelRouter = TabStripWheelRouter()
    nonisolated(unsafe) private var wheelMonitor: Any?
    nonisolated(unsafe) private var dragAutoScrollTimer: Timer?
    private var dragTrailingInset: CGFloat = 0
    private var pendingReveal: (id: UUID, reason: RevealReason, at: Date)?
    /// Something scrolled the strip since the selection last changed.
    private(set) var userScrolledSinceSelection = false

    deinit {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        dragAutoScrollTimer?.invalidate()
    }

    func attach(_ scrollView: NSScrollView?) {
        self.scrollView = scrollView
        enforceLeadingEdgeIfContentFits(reason: "attach")
    }

    // MARK: Metrics

    private var mirrorMetrics: ScrollMetrics? {
        guard mirror.container > 0 else { return nil }
        return ScrollMetrics(offset: mirror.offset, documentWidth: mirror.content, viewportWidth: mirror.container)
    }

    /// The `NSScrollView`'s numbers when it is reachable, else the mirror.
    private func currentMetrics() -> ScrollMetrics? {
        if let scrollView {
            let clipView = scrollView.contentView
            let documentWidth = max(
                scrollView.documentView?.frame.width ?? 0,
                scrollView.documentView?.bounds.width ?? 0
            )
            return ScrollMetrics(offset: clipView.bounds.origin.x, documentWidth: documentWidth, viewportWidth: clipView.bounds.width)
        }
        return mirrorMetrics
    }

    /// The visible strip in the bar's own coordinates (everything left of the chrome).
    private func stripBounds() -> NSRect? {
        guard let barView else { return nil }
        var rect = barView.bounds
        rect.size.width = max(0, rect.width - chromeInset)
        return rect
    }

    // MARK: Writing offsets

    /// Scrolls the strip by `delta` points (clamped to its content). Returns
    /// whether a driver actually took the write; only then is the mirror updated.
    @discardableResult
    private func scrollHorizontally(by delta: CGFloat, metrics: ScrollMetrics) -> Bool {
        let next = TabStripScroll.clampedOffset(
            metrics.offset + delta,
            contentWidth: metrics.documentWidth,
            viewportWidth: metrics.viewportWidth
        )
        guard abs(next - metrics.offset) > 0.01 else { return false }
        return write(offset: next)
    }

    private func write(offset next: CGFloat) -> Bool {
        if let scrollToOffset {
            scrollToOffset(next)
        } else if let scrollView {
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(x: next, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
        } else {
            return false
        }
        mirror.offset = next
        return true
    }

    /// Automation: scroll to an absolute offset.
    func setOffset(_ x: CGFloat) {
        guard let metrics = mirrorMetrics else { return }
        userScrolledSinceSelection = true
        scrollHorizontally(by: x - metrics.offset, metrics: metrics)
    }

    // MARK: Revealing a tab

    /// Brings a tab into the clear part of the strip with the least movement.
    /// `.geometry` requests (a width changed) are dropped unless the selected
    /// tab is wholly out of view and nothing has scrolled the strip since the
    /// selection changed. The tab's frame is measured on demand by the bar; the
    /// reveal runs when it arrives.
    func requestReveal(_ id: UUID, reason: RevealReason) {
        if reason == .selection { userScrolledSinceSelection = false }
        // A width change must not replace a selection or flash reveal still waiting
        // for its frame: that one is the stronger request.
        if reason == .geometry, let pending = pendingReveal, pending.reason != .geometry,
           Date().timeIntervalSince(pending.at) < 1.5 {
            performPendingReveal()
            return
        }
        pendingReveal = (id, reason, Date())
        performPendingReveal()
    }

    /// The bar measured a target tab's frame.
    func targetFramesChanged() { performPendingReveal() }

    private func performPendingReveal() {
        guard let pending = pendingReveal else { return }
        guard Date().timeIntervalSince(pending.at) < 1.5 else { pendingReveal = nil; return }
        guard let metrics = mirrorMetrics else { return }
        let canWrite = scrollToOffset != nil || scrollView != nil
        guard let frame = tabFrames[pending.id] else { return }
        if pending.reason == .geometry,
           !TabStripScroll.shouldRevealAfterGeometryChange(
                selectedMinX: frame.minX,
                selectedMaxX: frame.maxX,
                viewportWidth: metrics.viewportWidth,
                trailingObscured: chromeInset,
                userScrolledSinceSelection: userScrolledSinceSelection
           ) {
            pendingReveal = nil
            return
        }
        pendingReveal = nil
        let delta = TabStripScroll.revealDelta(
            frameMinX: frame.minX,
            frameMaxX: frame.maxX,
            viewportWidth: metrics.viewportWidth,
            trailingObscured: chromeInset
        )
        guard delta != 0 else { return }
        if canWrite {
            guard scrollHorizontally(by: delta, metrics: metrics) else { return }
        } else if let scrollToID {
            // No offset driver (macOS 14 without a reachable clip view): the proxy
            // places the tab where the reveal rule wants it, not at the centre.
            let anchor = TabStripScroll.proxyAnchor(
                frameMinX: frame.minX,
                frameWidth: frame.width,
                viewportWidth: metrics.viewportWidth,
                delta: delta
            )
            scrollToID(pending.id, UnitPoint(x: anchor, y: 0.5))
        } else {
            return
        }
        // The measured frame is stale until SwiftUI lays out again.
        tabFrames[pending.id] = nil
        if pending.reason == .hover { userScrolledSinceSelection = true }
    }

    // MARK: Leading-edge rules

    func shouldPreferLeadingTarget(
        selectedTabId: UUID?,
        fallbackContentWidth: CGFloat,
        fallbackContainerWidth: CGFloat
    ) -> Bool {
        guard selectedTabId != nil else { return true }

        if let metrics = currentMetrics(), metrics.viewportWidth > 0 {
            return TabBarStyling.shouldKeepLeadingAligned(
                contentWidth: metrics.documentWidth,
                containerWidth: metrics.viewportWidth
            )
        }

        return TabBarStyling.shouldKeepLeadingAligned(
            contentWidth: fallbackContentWidth,
            containerWidth: fallbackContainerWidth
        )
    }

    func enforceLeadingEdgeIfContentFits(reason: String) {
        guard let metrics = currentMetrics(), metrics.viewportWidth > 0 else { return }
        guard TabBarStyling.shouldKeepLeadingAligned(
            contentWidth: metrics.documentWidth,
            containerWidth: metrics.viewportWidth
        ) else {
            return
        }

        resetToLeadingEdgeIfNeeded(reason: reason)
    }

    func resetToLeadingEdgeIfNeeded(reason: String) {
        guard let metrics = currentMetrics() else { return }

        let currentOffset = metrics.offset
        guard abs(currentOffset) > 0.5 else { return }

        #if DEBUG
        dlog(
            "tab.bar.resetLeading reason=\(reason) " +
            "offset=\(Int(currentOffset.rounded())) " +
            "doc=\(Int(metrics.documentWidth.rounded())) " +
            "viewport=\(Int(metrics.viewportWidth.rounded()))"
        )
#endif
        // One writer per scroll view: ScrollPosition where it exists.
        if let scrollToOffset {
            scrollToOffset(0)
            mirror.offset = 0
            return
        }
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)

        // SwiftUI's ScrollView can briefly restore the stale offset during the same
        // layout cycle. Re-apply the correction on the next turn to keep split-pane
        // tab bars pinned to the leading edge once they stop overflowing.
        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView else { return }
            let clipView = scrollView.contentView
            let asyncOffset = clipView.bounds.origin.x
            guard abs(asyncOffset) > 0.5 else { return }
            clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    // MARK: Vertical wheel scrolls the strip sideways

    /// Installs the wheel monitor while a full-tier strip is on screen, removes
    /// it otherwise.
    func setWheelRoutingEnabled(_ enabled: Bool) {
        if enabled {
            guard wheelMonitor == nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handleScrollWheel(event) ? nil : event }
            }
        } else {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
            wheelRouter.reset()
        }
    }

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        // Cheap reject first: this monitor sees every scroll in the app.
        guard let barView, let window = barView.window, event.window === window else { return false }
        let input = TabStripWheelInput(
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        )
        return handleWheel(input, locationInWindow: event.locationInWindow, precise: event.hasPreciseScrollingDeltas)
    }

    /// Every scroll in the bar's window passes through the router, so it sees
    /// each gesture begin and end wherever the pointer is; whether the strip may
    /// take a gesture is decided once, at its start, by `isEligibleForWheel`
    /// (which includes the pointer being over the strip). Returns whether the
    /// event was consumed.
    func handleWheel(_ input: TabStripWheelInput, locationInWindow: NSPoint, precise: Bool) -> Bool {
        if isPointerOverStrip(locationInWindow) {
            // Any wheel over the strip counts as the operator scrolling it.
            userScrolledSinceSelection = true
        }
        let action = wheelRouter.route(input) { isEligibleForWheel(locationInWindow: locationInWindow) }
        guard case .remap(let delta) = action, let metrics = mirrorMetrics else { return false }
        return scrollHorizontally(by: delta * (precise ? 1 : 8), metrics: metrics)
    }

    private func isPointerOverStrip(_ locationInWindow: NSPoint) -> Bool {
        guard let barView, let strip = stripBounds() else { return false }
        return strip.contains(barView.convert(locationInWindow, from: nil))
    }

    /// Whether the strip may take a vertical scroll that starts here: the
    /// pointer is over the strip, this bar is on screen (not in a hidden
    /// workspace or under an overlay), its workspace is live, the pointer really
    /// hits this bar's content, and there is something to scroll.
    private func isEligibleForWheel(locationInWindow: NSPoint) -> Bool {
        guard isPointerOverStrip(locationInWindow),
              let barView, let window = barView.window, window.isVisible,
              !barView.isHiddenOrHasHiddenAncestor,
              isInteractiveProvider?() == true,
              let metrics = mirrorMetrics, metrics.documentWidth > metrics.viewportWidth + 1,
              let content = window.contentView else { return false }
        let hit = content.hitTest(content.convert(locationInWindow, from: nil))
        guard let hit else { return false }
        return hit.isDescendant(of: hostingAncestor(of: barView))
    }

    /// The SwiftUI hosting view the bar lives in.
    private func hostingAncestor(of view: NSView) -> NSView {
        var current: NSView? = view
        while let parent = current?.superview {
            if String(describing: type(of: parent)).contains("HostingView") { return parent }
            current = parent
        }
        return view.superview ?? view
    }

    // MARK: Auto-scroll while a tab is dragged near either end

    /// While a tab drag is in flight, nudges the strip when the pointer is near
    /// its left or right end. `trailingInset` is the chrome that covers the
    /// strip's right end. The ghost slot and the mid-drag scroll guard are
    /// untouched: this only moves the scroll offset, one small step per tick.
    func beginDragAutoScroll(trailingInset: CGFloat) {
        dragTrailingInset = trailingInset
        guard dragAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragAutoScrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragAutoScrollTimer = timer
    }

    func endDragAutoScroll() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
    }

    private func dragAutoScrollTick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { endDragAutoScroll(); return }
        guard let barView, let window = barView.window, let metrics = mirrorMetrics,
              let bounds = stripBounds(),
              metrics.documentWidth > metrics.viewportWidth + 1 else { return }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = barView.convert(inWindow, from: nil)
        guard point.y >= bounds.minY - 4, point.y <= bounds.maxY + 4 else { return }
        let zone: CGFloat = 36
        let visibleMaxX = bounds.maxX
        var step: CGFloat = 0
        if point.x >= bounds.minX, point.x < bounds.minX + zone {
            step = -14 * (1 - (point.x - bounds.minX) / zone)
        } else if point.x > visibleMaxX - zone, point.x <= bounds.maxX + dragTrailingInset {
            step = 14 * min(1, (point.x - (visibleMaxX - zone)) / zone)
        }
        if abs(step) > 0.1 { scrollHorizontally(by: step, metrics: metrics) }
    }
}

// MARK: - Wiring modifiers

/// Wires the strip's `ScrollView` to `TabBarScrollViewBridge.scrollToOffset` on
/// macOS 15+, where `ScrollPosition` can drive a scroll view to a point offset.
/// On macOS 14 it does nothing (the bridge then relies on the clip view or the
/// scroll view proxy).
struct TabStripScrollPositionModifier: ViewModifier {
    let bridge: TabBarScrollViewBridge

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(PositionDriver(bridge: bridge))
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private struct PositionDriver: ViewModifier {
        let bridge: TabBarScrollViewBridge
        @State private var position = ScrollPosition()

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onAppear {
                    bridge.scrollToOffset = { x in
                        withTransaction(Transaction(animation: nil)) {
                            position.scrollTo(x: x)
                        }
                    }
                }
        }
    }
}

/// Automation requests aimed at one pane: open/close its sheet, scroll its strip.
struct TabBarAutomationRequests: ViewModifier {
    let controller: BonsplitController
    let paneId: PaneID
    let bridge: TabBarScrollViewBridge
    @Binding var isSheetOpen: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: controller.tabStripScrollRequest) { _, request in
                guard let request, request.paneId == paneId else { return }
                bridge.setOffset(request.offset)
            }
            .onChange(of: controller.tabSheetRequest) { _, request in
                guard let request, request.paneId == paneId, request.open != isSheetOpen else { return }
                isSheetOpen = request.open
            }
    }
}

/// The few tabs the bar measures on demand (selected, hovered, flashed), keyed
/// by tab, in the strip's own space. Only those tabs carry a reader, so scrolling
/// costs a handful of frames rather than one per tab.
struct TabStripFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TabStripFrameReporter: ViewModifier {
    let id: UUID
    let active: Bool

    func body(content: Content) -> some View {
        content.background {
            if active {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TabStripFramesKey.self,
                        value: [id: proxy.frame(in: .named("tabScroll"))]
                    )
                }
            }
        }
    }
}

/// Feeds measured target frames to the bridge, and brings a hovered tab into
/// view when a sheet row lit it. Reads the hover state only while a sheet is
/// open, so closed bars never re-render for it.
struct TabStripTargetObserver: ViewModifier {
    let controller: BonsplitController
    let bridge: TabBarScrollViewBridge
    let isSheetOpen: Bool

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TabStripFramesKey.self) { frames in
                bridge.tabFrames = frames
                bridge.targetFramesChanged()
            }
            .onChange(of: isSheetOpen ? controller.linkedHoverTabId : nil) { _, hovered in
                guard isSheetOpen, controller.linkedHoverFromSheet, let hovered else { return }
                bridge.requestReveal(hovered, reason: .hover)
            }
    }
}

/// Hands the strip's `ScrollViewProxy` to the bridge as its last-resort driver.
struct TabStripProxyCapture: ViewModifier {
    let bridge: TabBarScrollViewBridge
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content.onAppear {
            bridge.scrollToID = { id, anchor in
                withTransaction(Transaction(animation: nil)) { proxy.scrollTo(id, anchor: anchor) }
            }
        }
    }
}
