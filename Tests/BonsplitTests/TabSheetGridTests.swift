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

    func testSecondsRoundDown() {
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(59.5)), "59s")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(59.99)), "59s")
        XCTAssertEqual(TabSheetFormat.age(from: base, to: base.addingTimeInterval(60)), "1m")
    }

    func testHostClocksNeedNoBonsplitChange() {
        // A clock bonsplit has never heard of is kept when the host knows it.
        XCTAssertEqual(
            TabSheetFormat.resolvedClocks(["active", "deploy"]) { $0 == "active" || $0 == "deploy" },
            ["active", "deploy"]
        )
        XCTAssertEqual(TabSheetFormat.clockTitle("deploy", hostTitle: "Deployed"), "Deployed")
        XCTAssertNil(TabSheetFormat.clockTitle("deploy"))
        XCTAssertEqual(TabSheetFormat.clockTitle("active"), "Active")
    }

    func testAttentionRuleBelongsToTheHost() {
        XCTAssertTrue(BonsplitTabDetail.Status(kind: .waiting).needsAttention)
        XCTAssertTrue(BonsplitTabDetail.Status(kind: .flagged).needsAttention)
        XCTAssertFalse(BonsplitTabDetail.Status(kind: .working).needsAttention)
        // The host can decide otherwise (a suppressed waiting tab, say).
        let suppressed = TabItem(title: "t", detail: BonsplitTabDetail(status: .init(kind: .waiting, needsAttention: false)))
        let idleButWanted = TabItem(title: "t", detail: BonsplitTabDetail(status: .init(kind: .idle, needsAttention: true)))
        XCTAssertEqual(TabSheetFormat.needYouCount([suppressed, idleButWanted]), 1)
    }

    func testPaletteIsCachedPerBackground() {
        let dark = BonsplitConfiguration.Appearance(chromeColors: .init(backgroundHex: "#101010"))
        let light = BonsplitConfiguration.Appearance(chromeColors: .init(backgroundHex: "#F4F4F6"))
        XCTAssertEqual(TabBarColors.sheetPalette(for: dark).background, TabBarColors.sheetPalette(for: dark).background)
        XCTAssertNotEqual(TabBarColors.sheetPalette(for: dark).background, TabBarColors.sheetPalette(for: light).background)
    }

    /// Every localized header, status word and time unit must fit its fixed column
    /// without truncating: the grid never reflows to make room.
    func testLocalizedTextFitsItsColumns() throws {
        let locales = ["en", "ja", "ko", "ru", "uk", "zh-Hans", "zh-Hant"]
        let header = NSFont.systemFont(ofSize: 10, weight: .bold)
        let bold11 = NSFont.systemFont(ofSize: 11, weight: .bold)
        let mono11 = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        func width(_ text: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font, .kern: kern]).width
        }
        for locale in locales {
            let path = try XCTUnwrap(
                Bundle.module.path(forResource: locale, ofType: "lproj")
                    ?? Bundle.module.path(forResource: locale.lowercased(), ofType: "lproj"),
                locale
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            func string(_ key: String) -> String { bundle.localizedString(forKey: "tabBar.sheet.\(key)", value: "MISSING", table: nil) }
            for (key, room) in [
                ("column.tab", TabSheetMetrics.numberWidth - 10),
                ("column.agent", TabSheetMetrics.agentWidth - 10),
                ("column.status", TabSheetMetrics.statusWidth - 10),
                ("clock.active", TabSheetMetrics.clockWidth - 8),
                ("clock.launched", TabSheetMetrics.clockWidth - 8),
                ("clock.seen", TabSheetMetrics.clockWidth - 8),
            ] as [(String, CGFloat)] {
                let text = string(key).uppercased()
                XCTAssertNotEqual(text, "MISSING", "\(locale) \(key)")
                XCTAssertLessThanOrEqual(width(text, header, kern: 0.6), room, "\(locale) \(key) '\(text)'")
            }
            // "Tab 1024", scaled down to 70% at worst.
            let tab = String(format: string("tabNumber"), 1024)
            XCTAssertLessThanOrEqual(width(tab, mono11) * 0.7, TabSheetMetrics.numberWidth - 10, "\(locale) '\(tab)'")
            // The longest status word with a three-character age and a space.
            for kind in ["working", "waiting", "flagged", "idle", "cold"] {
                let word = string("status.\(kind)")
                XCTAssertLessThanOrEqual(width(word + " 59m", bold11), TabSheetMetrics.statusWidth - 10, "\(locale) \(kind)")
            }
        }
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
