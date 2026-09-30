import XCTest
@testable import Bonsplit

final class TabSheetGridTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testAgeBuckets() {
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(0)), "1s")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(5)), "5s")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(12 * 60 + 20)), "12m")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(2.2 * 3600)), "2.2h")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(3 * 3600)), "3h")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(26 * 3600)), "26h")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(72 * 3600)), "3d")
    }

    func testAgeNeverNegative() {
        XCTAssertEqual(TabSheetFormat.age(from: base.addingTimeInterval(30), to: base), "1s")
    }

    func testClockOrderNormalization() {
        XCTAssertEqual(TabSheetFormat.resolvedClocks(nil), ["active", "launched"])
        XCTAssertEqual(TabSheetFormat.resolvedClocks([]), ["active", "launched"])
        XCTAssertEqual(TabSheetFormat.resolvedClocks(["launched", "active"]), ["launched", "active"])
        XCTAssertEqual(TabSheetFormat.resolvedClocks([" Active ", "SEEN", "launched"]), ["active", "seen", "launched"])
        XCTAssertEqual(TabSheetFormat.resolvedClocks(["bogus", "active", "active", "nope"]), ["active"])
        XCTAssertEqual(TabSheetFormat.resolvedClocks(["bogus"]), ["active", "launched"])
    }

    func testNeedYouCountsWaitingAndFlagged() {
        func tab(_ kind: BonsplitTabDetail.StatusKind?, activity: BonsplitTabActivityState? = nil) -> TabItem {
            TabItem(
                title: "t",
                activityState: activity,
                detail: kind.map { BonsplitTabDetail(status: .init(kind: $0)) }
            )
        }
        let tabs = [
            tab(.working), tab(.waiting), tab(.flagged), tab(.idle), tab(.cold),
            tab(nil), tab(nil, activity: .waiting),
        ]
        XCTAssertEqual(TabSheetFormat.needYouCount(tabs), 3)
    }

    func testWidthComesFromColumns() {
        // 3 rule + 68 + 18 + 150 + 104 + 22 + 24 + 6 = 395 fixed, plus clocks.
        XCTAssertEqual(TabSheetMetrics.fixedWidth(clockCount: 0), 395)
        XCTAssertEqual(TabSheetMetrics.fixedWidth(clockCount: 2), 395 + 156)
        XCTAssertEqual(TabSheetMetrics.idealWidth(clockCount: 2), 395 + 156 + 260)
    }

    func testDetailSurvivesTabRoundTrip() throws {
        let detail = BonsplitTabDetail(
            agentLabel: "Claude Code · Sonnet 5.5",
            subtitle: "Doing things",
            status: .init(kind: .flagged, since: base),
            clocks: ["active": base, "launched": base.addingTimeInterval(-60)]
        )
        let item = TabItem(title: "x", detail: detail)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TabItem.self, from: data)
        XCTAssertEqual(decoded.detail, detail)
    }

    @MainActor
    func testRefreshAsksTheHostForEveryTabInThePane() {
        let controller = BonsplitController()
        let a = controller.createTab(title: "a")
        let b = controller.createTab(title: "b")
        var asked: [TabID] = []
        controller.tabDetailProvider = { id in
            asked.append(id)
            return BonsplitTabDetail(subtitle: "for \(id.id.uuidString.prefix(4))")
        }
        guard let pane = controller.focusedPaneId else { return XCTFail("no pane") }
        controller.refreshTabDetails(inPane: pane)
        let inPane = controller.tabs(inPane: pane).map(\.id)
        XCTAssertTrue(inPane.contains(a!) && inPane.contains(b!))
        XCTAssertEqual(Set(asked), Set(inPane))
        XCTAssertNotNil(controller.tab(a!)?.detail?.subtitle)
    }
}
