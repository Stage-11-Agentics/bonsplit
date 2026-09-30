import XCTest
import AppKit
@testable import Bonsplit

final class TabStripScrollTests: XCTestCase {
    // MARK: Reveal math

    func testATabUnderTheControlsIsScrolledClearOfThem() {
        // Viewport 500, controls+count cell 206 on the right, 24pt fades each side:
        // the clear area is 24...270.
        let delta = TabStripScroll.revealDelta(frameMinX: 200, frameMaxX: 330, viewportWidth: 500, trailingObscured: 206)
        XCTAssertEqual(delta, 330 - 270)   // bring its trailing edge to 270
    }

    func testAClearTabDoesNotMove() {
        XCTAssertEqual(TabStripScroll.revealDelta(frameMinX: 40, frameMaxX: 160, viewportWidth: 500, trailingObscured: 206), 0)
    }

    func testATabCutOnTheLeftComesBackToTheFade() {
        XCTAssertEqual(TabStripScroll.revealDelta(frameMinX: -60, frameMaxX: 40, viewportWidth: 500, trailingObscured: 206), -84)
        // Fully to the left of the viewport, too.
        XCTAssertLessThan(TabStripScroll.revealDelta(frameMinX: -300, frameMaxX: -180, viewportWidth: 500, trailingObscured: 206), 0)
    }

    func testATabWiderThanTheClearAreaAlignsToItsLeadingSide() {
        XCTAssertEqual(TabStripScroll.revealDelta(frameMinX: 100, frameMaxX: 500, viewportWidth: 500, trailingObscured: 206), 76)
    }

    func testBetweenNarrowWidthsACenteredTabWouldHaveLandedUnderTheControls() {
        // The old behaviour centred a 130pt tab in the full viewport; for widths from
        // ~364 to ~570 that put it under a 206pt chrome. The reveal never does.
        for viewport in stride(from: CGFloat(390), through: 570, by: 13) {
            let centeredMinX = (viewport - 130) / 2
            let delta = TabStripScroll.revealDelta(
                frameMinX: centeredMinX, frameMaxX: centeredMinX + 130,
                viewportWidth: viewport, trailingObscured: 206
            )
            let maxX = centeredMinX + 130 - delta
            XCTAssertLessThanOrEqual(maxX, viewport - 206 - TabStripScroll.fadeWidth + 0.001, "viewport \(viewport)")
        }
    }

    func testWidthChangesOnlyRevealAWhollyHiddenSelectedTab() {
        func decide(_ minX: CGFloat, _ maxX: CGFloat, scrolled: Bool) -> Bool {
            TabStripScroll.shouldRevealAfterGeometryChange(
                selectedMinX: minX, selectedMaxX: maxX, viewportWidth: 500,
                trailingObscured: 206, userScrolledSinceSelection: scrolled
            )
        }
        XCTAssertFalse(decide(40, 160, scrolled: false))      // visible: leave it
        XCTAssertFalse(decide(200, 330, scrolled: false))     // partly under the controls: still leave it
        XCTAssertTrue(decide(-200, -80, scrolled: false))     // wholly gone to the left
        XCTAssertTrue(decide(300, 420, scrolled: false))      // wholly under the controls
        XCTAssertFalse(decide(-200, -80, scrolled: true))     // the operator scrolled away: never yank
    }

    func testOffsetsClampToTheContent() {
        XCTAssertEqual(TabStripScroll.clampedOffset(-5, contentWidth: 900, viewportWidth: 500), 0)
        XCTAssertEqual(TabStripScroll.clampedOffset(700, contentWidth: 900, viewportWidth: 500), 400)
        XCTAssertEqual(TabStripScroll.clampedOffset(50, contentWidth: 300, viewportWidth: 500), 0)
    }

    // MARK: Wheel routing

    private func event(
        _ phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [], dx: CGFloat = 0, dy: CGFloat = 0
    ) -> TabStripWheelInput {
        TabStripWheelInput(phase: phase, momentumPhase: momentum, deltaX: dx, deltaY: dy)
    }

    func testAHiddenBarOrOverlayNeverTakesTheScroll() {
        var router = TabStripWheelRouter()
        // Ineligible (hidden workspace, overlay on top): pass, and stay passed through the gesture.
        XCTAssertEqual(router.route(event(.began, dy: -4), eligible: { false }), .pass)
        XCTAssertEqual(router.route(event(.changed, dy: -9), eligible: { true }), .pass)
        XCTAssertEqual(router.route(event(.ended, dy: 0), eligible: { true }), .pass)
        XCTAssertEqual(router.route(event(momentum: .began, dy: -6), eligible: { true }), .pass)
    }

