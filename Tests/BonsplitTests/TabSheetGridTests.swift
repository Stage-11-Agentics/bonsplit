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
            // "Tab9999" at full size: the column is sized per language, so
            // this only bounds how wide any language can make it. The label has
            // no separator between the word and the number in any language.
            let tab = String(format: string("tabNumber"), 9999)
            XCTAssertFalse(tab.contains(" "), "\(locale) '\(tab)' has a space")
            XCTAssertTrue(tab.hasSuffix("9999"), "\(locale) '\(tab)'")
            XCTAssertLessThanOrEqual(width(tab, mono11) + 12, 130, "\(locale) '\(tab)'")
            // Each status word with the longest age this locale can print
            // (its own format strings and decimal separator), 4pt apart.
            let decimal = NumberFormatter()
            decimal.locale = Locale(identifier: locale)
            decimal.numberStyle = .decimal
            decimal.maximumFractionDigits = 1
            let hours = String(format: string("time.hours"), decimal.string(from: 9.9) ?? "9.9")
            let ages = [
                String(format: string("time.seconds"), 59),
                String(format: string("time.minutes"), 59),
                hours,
                String(format: string("time.days"), 99),
            ]
            let longestAge = ages.map { width($0, bold11) }.max() ?? 0
            for kind in ["working", "waiting", "flagged", "idle", "cold"] {
                let word = string("status.\(kind)")
                XCTAssertLessThanOrEqual(
                    width(word, bold11) + 4 + longestAge,
                    TabSheetMetrics.statusWidth - 10,
                    "\(locale) \(kind) '\(word)' + \(ages)"
                )
            }
        }
    }

    func testFlaggedInkReadsOnALightSheet() {
        let flag = NSColor(bonsplitHex: "#9D8AD9")!
        XCTAssertLessThan(TabBarColors.contrastRatio(flag, .white), 4.5)
        let deep = TabBarColors.inkDeepened(flag, against: .white, minRatio: 4.5)
        XCTAssertGreaterThanOrEqual(TabBarColors.contrastRatio(deep, .white), 4.5)
        // Still the same hue family: red channel stays below blue.
        let rgb = deep.usingColorSpace(.sRGB)!
        XCTAssertLessThan(rgb.redComponent, rgb.blueComponent)
        // A colour that already reads is left alone.
        let dark = NSColor(bonsplitHex: "#202020")!
        XCTAssertEqual(TabBarColors.inkDeepened(dark, against: .white, minRatio: 4.5), dark)
    }

    func testStatusDecodesWithoutNeedsAttention() throws {
        let json = #"{"kind":"waiting"}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(BonsplitTabDetail.Status.self, from: json)
        XCTAssertEqual(status.kind, .waiting)
        XCTAssertTrue(status.needsAttention)
        let idle = try JSONDecoder().decode(BonsplitTabDetail.Status.self, from: #"{"kind":"idle"}"#.data(using: .utf8)!)
        XCTAssertFalse(idle.needsAttention)
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

    func testSheetTiersFollowTheAreaWidth() {
        XCTAssertEqual(TabSheetTier(width: 1120), .full)
        XCTAssertEqual(TabSheetTier(width: 820), .full)
        XCTAssertEqual(TabSheetTier(width: 819), .oneClock)
        XCTAssertEqual(TabSheetTier(width: 600), .oneClock)
        XCTAssertEqual(TabSheetTier(width: 599), .agentInline)
        XCTAssertEqual(TabSheetTier(width: 440), .agentInline)
        XCTAssertEqual(TabSheetTier(width: 439), .compact)
        XCTAssertEqual(TabSheetTier(width: 320), .compact)
    }

    func testColumnsDropByTierAndStayFixedWithinOne() {
        let both = ["active", "launched"]
        XCTAssertEqual(TabSheetLayout(width: 900, clocks: both).clocks, both)
        XCTAssertEqual(TabSheetLayout(width: 700, clocks: both).clocks, ["active"])
        XCTAssertTrue(TabSheetLayout(width: 700, clocks: both).showsAgentColumn)
        let inline = TabSheetLayout(width: 500, clocks: both)
        XCTAssertEqual(inline.clocks, [])
        XCTAssertFalse(inline.showsAgentColumn)
        XCTAssertTrue(inline.agentOnLineTwo)
        let compact = TabSheetLayout(width: 340, clocks: both)
        XCTAssertFalse(compact.showsAgentColumn || compact.agentOnLineTwo || compact.showsClose)
        XCTAssertEqual(compact.clocks, [])
        // Within a tier the fixed columns never change with width; only the title flexes.
        XCTAssertEqual(TabSheetLayout(width: 830, clocks: both).fixedWidth, TabSheetLayout(width: 1400, clocks: both).fixedWidth)
        XCTAssertEqual(TabSheetLayout(width: 1000, clocks: both).titleWidth + TabSheetLayout(width: 1000, clocks: both).fixedWidth, 1000)
        // A full sheet keeps a comfortable title column at its threshold.
        XCTAssertGreaterThanOrEqual(TabSheetLayout(width: 820, clocks: both).titleWidth, 200)
        XCTAssertGreaterThanOrEqual(TabSheetLayout(width: 320, clocks: both).titleWidth, 60)
    }

    func testTabStripKeepsRoomForTabsBeforeFolding() {
        XCTAssertEqual(TabStripLayout.minTabsRoom, 150)
        XCTAssertEqual(TabCountCellMetrics.width, 64)
    }

    @MainActor
    func testLinkedHoverIsSharedState() {
        let controller = BonsplitController()
        let tab = controller.createTab(title: "a")!
        controller.setLinkedHover(tabId: tab, fromSheet: true)
        XCTAssertEqual(controller.linkedHoverTabId, tab.id)
        XCTAssertTrue(controller.linkedHoverFromSheet)
        // A strip-origin clear must not clear a sheet-origin hover.
        controller.clearLinkedHover(ifSheet: false)
        XCTAssertEqual(controller.linkedHoverTabId, tab.id)
        controller.clearLinkedHover(ifSheet: true)
        XCTAssertNil(controller.linkedHoverTabId)
    }

    func testRailWidthIsAboutThirtyEightPercentClamped() {
        XCTAssertEqual(TabRailMetrics.width(forAreaWidth: 500), 200)   // 190 -> min
        XCTAssertEqual(TabRailMetrics.width(forAreaWidth: 560), 213)   // 38%
        XCTAssertEqual(TabRailMetrics.width(forAreaWidth: 1120), 300)  // max
        // A small area is never crushed by the 200pt floor: at most 45% of it.
        XCTAssertEqual(TabRailMetrics.width(forAreaWidth: 250), 113)
        XCTAssertEqual(TabRailMetrics.width(forAreaWidth: 419), 189)
        XCTAssertEqual(TabRailMetrics.width(forAreaWidth: 420), 189)   // the cap has no cliff at 420
        XCTAssertEqual(TabRailMetrics.width(forAreaWidth: 444), 200)   // the floor returns once 45% allows it
        // Continuous: one point of area never moves the rail by more than a point or two.
        var previous = TabRailMetrics.width(forAreaWidth: 100)
        for area in stride(from: 101, through: 1200, by: 1) {
            let width = TabRailMetrics.width(forAreaWidth: CGFloat(area))
            XCTAssertLessThanOrEqual(abs(width - previous), 2, "jump at area \(area)")
            previous = width
        }
    }

    @MainActor
    func testRailStateNotifiesTheHostOnlyOnChange() {
        let controller = BonsplitController()
        _ = controller.createTab(title: "a")
        guard let pane = controller.focusedPaneId else { return XCTFail("no pane") }
        var events: [Bool] = []
        controller.onRailToggled = { _, open in events.append(open) }
        controller.setRailOpen(true, inPane: pane)
        controller.setRailOpen(true, inPane: pane)
        controller.setRailOpen(false, inPane: pane)
        XCTAssertEqual(events, [true, false])
        // Restore is silent.
        controller.restoreRailOpen(true, inPane: pane)
        XCTAssertEqual(events, [true, false])
        XCTAssertTrue(controller.railOpenPaneIds.contains(pane))
        // The rail only counts as visible detail in Rail layout.
        XCTAssertFalse(controller.isTabDetailVisible(inPane: pane))
        controller.configuration.appearance.tabLayout = .rail
        XCTAssertTrue(controller.isTabDetailVisible(inPane: pane))
    }

    func testNumberLabelFollowsTheSetting() {
        let tab = TabItem(title: "t", displayOrdinal: 171)
        XCTAssertEqual(tab.numberLabel(showOrdinals: true), "171")
        XCTAssertNil(tab.numberLabel(showOrdinals: false))
        XCTAssertNil(TabItem(title: "t").numberLabel(showOrdinals: true))
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

    // MARK: Sheet drag state machine

    func testTheSheetHidesOutsideAndReturnsWhenTheDragComesBack() {
        var tracker = SheetDragTracker()
        tracker.begin()
        XCTAssertNil(tracker.cursorMoved(insideFrame: true, insideMargin: true))
        XCTAssertEqual(tracker.cursorMoved(insideFrame: false, insideMargin: false), .hide)
        XCTAssertNil(tracker.cursorMoved(insideFrame: false, insideMargin: false), "already hidden")
        // In the margin but not in the frame: stays hidden (no flicker at the edge).
        XCTAssertNil(tracker.cursorMoved(insideFrame: false, insideMargin: true))
        XCTAssertEqual(tracker.cursorMoved(insideFrame: true, insideMargin: true), .show)
        XCTAssertEqual(tracker.cursorMoved(insideFrame: false, insideMargin: false), .hide)
    }

    func testAReorderDroppedInTheSheetKeepsItOpen() {
        var tracker = SheetDragTracker()
        tracker.begin()
        tracker.droppedInSheetRow()
        XCTAssertEqual(tracker.end(cursorInsideFrame: true), .keepOpen)
        // The model's report and the mouse-up backstop arrive later: already resolved.
        XCTAssertNil(tracker.end(cursorInsideFrame: true))
        XCTAssertNil(tracker.end(cursorInsideFrame: false))
    }

    func testADropElsewhereClosesIt() {
        var tracker = SheetDragTracker()
        tracker.begin()
        _ = tracker.cursorMoved(insideFrame: false, insideMargin: false)
        XCTAssertEqual(tracker.end(cursorInsideFrame: false), .close)
    }

    func testACancelWithThePointerOverTheSheetKeepsItOpenAndElsewhereCloses() {
        var over = SheetDragTracker()
        over.begin()
        XCTAssertEqual(over.end(cursorInsideFrame: true), .keepOpen)

        var away = SheetDragTracker()
        away.begin()
        _ = away.cursorMoved(insideFrame: false, insideMargin: false)
        XCTAssertEqual(away.end(cursorInsideFrame: false), .close)
    }

    func testEachDragIsDecidedOnItsOwn() {
        var tracker = SheetDragTracker()
        tracker.begin()
        tracker.droppedInSheetRow()
        XCTAssertEqual(tracker.end(cursorInsideFrame: true), .keepOpen)
        // A drop flag from the first drag must not carry into the second.
        tracker.begin()
        _ = tracker.cursorMoved(insideFrame: false, insideMargin: false)
        XCTAssertEqual(tracker.end(cursorInsideFrame: false), .close)
        // Outside any drag nothing moves or resolves.
        XCTAssertNil(tracker.cursorMoved(insideFrame: false, insideMargin: false))
        tracker.droppedInSheetRow()
        tracker.begin()
        XCTAssertEqual(tracker.end(cursorInsideFrame: false), .close, "a stray drop flag outside a drag is ignored")
    }

    func testTheTabLabelHasNoSeparator() {
        XCTAssertEqual(TabSheetFormat.tabLabel(17), "Tab17")
    }

    func testDetailDecodesWithoutClocksOrClockTexts() throws {
        // A payload written by an older build has neither key.
        let old = try JSONDecoder().decode(BonsplitTabDetail.self, from: Data(#"{"title":"t","subtitle":"s"}"#.utf8))
        XCTAssertEqual(old.title, "t")
        XCTAssertTrue(old.clocks.isEmpty)
        XCTAssertTrue(old.clockTexts.isEmpty)
    }

    func testDetailRoundTripsClockTexts() throws {
        let detail = BonsplitTabDetail(clocks: ["active": Date(timeIntervalSince1970: 5)], clockTexts: ["turn": "4m 12s", "tools": "7"])
        let back = try JSONDecoder().decode(BonsplitTabDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertEqual(back, detail)
    }
}
