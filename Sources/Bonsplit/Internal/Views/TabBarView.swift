import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum BonsplitTabBarHitRegionRegistry {
    private static let lock = NSLock()
    private static let registeredViews = NSHashTable<NSView>.weakObjects()

    static func register(_ view: NSView) {
        lock.lock()
        registeredViews.add(view)
        lock.unlock()
    }

    static func unregister(_ view: NSView) {
        lock.lock()
        registeredViews.remove(view)
        lock.unlock()
    }

    private static func snapshot() -> [NSView] {
        lock.lock()
        let views = registeredViews.allObjects
        lock.unlock()
        return views
    }

    private static func isVisibleInHierarchy(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            guard !candidate.isHidden, candidate.alphaValue > 0 else { return false }
            current = candidate.superview
        }
        return true
    }

    public static func containsWindowPoint(_ windowPoint: CGPoint, in window: NSWindow) -> Bool {
        let epsilon = max(0.5, 1.0 / max(1.0, window.backingScaleFactor))
        for view in snapshot() {
            guard view.window === window, isVisibleInHierarchy(view) else { continue }
            let frameInWindow = view.convert(view.bounds, to: nil).insetBy(dx: -epsilon, dy: -epsilon)
            if frameInWindow.contains(windowPoint) {
                return true
            }
        }
        return false
    }
}

private struct SelectedTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct TrailingAccessoryWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SplitButtonsIntrinsicWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct TabBarLayoutMetrics: Equatable {
    let paneId: PaneID
    let trailingContentInset: CGFloat
    let effectiveChromeWidth: CGFloat
    let selectedTabFrameInBar: CGRect?
}

// test-only: lets behavioral tests observe the runtime tab-bar layout after
// SwiftUI PreferenceKey measurements settle, without asserting on source shape.
private struct TabBarLayoutMetricsHandlerKey: EnvironmentKey {
    static let defaultValue: ((TabBarLayoutMetrics) -> Void)? = nil
}

extension EnvironmentValues {
    var bonsplitTabBarLayoutMetricsHandler: ((TabBarLayoutMetrics) -> Void)? {
        get { self[TabBarLayoutMetricsHandlerKey.self] }
        set { self[TabBarLayoutMetricsHandlerKey.self] = newValue }
    }
}

enum TabBarStyling {
    /// Initial fallback for the trailing split-buttons cluster before the measured
    /// width lands. Lives in `TabBarMetrics` alongside its sibling sizing constants.
    static let splitButtonsBackdropWidth: CGFloat = TabBarMetrics.splitButtonsBackdropWidth
    static let trailingChromeFadeWidth: CGFloat = 24

    enum ScrollTarget: Equatable {
        case leading
        case selectedTab(UUID)
    }

    static func separatorSegments(
        totalWidth: CGFloat,
        gap: ClosedRange<CGFloat>?
    ) -> (left: CGFloat, right: CGFloat) {
        let clampedTotal = max(0, totalWidth)
        guard let gap else {
            return (left: clampedTotal, right: 0)
        }

        let start = min(max(gap.lowerBound, 0), clampedTotal)
        let end = min(max(gap.upperBound, 0), clampedTotal)
        let normalizedStart = min(start, end)
        let normalizedEnd = max(start, end)
        let left = max(0, normalizedStart)
        let right = max(0, clampedTotal - normalizedEnd)
        return (left: left, right: right)
    }

    static func trailingTabContentInset(
        effectiveChromeWidth: CGFloat,
        isMinimalMode: Bool
    ) -> CGFloat {
        // In minimal mode the split buttons fade in on hover as an overlay. Reserving that
        // width in the scroll content leaves a dead NSClipView strip when the buttons are
        // hidden, so clicks there never reach the tab-bar chrome.
        return isMinimalMode ? 0 : max(0, effectiveChromeWidth)
    }

    static func activityAnimationVisibleRightEdge(
        containerWidth: CGFloat,
        effectiveChromeWidth: CGFloat,
        isMinimalMode: Bool,
        isHoveringTabBar: Bool
    ) -> CGFloat {
        let chromeIsVisible = !isMinimalMode || isHoveringTabBar
        let obscuredWidth = chromeIsVisible ? max(0, effectiveChromeWidth) : 0
        return max(0, containerWidth - obscuredWidth)
    }

    static func isActivityMarkVisible(
        frame: CGRect,
        visibleRightEdge: CGFloat
    ) -> Bool {
        visibleRightEdge > 0
            && frame.maxX > 0
            && frame.minX < visibleRightEdge
    }

    static func preferredScrollTarget(
        selectedTabId: UUID?,
        contentWidth: CGFloat,
        containerWidth: CGFloat
    ) -> ScrollTarget {
        guard let selectedTabId else { return .leading }

        // When the tab strip fits without horizontal scrolling, centering the selected tab
        // can strand empty NSClipView space at the leading edge in split panes. Keep the
        // content snapped to the leading edge until it actually overflows.
        guard !shouldKeepLeadingAligned(contentWidth: contentWidth, containerWidth: containerWidth) else {
            return .leading
        }

        return .selectedTab(selectedTabId)
    }

    static func shouldKeepLeadingAligned(
        contentWidth: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        let overflowThreshold: CGFloat = 1
        return contentWidth <= containerWidth + overflowThreshold
    }

    static func shouldForceResetToLeading(
        scrollOffset: CGFloat,
        contentWidth: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        guard shouldKeepLeadingAligned(contentWidth: contentWidth, containerWidth: containerWidth) else {
            return false
        }

        let overflowThreshold: CGFloat = 1
        return abs(scrollOffset) > overflowThreshold
    }
}

struct TabContextMenuState {
    let isPinned: Bool
    let isUnread: Bool
    let isBrowser: Bool
    let isTerminal: Bool
    let hasCustomTitle: Bool
    let hasCustomColor: Bool
    let canCloseToLeft: Bool
    let canCloseToRight: Bool
    let canCloseOthers: Bool
    let canMoveToLeftPane: Bool
    let canMoveToRightPane: Bool
    let isZoomed: Bool
    let hasSplits: Bool
    let shortcuts: [TabContextAction: KeyboardShortcut]
    let tabColorPalette: [BonsplitTabColorMenuItem]
    /// Host-supplied stable handle for the tab's surface (e.g. `surface:75`).
    /// nil when the host has no handle; the copy-handle menu item is hidden.
    let surfaceRef: String?

    var canMarkAsUnread: Bool {
        !isUnread
    }

    var canMarkAsRead: Bool {
        isUnread
    }
}

/// Tab bar view with scrollable tabs, drag/drop support, and split buttons
/// Responsive layout tier for a pane's tab strip. The strip keeps its tabs
/// visible (scrolling sideways when they overflow) until fewer than
/// `TabStripLayout.minTabsRoom` points remain for them; only then does it fold
/// into the solid block, with the controls moved into the sheet.
private enum TabStripLayoutTier {
    case full      // scrolling tab strip + count cell + controls inline
    case narrow    // active title + count cell; controls + tab list in the sheet
}

enum TabStripLayout {
    /// Room the strip must keep for tabs, after the count cell and controls,
    /// before it folds into the block.
    static let minTabsRoom: CGFloat = 150
}

private struct CollapsedBlockWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum CollapsedTabAccessibility {
    static func value(
        tabCount: Int,
        activityState: BonsplitTabActivityState?,
        hasBackgroundWaiting: Bool
    ) -> String {
        var parts = ["\(tabCount) tabs"]
        let activity = TabActivityAccessibility.value(for: activityState)
        if !activity.isEmpty {
            parts.append(activity)
        }
        if hasBackgroundWaiting, activityState != .waiting {
            parts.append(TabActivityAccessibility.value(for: .waiting))
        }
        return parts.joined(separator: ", ")
    }
}

struct CollapsedTabCloseButton: View {
    let tab: TabItem
    let pane: PaneState
    let controller: BonsplitController
    let appearance: BonsplitConfiguration.Appearance

    /// Closes `tab` from the collapsed list, restoring the pane's prior
    /// selection when a background tab is closed. Shared by the visible close
    /// button and the row's accessibility action.
    static func close(tab: TabItem, pane: PaneState, controller: BonsplitController) {
        let selectedTabId = pane.selectedTabId
        var didClose = false
        withTransaction(Transaction(animation: nil)) {
            controller.onTabCloseRequest?(TabID(id: tab.id), pane.id)
            didClose = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
        }
        if didClose, selectedTabId != tab.id {
            DispatchQueue.main.async {
                withTransaction(Transaction(animation: nil)) {
                    if let selectedTabId {
                        controller.selectTab(TabID(id: selectedTabId))
                    }
                }
            }
        }
    }

    var body: some View {
        Button {
            Self.close(tab: tab, pane: pane, controller: controller)
        } label: {
            Text("×")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                .frame(
                    width: SimplifiedTabGeometry.closeHitSize.width,
                    height: SimplifiedTabGeometry.closeHitSize.height
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Bundle.module.localizedString(
            forKey: "command.closeTab.title",
            value: "Close Tab",
            table: nil
        ))
    }
}

struct TabBarView<TrailingAccessory: View>: View {
    @Environment(BonsplitController.self) private var controller
    @Environment(SplitViewController.self) private var splitViewController
    @Environment(\.bonsplitTabBarLayoutMetricsHandler) private var layoutMetricsHandler
    @Environment(\.bonsplitActivityAnimationEnabled) private var activityAnimationEnabled
    @Environment(\.bonsplitExplicitActivityAnimationEnabled) private var explicitActivityAnimationEnabled
    
    @Bindable var pane: PaneState
    let isFocused: Bool
    var showSplitButtons: Bool = true
    let trailingAccessoryBuilder: (PaneID, Double) -> TrailingAccessory

    @AppStorage("workspacePresentationMode") private var presentationMode = "standard"
    @AppStorage("debugFadeColorStyle") private var fadeColorStyle = 0
    @State private var isHoveringTabBar = false
    @State private var dropTargetIndex: Int?
    @State private var dropLifecycle: TabDropLifecycle = .idle
    /// Which drop view last claimed the hover, so a stale `dropExited` from the
    /// view the ghost slot displaced cannot clear the target the ghost now owns.
    @State private var dropOwner: String?
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var selectedTabFrameInBar: CGRect?
    @State private var trailingAccessoryWidth: CGFloat = 0
    @State private var splitButtonsIntrinsicWidth: CGFloat = 0
    @State private var effectiveChromeWidth: CGFloat =
        TabBarStyling.splitButtonsBackdropWidth + TabCountCellMetrics.width
    @StateObject private var controlKeyMonitor = TabControlShortcutKeyMonitor()
    @StateObject private var scrollViewBridge = TabBarScrollViewBridge()
    // Responsive tab-strip tier. As a pane narrows the strip degrades in two
    // steps: the tab list folds into a dropdown first (controls stay inline),
    // then the controls fold in too. See the "Collapsed (narrow-pane) tab
    // dropdown" section.
    @State private var layoutTier: TabStripLayoutTier = .full
    @State private var isDropdownOpen = false
    @StateObject private var sheetPresenter = CollapsedSheetPresenter()
    @State private var collapsedBlockWidth: CGFloat = 0
    /// The bar's (that is, the area's) width; the sheet is exactly this wide.
    @State private var barWidth: CGFloat = 0
    @State private var isCountCellHovered = false

