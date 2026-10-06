import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Rail geometry: about 38% of the area, clamped to 200-300pt; in a small area
/// (under 420pt) no more than 45% of it, so the rail never crushes the content.
enum TabRailMetrics {
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 22
    /// Under this width the rail's controls wrap onto two rows.
    static let compactControlsWidth: CGFloat = 260
    /// Under this width even two rows clip, so the rail keeps the agent spawn
    /// button and folds the rest into a menu.
    static let menuControlsWidth: CGFloat = 140

    /// About 38% of the area, 200-300pt, and never more than 45% of the area,
    /// at every width (the cap only bites in small areas).
    static func width(forAreaWidth area: CGFloat) -> CGFloat {
        let base = min(300, max(200, (area * 0.38).rounded()))
        return min(base, (area * 0.45).rounded())
    }
}

/// Places the rail (when present) on the left and the content in the rest, in a
/// single layout pass, so a rail that is open from the start never lays the
/// content out at one width and then another.
struct RailSplitLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 200, height: proposal.height ?? 200)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.last else { return }
        if subviews.count >= 2, let rail = subviews.first {
            let railWidth = TabRailMetrics.width(forAreaWidth: bounds.width)
            rail.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: railWidth, height: bounds.height)
            )
            content.place(
                at: CGPoint(x: bounds.minX + railWidth, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: max(0, bounds.width - railWidth), height: bounds.height)
            )
        } else {
            content.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// Vertical auto-scroll for the rail while a tab is dragged near its top or
/// bottom edge. Needs `ScrollPosition` (macOS 15+); on macOS 14 there is no
/// driver, so nothing is written and the rail simply does not auto-scroll.
@MainActor
final class TabRailScrollBridge: ObservableObject {
    weak var viewport: NSView?
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var scrollToY: ((CGFloat) -> Void)?
    nonisolated(unsafe) private var timer: Timer?

    deinit { timer?.invalidate() }

    func begin() {
        guard timer == nil, scrollToY != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func end() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { end(); return }
        guard let viewport, let window = viewport.window, let scrollToY else { return }
        let height = viewport.bounds.height
        guard contentHeight > height + 1 else { return }
        let point = viewport.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard point.x >= viewport.bounds.minX, point.x <= viewport.bounds.maxX else { return }
        let zone: CGFloat = 32
        // Flipped hosting views put y = 0 at the top; AppKit's default puts it at the bottom.
        let fromTop = viewport.isFlipped ? point.y : height - point.y
        var step: CGFloat = 0
        if fromTop >= -4, fromTop < zone {
            step = -12 * (1 - max(0, fromTop) / zone)
        } else if fromTop > height - zone, fromTop <= height + 4 {
            step = 12 * min(1, (fromTop - (height - zone)) / zone)
        }
        guard abs(step) > 0.1 else { return }
        let next = min(max(0, offset + step), contentHeight - height)
        guard abs(next - offset) > 0.01 else { return }
        offset = next
        scrollToY(next)
    }
}

private struct RailScrollPositionModifier: ViewModifier {
    let bridge: TabRailScrollBridge

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(Driver(bridge: bridge))
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private struct Driver: ViewModifier {
        let bridge: TabRailScrollBridge
        @State private var position = ScrollPosition()

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onAppear {
                    bridge.scrollToY = { y in
                        withTransaction(Transaction(animation: nil)) { position.scrollTo(y: y) }
                    }
                }
        }
    }
}

private struct RailContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The vertical tab list docked on an area's left edge (Rail layout). The same
/// tabs as the strip, turned sideways: mark, title, status with its duration
/// on line two, `Tab N` at the right, and the gold rule on the visible tab.
/// Rows scroll vertically and drag like strip tabs: reorder here, or drag out to
/// another area's strip or rail (also across workspaces and windows).
struct TabRailView: View {
    let pane: PaneState
    let controller: BonsplitController
    let splitViewController: SplitViewController
    let appearance: BonsplitConfiguration.Appearance
    /// The bar had no room for the controls, so the rail carries them on top.
    var includesControls = false
    let activityAnimationEnabled: Bool
    let explicitActivityAnimationEnabled: Bool

    @State private var dropIndex: Int?
    @State private var dropOwner: Int?
    @State private var hoveredTabId: UUID?
    @StateObject private var scrollBridge = TabRailScrollBridge()

    private var palette: TabBarColors.SheetPalette { TabBarColors.sheetPalette(for: appearance) }