    func testAGestureStartedOnTheStripStaysWithItThroughMomentum() {
        var router = TabStripWheelRouter()
        XCTAssertEqual(router.route(event(.began, dy: -4), eligible: { true }), .remap(4))
        // The pointer wanders off the strip: eligibility is no longer asked.
        XCTAssertEqual(router.route(event(.changed, dy: -9), eligible: { XCTFail("asked mid-gesture"); return false }), .remap(9))
        XCTAssertEqual(router.route(event(.ended), eligible: { false }), .pass)   // no movement
        XCTAssertEqual(router.route(event(momentum: .began, dy: -7), eligible: { false }), .remap(7))
        XCTAssertEqual(router.route(event(momentum: .changed, dy: -3), eligible: { false }), .remap(3))
        XCTAssertEqual(router.route(event(momentum: .ended), eligible: { false }), .pass)
        // The next gesture decides afresh.
        XCTAssertEqual(router.route(event(.began, dy: -4), eligible: { false }), .pass)
    }

    func testAScrollThatStartedElsewhereIsNotHijackedOntoTheStrip() {
        var router = TabStripWheelRouter()
        XCTAssertEqual(router.route(event(.began, dy: -4), eligible: { false }), .pass)
        // It drifts over the strip mid-gesture and into momentum: still the terminal's.
        XCTAssertEqual(router.route(event(.changed, dy: -9), eligible: { true }), .pass)
        XCTAssertEqual(router.route(event(momentum: .began, dy: -7), eligible: { true }), .pass)
    }

    func testDiagonalSwipesAreDecidedOnceByTheirFirstMovement() {
        var vertical = TabStripWheelRouter()
        XCTAssertEqual(vertical.route(event(.began, dx: 1, dy: -6), eligible: { true }), .remap(6))
        // Horizontal dominates later: still remapped with its vertical component only.
        XCTAssertEqual(vertical.route(event(.changed, dx: 12, dy: -2), eligible: { true }), .remap(2))

        var horizontal = TabStripWheelRouter()
        XCTAssertEqual(horizontal.route(event(.began, dx: 8, dy: -2), eligible: { true }), .pass)
        XCTAssertEqual(horizontal.route(event(.changed, dx: 1, dy: -9), eligible: { true }), .pass)
    }

    func testAMayBeginWithNoMovementDoesNotDecide() {
        var router = TabStripWheelRouter()
        XCTAssertEqual(router.route(event(.mayBegin), eligible: { XCTFail("decided on a still event"); return true }), .pass)
        XCTAssertEqual(router.route(event(.began, dy: -5), eligible: { true }), .remap(5))
    }

    func testAMouseWheelWithoutPhasesIsDecidedEventByEvent() {
        var router = TabStripWheelRouter()
        XCTAssertEqual(router.route(event(dy: -3), eligible: { true }), .remap(3))
        XCTAssertEqual(router.route(event(dy: -3), eligible: { false }), .pass)
        XCTAssertEqual(router.route(event(dx: 5, dy: -1), eligible: { true }), .pass)
    }

    func testMomentumWithNoGestureBehindItPasses() {
        var router = TabStripWheelRouter()
        XCTAssertEqual(router.route(event(momentum: .changed, dy: -8), eligible: { true }), .pass)
    }

    // MARK: Unroll runs

    func testASupersededUnrollCannotTouchTheLayer() {
        var sequencer = UnrollSequencer()
        let opening = sequencer.begin()
        let closing = sequencer.begin()         // closed within the open's 120ms
        XCTAssertFalse(sequencer.isCurrent(opening), "the open's completion must be ignored")
        XCTAssertTrue(sequencer.isCurrent(closing))
        sequencer.invalidate()                  // reopened / torn down mid-roll-up
        XCTAssertFalse(sequencer.isCurrent(closing))
    }

    // MARK: Wheel, through the bridge's real entry (location filter and router together)

    private final class FakeHostingView: NSView {}

    /// A window with a bar (strip 0...500, controls 500...600) in a hosting view
    /// along the top, and a "terminal" view filling the rest.
    @MainActor
    private struct WheelRig {
        let window: NSWindow
        let hosting: FakeHostingView
        let bridge: TabBarScrollViewBridge
        let written: Box
        final class Box { var offsets: [CGFloat] = [] }

        static let onStrip = NSPoint(x: 100, y: 185)
        static let onTerminal = NSPoint(x: 100, y: 50)