    init(
        pane: PaneState,
        isFocused: Bool,
        showSplitButtons: Bool = true,
        @ViewBuilder trailingAccessory: @escaping (PaneID, Double) -> TrailingAccessory
    ) {
        self.pane = pane
        self.isFocused = isFocused
        self.showSplitButtons = showSplitButtons
        self.trailingAccessoryBuilder = trailingAccessory
    }

    private var canScrollLeft: Bool {
        scrollOffset > 1
    }

    private var canScrollRight: Bool {
        // contentWidth includes the 30pt drop zone after tabs.
        let tabsWidth = contentWidth - 30
        guard tabsWidth > containerWidth + 4 else { return false }
        return scrollOffset < tabsWidth - containerWidth
    }

    /// Whether this tab bar should show full saturation (focused or drag source)
    private var shouldShowFullSaturation: Bool {
        isFocused || splitViewController.dragSourcePaneId == pane.id
    }

    private var tabBarSaturation: Double {
        shouldShowFullSaturation ? 1.0 : 0.0
    }

    private var appearance: BonsplitConfiguration.Appearance {
        controller.configuration.appearance
    }

    private var showsControlShortcutHints: Bool {
        isFocused && controlKeyMonitor.isShortcutHintVisible
    }

    /// Rail layout: the count cell toggles a docked vertical list instead of the sheet.
    private var isRailLayout: Bool { appearance.tabLayout == .rail }
    private var isRailOpen: Bool { isRailLayout && controller.railOpenPaneIds.contains(pane.id) }
    /// The count cell shows "open" for whichever list it toggles.
    private var isCountOpen: Bool { isDropdownOpen || isRailOpen }

    /// The count cell's action: focus the area, then toggle its list (the
    /// sheet, or the rail in Rail layout).
    private func toggleCountList() {
        guard splitViewController.isInteractive else { return }
        withTransaction(Transaction(animation: nil)) {
            controller.focusPane(pane.id)
        }
        if isRailLayout {
            isDropdownOpen = false
            controller.setRailOpen(!isRailOpen, inPane: pane.id)
        } else {
            isDropdownOpen.toggle()
        }
    }

    private var isMinimalMode: Bool {
        presentationMode == "minimal"
    }

    private var trailingTabContentInset: CGFloat {
        TabBarStyling.trailingTabContentInset(
            effectiveChromeWidth: currentEffectiveChromeWidth,
            isMinimalMode: isMinimalMode
        )
    }

    private var currentEffectiveChromeWidth: CGFloat {
        resolvedEffectiveChromeWidth(
            trailingAccessoryWidth: trailingAccessoryWidth,
            splitButtonsIntrinsicWidth: splitButtonsIntrinsicWidth
        )
    }

    private var activityAnimationVisibleRightEdge: CGFloat {
        TabBarStyling.activityAnimationVisibleRightEdge(
            containerWidth: containerWidth,
            effectiveChromeWidth: currentEffectiveChromeWidth,
            isMinimalMode: isMinimalMode,
            isHoveringTabBar: isHoveringTabBar
        )
    }

    private var currentLayoutMetrics: TabBarLayoutMetrics {
        TabBarLayoutMetrics(
            paneId: pane.id,
            trailingContentInset: trailingTabContentInset,
            effectiveChromeWidth: currentEffectiveChromeWidth,
            selectedTabFrameInBar: selectedTabFrameInBar
        )
    }

    private func resolvedEffectiveChromeWidth(
        trailingAccessoryWidth: CGFloat,
        splitButtonsIntrinsicWidth: CGFloat
    ) -> CGFloat {
        let internalSplitButtonsWidth = showSplitButtons ? splitButtonsIntrinsicWidth : 0
        let measuredWidth = max(max(0, trailingAccessoryWidth), max(0, internalSplitButtonsWidth))
        // The count cell always sits at the left of the chrome, so its fixed
        // width is part of every measured result. The stored fallback (its
        // initial value included) already carries it.
        guard measuredWidth > 0 else {
            return showSplitButtons ? max(0, effectiveChromeWidth) : TabCountCellMetrics.width
        }
        return measuredWidth + TabCountCellMetrics.width
    }

    /// The tabs whose frames the strip measures: the selected one, the one lit by
    /// linked hover while a sheet is open, and a flashing one. Everything else
    /// goes unmeasured.
    private var measuredTabIds: Set<UUID> {
        var ids = Set<UUID>()
        if let selected = pane.selectedTabId { ids.insert(selected) }
        if isDropdownOpen, let hovered = controller.linkedHoverTabId { ids.insert(hovered) }
        if let flashed = pane.flashTabId { ids.insert(flashed) }
        return ids
    }

    private var leadingScrollAnchorId: String {
        "tab-bar-leading-\(pane.id.id.uuidString)"
    }

    private func focusPaneFromTabBarChrome() -> Bool {
        guard !isFocused else { return false }
        withTransaction(Transaction(animation: nil)) {
            controller.focusPane(pane.id)
        }
        return true
    }

    /// Keeps the strip anchored to the leading edge while it fits, and otherwise
    /// asks the bridge to reveal the selected tab with the least movement,
    /// clear of the controls and fades. Width changes only re-reveal when the
    /// selected tab is wholly out of view and the operator has not scrolled.
    private func scrollToPreferredTarget(
        _ proxy: ScrollViewProxy,
        selectedTabId: UUID?,
        reason: TabBarScrollViewBridge.RevealReason
    ) {
        if scrollViewBridge.shouldPreferLeadingTarget(
            selectedTabId: selectedTabId,
            fallbackContentWidth: contentWidth,
            fallbackContainerWidth: containerWidth
        ) || selectedTabId == nil {
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(leadingScrollAnchorId, anchor: .leading)
            }
            if TabBarStyling.shouldForceResetToLeading(
                scrollOffset: scrollOffset,
                contentWidth: contentWidth,
                containerWidth: containerWidth
            ) {
                scrollViewBridge.resetToLeadingEdgeIfNeeded(reason: "scrollToPreferredTarget")
            } else {
                scrollViewBridge.enforceLeadingEdgeIfContentFits(reason: "scrollToPreferredTarget")
            }
            return
        }
        if let selectedTabId {
            scrollViewBridge.requestReveal(selectedTabId, reason: reason)
        }
    }

    var body: some View {
        sizedBar
            .modifier(TabBarAutomationRequests(
                controller: controller,
                paneId: pane.id,
                bridge: scrollViewBridge,
                isSheetOpen: $isDropdownOpen
            ))
            .onChange(of: isDropdownOpen) { _, open in
                if open {
                    controller.openTabSheetPaneIds.insert(pane.id)
                } else {
                    controller.openTabSheetPaneIds.remove(pane.id)
                    // Nothing left to link to: don't leave a tab lit.
                    controller.clearLinkedHover()
                }
                syncCollapsedSheet()
            }
            .onChange(of: collapsedBlockWidth) { _, _ in
                if isDropdownOpen { syncCollapsedSheet() }
            }
            .onChange(of: splitViewController.draggingTab) { _, newValue in
                handleDraggingTabChange(newValue)
            }
            // Inactive workspaces stay mounted (hidden), so `onDisappear` never fires
            // on a workspace switch. Interactivity is the signal that this pane's
            // workspace went away.
            .onChange(of: splitViewController.isInteractive) { _, interactive in
                // A workspace switch takes the sheet away at once: no roll-up
                // playing over the workspace that just arrived.
                if !interactive, isDropdownOpen {
                    sheetPresenter.dismiss()
                    isDropdownOpen = false
                }
            }
            .onDisappear {
                isDropdownOpen = false
                controller.openTabSheetPaneIds.remove(pane.id)
                sheetPresenter.dismiss()
            }
    }

