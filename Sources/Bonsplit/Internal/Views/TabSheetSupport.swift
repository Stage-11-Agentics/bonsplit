import SwiftUI
import AppKit

// MARK: - Grid metrics

/// Fixed column widths of the tab sheet. Every column but the title is
/// fixed, so nothing moves when text changes length or a clock ticks.
enum TabSheetMetrics {
    static let rowHeight: CGFloat = 46
    static let lineHeight: CGFloat = 18
    static let headerHeight: CGFloat = 24
    static let footerHeight: CGFloat = 28
    static let leadingRule: CGFloat = 3
    static let trailingPadding: CGFloat = 6

    /// Wide enough for the localized "Panel 9999" at full size, never below 68.
    /// Fixed within a language, so nothing moves while the app runs.
    static let numberWidth: CGFloat = {
        let sample = TabSheetFormat.tabLabel(9999)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let text = ceil((sample as NSString).size(withAttributes: [.font: font]).width)
        return max(68, text + numberTrailingInset + 2)
    }()
    static let numberTrailingInset: CGFloat = 10
    static let minTitleWidth: CGFloat = 260
    static let typeWidth: CGFloat = 150
    static let statusWidth: CGFloat = 104
    static let clockWidth: CGFloat = 78
    /// The grip column: the drag handle on line one, the close button under it
    /// on line two. Present in every tier, so a tab can always be closed.
    static let gripWidth: CGFloat = 24

    static let maxVisibleRows = 9
    /// The narrowest sheet: an area below this still gets this much.
    static let minSheetWidth: CGFloat = 320

    /// Width of everything except the title column.
    static func fixedWidth(clockCount: Int) -> CGFloat {
        leadingRule + numberWidth + typeWidth + statusWidth
            + clockWidth * CGFloat(clockCount) + gripWidth + trailingPadding
    }

    /// Natural sheet width: the fixed columns plus the minimum title column.
    static func idealWidth(clockCount: Int) -> CGFloat {
        fixedWidth(clockCount: clockCount) + minTitleWidth
    }
}

// MARK: - Width tiers

/// The sheet is exactly its area's width, and its columns drop out by that
/// width, fixed within each tier so nothing jitters:
/// ≥820 everything · 600–819 first clock only · 440–599 type tag moves to
/// line 2, clocks go · <440 Tab N, mark, title and status.
enum TabSheetTier: Equatable {
    case full, oneClock, typeInline, compact

    init(width: CGFloat) {
        // Pane widths arrive as fractional points (819.6 for an 820 area).
        switch width.rounded() {
        case 820...: self = .full
        case 600..<820: self = .oneClock
        case 440..<600: self = .typeInline
        default: self = .compact
        }
    }
}

struct TabSheetLayout: Equatable {
    let width: CGFloat
    let tier: TabSheetTier
    /// Clock names actually shown in this tier.
    let clocks: [String]

    init(width: CGFloat, clocks allClocks: [String]) {
        self.width = width
        self.tier = TabSheetTier(width: width)
        switch tier {
        case .full: clocks = allClocks
        case .oneClock: clocks = Array(allClocks.prefix(1))
        case .typeInline, .compact: clocks = []
        }
    }

    typealias M = TabSheetMetrics

    /// Compact sheets use a narrower Panel column: sized for "Panel 999", never below 56.
    private static let compactNumberWidth: CGFloat = {
        let sample = TabSheetFormat.tabLabel(999)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        return max(56, ceil((sample as NSString).size(withAttributes: [.font: font]).width) + 10)
    }()

    var numberWidth: CGFloat { tier == .compact ? Self.compactNumberWidth : M.numberWidth }
    var numberTrailingInset: CGFloat { tier == .compact ? 8 : M.numberTrailingInset }
    var showsTypeColumn: Bool { tier == .full || tier == .oneClock }
    var typeOnLineTwo: Bool { tier == .typeInline }