    /// One ticker for the whole rail while its workspace is live; about every
    /// five seconds the host is asked for fresh detail so durations and states
    /// keep advancing. A hidden workspace's rail stops ticking and asking.
    var body: some View {
        let live = splitViewController.isInteractive
        TimelineView(.periodic(from: .now, by: live ? 1 : 3600)) { context in
            GeometryReader { geo in
                rail(now: context.date, width: geo.size.width)
            }
            .onChange(of: Int(context.date.timeIntervalSinceReferenceDate / 5)) { _, _ in
                guard live else { return }
                controller.refreshTabDetails(inPane: pane.id)
            }
        }
        .onAppear { controller.refreshTabDetails(inPane: pane.id) }
        // A workspace coming back to life catches up at once, not at the next tick.
        .onChange(of: live) { _, isLive in
            if isLive { controller.refreshTabDetails(inPane: pane.id) }
        }
        .onChange(of: splitViewController.draggingTab != nil) { _, dragging in
            if dragging { scrollBridge.begin() } else { scrollBridge.end() }
        }
        .onDisappear { scrollBridge.end() }
    }

    private func rail(now: Date, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if includesControls {
                let style: TabControlsRow.Style = width < TabRailMetrics.menuControlsWidth
                    ? .menu
                    : (width < TabRailMetrics.compactControlsWidth ? .twoLines : .oneLine)
                TabControlsRow(
                    pane: pane,
                    controller: controller,
                    appearance: appearance,
                    height: style == .twoLines ? 56 : 30,
                    style: style
                )
                Rectangle().fill(palette.separator).frame(height: 1)
            }
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        row(tab, at: index, now: now)
                    }
                    endDropZone
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: RailContentFrameKey.self, value: proxy.frame(in: .named("railScroll")))
                    }
                )
            }
            .coordinateSpace(name: "railScroll")
            .onPreferenceChange(RailContentFrameKey.self) { frame in
                scrollBridge.offset = -frame.minY
                scrollBridge.contentHeight = frame.height
            }
            .modifier(RailScrollPositionModifier(bridge: scrollBridge))
            .background(CollapsedSheetAnchorReader { scrollBridge.viewport = $0 })
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.border).frame(width: 1).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TabSheetFormat.localized("tabBar.rail.accessibilityLabel", "Panel rail"))
    }

    /// The tab count, and the Tabs | Rail switch at the right. When both do not
    /// fit, the count goes (never cut to "…"); the switch goes only when the
    /// rail is narrower than the switch itself.
    private var header: some View {
        HStack(spacing: 0) {
            if let layoutSwitch = controller.tabLayoutSwitch {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        headerCount.fixedSize()
                        Spacer(minLength: 0)
                        layoutSwitchView(layoutSwitch)
                    }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        layoutSwitchView(layoutSwitch)
                    }
                    HStack(spacing: 0) {
                        headerCount
                        Spacer(minLength: 0)
                    }
                }
            } else {
                headerCount
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TabRailMetrics.headerHeight)
        .background(palette.header)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1) }
    }

    private var headerCount: some View {
        Text(TabSheetFormat.tabsFooter(count: pane.tabs.count).uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(palette.faintText)
            .lineLimit(1)
    }

    private func layoutSwitchView(_ layoutSwitch: BonsplitController.TabLayoutSwitch) -> some View {
        TabLayoutSwitchView(
            paneId: pane.id,
            controller: controller,
            config: layoutSwitch,
            current: appearance.tabLayout,
            palette: palette
        )
    }

    private func row(_ tab: TabItem, at index: Int, now: Date) -> some View {
        let isSelected = pane.selectedTabId == tab.id
        let isHovered = hoveredTabId == tab.id
        let gold = TabBarColors.activeIndicator(for: appearance)
        let title = tab.detail?.title.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: appearance.tabTitleFontSize + 0.5, weight: isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected || isHovered ? palette.text : palette.dimText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    TabBadgeView(
                        glyph: tab.badgeGlyph,
                        colorHex: tab.customColorHex,
                        size: appearance.tabIconSize - 1,
                        foreground: isSelected || isHovered ? palette.text : palette.dimText
                    )
                    .layoutPriority(1)
                }
                statusLine(tab, now: now)
                    .frame(height: 14, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The number on top, the lifecycle mark under it, as in the sheet.
            VStack(alignment: .trailing, spacing: 1) {
                Group {
                    if let ordinal = tab.displayOrdinal {
                        Text(TabSheetFormat.tabLabel(ordinal))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isSelected ? gold : palette.faintText)
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 14)
                TabLifecycleMarkSlot(
                    tab: tab,
                    appearance: appearance,
                    activityAnimationEnabled: activityAnimationEnabled,
                    explicitActivityAnimationEnabled: explicitActivityAnimationEnabled
                )
            }

            // Every row keeps its close, always laid out so nothing shifts.
            Group {
                if !tab.isPinned {
                    CollapsedTabCloseButton(
                        tab: tab,
                        pane: pane,
                        controller: controller,
                        appearance: appearance,
                        hitSize: CGSize(width: 18, height: TabRailMetrics.rowHeight)
                    )
                    .opacity(isHovered || isSelected ? 1 : 0.6)
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)
        }
        .padding(.leading, 7 + TabSheetMetrics.leadingRule)
        .padding(.trailing, 4)
        .frame(height: TabRailMetrics.rowHeight)
        .background(isSelected ? palette.rowActive : (isHovered ? palette.rowHover : Color.clear))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1).allowsHitTesting(false) }
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(gold).frame(width: TabSheetMetrics.leadingRule).allowsHitTesting(false) }
        }
        .overlay(alignment: .top) { if dropIndex == index { insertionRule } }
        .opacity(splitViewController.draggingTab?.id == tab.id ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { select(tab) }
        .onDrag {
            TabDragSource.makeItemProvider(for: tab, in: pane.id, controller: splitViewController)
        } preview: {
            TabDragPreview(tab: tab, appearance: appearance)
        }
        .onDrop(of: [.tabTransfer], delegate: TabRailRowDropDelegate(
            rowIndex: index,
            rowHeight: TabRailMetrics.rowHeight,
            pane: pane,
            controller: splitViewController,
            bonsplitController: controller,
            dropIndex: $dropIndex,
            dropOwner: $dropOwner,
            onDragActive: { scrollBridge.begin() }
        ))
        .onHover { inside in
            if inside {
                hoveredTabId = tab.id
            } else if hoveredTabId == tab.id {
                hoveredTabId = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(TabSheetFormat.localized("tabBar.collapsedList.selectAction", "Select"))) { select(tab) }
        // `.combine` folds the close button into the row, so expose it explicitly.
        .accessibilityAction(named: Text(TabSheetFormat.localized("command.closeTab.title", "Close Tab"))) {
            guard !tab.isPinned else { return }
            CollapsedTabCloseButton.close(tab: tab, pane: pane, controller: controller)
        }
    }

    @ViewBuilder
    private func statusLine(_ tab: TabItem, now: Date) -> some View {
        if let status = tab.detail?.status {
            HStack(spacing: 4) {
                Text(TabSheetFormat.statusWord(status.kind))
                    .lineLimit(1)
                if let since = status.since {
                    TabSheetAgeText(since: since, now: now, font: .system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(statusColor(status.kind, tab: tab))
        } else if let subtitle = tab.detail?.subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(palette.faintText)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("—").font(.system(size: 11)).foregroundStyle(palette.dash)
        }
    }

    private func statusColor(_ kind: BonsplitTabDetail.StatusKind, tab: TabItem) -> Color {
        switch kind {
        case .working: return TabBarColors.activity(.running, for: appearance)
        case .waiting: return TabBarColors.activity(.waiting, for: appearance)
        case .flagged:
            let mark = tab.activityPresentation?.colorOverrideHex.flatMap(NSColor.init(bonsplitHex:))
                ?? NSColor(bonsplitHex: "#9D8AD9")!
            return TabBarColors.readableInk(mark, for: appearance)
        case .idle, .cold: return palette.faintText
        }
    }

    private var insertionRule: some View {
        Rectangle()
            .fill(TabBarColors.activeIndicator(for: appearance))
            .frame(height: 3)
            .allowsHitTesting(false)
    }

    /// The empty stretch under the last row: dropping here appends.
    private var endDropZone: some View {
        Color.clear
            .frame(height: 36)
            .overlay(alignment: .top) { if dropIndex == pane.tabs.count { insertionRule } }
            .contentShape(Rectangle())
            .onDrop(of: [.tabTransfer], delegate: TabRailRowDropDelegate(
                rowIndex: pane.tabs.count,
                rowHeight: 36,
                pane: pane,
                controller: splitViewController,
                bonsplitController: controller,
                dropIndex: $dropIndex,
                dropOwner: $dropOwner,
                isEndZone: true,
                onDragActive: { scrollBridge.begin() }
            ))
    }

    private func select(_ tab: TabItem) {
        withTransaction(Transaction(animation: nil)) {
            pane.selectTab(tab.id)
            controller.focusPane(pane.id)
        }
    }
}

// MARK: - Drag source

/// The drag payload shared by every tab drag source (strip tab, sheet row, rail
/// row): records the drag in the split controller and installs the one-shot
/// mouse-up backstop that clears stale drag state when a drag is dropped
/// nowhere.
enum TabDragSource {
    @MainActor
    static func makeItemProvider(for tab: TabItem, in paneId: PaneID, controller: SplitViewController) -> NSItemProvider {
        controller.dragGeneration += 1
        controller.draggingTab = tab
        controller.dragSourcePaneId = paneId
        controller.activeDragTab = tab
        controller.activeDragSourcePaneId = paneId

        let dragGen = controller.dragGeneration
        var monitorRef: Any?
        monitorRef = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if let m = monitorRef {
                NSEvent.removeMonitor(m)
                monitorRef = nil
            }
            DispatchQueue.main.async {
                guard controller.dragGeneration == dragGen else { return }
                if controller.draggingTab != nil || controller.activeDragTab != nil {
                    controller.draggingTab = nil
                    controller.dragSourcePaneId = nil
                    controller.activeDragTab = nil
                    controller.activeDragSourcePaneId = nil
                }
            }
            return event
        }

        let transfer = TabTransferData(tab: tab, sourcePaneId: paneId.id)
        if let data = try? JSONEncoder().encode(transfer) {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.tabTransfer.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        return NSItemProvider()
    }
}

// MARK: - Drop

/// Reads the in-flight tab drag from the drag pasteboard (for drags that began
/// in another workspace or window, where this process has no drag state).
enum TabTransferDecoder {
    static func fromDragPasteboard() -> TabTransferData? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)
        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        if let raw = pasteboard.string(forType: type), let data = raw.data(using: .utf8),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        return nil
    }
}