    private var sizedBar: some View {
        GeometryReader { outerGeo in
            Group {
                if isRailOpen {
                    railBar
                } else if layoutTier == .full {
                    horizontalBar
                } else {
                    collapsedBar()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .onAppear {
                barWidth = outerGeo.size.width
                recomputeLayoutTier(availableWidth: outerGeo.size.width)
            }
            .onChange(of: outerGeo.size.width) { _, newWidth in
                barWidth = newWidth
                recomputeLayoutTier(availableWidth: newWidth)
                // A resize across a width tier relays the open sheet at once.
                if isDropdownOpen { syncCollapsedSheet() }
            }
            .onChange(of: collapseDecisionSignature) { _, _ in
                recomputeLayoutTier(availableWidth: outerGeo.size.width)
                if isDropdownOpen { syncCollapsedSheet() }
            }
        }
        .frame(height: appearance.tabBarHeight)
    }

    private func handleDraggingTabChange(_ newValue: TabItem?) {
#if DEBUG
        dlog(
            "tab.sheet.dragState pane=\(pane.id.id.uuidString.prefix(5)) " +
            "dragging=\(newValue != nil ? 1 : 0) open=\(isDropdownOpen ? 1 : 0) " +
            "presented=\(sheetPresenter.isPresented ? 1 : 0)"
        )
#endif
        if newValue != nil {
            if sheetPresenter.isPresented { sheetPresenter.beginDragTracking() }
            if layoutTier == .full { scrollViewBridge.beginDragAutoScroll(trailingInset: currentEffectiveChromeWidth) }
        } else {
            scrollViewBridge.endDragAutoScroll()
            // The drag is over (dropped, cancelled, or landed elsewhere):
            // any lingering collapsed-bar drop state goes, and the sheet is torn
            // down once AppKit has finished the drag session (its rows are the
            // drag source, so it must outlive the drop callback).
            dropTargetIndex = nil
            dropLifecycle = .idle
            dropOwner = nil
            sheetPresenter.dragEnded()
        }
    }

    // MARK: - Rail bar

    /// The bar while an area's rail is open: the visible tab's `Tab N · title`,
    /// the count cell (gold, closing the rail) and the controls. The strip is
    /// hidden; the rail replaces it. Too narrow for the controls, they move to
    /// the top of the rail.
    private var railBar: some View {
        let palette = sheetPalette
        let ruleHeight = isFocused ? appearance.tabActiveIndicatorHeight : 1
        let blockHeight = max(0, appearance.tabBarHeight - ruleHeight)
        let tab = activeTab
        let number = tab?.displayOrdinal.map { TabSheetFormat.tabLabel($0) }
        let title = tab?.detail?.title.flatMap { $0.isEmpty ? nil : $0 } ?? tab?.title ?? ""
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                if let tab, let state = tab.activityState {
                    collapsedActivityMark(for: tab, state: state)
                }
                Text([number, title].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: appearance.tabTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: blockHeight)
            .background(palette.block)
            .saturation(tabBarSaturation)

            TabCountCell(
                count: pane.tabs.count,
                hasBackgroundActivity: hasBackgroundActivity,
                hasBackgroundWaiting: hasBackgroundWaiting,
                isOpen: true,
                isHovered: false,
                appearance: appearance,
                height: blockHeight
            )
            .frame(maxHeight: .infinity, alignment: .top)
            .saturation(tabBarSaturation)
            .contentShape(Rectangle())
            .onTapGesture { toggleCountList() }

            if !railBarLacksRoomForControls {
                splitButtons.saturation(tabBarSaturation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: appearance.tabBarHeight)
        .background(collapsedBarBackground)
        .background(TabBarDragAndHoverView(
            isMinimalMode: isMinimalMode,
            onHoverChanged: { isHoveringTabBar = $0 }
        ))
        .background(CollapsedSheetAnchorReader {
            sheetPresenter.anchorView = $0
            scrollViewBridge.barView = $0
        })
        .onAppear { controller.railNeedsControlsUpdate(pane.id, needs: railBarLacksRoomForControls) }
        .onChange(of: barWidth) { _, _ in
            controller.railNeedsControlsUpdate(pane.id, needs: railBarLacksRoomForControls)
        }
    }

    /// The controls move into the rail only when the bar truly lacks room for
    /// them next to the count cell and a readable title.
    private var railBarLacksRoomForControls: Bool {
        let minTitleRoom: CGFloat = 110
        return barWidth - 8 - TabCountCellMetrics.width - estimatedChromeWidth < minTitleRoom
    }

    // MARK: - Horizontal Tab Strip (default / wide layout)

    @ViewBuilder
    private var horizontalBar: some View {
        HStack(spacing: 0) {
            if appearance.tabBarLeadingInset > 0 && controller.internalController.rootNode.allPaneIds.first == pane.id {
                TabBarDragZoneView(
                    isMinimalMode: isMinimalMode,
                    isFocusedPane: isFocused,
                    onSingleClick: focusPaneFromTabBarChrome
                ) { return false }
                    .frame(width: appearance.tabBarLeadingInset)
            }
            // Scrollable tabs with fade overlays
            GeometryReader { containerGeo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: appearance.tabSpacing) {
                            Color.clear
                                .frame(width: 0, height: appearance.tabItemHeight)
                                .id(leadingScrollAnchorId)

                            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                                // Ghost slot: opens at the landing index and pushes
                                // the neighbors over, so the strip previews the result.
                                if dropTargetIndex == index {
                                    ghostSlot(at: index)
                                }
                                tabItem(for: tab, at: index)
                                    .modifier(TabStripFrameReporter(id: tab.id, active: measuredTabIds.contains(tab.id)))
                                    .id(tab.id)
                            }

                            if dropTargetIndex == pane.tabs.count {
                                ghostSlot(at: pane.tabs.count)
                            }

                            // Unified drop zone after the last tab.
                            dropZoneAfterTabs
                        }
                        .padding(.horizontal, TabBarMetrics.barPadding)
                        .padding(.trailing, trailingTabContentInset)
                        .animation(nil, value: pane.tabs.map(\.id))
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear
                                    .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                                        scrollOffset = -newFrame.minX
                                        contentWidth = newFrame.width
                                        scrollViewBridge.mirror.offset = scrollOffset
                                        scrollViewBridge.mirror.content = contentWidth
                                    }
                                    .onAppear {
                                        let frame = contentGeo.frame(in: .named("tabScroll"))
                                        scrollOffset = -frame.minX
                                        contentWidth = frame.width
                                        scrollViewBridge.mirror.offset = scrollOffset
                                        scrollViewBridge.mirror.content = contentWidth
                                    }
                            }
                        )
                    }
                    .background(
                        TabBarScrollViewResolver { scrollView in
                            scrollViewBridge.attach(scrollView)
                        }
                        .frame(width: 0, height: 0)
                    )
                    // When the tab strip is shorter than the visible area, allow dropping in the
                    // empty trailing space without forcing tabs to stretch.
                    .overlay(alignment: .trailing) {
                        // The scroll content reserves `trailingTabContentInset` for the
                        // chrome, so the visible empty stretch runs from the end of the
                        // tabs to the chrome's left edge. Cover that stretch (the zone
                        // extends under the chrome backdrop, which draws above it).
                        let trailing = max(0, containerGeo.size.width - contentWidth + trailingTabContentInset)
                        if trailing >= 1 {
                            TabBarDragZoneView(
                                isMinimalMode: isMinimalMode,
                                isFocusedPane: isFocused,
                                onSingleClick: focusPaneFromTabBarChrome
                            ) {
                                guard splitViewController.isInteractive else { return false }
                                controller.requestNewTab(kind: "terminal", inPane: pane.id)
                                return true
                            }
                            .frame(width: trailing, height: appearance.tabItemHeight)
                            .overlay { neutralZoneTint(fadesOut: true) }
                            .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
                                ownerId: "zone-trailing",
                                dropOwner: $dropOwner,
                                targetIndex: pane.tabs.count,
                                pane: pane,
                                bonsplitController: controller,
                                controller: splitViewController,
                                dropTargetIndex: $dropTargetIndex,
                                dropLifecycle: $dropLifecycle
                            ))
                        }
                    }
                    .coordinateSpace(name: "tabScroll")
                    // The scroll math (offsets, reveal, wheel) is left-to-right only.
                    .environment(\.layoutDirection, .leftToRight)
                    .modifier(TabStripProxyCapture(bridge: scrollViewBridge, proxy: proxy))
                    .onAppear {
                        containerWidth = containerGeo.size.width
                        scrollViewBridge.mirror.container = containerGeo.size.width
                        // The first reveal must already clear the controls.
                        scrollViewBridge.chromeInset = currentEffectiveChromeWidth
                        scrollToPreferredTarget(proxy, selectedTabId: pane.selectedTabId, reason: .selection)
                    }
                    .onChange(of: containerGeo.size.width) { _, newWidth in
                        containerWidth = newWidth
                        scrollViewBridge.mirror.container = newWidth
                        scrollToPreferredTarget(proxy, selectedTabId: pane.selectedTabId, reason: .geometry)
                    }
                    .onChange(of: contentWidth) { _, _ in
                        // The ghost slot grows the content mid-drag; scrolling to the
                        // selected tab then would slide the strip under the cursor.
                        guard splitViewController.draggingTab == nil, dropTargetIndex == nil else { return }
                        scrollToPreferredTarget(proxy, selectedTabId: pane.selectedTabId, reason: .geometry)
                    }
                    .onChange(of: pane.selectedTabId) { _, newTabId in
                        scrollToPreferredTarget(proxy, selectedTabId: newTabId, reason: .selection)
                    }

                    .onChange(of: pane.flashTabGeneration) { _, _ in
                        guard let flashId = pane.flashTabId else { return }
                        // Bring the flashed tab into view before its pulse animation begins.
                        // Selection is intentionally unchanged.
                        scrollViewBridge.requestReveal(flashId, reason: .flash)
                    }
                }
                .frame(height: appearance.tabBarHeight)
                .mask(combinedMask)
                // Trailing chrome sits on top of the tab strip in its own opaque backdrop.
                // The backdrop visually obscures any tabs that scroll under the chrome,
                // and (critically) does not break hit testing on tabs outside the backdrop —
                // unlike the prior approach of using a `Color.clear` region in `combinedMask`,
                // which silently blocked SwiftUI hit tests in the masked-out area and let
                // tab clicks fall through to `TabBarDragAndHoverView` (which performs a
                // window drag in minimal mode).
                .overlay(alignment: .trailing) {
                    let shouldShow = !isMinimalMode || isHoveringTabBar || isDropdownOpen
                    let backdropColor = Color(nsColor: Self.buttonBackdropColor(
                        for: appearance,
                        focused: isFocused,
                        style: fadeColorStyle
                    ))
                    let chromeWidth = currentEffectiveChromeWidth
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [backdropColor.opacity(0), backdropColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: TabBarStyling.trailingChromeFadeWidth)
                            Rectangle().fill(backdropColor)
                        }
                        .frame(width: chromeWidth > 0 ? chromeWidth + TabBarStyling.trailingChromeFadeWidth : 0)

                        // During the staged CMUX-30 migration, host-supplied chrome is
                        // rendered to the left of the internal split-buttons row. Phase 3
                        // removes the internal row after c11mux owns this accessory.
                        HStack(spacing: 0) {
                            fullTierCountCell
                                .saturation(tabBarSaturation)

                            trailingAccessoryBuilder(pane.id, tabBarSaturation)
                                .environment(\.bonsplitTabBarHover, isHoveringTabBar)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: TrailingAccessoryWidthKey.self,
                                            value: geometry.size.width
                                        )
                                    }
                                )

                            if showSplitButtons {
                                splitButtons
                                    .saturation(tabBarSaturation)
                                    .background(
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: SplitButtonsIntrinsicWidthKey.self,
                                                value: geometry.size.width
                                            )
                                        }
                                    )
                            }
                        }
                    }
                    .padding(.bottom, 1)
                    .opacity(shouldShow ? 1 : 0)
                    .allowsHitTesting(shouldShow)
                    .animation(.easeInOut(duration: 0.14), value: shouldShow)
                }
            }
        }
        .frame(height: appearance.tabBarHeight)
        .coordinateSpace(name: "tabBar")
        .modifier(TabStripScrollPositionModifier(bridge: scrollViewBridge))
        .modifier(TabStripTargetObserver(
            controller: controller,
            bridge: scrollViewBridge,
            isSheetOpen: isDropdownOpen
        ))
        .background(tabBarBackground)
        .background(TabBarDragAndHoverView(
            isMinimalMode: isMinimalMode,
            onHoverChanged: { isHoveringTabBar = $0 }
        ))
        .background(CollapsedSheetAnchorReader {
            sheetPresenter.anchorView = $0
            scrollViewBridge.barView = $0
        })
        .background(
            TabBarHostWindowReader { window in
                controlKeyMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        // Clear drop state when drag ends elsewhere (cancelled, dropped in another pane, etc.)
        .onChange(of: splitViewController.draggingTab) { _, newValue in
#if DEBUG
            dlog(
                "tab.dragState pane=\(pane.id.id.uuidString.prefix(5)) " +
                "draggingTab=\(newValue != nil ? 1 : 0) " +
                "activeDragTab=\(splitViewController.activeDragTab != nil ? 1 : 0)"
            )
#endif
            if newValue == nil {
                dropTargetIndex = nil
                dropLifecycle = .idle
                dropOwner = nil
            }
        }
        .onAppear {
            controlKeyMonitor.start()
            layoutMetricsHandler?(currentLayoutMetrics)
            // The wheel remap only exists while a full-tier strip is on screen.
            scrollViewBridge.isInteractiveProvider = { [weak splitViewController] in splitViewController?.isInteractive ?? false }
            scrollViewBridge.setWheelRoutingEnabled(true)
        }
        .onPreferenceChange(SelectedTabFramePreferenceKey.self) { frame in
            selectedTabFrameInBar = frame
        }
        .onPreferenceChange(TrailingAccessoryWidthKey.self) { width in
            let normalizedWidth = max(0, width)
            trailingAccessoryWidth = normalizedWidth
            effectiveChromeWidth = resolvedEffectiveChromeWidth(
                trailingAccessoryWidth: normalizedWidth,
                splitButtonsIntrinsicWidth: splitButtonsIntrinsicWidth
            )
            scrollViewBridge.chromeInset = effectiveChromeWidth
        }
        .onPreferenceChange(SplitButtonsIntrinsicWidthKey.self) { width in
            let normalizedWidth = max(0, width)
            splitButtonsIntrinsicWidth = normalizedWidth
            effectiveChromeWidth = resolvedEffectiveChromeWidth(
                trailingAccessoryWidth: trailingAccessoryWidth,
                splitButtonsIntrinsicWidth: normalizedWidth
            )
            scrollViewBridge.chromeInset = effectiveChromeWidth
        }
        .onChange(of: currentLayoutMetrics) { _, metrics in
            layoutMetricsHandler?(metrics)
        }
        .onDisappear {
            controlKeyMonitor.stop()
            scrollViewBridge.setWheelRoutingEnabled(false)
            scrollViewBridge.endDragAutoScroll()
        }
    }

    // MARK: - Collapsed (narrow-pane) tab dropdown

    /// Value the collapse decision depends on, beyond raw width: the set of tab
    /// titles plus the active selection. Recompute the mode when any change.
    private var collapseDecisionSignature: [String] {
        pane.tabs.map {
            "\($0.id.uuidString)\u{1}\($0.numberLabel(showOrdinals: appearance.showTabOrdinals) ?? "")\u{1}\($0.title)\u{1}\($0.activityState?.rawValue ?? "-")"
        }
            + ["sel:\(pane.selectedTabId?.uuidString ?? "-")"]
    }

    private var activeTab: TabItem? {
        if let id = pane.selectedTabId, let match = pane.tabs.first(where: { $0.id == id }) {
            return match
        }
        return pane.tabs.first
    }

    /// Any non-active tab asking for attention (unread/activity or dirty).
    private var hasBackgroundActivity: Bool {
        let activeId = activeTab?.id
        return pane.tabs.contains {
            $0.id != activeId
                && ($0.activityState == .waiting || $0.showsNotificationBadge || $0.isDirty)
        }
    }

    private var hasBackgroundWaiting: Bool {
        let activeId = activeTab?.id
        return pane.tabs.contains { $0.id != activeId && $0.activityState == .waiting }
    }

    /// Width the mono tab number takes in the strip (digits plus its gap).
    private func numberSlotWidth(for tab: TabItem) -> CGFloat {
        guard let label = tab.numberLabel(showOrdinals: appearance.showTabOrdinals) else { return 0 }
        return CGFloat(label.count) * (appearance.tabTitleFontSize - 2) * 0.62 + appearance.tabContentSpacing
    }

    private func measuredTitleWidth(_ title: String, bold: Bool) -> CGFloat {
        let weight: NSFont.Weight = bold ? .semibold : .regular
        let font = NSFont.systemFont(ofSize: appearance.tabTitleFontSize, weight: weight)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    private func perTabFixedCost(for tab: TabItem) -> CGFloat {
        let leading = tab.activityState.map(TabActivityMarkMetrics.leadingAccessoryWidth)
            ?? SimplifiedTabGeometry.unmarkedLeadingInset
        return leading
            + SimplifiedTabGeometry.closeHitSize.width
            + SimplifiedTabGeometry.closeTrailingInset
    }

    /// Estimated width of the trailing chrome cluster (surface-spawn + split +
    /// new-tab + close-pane buttons, plus the two group separators). Derived
    /// from `appearance` so it tracks compact/spacious presets and stays valid
    /// while collapsed, when the rendered preference keys no longer update.
    private var estimatedChromeWidth: CGFloat {
        guard showSplitButtons else { return max(0, trailingAccessoryWidth) }
        // Prefer the real measured cluster width once the horizontal (or medium)
        // strip has rendered the buttons; the @State retains it while narrow, so
        // the full↔medium boundary stays exact. Fall back to a computed estimate
        // only before the first measurement.
        if splitButtonsIntrinsicWidth > 0 {
            return splitButtonsIntrinsicWidth + max(0, trailingAccessoryWidth)
        }
        let buttonCount: CGFloat = 8        // A, terminal, browser, markdown, split→, split↓, +, ✕
        let separatorCount: CGFloat = 2
        let itemCount = buttonCount + separatorCount
        let buttons = buttonCount * appearance.splitToolbarButtonFrameSize
        let separators = separatorCount * (1 + 16)      // 1pt rule + 8pt padding per side
        let interItemSpacing: CGFloat = 2 * max(0, itemCount - 1)
        let outerPadding: CGFloat = 6 + 8
        return buttons + separators + interItemSpacing + outerPadding + max(0, trailingAccessoryWidth)
    }

    /// Sum of every tab's natural (untruncated) width, clamped to the per-tab
    /// min/max. When this exceeds the room left after the chrome, the strip
    /// would have to truncate — the signal to fold into the dropdown.
    private var desiredTabsWidth: CGFloat {
        // Decision floor is intentionally below the layout `tabMinWidth` so the
        // strip stays inline a bit tighter — letting the controls cover more of
        // a narrow pane before collapsing. This only affects short-title tabs
        // (e.g. "~"); long titles collapse on their real measured width.
        let floor: CGFloat = min(appearance.tabMinWidth, 68)
        let maxW = appearance.tabMaxWidth
        var total: CGFloat = 0
        for tab in pane.tabs {
            let natural = perTabFixedCost(for: tab)
                + measuredTitleWidth(
                    tab.title,
                    bold: pane.selectedTabId == tab.id
                )
                + numberSlotWidth(for: tab)
            total += min(maxW, max(floor, natural))
        }
        if pane.tabs.count > 1 {
            total += appearance.tabSpacing * CGFloat(pane.tabs.count - 1)
        }
        return total
    }

    /// Choose the layout tier for the available width with directional
    /// hysteresis: the strip degrades promptly when space runs out, but
    /// re-expands only past a slack margin, so dragging a divider near a
    /// boundary doesn't strobe between tiers.
    ///
    /// - `.full`   : at least `minTabsRoom` remains for tabs after the count
    ///               cell and controls (or all tabs fit in less). Overflowing
    ///               tabs scroll sideways.
    /// - `.narrow` : less than that; only the active title shows, the controls
    ///               move into the sheet's first row.
    private func recomputeLayoutTier(availableWidth: CGFloat) {
        guard availableWidth > 1, !pane.tabs.isEmpty else {
            setLayoutTier(.full)
            return
        }
        let hysteresis: CGFloat = 28
        let trailingSlack: CGFloat = 8
        let roomForTabs = availableWidth - trailingSlack - estimatedChromeWidth - TabCountCellMetrics.width
        let need = min(TabStripLayout.minTabsRoom, desiredTabsWidth)

        var target = layoutTier
        switch layoutTier {
        case .full:
            if roomForTabs < need { target = .narrow }
        case .narrow:
            if roomForTabs >= need + hysteresis { target = .full }
        }
        setLayoutTier(target)
    }

    private func setLayoutTier(_ newTier: TabStripLayoutTier) {
        guard newTier != layoutTier else { return }
        layoutTier = newTier
        // Close any open dropdown on a tier change: `.full` has no dropdown, and
        // the dropdown's contents differ between medium and narrow.
        if isDropdownOpen { isDropdownOpen = false }
    }

    /// Height of the folded controls row at the top of the narrow-tier sheet.
    private var sheetControlsRowHeight: CGFloat {
        max(30, appearance.tabItemHeight + 4)
    }

    /// Sheet width: exactly the area's, so the drawer belongs to it and never
    /// overhangs a neighbour. An area narrower than 320pt still gets 320pt
    /// (anchored left), and the result never exceeds the screen.
    private func sheetWidth() -> CGFloat {
        let area = barWidth > 1 ? barWidth : (sheetPresenter.anchorView?.bounds.width ?? containerWidth)
        let wanted = max(TabSheetMetrics.minSheetWidth, area)
        guard let visible = (sheetPresenter.anchorView?.window?.screen ?? NSScreen.main)?.visibleFrame else {
            return wanted
        }
        return min(wanted, visible.width)
    }

    @ViewBuilder
    private func collapsedBar() -> some View {
        HStack(spacing: 0) {
            // The whole header is one solid block (active tab + count cell),
            // flush left and as tall as the bar.
            collapsedHeaderBlock

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: appearance.tabBarHeight)
        // The ENTIRE header (title included) is one tap target. The gesture is
        // on this outer view, ahead of the NSView-backed hover/drag background,
        // so SwiftUI receives the click. Do NOT wrap the title/disclosure in a
        // child that adds its own `.onHover` + `.background`: that creates an
        // AppKit hosting layer which swallows the mouse-down and the tap stops
        // firing. The hover affordance is driven from `isHoveringTabBar` in the
        // background instead. Everything on the bar opens the sheet.
        .contentShape(Rectangle())
        .onTapGesture { toggleCountList() }
        .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
            ownerId: "collapsed-bar",
            dropOwner: $dropOwner,
            targetIndex: pane.tabs.count,
            pane: pane,
            bonsplitController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
        .background(collapsedBarBackground)
        .background(TabBarDragAndHoverView(
            isMinimalMode: isMinimalMode,
            onHoverChanged: { isHoveringTabBar = $0 }
        ))
        .background(CollapsedSheetAnchorReader {
            sheetPresenter.anchorView = $0
            // Collapsed tiers hang flush-left under the bar, not off the cell.
            sheetPresenter.trailingAnchorView = nil
        })
    }

    /// Cached per chrome background: a lookup, not a rebuild.
    private var sheetPalette: TabBarColors.SheetPalette {
        TabBarColors.sheetPalette(for: appearance)
    }

    /// The full tier's count cell: pinned at the left edge of the trailing
    /// chrome, so it holds one spot whatever the tabs do. Tapping it opens the
    /// same sheet as the collapsed header.
    private var fullTierCountCell: some View {
        let ruleHeight = isFocused ? appearance.tabActiveIndicatorHeight : 1
        return TabCountCell(
            count: pane.tabs.count,
            hasBackgroundActivity: hasBackgroundActivity,
            hasBackgroundWaiting: hasBackgroundWaiting,
            isOpen: isCountOpen,
            isHovered: isCountCellHovered,
            appearance: appearance,
            height: max(0, appearance.tabBarHeight - ruleHeight)
        )
        .onHover { isCountCellHovered = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CollapsedSheetTrailingAnchorReader { sheetPresenter.trailingAnchorView = $0 })
        .contentShape(Rectangle())
        .onTapGesture { toggleCountList() }
    }

    /// The dropdown control: a solid block in the active tab's background that
    /// fills the bar's height (above the bottom rule), square-cornered and
    /// flush left. Inside: activity mark, `N: title`, and a separate square
    /// count cell at the right edge (background-waiting dot, count, chevron)
    /// that fills gold while the sheet is open. Brightens on hover via the
    /// shared `isHoveringTabBar` (the AppKit hover view). This view only
    /// DRAWS; it adds no `.onHover`/NSView layer, so the outer bar's tap
    /// gesture still fires over it. (A child `.onHover` here would create an
    /// AppKit hosting layer that swallows the mouse-down: that mistake is why
    /// the tap broke once.)
    private var collapsedHeaderBlock: some View {
        let palette = sheetPalette
        let isBlockLinked = isDropdownOpen && activeTab.map { controller.linkedHoverTabId == $0.id } == true
        let ruleHeight = isFocused ? appearance.tabActiveIndicatorHeight : 1
        let blockHeight = max(0, appearance.tabBarHeight - ruleHeight)
        let gold = TabBarColors.activeIndicator(for: appearance)
        let isDropHot = splitViewController.draggingTab != nil && dropTargetIndex == pane.tabs.count
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                if let tab = activeTab, let state = tab.activityState {
                    collapsedActivityMark(for: tab, state: state)
                }

                if let number = activeTab?.numberLabel(showOrdinals: appearance.showTabOrdinals) {
                    Text(number)
                        .font(.system(size: appearance.tabTitleFontSize - 2, weight: .bold, design: .monospaced))
                        .foregroundStyle(gold)
                }

                Text(activeTab?.title ?? "")
                    .font(.system(size: appearance.tabTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(palette.text)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            TabCountCell(
                count: pane.tabs.count,
                hasBackgroundActivity: hasBackgroundActivity,
                hasBackgroundWaiting: hasBackgroundWaiting,
                isOpen: isCountOpen,
                isHovered: isHoveringTabBar,
                appearance: appearance,
                height: blockHeight
            )
        }
        .frame(height: blockHeight)
        .background(isHoveringTabBar || isBlockLinked ? palette.blockHover : palette.block)
        .overlay(alignment: .bottom) {
            // Linked hover: hovering the active tab's sheet row lights the block.
            if isBlockLinked {
                Rectangle()
                    .fill(TabBarColors.activeText(for: appearance))
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(TabBarColors.separator(for: appearance))
                .frame(width: 1)
        }
        .frame(height: appearance.tabBarHeight, alignment: .top)
        .saturation(tabBarSaturation)
        .overlay(alignment: .top) {
            // Drop target: a tab dragged over the block lands at the end. Drawn
            // after the desaturation so it stays gold on an unfocused pane.
            if isDropHot {
                ZStack {
                    gold.opacity(0.35)
                    Rectangle().strokeBorder(gold, lineWidth: 1.5)
                }
                .frame(height: blockHeight)
                .allowsHitTesting(false)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CollapsedBlockWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(CollapsedBlockWidthKey.self) { collapsedBlockWidth = $0 }
        .accessibilityLabel(Bundle.module.localizedString(
            forKey: "tabBar.collapsedHeader.accessibilityLabel",
            value: "Show all tabs",
            table: nil
        ))
        .accessibilityValue(CollapsedTabAccessibility.value(
            tabCount: pane.tabs.count,
            activityState: activeTab?.activityState,
            hasBackgroundWaiting: hasBackgroundWaiting
        ))
        .accessibilityHint(TabActivityAccessibility.help(
            for: activeTab?.activityState == .waiting || hasBackgroundWaiting ? .waiting : nil
        ))
    }

    /// Background for the collapsed bar: bar fill plus a continuous full-width
    /// bottom accent line (gold when focused, separator otherwise). Drawn behind
    /// the content so it never covers it or intercepts the tap.
    @ViewBuilder
    private var collapsedBarBackground: some View {
        let base = isFocused
            ? TabBarColors.barBackground(for: appearance)
            : TabBarColors.barBackground(for: appearance).opacity(0.95)
        Rectangle()
            .fill(base)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused
                        ? TabBarColors.activeIndicator(for: appearance)
                        : TabBarColors.separator(for: appearance))
                    .frame(height: isFocused ? appearance.tabActiveIndicatorHeight : 1)
            }
    }

    // MARK: Collapsed sheet

    /// Opens, refreshes, or tears down the sheet panel to match
    /// `isDropdownOpen` and the current tier.
    private func syncCollapsedSheet() {
        guard isDropdownOpen else {
            sheetPresenter.dismissAnimated()
            return
        }
        let titleProvider = controller.sheetClockTitleProvider
        let clocks = TabSheetFormat.resolvedClocks(controller.sheetClockOrderProvider?()) { name in
            TabSheetFormat.clockTitle(name, hostTitle: titleProvider?(name)) != nil
        }
        var clockTitles: [String: String] = [:]
        for name in clocks { if let title = titleProvider?(name) { clockTitles[name] = title } }
        if !sheetPresenter.isPresented {
            // Recompute the host detail once as the sheet opens: values that
            // change without a metadata event (the activity clock) are fresh.
            controller.refreshTabDetails(inPane: pane.id)
        }
        sheetPresenter.blockWidth = collapsedBlockWidth
        sheetPresenter.onDismiss = { isDropdownOpen = false }
        sheetPresenter.present(rootView: AnyView(
            CollapsedTabSheetView(
                pane: pane,
                controller: controller,
                splitViewController: splitViewController,
                appearance: appearance,
                includesControls: layoutTier == .narrow,
                layout: TabSheetLayout(width: sheetWidth(), clocks: clocks),
                controlsRowHeight: sheetControlsRowHeight,
                clockTitles: clockTitles,
                activityAnimationEnabled: activityAnimationEnabled,
                explicitActivityAnimationEnabled: explicitActivityAnimationEnabled,
                makeItemProvider: { createItemProvider(for: $0) },
                dismiss: { isDropdownOpen = false },
                onReordered: { [weak sheetPresenter] in sheetPresenter?.dropAppliedInSheet() }
            )
        ))
    }

    private func collapsedActivityMark(
        for tab: TabItem,
        state: BonsplitTabActivityState
    ) -> some View {
        CollapsedActivityMarkView(
            tab: tab,
            state: state,
            appearance: appearance,
            activityAnimationEnabled: activityAnimationEnabled,
            explicitActivityAnimationEnabled: explicitActivityAnimationEnabled
        )
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for tab: TabItem, at index: Int) -> some View {
        let contextMenuState = contextMenuState(for: tab, at: index)
        let showsZoomIndicator = splitViewController.zoomedPaneId == pane.id && pane.selectedTabId == tab.id
        TabItemView(
            tab: tab,
            isSelected: pane.selectedTabId == tab.id,
            showsZoomIndicator: showsZoomIndicator,
            appearance: appearance,
            saturation: tabBarSaturation,
            controlShortcutDigit: tabControlShortcutDigit(for: index, tabCount: pane.tabs.count),
            showsControlShortcutHint: showsControlShortcutHints,
            shortcutModifierSymbol: controlKeyMonitor.shortcutModifierSymbol,
            contextMenuState: contextMenuState,
            activityAnimationVisibleRightEdge: activityAnimationVisibleRightEdge,
            useSimplifiedTabUX: controller.configuration.simplifiedTabContextMenu,
            flashGeneration: (pane.flashTabId == tab.id) ? pane.flashTabGeneration : 0,
            isLinkedHover: isDropdownOpen && controller.linkedHoverTabId == tab.id,
            onHoverChanged: { hovering in
                if hovering {
                    // Only while the sheet is open is there a row to light.
                    guard isDropdownOpen else { return }
                    controller.setLinkedHover(tab.id, fromSheet: false)
                } else {
                    // Always clear on exit, so a sheet closing under the pointer
                    // cannot strand the highlight.
                    controller.clearLinkedHover(ifSheet: false)
                }
            },
            onSelect: {
                // Tab selection must be instant. Animating this transaction causes the pane
                // content (often swapped via opacity) to crossfade, which is undesirable for
                // terminal/browser surfaces.
#if DEBUG
                dlog("tab.select pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
                withTransaction(Transaction(animation: nil)) {
                    pane.selectTab(tab.id)
                    controller.focusPane(pane.id)
                }
            },
            onClose: {
                guard !tab.isPinned else { return }
                // Close should be instant (no fade-out/removal animation).
#if DEBUG
                dlog("tab.close pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
                withTransaction(Transaction(animation: nil)) {
                    controller.onTabCloseRequest?(TabID(id: tab.id), pane.id)
                    _ = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
                }
            },
            onZoomToggle: {
                _ = splitViewController.togglePaneZoom(pane.id)
            },
            onContextAction: { action in
                controller.requestTabContextAction(action, for: TabID(id: tab.id), inPane: pane.id)
            },
            onSetTabColor: { hex in
                controller.requestSetTabColor(hex: hex, for: TabID(id: tab.id), inPane: pane.id)
            }
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SelectedTabFramePreferenceKey.self,
                    value: pane.selectedTabId == tab.id
                        ? geometry.frame(in: .named("tabBar"))
                        : nil
                )
            }
        )
        .onDrag {
            createItemProvider(for: tab)
        } preview: {
            TabDragPreview(tab: tab, appearance: appearance)
        }
        .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
            ownerId: "tab-\(tab.id.uuidString)",
            dropOwner: $dropOwner,
            targetIndex: index,
            pane: pane,
            bonsplitController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
        .opacity(splitViewController.draggingTab?.id == tab.id ? 0.35 : 1)
    }

    private func contextMenuState(for tab: TabItem, at index: Int) -> TabContextMenuState {
        let leftTabs = pane.tabs.prefix(index)
        let canCloseToLeft = leftTabs.contains(where: { !$0.isPinned })
        let canCloseToRight: Bool
        if (index + 1) < pane.tabs.count {
            canCloseToRight = pane.tabs.suffix(from: index + 1).contains(where: { !$0.isPinned })
        } else {
            canCloseToRight = false
        }
        let canCloseOthers = pane.tabs.enumerated().contains { itemIndex, item in
            itemIndex != index && !item.isPinned
        }
        return TabContextMenuState(
            isPinned: tab.isPinned,
            isUnread: tab.showsNotificationBadge,
            isBrowser: tab.kind == "browser",
            isTerminal: tab.kind == "terminal",
            hasCustomTitle: tab.hasCustomTitle,
            hasCustomColor: tab.customColorHex != nil,
            canCloseToLeft: canCloseToLeft,
            canCloseToRight: canCloseToRight,
            canCloseOthers: canCloseOthers,
            canMoveToLeftPane: controller.adjacentPane(to: pane.id, direction: .left) != nil,
            canMoveToRightPane: controller.adjacentPane(to: pane.id, direction: .right) != nil,
            isZoomed: splitViewController.zoomedPaneId == pane.id,
            hasSplits: splitViewController.rootNode.allPaneIds.count > 1,
            shortcuts: controller.contextMenuShortcuts,
            tabColorPalette: controller.tabColorPalette,
            surfaceRef: controller.surfaceRefProvider.flatMap { $0(TabID(id: tab.id)) }
        )
    }

    // MARK: - Item Provider

    private func createItemProvider(for tab: TabItem) -> NSItemProvider {
#if DEBUG
        dlog("tab.dragStart pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
        // Clear any stale drop indicator from previous incomplete drag
        dropTargetIndex = nil
        dropLifecycle = .idle
        // One drag source for strip tabs, sheet rows and rail rows.
        return TabDragSource.makeItemProvider(for: tab, in: pane.id, controller: splitViewController)
    }

    private func tabControlShortcutDigit(for index: Int, tabCount: Int) -> Int? {
        for digit in 1...9 {
            if tabIndexForControlShortcutDigit(digit, tabCount: tabCount) == index {
                return digit
            }
        }
        return nil
    }

    private func tabIndexForControlShortcutDigit(_ digit: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, digit >= 1, digit <= 9 else { return nil }
        if digit == 9 {
            return tabCount - 1
        }
        let index = digit - 1
        return index < tabCount ? index : nil
    }

    // MARK: - Drop Zone at End

    @ViewBuilder
    private var dropZoneAfterTabs: some View {
        TabBarDragZoneView(
            isMinimalMode: isMinimalMode,
            isFocusedPane: isFocused,
            onSingleClick: focusPaneFromTabBarChrome
        ) {
            guard splitViewController.isInteractive else { return false }
            controller.requestNewTab(kind: "terminal", inPane: pane.id)
            return true
        }
        .frame(width: 30, height: appearance.tabItemHeight)
        .overlay { neutralZoneTint(fadesOut: false) }
        .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
            ownerId: "zone-after-tabs",
            dropOwner: $dropOwner,
            targetIndex: pane.tabs.count,
            pane: pane,
            bonsplitController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
    }

    // MARK: - Drop Indicator (ghost slot)

    /// The tab being dragged, for the ghost slot's label. Read from drag state
    /// on the controller (never the pasteboard). A drag from another window's
    /// controller has none, and the slot renders unlabeled.
    private var ghostTab: TabItem? {
        splitViewController.draggingTab ?? splitViewController.activeDragTab
    }

    /// A tab-sized slot at the landing index: dashed gold border, gold wash,
    /// the dragged tab's mark and title. It carries the same drop delegate as
    /// the tab it displaces, so the cursor resting on it keeps the same target
    /// and the strip never strobes as neighbors shift.
    @ViewBuilder
    private func ghostSlot(at index: Int) -> some View {
        let gold = TabBarColors.activeIndicator(for: appearance)
        HStack(spacing: 6) {
            if let tab = ghostTab {
                if let state = tab.activityState {
                    collapsedActivityMark(for: tab, state: state)
                }
                Text(tab.title)
                    .font(.system(size: appearance.tabTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(gold)
            }
        }
        .padding(.horizontal, 10)
        .frame(
            minWidth: min(appearance.tabMinWidth, 70),
            maxWidth: appearance.tabMaxWidth,
            minHeight: appearance.tabItemHeight - 4,
            maxHeight: appearance.tabItemHeight - 4
        )
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 3).fill(gold.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(gold, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        )
        .padding(.horizontal, 2)
        .frame(height: appearance.tabItemHeight)
        .contentShape(Rectangle())
        .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
            ownerId: "ghost-\(index)",
            dropOwner: $dropOwner,
            targetIndex: index,
            pane: pane,
            bonsplitController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
    }

    /// Gold wash over the neutral (trailing empty) zone while a drop would land
    /// at the end, so a drop anywhere in the zone visibly lands there.
    @ViewBuilder
    private func neutralZoneTint(fadesOut: Bool) -> some View {
        if dropTargetIndex == pane.tabs.count {
            let gold = TabBarColors.activeIndicator(for: appearance)
            ZStack {
                LinearGradient(
                    colors: [gold.opacity(0.14), gold.opacity(fadesOut ? 0.05 : 0.14)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                Rectangle().strokeBorder(gold.opacity(0.35), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Split Buttons

    @ViewBuilder
    private var splitButtons: some View {
        let tooltips = controller.configuration.appearance.splitButtonTooltips
        // Honour `allowCloseLastPane` so hosts can take over the only-pane
        // case (e.g. c11 routes the click through its own confirmation +
        // pane-reset flow). Without this, the button stays disabled when
        // paneCount==1 and the host never gets the request.
        let canClosePane = controller.allPaneIds.count > 1
            || controller.configuration.allowCloseLastPane
        HStack(spacing: 2) {
            // Separator between the tabs and the surface-spawn toolbar. Keeps
            // the rightmost tab's close (×) glyph from crowding into the A
            // button and makes the two regions visually distinct.
            splitButtonsGroupSeparator

            AgentSpawnButtonCluster(
                controller: controller,
                paneId: pane.id,
                appearance: appearance
            )

            SplitToolbarButton(
                systemImage: "terminal",
                tooltip: tooltips.newTerminal,
                appearance: appearance
            ) {
                controller.requestNewTab(kind: "terminal", inPane: pane.id)
            }

            if controller.configuration.showsBrowserSpawnButton {
                SplitToolbarButton(
                    systemImage: "globe",
                    tooltip: tooltips.newBrowser,
                    appearance: appearance
                ) {
                    controller.requestNewTab(kind: "browser", inPane: pane.id)
                }
            }

            if controller.configuration.showsMarkdownSpawnButton {
                SplitToolbarButton(
                    systemImage: "doc.text",
                    tooltip: tooltips.newMarkdown,
                    appearance: appearance
                ) {
                    controller.requestNewTab(kind: "markdown", inPane: pane.id)
                }
            }

            splitButtonsGroupSeparator

            SplitToolbarButton(
                systemImage: "square.split.2x1",
                tooltip: tooltips.splitRight,
                appearance: appearance
            ) {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .horizontal)
            }

            SplitToolbarButton(
                systemImage: "square.split.1x2",
                tooltip: tooltips.splitDown,
                appearance: appearance
            ) {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .vertical)
            }

            SplitToolbarButton(
                systemImage: "plus",
                tooltip: tooltips.newTab,
                appearance: appearance
            ) {
                controller.requestNewTab(kind: "newTab", inPane: pane.id)
            }

            SplitToolbarButton(
                systemImage: "xmark",
                tooltip: tooltips.closePane,
                appearance: appearance,
                isEnabled: canClosePane
            ) {
                controller.requestClosePane(pane.id)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var splitButtonsGroupSeparator: some View {
        Rectangle()
            .fill(TabBarColors.separator(for: appearance))
            .frame(width: 1, height: appearance.splitToolbarSeparatorHeight)
            .padding(.horizontal, 8)
    }

    private static func buttonBackdropColor(
        for appearance: BonsplitConfiguration.Appearance,
        focused: Bool,
        style: Int
    ) -> NSColor {
        switch style {
        case 1: // raw paneBackground forced opaque
            return TabBarColors.nsColorPaneBackground(for: appearance).withAlphaComponent(1.0)
        case 2: // barBackground (tab bar chrome)
            let c = NSColor(TabBarColors.barBackground(for: appearance))
            return (c.usingColorSpace(.sRGB) ?? c).withAlphaComponent(1.0)
        case 3: // windowBackgroundColor
            return NSColor.windowBackgroundColor.withAlphaComponent(1.0)
        case 4: // controlBackgroundColor
            return NSColor.controlBackgroundColor.withAlphaComponent(1.0)
        case 5: // pre-composited barBackground over windowBg
            let chrome = NSColor(TabBarColors.barBackground(for: appearance))
            let winBg = NSColor.windowBackgroundColor
            guard let fg = chrome.usingColorSpace(.sRGB),
                  let bk = winBg.usingColorSpace(.sRGB) else {
                return chrome.withAlphaComponent(1.0)
            }
            let a: CGFloat = focused ? fg.alphaComponent : fg.alphaComponent * 0.95
            let oneMinusA = 1.0 - a
            let r = fg.redComponent * a + bk.redComponent * oneMinusA
            let g = fg.greenComponent * a + bk.greenComponent * oneMinusA
            let b = fg.blueComponent * a + bk.blueComponent * oneMinusA
            return NSColor(red: r, green: g, blue: b, alpha: 1.0)
        default: // 0: pre-composited paneBackground over windowBg
            return precompositedPaneBackground(for: appearance, focused: focused)
        }
    }

    /// Pre-composite the pane background over the window background to produce
    /// a flat opaque color that matches what .background(barFill) looks like
    /// after compositing. Avoids double-compositing mismatch on overlays.
    private static func precompositedPaneBackground(
        for appearance: BonsplitConfiguration.Appearance,
        focused: Bool
    ) -> NSColor {
        let chrome = TabBarColors.nsColorPaneBackground(for: appearance)
        let winBg = NSColor.windowBackgroundColor
        guard let fg = chrome.usingColorSpace(.sRGB),
              let bk = winBg.usingColorSpace(.sRGB) else {
            return chrome.withAlphaComponent(1.0)
        }
        let a: CGFloat = focused ? fg.alphaComponent : fg.alphaComponent * 0.95
        let oneMinusA = 1.0 - a
        let r = fg.redComponent * a + bk.redComponent * oneMinusA
        let g = fg.greenComponent * a + bk.greenComponent * oneMinusA
        let b = fg.blueComponent * a + bk.blueComponent * oneMinusA
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Combined Mask (scroll fades + button area)
    //
    // IMPORTANT: SwiftUI's `.mask()` with `Color.clear` regions blocks hit testing on the
    // masked content in those regions. Previously this mask used a 90pt clear region at the
    // trailing edge to hide tabs under the split buttons; that caused clicks on tabs in that
    // 90pt area to fall through the masked ScrollView to the `TabBarDragAndHoverView`
    // background, which (in minimal mode) interpreted the click as a window drag instead
    // of a tab tap. Keep the entire mask opaque so hit testing works on every tab; the split
    // buttons' opaque backdrop (rendered in the splitButtons overlay) handles the visual
    // obscuring of tabs underneath.

    @ViewBuilder
    private var combinedMask: some View {
        let fadeWidth: CGFloat = 24
        HStack(spacing: 0) {
            // Left scroll fade
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollLeft ? fadeWidth : 0)

            // Visible content area (always opaque so hit testing reaches the tabs)
            Rectangle().fill(Color.black)

            // Right scroll fade only when scroll content actually overflows.
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollRight ? fadeWidth : 0)
        }
    }

    // MARK: - Fade Overlays

    /// Mask that fades scroll content at the edges instead of overlaying
    /// a colored gradient. The mask uses black (visible) → clear (hidden),
    /// so the tab bar background shows through naturally with no compositing.
    @ViewBuilder
    private var fadeOverlays: some View {
        let fadeWidth: CGFloat = 24
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollLeft ? fadeWidth : 0)

            Rectangle().fill(Color.black)

            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollRight ? fadeWidth : 0)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var tabBarBackground: some View {
        let barFill = isFocused
            ? TabBarColors.barBackground(for: appearance)
            : TabBarColors.barBackground(for: appearance).opacity(0.95)

        Rectangle()
            .fill(barFill)
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    let separator = TabBarColors.separator(for: appearance)
                    let gapRange: ClosedRange<CGFloat>? = selectedTabFrameInBar.map { frame in
                        frame.minX...frame.maxX
                    }
                    let segments = TabBarStyling.separatorSegments(
                        totalWidth: geometry.size.width,
                        gap: gapRange
                    )

                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(separator)
                            .frame(width: segments.left, height: 1)
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(separator)
                            .frame(width: segments.right, height: 1)
                    }
                }
                .frame(height: 1)
            }
    }
}

extension TabBarView where TrailingAccessory == EmptyView {
    init(
        pane: PaneState,
        isFocused: Bool,
        showSplitButtons: Bool = true
    ) {
        self.init(
            pane: pane,
            isFocused: isFocused,
            showSplitButtons: showSplitButtons,
            trailingAccessory: { _, _ in EmptyView() }
        )
    }
}

/// The agent spawn control — the split-button idiom that keeps the one-click
/// launch and makes the launch picker discoverable: the "A" zone launches the
/// default on click (press-and-hold or right/ctrl-click opens the picker), and
/// the narrow caret zone opens the picker on any click. All pointer paths run
/// through RightClickCatchView so they fire deterministically on the real
/// event; the SplitToolbarButton underneath is visual-only.
struct AgentSpawnButtonCluster: View {
    let controller: BonsplitController
    let paneId: PaneID
    let appearance: BonsplitConfiguration.Appearance
    var afterAction: () -> Void = {}

    @State private var caretHovered = false

    var body: some View {
        let tooltips = appearance.splitButtonTooltips
        HStack(spacing: 0) {
            SplitToolbarButton(systemImage: "", labelText: "A", tooltip: tooltips.newAgent, appearance: appearance) {
                // Visual-only: the catch overlay owns every pointer path.
            }
            .overlay(
                RightClickCatchView(
                    onContextClick: { rect in openPicker(rect) },
                    onPrimaryClick: { _ in
                        controller.requestNewTab(kind: "agent", inPane: paneId)
                        afterAction()
                    }
                )
            )

            Text("\u{25BE}")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TabBarColors.splitActionIcon(for: appearance, isPressed: false))
                .frame(width: 13, height: appearance.splitToolbarButtonFrameSize)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(caretHovered ? 0.09 : 0))
                )
                .contentShape(Rectangle())
                .onHover { caretHovered = $0 }
                .help(tooltips.chooseAgent)
                .overlay(
                    RightClickCatchView(
                        onContextClick: { rect in openPicker(rect) },
                        onPrimaryClick: { rect in openPicker(rect) }
                    )
                )
        }
    }

    private func openPicker(_ buttonScreenRect: CGRect) {
        controller.rightClickNewTabButton(kind: "agent", inPane: paneId, buttonScreenRect: buttonScreenRect)
        afterAction()
    }
}

private struct SplitActionButtonStyle: ButtonStyle {
    let appearance: BonsplitConfiguration.Appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(TabBarColors.splitActionIcon(for: appearance, isPressed: configuration.isPressed))
    }
}

/// Tab-bar action button with a hover highlight. Wraps the Button + style so
/// each button owns its own @State for hover tracking without leaking it into
/// TabBarView's body (where it would cause spurious invalidations during
/// typing).
struct SplitToolbarButton: View {
    let systemImage: String
    let labelText: String?
    let tooltip: String
    let appearance: BonsplitConfiguration.Appearance
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    init(
        systemImage: String,
        labelText: String? = nil,
        tooltip: String,
        appearance: BonsplitConfiguration.Appearance,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.labelText = labelText
        self.tooltip = tooltip
        self.appearance = appearance
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        // Dimming of the disabled state happens via the ButtonStyle's
        // foreground color. No view-level `.opacity()` / `.disabled()` /
        // `_ConditionalContent` in this body — any of those keep a SwiftUI
        // compositing layer around the button that rendered at the wrong
        // bounds on some displays and painted a phantom outline into the
        // tab bar area.
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            Group {
                if let labelText {
                    Text(labelText)
                        .font(.system(size: appearance.splitToolbarButtonIconSize, weight: .semibold))
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: appearance.splitToolbarButtonIconSize))
                }
            }
            .frame(width: appearance.splitToolbarButtonFrameSize,
                   height: appearance.splitToolbarButtonFrameSize)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.09 : 0))
            )
        }
        .buttonStyle(SplitActionButtonStyle(appearance: appearance))
        // Native `.help` attaches the tooltip to the button itself so macOS
        // actually shows it. (`safeHelp` registers the tooltip on an occluded
        // background view whose `hitTest` returns nil, so the system never
        // queries it — the tooltips silently never appeared.) Works in both the
        // normal/medium bar and the dropdown controls row.
        .help(tooltip)
        .onHover { isHovered = $0 }
    }
}