    /// Width of everything except the title column.
    var fixedWidth: CGFloat {
        M.leadingRule + numberWidth
            + (showsTypeColumn ? M.typeWidth : 0) + M.statusWidth
            + M.clockWidth * CGFloat(clocks.count)
            + M.gripWidth + M.trailingPadding
    }

    var titleWidth: CGFloat { max(60, width - fixedWidth) }
    /// Title + type + status: the span line 2 runs across.
    var mainWidth: CGFloat { titleWidth + (showsTypeColumn ? M.typeWidth : 0) + M.statusWidth }
}

// MARK: - Formatting

enum TabSheetFormat {
    /// "Panel 17": the localized panel label, the word, one space, the number.
    static func tabLabel(_ ordinal: Int) -> String {
        String(format: localized("tabBar.sheet.tabNumber", "Panel %lld"), Int64(ordinal))
    }

    /// Clock names bonsplit can title on its own; a host can add more through
    /// `BonsplitController.sheetClockTitleProvider`.
    static let builtInClocks: [String] = ["active", "launched", "seen"]
    static let defaultClocks: [String] = ["active", "launched"]

    /// Normalizes a host-supplied clock list: lowercased, trimmed, names that
    /// `isKnown` rejects dropped, duplicates removed, order kept. Empty falls
    /// back to the default order.
    static func resolvedClocks(_ raw: [String]?, isKnown: (String) -> Bool = { builtInClocks.contains($0) }) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw ?? [] {
            let name = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard isKnown(name), seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out.isEmpty ? defaultClocks : out
    }

    /// Compact relative age: `5s`, `12m`, `2.2h`, `26h`, `3d`. Every bucket
    /// rounds down, so 59.5 seconds reads `59s`, never `60s`.
    static func age(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return String(format: localized("tabBar.sheet.time.seconds", "%llds"), Int64(max(1, seconds.rounded(.down))))
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(format: localized("tabBar.sheet.time.minutes", "%lldm"), Int64(minutes.rounded(.down)))
        }
        let hours = minutes / 60
        if hours < 48 {
            let number: String
            if hours < 10 {
                number = hoursFormatter.string(from: NSNumber(value: (hours * 10).rounded(.down) / 10)) ?? String(Int64(hours))
            } else {
                number = String(Int64(hours.rounded(.down)))
            }
            return String(format: localized("tabBar.sheet.time.hours", "%@h"), number)
        }
        return String(format: localized("tabBar.sheet.time.days", "%lldd"), Int64((hours / 24).rounded(.down)))
    }

    /// One decimal at most, in the user's locale (`2,2` in Russian).
    private static let hoursFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .floor
        // The app's language, not the region: a Russian UI on a US-region Mac
        // still reads "2,2".
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatter
    }()

    static func statusWord(_ kind: BonsplitTabDetail.StatusKind) -> String {
        switch kind {
        case .working: return localized("tabBar.sheet.status.working", "working")
        case .waiting: return localized("tabBar.sheet.status.waiting", "waiting")
        case .flagged: return localized("tabBar.sheet.status.flagged", "flagged")
        case .idle: return localized("tabBar.sheet.status.idle", "idle")
        case .cold: return localized("tabBar.sheet.status.cold", "cold")
        }
    }

    /// Header title for a clock: the host's, else bonsplit's built-in, else nil.
    static func clockTitle(_ name: String, hostTitle: String? = nil) -> String? {
        if let hostTitle, !hostTitle.isEmpty { return hostTitle }
        switch name {
        case "active": return localized("tabBar.sheet.clock.active", "Active")
        case "launched": return localized("tabBar.sheet.clock.launched", "Launched")
        case "seen": return localized("tabBar.sheet.clock.seen", "Seen")
        default: return nil
        }
    }

    /// `N panels`, `1 panel`.
    static func tabsFooter(count: Int) -> String {
        count == 1
            ? localized("tabBar.sheet.footer.oneTab", "1 panel")
            : String(format: localized("tabBar.sheet.footer.tabs", "%lld panels"), Int64(count))
    }

    static func needYouFooter(count: Int) -> String {
        String(format: localized("tabBar.sheet.footer.needYou", "%lld need you"), Int64(count))
    }

    /// Tabs the host says want the operator (by default waiting and flagged).
    static func needYouCount(_ tabs: [TabItem]) -> Int {
        tabs.filter { tab in
            if let status = tab.detail?.status { return status.needsAttention }
            return tab.activityState == .waiting
        }.count
    }

    /// What a clock cell shows: a live age from a date, a plain text value the
    /// host formatted itself, or nothing (a dash).
    enum ClockValue: Equatable {
        case age(Date)
        case text(String)
        case none
    }

    /// The value for a named clock. Dates render as ages; a host that carries
    /// non-date clocks (turn count, tokens) supplies text through this seam.
    static func clockValue(_ name: String, in tab: TabItem) -> ClockValue {
        if let text = tab.detail?.clockTexts[name] { return .text(text) }
        if let date = tab.detail?.clocks[name] { return .age(date) }
        return .none
    }

    static func localized(_ key: String, _ value: String) -> String {
        Bundle.module.localizedString(forKey: key, value: value, table: nil)
    }
}

