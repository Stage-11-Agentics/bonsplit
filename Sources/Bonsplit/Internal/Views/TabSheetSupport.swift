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

    static let numberWidth: CGFloat = 68
    static let markWidth: CGFloat = 18
    static let minTitleWidth: CGFloat = 260
    static let agentWidth: CGFloat = 150
    static let statusWidth: CGFloat = 104
    static let clockWidth: CGFloat = 78
    static let closeWidth: CGFloat = 22
    static let gripWidth: CGFloat = 24

    static let maxVisibleRows = 9

    /// Width of everything except the title column.
    static func fixedWidth(clockCount: Int) -> CGFloat {
        leadingRule + numberWidth + markWidth + agentWidth + statusWidth
            + clockWidth * CGFloat(clockCount) + closeWidth + gripWidth + trailingPadding
    }

    /// Natural sheet width: the fixed columns plus the minimum title column.
    static func idealWidth(clockCount: Int) -> CGFloat {
        fixedWidth(clockCount: clockCount) + minTitleWidth
    }
}

// MARK: - Formatting

enum TabSheetFormat {
    static let knownClocks: [String] = ["active", "launched", "seen"]
    static let defaultClocks: [String] = ["active", "launched"]

    /// Normalizes a host-supplied clock list: lowercased, trimmed, unknown
    /// names dropped, duplicates removed, order kept. Empty falls back to the
    /// default order.
    static func resolvedClocks(_ raw: [String]?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw ?? [] {
            let name = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard knownClocks.contains(name), seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out.isEmpty ? defaultClocks : out
    }

    /// Compact relative age: `5s`, `12m`, `2.2h`, `26h`, `3d`.
    static func age(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return String(format: localized("tabBar.sheet.time.seconds", "%llds"), Int64(max(1, seconds.rounded())))
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return String(format: localized("tabBar.sheet.time.minutes", "%lldm"), Int64(minutes.rounded(.down)))
        }
        let hours = minutes / 60
        if hours < 48 {
            let number = hours < 10
                ? String(format: "%.1f", (hours * 10).rounded(.down) / 10).replacingOccurrences(of: ".0", with: "")
                : String(Int64(hours.rounded(.down)))
            return String(format: localized("tabBar.sheet.time.hours", "%@h"), number)
        }
        return String(format: localized("tabBar.sheet.time.days", "%lldd"), Int64((hours / 24).rounded(.down)))
    }

    static func statusWord(_ kind: BonsplitTabDetail.StatusKind) -> String {
        switch kind {
        case .working: return localized("tabBar.sheet.status.working", "working")
        case .waiting: return localized("tabBar.sheet.status.waiting", "waiting")
        case .flagged: return localized("tabBar.sheet.status.flagged", "flagged")
        case .idle: return localized("tabBar.sheet.status.idle", "idle")
        case .cold: return localized("tabBar.sheet.status.cold", "cold")
        }
    }

    static func clockTitle(_ name: String) -> String {
        switch name {
        case "active": return localized("tabBar.sheet.clock.active", "Active")
        case "launched": return localized("tabBar.sheet.clock.launched", "Launched")
        case "seen": return localized("tabBar.sheet.clock.seen", "Seen")
        default: return name
        }
    }

    /// `N tabs`, `1 tab`.
    static func tabsFooter(count: Int) -> String {
        count == 1
            ? localized("tabBar.sheet.footer.oneTab", "1 tab")
            : String(format: localized("tabBar.sheet.footer.tabs", "%lld tabs"), Int64(count))
    }

    static func needYouFooter(count: Int) -> String {
        String(format: localized("tabBar.sheet.footer.needYou", "%lld need you"), Int64(count))
    }

    /// Tabs that want the operator: waiting plus flagged.
    static func needYouCount(_ tabs: [TabItem]) -> Int {
        tabs.filter { tab in
            tab.detail?.status?.kind == .flagged
                || tab.detail?.status?.kind == .waiting
                || (tab.detail?.status == nil && tab.activityState == .waiting)
        }.count
    }

    /// Date for a named clock, or nil (`seen` is nil until the host supplies it).
    static func clockDate(_ name: String, in tab: TabItem) -> Date? {
        tab.detail?.clocks[name]
    }

    static func localized(_ key: String, _ value: String) -> String {
        Bundle.module.localizedString(forKey: key, value: value, table: nil)
    }
}

// MARK: - Live relative time

/// Relative-time text that refreshes about once a second. It exists only
/// inside the open sheet, so nothing ticks while the sheet is closed. Digits
/// are tabular and the caller fixes the width, so a tick never moves a column.
struct TabSheetAgeText: View {
    let since: Date
    var font: Font = .system(size: 11, design: .monospaced)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(TabSheetFormat.age(from: since, to: context.date))
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

// MARK: - Count cell

enum TabCountCellMetrics {
    static let width: CGFloat = 54
}

/// The `N ▾` cell: tab count, background-waiting dot, disclosure chevron.
/// One primitive shared by every tier: fixed width, so the bar never shifts
/// as tabs come and go. Draws only; the host attaches the tap.
struct TabCountCell: View {
    let count: Int
    let hasBackgroundActivity: Bool
    let hasBackgroundWaiting: Bool
    let isOpen: Bool
    let isHovered: Bool
    let appearance: BonsplitConfiguration.Appearance
    let height: CGFloat

    var body: some View {
        let palette = TabBarColors.sheetPalette(for: appearance)
        HStack(spacing: 5) {
            if hasBackgroundActivity {
                Circle()
                    .fill(hasBackgroundWaiting
                        ? TabBarColors.activity(.waiting, for: appearance)
                        : TabBarColors.notificationBadge(for: appearance))
                    .frame(width: 6, height: 6)
            }
            Text("\(count)")
                .font(.system(size: appearance.tabTitleFontSize, weight: .heavy))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: "chevron.down")
                .font(.system(size: appearance.tabTitleFontSize - 2, weight: .heavy))
        }
        .foregroundStyle(isOpen ? Color(white: 0.1) : palette.text)
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