/// Background view that provides window-drag-from-empty-space in minimal mode
/// and hover tracking via NSTrackingArea (replacing .contentShape + .onHover).
/// As a .background(), AppKit routes clicks to tabs/buttons in front first;
/// this view only receives hits in truly empty space.
private struct TabBarDragAndHoverView: NSViewRepresentable {
    let isMinimalMode: Bool
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> TabBarBackgroundNSView {
        let view = TabBarBackgroundNSView()
        view.isMinimalMode = isMinimalMode
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: TabBarBackgroundNSView, context: Context) {
        nsView.isMinimalMode = isMinimalMode
        nsView.onHoverChanged = onHoverChanged
    }

    final class TabBarBackgroundNSView: NSView {
        var isMinimalMode = false
        var onHoverChanged: ((Bool) -> Void)?
        private var hoverTrackingArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }

        deinit {
            BonsplitTabBarHitRegionRegistry.unregister(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            BonsplitTabBarHitRegionRegistry.unregister(self)
            if window != nil {
                BonsplitTabBarHitRegionRegistry.register(self)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil {
                BonsplitTabBarHitRegionRegistry.unregister(self)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = hoverTrackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseDown(with event: NSEvent) {
#if DEBUG
            dlog("tab.bar.bg.mouseDown isMinimal=\(isMinimalMode ? 1 : 0) clickCount=\(event.clickCount)")
#endif
            guard isMinimalMode, let window else {
                super.mouseDown(with: event)
                return
            }
            if event.clickCount >= 2 {
                let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
                switch action {
                case "Minimize": window.miniaturize(nil)
                default: window.zoom(nil)
                }
                return
            }
            let wasMovable = window.isMovable
            window.isMovable = true
            window.performDrag(with: event)
            window.isMovable = wasMovable
        }
    }
}

struct TabBarDragZoneView: NSViewRepresentable {
    let isMinimalMode: Bool
    let isFocusedPane: Bool
    let onSingleClick: () -> Bool
    let onDoubleClick: () -> Bool

    func makeNSView(context: Context) -> DragNSView {
        let view = DragNSView()
        view.isMinimalMode = isMinimalMode
        view.isFocusedPane = isFocusedPane
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {
        nsView.isMinimalMode = isMinimalMode
        nsView.isFocusedPane = isFocusedPane
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
    }

    final class DragNSView: NSView {
        var isMinimalMode = false
        var isFocusedPane = false
        var onSingleClick: (() -> Bool)?
        var onDoubleClick: (() -> Bool)?
        var performWindowDrag: ((NSEvent) -> Bool)?

        override var mouseDownCanMoveWindow: Bool {
            isMinimalMode && isFocusedPane
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            return bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
#if DEBUG
            dlog(
                "tab.bar.dragZone.mouseDown isMinimal=\(isMinimalMode ? 1 : 0) " +
                "focused=\(isFocusedPane ? 1 : 0) clickCount=\(event.clickCount)"
            )
#endif
            guard let window = self.window else {
                super.mouseDown(with: event)
                return
            }

            if event.clickCount >= 2 {
                if isMinimalMode {
                    let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
                    switch action {
                    case "Minimize": window.miniaturize(nil)
                    default: window.zoom(nil)
                    }
                    return
                } else {
                    if onDoubleClick?() == true {
                        return
                    }
                }
            }

            if isMinimalMode, !isFocusedPane, onSingleClick?() == true {
#if DEBUG
                dlog("tab.bar.dragZone.focusPane")
#endif
                return
            }

            if isMinimalMode {
                if let performWindowDrag, performWindowDrag(event) {
                    return
                }
                let wasMovable = window.isMovable
                window.isMovable = true
                window.performDrag(with: event)
                window.isMovable = wasMovable
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

private struct TabBarScrollViewResolver: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveScrollView()
    }

    final class ResolverView: NSView {
        var onResolve: ((NSScrollView?) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveScrollView()
        }

        override func layout() {
            super.layout()
            resolveScrollView()
        }

        func resolveScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onResolve?(self.enclosingScrollView)
            }
        }
    }
}

private struct TabControlShortcutStoredShortcut: Decodable {
    let key: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var modifierSymbol: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }
}

private enum TabControlShortcutSettings {
    static let surfaceByNumberKey = "shortcut.selectSurfaceByNumber"
    static let defaultShortcut = TabControlShortcutStoredShortcut(
        key: "1",
        command: false,
        shift: false,
        option: false,
        control: true
    )

    static func surfaceByNumberShortcut(defaults: UserDefaults = .standard) -> TabControlShortcutStoredShortcut {
        guard let data = defaults.data(forKey: surfaceByNumberKey),
              let shortcut = try? JSONDecoder().decode(TabControlShortcutStoredShortcut.self, from: data) else {
            return defaultShortcut
        }
        return shortcut
    }
}

struct TabControlShortcutModifier: Equatable {
    let modifierFlags: NSEvent.ModifierFlags
    let symbol: String
}

enum TabControlShortcutHintPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30
    static let showHintsOnCommandHoldKey = "shortcutHintShowOnCommandHold"
    static let defaultShowHintsOnCommandHold = true

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnCommandHoldKey) != nil else {
            return defaultShowHintsOnCommandHold
        }
        return defaults.bool(forKey: showHintsOnCommandHoldKey)
    }