        init(interactive: Bool = true) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let content = window.contentView!
            hosting = FakeHostingView(frame: NSRect(x: 0, y: 170, width: 600, height: 30))
            let bar = NSView(frame: hosting.bounds)
            hosting.addSubview(bar)
            let terminal = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 170))
            content.addSubview(hosting)
            content.addSubview(terminal)
            window.orderFront(nil)
            let b = TabBarScrollViewBridge()
            b.barView = bar
            b.chromeInset = 100
            b.mirror = .init(offset: 0, content: 1_000, container: 600)
            b.isInteractiveProvider = { interactive }
            let box = Box()
            b.scrollToOffset = { box.offsets.append($0) }
            bridge = b
            written = box
        }

        func send(_ phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [], dy: CGFloat, at point: NSPoint) -> Bool {
            bridge.handleWheel(
                TabStripWheelInput(phase: phase, momentumPhase: momentum, deltaX: 0, deltaY: dy),
                locationInWindow: point, precise: true
            )
        }
    }

    @MainActor
    func testAGestureThatBeginsOnTheStripScrollsIt() {
        let rig = WheelRig()
        XCTAssertTrue(rig.send(.began, dy: -10, at: WheelRig.onStrip))
        XCTAssertTrue(rig.send(.changed, dy: -10, at: WheelRig.onStrip))
        XCTAssertEqual(rig.written.offsets.last ?? 0, 20, accuracy: 0.01)
    }

    @MainActor
    func testATerminalScrollDriftingOntoTheStripIsNeverHijacked() {
        let rig = WheelRig()
        // The router sees the gesture begin over the terminal, so it is decided there.
        XCTAssertFalse(rig.send(.began, dy: -10, at: WheelRig.onTerminal))
        XCTAssertFalse(rig.send(.changed, dy: -10, at: WheelRig.onStrip))
        XCTAssertFalse(rig.send(.ended, dy: 0, at: WheelRig.onStrip))
        XCTAssertFalse(rig.send(momentum: .began, dy: -8, at: WheelRig.onStrip))
        XCTAssertFalse(rig.send(momentum: .changed, dy: -4, at: WheelRig.onStrip))
        XCTAssertTrue(rig.written.offsets.isEmpty)
    }

    @MainActor
    func testAStripGestureEndingOffTheStripDoesNotLeaveTheNextGestureLatched() {
        let rig = WheelRig()
        XCTAssertTrue(rig.send(.began, dy: -10, at: WheelRig.onStrip))
        // The pointer wandered off; the gesture ends there with no momentum.
        XCTAssertTrue(rig.send(.changed, dy: -10, at: WheelRig.onTerminal))
        XCTAssertTrue(rig.send(.ended, dy: 0, at: WheelRig.onTerminal) == false)
        let scrolled = rig.written.offsets.count
        // A touch sequence whose start was never seen (the lift was the last thing the
        // router saw) is not inherited from the strip gesture that just ended.
        XCTAssertFalse(rig.send(.changed, dy: -10, at: WheelRig.onStrip))
        XCTAssertEqual(rig.written.offsets.count, scrolled)
        // A terminal gesture that then crosses the strip stays the terminal's.
        XCTAssertFalse(rig.send(.began, dy: -10, at: WheelRig.onTerminal))
        XCTAssertFalse(rig.send(.changed, dy: -10, at: WheelRig.onStrip))
        XCTAssertEqual(rig.written.offsets.count, scrolled)
    }

    @MainActor
    func testAHiddenBarNeverTakesAScrollEvenWhenItsGestureEndedElsewhere() {
        let rig = WheelRig()
        rig.hosting.isHidden = true   // a mounted bar of a workspace that is not showing
        XCTAssertFalse(rig.send(.began, dy: -10, at: WheelRig.onStrip))
        XCTAssertFalse(rig.send(.changed, dy: -10, at: WheelRig.onStrip))
        rig.hosting.isHidden = false
        // A terminal gesture crossing the (now shown) strip is still the terminal's.
        XCTAssertFalse(rig.send(.began, dy: -10, at: WheelRig.onTerminal))
        XCTAssertFalse(rig.send(.changed, dy: -10, at: WheelRig.onStrip))
        XCTAssertTrue(rig.written.offsets.isEmpty)
    }

    @MainActor
    func testABarInAWorkspaceThatIsNotLiveNeverTakesAScroll() {
        let rig = WheelRig(interactive: false)
        XCTAssertFalse(rig.send(.began, dy: -10, at: WheelRig.onStrip))
        XCTAssertTrue(rig.written.offsets.isEmpty)
    }

    @MainActor
    func testAWheelOverTheControlsDoesNotScrollTheStrip() {
        let rig = WheelRig()
        XCTAssertFalse(rig.send(.began, dy: -10, at: NSPoint(x: 550, y: 185)))
    }

    // MARK: Proxy anchor (no offset driver)

    func testProxyAnchorPlacesTheTabWhereTheRevealRuleWantsIt() {
        // A 100pt tab at x=500 in a 400pt viewport with 80pt of controls: the rule
        // scrolls it clear of the controls, to the right-most clear position.
        let delta = TabStripScroll.revealDelta(frameMinX: 500, frameMaxX: 600, viewportWidth: 400, trailingObscured: 80)
        let anchor = TabStripScroll.proxyAnchor(frameMinX: 500, frameWidth: 100, viewportWidth: 400, delta: delta)
        let landedMinX = anchor * (400 - 100)
        XCTAssertEqual(landedMinX, 500 - delta, accuracy: 0.001)
        XCTAssertLessThanOrEqual(landedMinX + 100, 400 - 80 + 0.001, "clear of the controls")
        XCTAssertNotEqual(anchor, 0.5, accuracy: 0.05, "not the centre")
    }

    func testProxyAnchorClampsAndHandlesATabWiderThanTheViewport() {
        XCTAssertEqual(TabStripScroll.proxyAnchor(frameMinX: 10, frameWidth: 100, viewportWidth: 400, delta: 500), 0)
        XCTAssertEqual(TabStripScroll.proxyAnchor(frameMinX: 900, frameWidth: 100, viewportWidth: 400, delta: 0), 1)
        XCTAssertEqual(TabStripScroll.proxyAnchor(frameMinX: 10, frameWidth: 500, viewportWidth: 400, delta: 0), 0)
    }
}