/// Reorders inside the rail and moves tabs in from other areas, workspaces and
/// windows. The insertion index is the row boundary nearest the cursor. Rows
/// arbitrate through `dropOwner` so a stale exit from the row the pointer just
/// left cannot clear the rule the row it entered is showing.
struct TabRailRowDropDelegate: DropDelegate {
    let rowIndex: Int
    let rowHeight: CGFloat
    let pane: PaneState
    let controller: SplitViewController
    let bonsplitController: BonsplitController
    @Binding var dropIndex: Int?
    @Binding var dropOwner: Int?
    var isEndZone = false
    /// A drag is over the rail: start edge auto-scroll (drags from other
    /// workspaces and windows have no local drag state to start it from).
    var onDragActive: () -> Void = {}

    private var draggedTab: TabItem? { controller.activeDragTab ?? controller.draggingTab }
    private var sourcePaneId: PaneID? { controller.activeDragSourcePaneId ?? controller.dragSourcePaneId }

    private var sourceIndex: Int? {
        guard let draggedTab else { return nil }
        return pane.tabs.firstIndex(where: { $0.id == draggedTab.id })
    }

    private func insertionIndex(for info: DropInfo) -> Int {
        if isEndZone { return pane.tabs.count }
        return info.location.y < rowHeight / 2 ? rowIndex : rowIndex + 1
    }