    static func hintModifier(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> TabControlShortcutModifier? {
        guard showHintsOnCommandHoldEnabled(defaults: defaults) else { return nil }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let shortcut = TabControlShortcutSettings.surfaceByNumberShortcut(defaults: defaults)
        if flags != shortcut.modifierFlags {
            // Command-only hold reveals all hints (including pane hints), while
            // control (or other modifiers) remains strict to the pane shortcut.
            guard flags == [.command] else { return nil }
        }
        return TabControlShortcutModifier(
            modifierFlags: shortcut.modifierFlags,
            symbol: shortcut.modifierSymbol
        )
    }

    static func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        hintModifier(for: modifierFlags, defaults: defaults) != nil &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}

private struct TabBarHostWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            onResolve(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onResolve(nsView?.window)
        }
    }
}

@MainActor
private final class TabControlShortcutKeyMonitor: ObservableObject {
    @Published private(set) var isShortcutHintVisible = false
    @Published private(set) var shortcutModifierSymbol = "⌃"

    private weak var hostWindow: NSWindow?
    private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingModifier: TabControlShortcutModifier?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        hostWindowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(from: NSEvent.modifierFlags, eventWindow: nil)
            }
        }

        hostWindowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags, eventWindow: nil)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags, eventWindow: event.window)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.isCurrentWindow(eventWindow: event.window) == true else { return event }
            self?.cancelPendingHintShow(resetVisible: true)
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        TabControlShortcutHintPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard TabControlShortcutHintPolicy.shouldShowHints(
            for: modifierFlags,
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        guard let modifier = TabControlShortcutHintPolicy.hintModifier(for: modifierFlags) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        if isShortcutHintVisible {
            shortcutModifierSymbol = modifier.symbol
            return
        }

        queueHintShow(for: modifier)
    }

    private func queueHintShow(for modifier: TabControlShortcutModifier) {
        if pendingModifier == modifier, pendingShowWorkItem != nil {
            return
        }

        pendingShowWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            self.pendingModifier = nil
            guard TabControlShortcutHintPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else { return }
            guard let currentModifier = TabControlShortcutHintPolicy.hintModifier(for: NSEvent.modifierFlags) else { return }
            self.shortcutModifierSymbol = currentModifier.symbol
            withAnimation(.easeInOut(duration: 0.14)) {
                self.isShortcutHintVisible = true
            }
        }

        pendingModifier = modifier
        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + TabControlShortcutHintPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        pendingModifier = nil
        if resetVisible {
            withAnimation(.easeInOut(duration: 0.14)) {
                isShortcutHintVisible = false
            }
        }
    }

    private func removeHostWindowObservers() {
        if let hostWindowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidBecomeKeyObserver)
            self.hostWindowDidBecomeKeyObserver = nil
        }
        if let hostWindowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidResignKeyObserver)
            self.hostWindowDidResignKeyObserver = nil
        }
    }
}


