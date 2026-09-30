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
}
