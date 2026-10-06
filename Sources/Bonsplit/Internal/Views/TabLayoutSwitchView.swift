import SwiftUI
import AppKit

/// The Tabs | Rail switch: two equal segments with the current layout lit, at
/// the right of the tab sheet's footer and the rail's header. Segment width is
/// fixed for the run (sized to the wider localized label), so nothing moves
/// when the layout flips or the pointer crosses it.
struct TabLayoutSwitchView: View {
    let paneId: PaneID
    let controller: BonsplitController
    let config: BonsplitController.TabLayoutSwitch
    let current: BonsplitTabLayout
    let palette: TabBarColors.SheetPalette
    /// Runs before the switch applies (the sheet dismisses itself).
    var beforeSwitch: () -> Void = {}

    static let height: CGFloat = 16
    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

    /// Wide enough for either label at full size, never below 36.
    static func segmentWidth(_ config: BonsplitController.TabLayoutSwitch) -> CGFloat {
        let widest = [config.tabsLabel, config.railLabel]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return max(36, ceil(widest) + 12)
    }

    static func width(_ config: BonsplitController.TabLayoutSwitch) -> CGFloat {
        segmentWidth(config) * 2
    }

    @State private var hovered: BonsplitTabLayout?

    var body: some View {
        let segmentWidth = Self.segmentWidth(config)
        HStack(spacing: 0) {
            segment(.tabs, label: config.tabsLabel, width: segmentWidth)
            segment(.rail, label: config.railLabel, width: segmentWidth)
        }
        .frame(width: segmentWidth * 2, height: Self.height)
        .background(palette.chipFill)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(palette.chipBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .safeHelp(config.help)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(config.accessibilityLabel)
    }

    private func segment(_ layout: BonsplitTabLayout, label: String, width: CGFloat) -> some View {
        let isCurrent = layout == current
        let isHovered = hovered == layout && !isCurrent
        return Button {
            guard !isCurrent else { return }
            beforeSwitch()
            controller.switchTabLayout(to: layout, fromPane: paneId)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(isCurrent ? palette.text : (isHovered ? palette.dimText : palette.faintText))
                .frame(width: width, height: Self.height)
                .background(isCurrent ? palette.block : (isHovered ? palette.rowHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = layout } else if hovered == layout { hovered = nil }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("TabLayoutSwitch.\(layout.rawValue)")
    }
}