/// Drop lifecycle state to prevent dropUpdated from re-setting state after performDrop
enum TabDropLifecycle {
    case idle
    case hovering
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    /// Identity of the view this delegate is attached to (see `dropOwner`).
    var ownerId: String = ""
    var dropOwner: Binding<String?>? = nil
    let targetIndex: Int
    let pane: PaneState
    let bonsplitController: BonsplitController
    let controller: SplitViewController
    @Binding var dropTargetIndex: Int?
    @Binding var dropLifecycle: TabDropLifecycle

    func performDrop(info: DropInfo) -> Bool {
        #if DEBUG
        NSLog("[Bonsplit Drag] performDrop called, targetIndex: \(targetIndex)")
        #endif
#if DEBUG
        dlog("tab.drop pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex)")
#endif

        // Ensure all drag/drop side-effects run on the main actor. SwiftUI can call these
        // callbacks off-main, and SplitViewController is @MainActor.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                performDrop(info: info)
            }
        }

        // Read from non-observable drag state — @Observable writes from createItemProvider
        // may not have propagated yet when performDrop runs.
        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            guard let transfer = decodeTransfer(from: info),
                  transfer.isFromCurrentProcess else {
                return false
            }
            let request = BonsplitController.ExternalTabDropRequest(
                tabId: TabID(id: transfer.tab.id),
                sourcePaneId: PaneID(id: transfer.sourcePaneId),
                destination: .insert(targetPane: pane.id, targetIndex: targetIndex)
            )
            let handled = bonsplitController.onExternalTabDrop?(request) ?? false
            if handled {
                dropLifecycle = .idle
                dropTargetIndex = nil
            }
            return handled
        }

        // Execute synchronously when possible so the dragged tab disappears immediately.
        let applyMove = {
            // Ensure the move itself doesn't animate.
            withTransaction(Transaction(animation: nil)) {
                if sourcePaneId == pane.id {
                    guard let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id }) else { return }
                    // Same-pane no-op: don't mutate the model (and don't show an indicator).
                    if targetIndex == sourceIndex || targetIndex == sourceIndex + 1 {
                        return
                    }
                    pane.moveTab(from: sourceIndex, to: targetIndex)
                } else {
                    _ = bonsplitController.moveTab(
                        TabID(id: draggedTab.id),
                        toPane: pane.id,
                        atIndex: targetIndex
                    )
                }
            }
        }

        applyMove()

        // Clear visual state immediately to prevent lingering indicators.
        // Must happen synchronously before returning, not in async callback.
        // Setting dropLifecycle to idle prevents dropUpdated from re-setting dropTargetIndex.
        dropLifecycle = .idle
        dropTargetIndex = nil
        dropOwner?.wrappedValue = nil
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil

        return true
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        NSLog("[Bonsplit Drag] dropEntered at index: \(targetIndex)")
        dlog(
            "tab.dropEntered pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) owner=\(ownerId.suffix(8)) " +
            "hasDrag=\(controller.draggingTab != nil ? 1 : 0) " +
            "hasActive=\(controller.activeDragTab != nil ? 1 : 0)"
        )
        #endif
        dropLifecycle = .hovering
        dropOwner?.wrappedValue = ownerId
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            dropTargetIndex = nil
        } else {
            dropTargetIndex = targetIndex
        }
    }

    func dropExited(info: DropInfo) {
        #if DEBUG
        NSLog("[Bonsplit Drag] dropExited from index: \(targetIndex)")
        dlog(
            "tab.dropExited pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) " +
            "owner=\(ownerId.suffix(8)) current=\((dropOwner?.wrappedValue ?? "-").suffix(8))"
        )
        #endif
        // The ghost slot is inserted in front of the tab under a resting
        // cursor, so `dropEntered(ghost)` can precede `dropExited(tab)`. Only the
        // view that still owns the hover may clear it.
        if let current = dropOwner?.wrappedValue, current != ownerId {
            return
        }
        dropOwner?.wrappedValue = nil
        dropLifecycle = .idle
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Guard against dropUpdated firing after performDrop/dropExited
        // This is the key fix for the lingering indicator bug
        guard dropLifecycle == .hovering else {
#if DEBUG
            dlog("tab.dropUpdated.skip pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) reason=lifecycle_idle")
#endif
            return DropProposal(operation: .move)
        }
        if dropOwner?.wrappedValue != ownerId { dropOwner?.wrappedValue = ownerId }
        // Only update if this is the active target, and suppress same-pane no-op indicators.
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            if dropTargetIndex == targetIndex {
                dropTargetIndex = nil
            }
        } else if dropTargetIndex != targetIndex {
            dropTargetIndex = targetIndex
        }