// MARK: - Relative time

/// Relative-time text for one cell. It takes the sheet's single shared tick
/// (`now`), so every cell changes on the same instant and nothing ticks on its
/// own. Digits are tabular and the caller fixes the width, so a tick never
/// moves a column.
struct TabSheetAgeText: View {
    let since: Date
    let now: Date
    var font: Font = .system(size: 11, design: .monospaced)

    var body: some View {
        Text(TabSheetFormat.age(from: since, to: now))
            .font(font)
            .monospacedDigit()
            .lineLimit(1)
    }
}

// MARK: - Count cell

enum TabCountCellMetrics {
    static let width: CGFloat = 64
}

/// A bold stroked chevron, 12×8 at 2.4pt: the cell's disclosure mark.
struct TabCountChevron: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 6, y: 6))
            path.addLine(to: CGPoint(x: 10.5, y: 1.5))
        }
        .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        .frame(width: 12, height: 8)
    }
}

/// The count cell: attention dot, chevron, then the number (`● ⌄ 6`). One
/// primitive shared by every tier at a fixed width; the dot's slot is always
/// reserved so nothing shifts when it appears. It sits in the bar's own colour
/// family and only goes gold while the sheet is open. Draws only; the host
/// attaches the tap.
struct TabCountCell: View {
    let count: Int
    let hasBackgroundActivity: Bool
    let hasBackgroundWaiting: Bool
    let isOpen: Bool
    var isHovered: Bool = false
    let appearance: BonsplitConfiguration.Appearance
    let height: CGFloat

    var body: some View {
        let palette = TabBarColors.sheetPalette(for: appearance)
        let openInk = Color(white: 0.1)
        HStack(spacing: 6) {
            Circle()
                .fill(isOpen
                    ? openInk
                    : (hasBackgroundWaiting
                        ? TabBarColors.activity(.waiting, for: appearance)
                        : TabBarColors.notificationBadge(for: appearance)))
                .frame(width: 6, height: 6)
                .opacity(hasBackgroundActivity ? 1 : 0)
            TabCountChevron()
            Text("\(count)")
                .font(.system(size: appearance.tabTitleFontSize, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 14, alignment: .leading)
        }
        .foregroundStyle(isOpen ? openInk : palette.text)
        .frame(width: TabCountCellMetrics.width, height: height)
        .background(
            isOpen
                ? TabBarColors.activeIndicator(for: appearance)
                : (isHovered ? palette.countCellHover : palette.countCell)
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(TabBarColors.separator(for: appearance)).frame(width: 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(TabBarColors.separator(for: appearance)).frame(width: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TabSheetFormat.localized("tabBar.collapsedHeader.accessibilityLabel", "Show all tabs"))
        .accessibilityValue(TabSheetFormat.tabsFooter(count: count))
    }
}
