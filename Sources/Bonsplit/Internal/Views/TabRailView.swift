import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Rail geometry: about 38% of the area, clamped to 200–300pt.
enum TabRailMetrics {
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 22

    static func width(forAreaWidth area: CGFloat) -> CGFloat {
        min(300, max(200, (area * 0.38).rounded()))
    }
}

/// The vertical tab list docked on an area's left edge (Rail layout). The same
/// tabs as the strip, turned sideways: mark, title, status with its duration
/// on line two, `Tab N` at the right, and the gold rule on the visible tab.
/// Rows scroll vertically and drag like strip tabs: reorder here, or drag out to
/// another area's strip or rail.
struct TabRailView: View {
    let pane: PaneState
    let controller: BonsplitController
    let splitViewController: SplitViewController
    let appearance: BonsplitConfiguration.Appearance
    let width: CGFloat
    /// The bar had no room for the controls, so the rail carries them on top.
    var includesControls = false
    let activityAnimationEnabled: Bool
    let explicitActivityAnimationEnabled: Bool

    @State private var dropIndex: Int?
    @State private var hoveredTabId: UUID?

    private var palette: TabBarColors.SheetPalette { TabBarColors.sheetPalette(for: appearance) }

    /// One ticker for the whole rail; about every five seconds the host is asked
    /// for fresh detail so durations and states keep advancing while it is open.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            rail(now: context.date)
                .onChange(of: Int(context.date.timeIntervalSinceReferenceDate / 5)) { _, _ in
                    controller.refreshTabDetails(inPane: pane.id)
                }
        }
        .onAppear { controller.refreshTabDetails(inPane: pane.id) }
    }

    private func rail(now: Date) -> some View {
        VStack(spacing: 0) {
            if includesControls {
                TabControlsRow(pane: pane, controller: controller, appearance: appearance, height: 30)
                    .frame(width: width)
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
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.background)
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.border).frame(width: 1).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TabSheetFormat.localized("tabBar.rail.accessibilityLabel", "Tab rail"))
    }

    private var header: some View {
        HStack {
            Text(TabSheetFormat.tabsFooter(count: pane.tabs.count).uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.faintText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: TabRailMetrics.headerHeight)
        .background(palette.header)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1) }
    }

    private func row(_ tab: TabItem, at index: Int, now: Date) -> some View {
        let isSelected = pane.selectedTabId == tab.id
        let isHovered = hoveredTabId == tab.id
        let gold = TabBarColors.activeIndicator(for: appearance)
        let title = tab.detail?.title.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        return HStack(spacing: 8) {
            ZStack {
                if let state = tab.activityState {
                    CollapsedActivityMarkView(
                        tab: tab,
                        state: state,
                        appearance: appearance,
                        activityAnimationEnabled: activityAnimationEnabled,
                        explicitActivityAnimationEnabled: explicitActivityAnimationEnabled
                    )
                } else if tab.showsNotificationBadge || tab.isDirty {
                    Circle().fill(TabBarColors.notificationBadge(for: appearance)).frame(width: 7, height: 7)
                }
            }
            .frame(width: 17, height: 17)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: appearance.tabTitleFontSize + 0.5, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected || isHovered ? palette.text : palette.dimText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusLine(tab, now: now)
                    .frame(height: 14, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let ordinal = tab.displayOrdinal {
                Text(String(format: TabSheetFormat.localized("tabBar.sheet.tabNumber", "Tab %lld"), Int64(ordinal)))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? gold : palette.faintText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, 7 + TabSheetMetrics.leadingRule)
        .padding(.trailing, 10)
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
            dropIndex: $dropIndex
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
                isEndZone: true
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

/// Reorders inside the rail and moves tabs in from other areas. The insertion
/// index is the row boundary nearest the cursor.
struct TabRailRowDropDelegate: DropDelegate {
    let rowIndex: Int
    let rowHeight: CGFloat
    let pane: PaneState
    let controller: SplitViewController
    let bonsplitController: BonsplitController
    @Binding var dropIndex: Int?
    var isEndZone = false

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
        let target = insertionIndex(for: info)
        let shown: Int? = isNoop(target) ? nil : target
        if dropIndex != shown { dropIndex = shown }
    }

    func validateDrop(info: DropInfo) -> Bool {
        controller.isInteractive && info.hasItemsConforming(to: [.tabTransfer]) && draggedTab != nil
    }

    func dropEntered(info: DropInfo) { updateIndicator(for: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropIndex == rowIndex || dropIndex == rowIndex + 1 || isEndZone { dropIndex = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { performDrop(info: info) }
        }
        guard let draggedTab, let sourcePaneId else { return false }
        let target = insertionIndex(for: info)
        withTransaction(Transaction(animation: nil)) {
            if sourcePaneId == pane.id {
                if let source = sourceIndex, !isNoop(target) { pane.moveTab(from: source, to: target) }
            } else {
                _ = bonsplitController.moveTab(TabID(id: draggedTab.id), toPane: pane.id, atIndex: target)
            }
        }
        dropIndex = nil
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil
        return true
    }
}