#if DEBUG
        dlog(
            "tab.dropUpdated pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) " +
            "dropTarget=\(dropTargetIndex.map(String.init) ?? "nil")"
        )
#endif
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Reject drops on inactive workspaces whose views are kept alive in a ZStack.
        guard controller.isInteractive else {
#if DEBUG
            dlog("tab.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) allowed=0 reason=inactive")
#endif
            return false
        }
        // The custom UTType alone is sufficient — only Bonsplit tab drags produce it.
        // Do NOT gate on draggingTab != nil: @Observable changes from createItemProvider
        // may not have propagated to the drop delegate yet, causing false rejections.
        let hasType = info.hasItemsConforming(to: [.tabTransfer])
        guard hasType else { return false }

        // Local drags use in-memory state and are always same-process.
        if controller.activeDragTab != nil || controller.draggingTab != nil {
            return true
        }

        // External drags (another Bonsplit controller) must include a payload from this process.
        guard let transfer = decodeTransfer(from: info),
              transfer.isFromCurrentProcess else {
            return false
        }
#if DEBUG
        let hasDrag = controller.draggingTab != nil
        let hasActive = controller.activeDragTab != nil
        dlog(
            "tab.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) " +
            "allowed=\(hasType ? 1 : 0) hasDrag=\(hasDrag ? 1 : 0) hasActive=\(hasActive ? 1 : 0)"
        )
#endif
        return true
    }

    private func shouldSuppressIndicatorForNoopSamePaneDrop() -> Bool {
        guard let draggedTab = controller.draggingTab,
              controller.dragSourcePaneId == pane.id,
              let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id }) else {
            return false
        }
        // Insertion indices are expressed in "original array" coordinates; after removal,
        // inserting at `sourceIndex` or `sourceIndex + 1` results in no change.
        return targetIndex == sourceIndex || targetIndex == sourceIndex + 1
    }

    private func decodeTransfer(from string: String) -> TabTransferData? {
        guard let data = string.data(using: .utf8),
              let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) else {
            return nil
        }
        return transfer
    }

    private func decodeTransfer(from info: DropInfo) -> TabTransferData? {
        TabTransferDecoder.fromDragPasteboard()
    }
}