    private func isNoop(_ target: Int) -> Bool {
        guard let source = sourceIndex else { return false }
        return target == source || target == source + 1
    }

    private func updateIndicator(for info: DropInfo) {
        if dropOwner != rowIndex { dropOwner = rowIndex }
        let target = insertionIndex(for: info)
        let shown: Int? = isNoop(target) ? nil : target
        if dropIndex != shown { dropIndex = shown }
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard controller.isInteractive, info.hasItemsConforming(to: [.tabTransfer]) else { return false }
        onDragActive()
        return true
    }

    func dropEntered(info: DropInfo) {
        onDragActive()
        updateIndicator(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onDragActive()
        updateIndicator(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Only the row that still owns the hover may clear it.
        if let owner = dropOwner, owner != rowIndex { return }
        dropOwner = nil
        dropIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { performDrop(info: info) }
        }
        let target = insertionIndex(for: info)
        defer {
            dropIndex = nil
            dropOwner = nil
        }
        guard let draggedTab, let sourcePaneId else {
            // The drag began in another workspace or window: hand it to the
            // host, as the strip does.
            guard let transfer = TabTransferDecoder.fromDragPasteboard(), transfer.isFromCurrentProcess else {
                return false
            }
            let request = BonsplitController.ExternalTabDropRequest(
                tabId: TabID(id: transfer.tab.id),
                sourcePaneId: PaneID(id: transfer.sourcePaneId),
                destination: .insert(targetPane: pane.id, targetIndex: target)
            )
            return bonsplitController.onExternalTabDrop?(request) ?? false
        }
        withTransaction(Transaction(animation: nil)) {
            if sourcePaneId == pane.id {
                if let source = sourceIndex, !isNoop(target) { pane.moveTab(from: source, to: target) }
            } else {
                _ = bonsplitController.moveTab(TabID(id: draggedTab.id), toPane: pane.id, atIndex: target)
            }
        }
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil
        return true
    }
}
