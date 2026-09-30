import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Presenter

/// Hosts the collapsed-tab list as a solid sheet hung flush under the tab bar.
///
/// The sheet is a borderless child `NSPanel` of the bar's window, not a SwiftUI
/// overlay: terminal surfaces are AppKit views in a portal layer and would draw
/// over anything SwiftUI places inside the pane. A child window always orders
/// above its parent's content, whatever the surface kind.
///
/// Drag contract: a row is the drag source, so the panel (and its hosting view)
/// must outlive the drag session. When the cursor leaves the panel the sheet
/// goes invisible and click-through (alpha 0, ignoring mouse events) instead of
/// being ordered out, so the panes beneath become drop targets while the source
/// view stays alive. It is torn down only after the drag ends.
@MainActor
final class CollapsedSheetPresenter: ObservableObject {
    /// The tab bar's own background view; its screen frame anchors the sheet.
    weak var anchorView: NSView?
    /// Width of the header block. Clicks inside it are the header's own
    /// toggle, so the click-outside monitor leaves them alone.
    var blockWidth: CGFloat = 0
    var onDismiss: (() -> Void)?

    private var panel: CollapsedSheetPanel?
    private var hosting: CollapsedSheetHostingView?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var dragTimer: Timer?
    private var isHiddenForDrag = false
    private var repositionScheduled = false

    var isPresented: Bool { panel != nil }

    func present(rootView: AnyView) {
        if let hosting, panel != nil {
            hosting.rootView = rootView
            reposition()
            return
        }
        guard let anchor = anchorView, let window = anchor.window else {
            onDismiss?()
            return
        }

        let hosting = CollapsedSheetHostingView(rootView: rootView)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onIntrinsicSizeChange = { [weak self] in self?.scheduleReposition() }

        let panel = CollapsedSheetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = window.level
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = window.effectiveAppearance
        panel.contentView = hosting

        self.hosting = hosting
        self.panel = panel
        isHiddenForDrag = false

        window.addChildWindow(panel, ordered: .above)
        reposition()
        panel.orderFront(nil)
        installMonitors(hostWindow: window)
    }

    /// Tears the sheet down without notifying `onDismiss`.
    func dismiss() {
        dragTimer?.invalidate()
        dragTimer = nil
        removeMonitors()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        hosting = nil
        isHiddenForDrag = false
    }

    private func dismissAndNotify() {
        dismiss()
        onDismiss?()
    }

    // MARK: Drag tracking

    /// Called when a tab drag starts while the sheet is up (the only source of
    /// such a drag is a row in the sheet). Hides the sheet the moment the
    /// cursor leaves it.
    func beginDragTracking() {
        guard panel != nil, dragTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDragCursor() }
        }
        // Drags run the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    func endDragTracking() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func pollDragCursor() {
        guard let panel, !isHiddenForDrag else { return }
        if !panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
            isHiddenForDrag = true
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.hasShadow = false
        }
    }

    // MARK: Geometry

    private func scheduleReposition() {
        guard !repositionScheduled else { return }
        repositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.repositionScheduled = false
            self.reposition()
        }
    }

    private var anchorScreenRect: NSRect? {
        guard let anchor = anchorView, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    private func reposition() {
        guard let panel, let hosting, let rect = anchorScreenRect else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let frame = NSRect(
            x: rect.minX,
            y: rect.minY - size.height,
            width: size.width,
            height: size.height
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Dismissal triggers

    private func installMonitors(hostWindow: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil, event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.dismissAndNotify() }
            return nil
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
                ?? NSEvent.mouseLocation
            if let bar = self.anchorScreenRect,
               NSRect(x: bar.minX, y: bar.minY, width: max(self.blockWidth, 1), height: bar.height)
                .contains(location) {
                // The header's own tap toggles the sheet.
                return event
            }
            MainActor.assumeIsolated { self.dismissAndNotify() }
            return event
        }

        let center = NotificationCenter.default
        let dismissOn: [(Notification.Name, AnyObject?)] = [
            (NSApplication.didResignActiveNotification, nil),
            (NSWindow.didMoveNotification, hostWindow),
            (NSWindow.didResizeNotification, hostWindow),
            (NSWindow.didMiniaturizeNotification, hostWindow),
        ]
        for (name, object) in dismissOn {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A drag hides the sheet by design; window churn mid-drag
                    // must not tear the source view down.
                    guard let self, !self.isHiddenForDrag, self.dragTimer == nil else { return }
                    self.dismissAndNotify()
                }
            })
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil
        mouseMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

/// Non-activating so a click on a row never steals key status from the pane.
private final class CollapsedSheetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CollapsedSheetHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}

// MARK: - Anchor

/// Reports the tab bar's NSView so the presenter can read its screen frame.
/// Never hit-tests: it sits behind the header and must not swallow its tap.
struct CollapsedSheetAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.onResolve = onResolve
        onResolve(nsView)
    }

    final class AnchorView: NSView {
        var onResolve: ((NSView) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(self)
        }
    }
}

// MARK: - Activity mark

struct CollapsedActivityMarkView: View {
    let tab: TabItem
    let state: BonsplitTabActivityState
    let appearance: BonsplitConfiguration.Appearance
    let activityAnimationEnabled: Bool
    let explicitActivityAnimationEnabled: Bool

    var body: some View {
        let presentation = tab.activityPresentation
        TabActivityMark(
            state: state,
            appearance: appearance,
            phaseId: tab.id,
            colorOverride: presentation?.colorOverrideHex
                .flatMap(NSColor.init(bonsplitHex:))
                .map(Color.init(nsColor:)),
            motion: TabActivityMarkMotionPolicy.resolvedMotion(
                for: state,
                defaultMotionEnabled: activityAnimationEnabled,
                explicitMotionEnabled: explicitActivityAnimationEnabled,
                presentation: presentation
            ),
            alternateCoreColor: presentation?.alternateCoreColorHex
                .flatMap(NSColor.init(bonsplitHex:))
                .map(Color.init(nsColor:))
                ?? (presentation?.alternatesWithBaseColor == true
                    ? TabBarColors.activity(state, for: appearance)
                    : nil)
        )
    }
}

// MARK: - Sheet content

struct CollapsedTabSheetView: View {
    let pane: PaneState
    let controller: BonsplitController
    let splitViewController: SplitViewController
    let appearance: BonsplitConfiguration.Appearance
    /// Narrow tier: the controls fold into the top of the sheet.
    let includesControls: Bool
    let width: CGFloat
    let rowHeight: CGFloat
    let activityAnimationEnabled: Bool
    let explicitActivityAnimationEnabled: Bool
    let makeItemProvider: (TabItem) -> NSItemProvider
    let dismiss: () -> Void

    @State private var dropIndex: Int?
    @State private var hoveredTabId: UUID?

    private static let maxVisibleRows = 9

    private var showsNumbers: Bool {
        appearance.showTabOrdinals && pane.tabs.contains { $0.displayOrdinal != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            if includesControls {
                controlsRow
                Rectangle()
                    .fill(TabBarColors.activeText(for: appearance).opacity(0.14))
                    .frame(height: 1)
            }
            if pane.tabs.count > Self.maxVisibleRows - (includesControls ? 1 : 0) {
                ScrollView { rows }
                    .frame(maxHeight: rowHeight * CGFloat(Self.maxVisibleRows))
            } else {
                rows
            }
        }
        .frame(width: width)
        .background(TabBarColors.barBackground(for: appearance))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TabBarColors.activeIndicator(for: appearance))
                .frame(height: 2)
                .allowsHitTesting(false)
        }
        .overlay {
            Rectangle()
                .strokeBorder(TabBarColors.activeText(for: appearance).opacity(0.28), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab list")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                row(tab, at: index)
            }
        }
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ tab: TabItem, at index: Int) -> some View {
        let isSelected = pane.selectedTabId == tab.id
        let isHovered = hoveredTabId == tab.id
        HStack(spacing: 0) {
            if showsNumbers {
                Text(tab.displayOrdinal.map(String.init) ?? "")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                    .frame(width: 34, alignment: .trailing)
                    .padding(.trailing, 9)
            } else {
                Color.clear.frame(width: 12)
            }

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
                    Circle()
                        .fill(TabBarColors.notificationBadge(for: appearance))
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 17, height: 17)
            .padding(.trailing, 8)

            Text(tab.title)
                .font(.system(size: appearance.tabTitleFontSize + 1, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(
                    isSelected
                        ? TabBarColors.activeText(for: appearance)
                        : TabBarColors.inactiveText(for: appearance)
                )

            Spacer(minLength: 8)

            // Always laid out so the row never reflows on hover; only the
            // glyph's visibility changes.
            if !tab.isPinned {
                CollapsedTabCloseButton(
                    tab: tab,
                    pane: pane,
                    controller: controller,
                    appearance: appearance
                )
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
        }
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(TabBarColors.activeIndicator(for: appearance))
                    .frame(width: 3)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if dropIndex == index { insertionRule }
        }
        .overlay(alignment: .bottom) {
            if index == pane.tabs.count - 1, dropIndex == pane.tabs.count { insertionRule }
        }
        .contentShape(Rectangle())
        // One drag source per row: a click selects, a press-drag starts the
        // standard tab drag. Deliberately not a Button with `.onDrag` bolted
        // on: the Button owns the mouse-down and the drag never starts.
        .onTapGesture {
            withTransaction(Transaction(animation: nil)) {
                pane.selectTab(tab.id)
                controller.focusPane(pane.id)
            }
            dismiss()
        }
        .onDrag {
            makeItemProvider(tab)
        } preview: {
            TabDragPreview(tab: tab, appearance: appearance)
        }
        .onDrop(of: [.tabTransfer], delegate: CollapsedSheetRowDropDelegate(
            rowIndex: index,
            rowHeight: rowHeight,
            pane: pane,
            controller: splitViewController,
            dropIndex: $dropIndex,
            onDropped: dismiss
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
        .accessibilityValue([
            tab.activityPresentation?.accessibilityValue,
            TabActivityAccessibility.value(for: tab.activityState),
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(TabActivityAccessibility.help(for: tab.activityState))
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return TabBarColors.activeTabBackground(for: appearance) }
        if isHovered { return TabBarColors.activeTabBackground(for: appearance).opacity(0.55) }
        return .clear
    }

    private var insertionRule: some View {
        Rectangle()
            .fill(TabBarColors.activeIndicator(for: appearance))
            .frame(height: 3)
            .allowsHitTesting(false)
    }

    // MARK: Controls (narrow tier)

    /// The same actions as the horizontal strip's trailing chrome. Each action
    /// dismisses the sheet after firing.
    @ViewBuilder
    private var controlsRow: some View {
        let tooltips = appearance.splitButtonTooltips
        let canClosePane = controller.allPaneIds.count > 1
            || controller.configuration.allowCloseLastPane
        HStack(spacing: 4) {
            AgentSpawnButtonCluster(
                controller: controller,
                paneId: pane.id,
                appearance: appearance,
                afterAction: dismiss
            )

            SplitToolbarButton(systemImage: "terminal", tooltip: tooltips.newTerminal, appearance: appearance) {
                controller.requestNewTab(kind: "terminal", inPane: pane.id)
                dismiss()
            }
            SplitToolbarButton(systemImage: "globe", tooltip: tooltips.newBrowser, appearance: appearance) {
                controller.requestNewTab(kind: "browser", inPane: pane.id)
                dismiss()
            }
            SplitToolbarButton(systemImage: "doc.text", tooltip: tooltips.newMarkdown, appearance: appearance) {
                controller.requestNewTab(kind: "markdown", inPane: pane.id)
                dismiss()
            }

            Spacer(minLength: 8)

            SplitToolbarButton(systemImage: "square.split.2x1", tooltip: tooltips.splitRight, appearance: appearance) {
                controller.splitPane(pane.id, orientation: .horizontal)
                dismiss()
            }
            SplitToolbarButton(systemImage: "square.split.1x2", tooltip: tooltips.splitDown, appearance: appearance) {
                controller.splitPane(pane.id, orientation: .vertical)
                dismiss()
            }
            SplitToolbarButton(systemImage: "plus", tooltip: tooltips.newTab, appearance: appearance) {
                controller.requestNewTab(kind: "newTab", inPane: pane.id)
                dismiss()
            }
            SplitToolbarButton(systemImage: "xmark", tooltip: tooltips.closePane, appearance: appearance, isEnabled: canClosePane) {
                controller.requestClosePane(pane.id)
                dismiss()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row drop delegate

/// Reorders within the sheet. Insertion index is the row boundary nearest the
/// cursor: the upper half of row `i` inserts before it, the lower half after.
struct CollapsedSheetRowDropDelegate: DropDelegate {
    let rowIndex: Int
    let rowHeight: CGFloat
    let pane: PaneState
    let controller: SplitViewController
    @Binding var dropIndex: Int?
    let onDropped: () -> Void

    private var draggedTab: TabItem? { controller.activeDragTab ?? controller.draggingTab }

    private var sourceIndex: Int? {
        guard let draggedTab else { return nil }
        return pane.tabs.firstIndex(where: { $0.id == draggedTab.id })
    }

    private func insertionIndex(for info: DropInfo) -> Int {
        info.location.y < rowHeight / 2 ? rowIndex : rowIndex + 1
    }

    private func isNoop(_ target: Int, source: Int) -> Bool {
        target == source || target == source + 1
    }

    private func updateIndicator(for info: DropInfo) {
        guard let source = sourceIndex else { return }
        let target = insertionIndex(for: info)
        let shown: Int? = isNoop(target, source: source) ? nil : target
        if dropIndex != shown { dropIndex = shown }
    }

    func validateDrop(info: DropInfo) -> Bool {
        controller.isInteractive
            && info.hasItemsConforming(to: [.tabTransfer])
            && sourceIndex != nil
    }

    func dropEntered(info: DropInfo) { updateIndicator(for: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropIndex == rowIndex || dropIndex == rowIndex + 1 { dropIndex = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync { performDrop(info: info) }
        }
        guard let source = sourceIndex else { return false }
        let target = insertionIndex(for: info)
        if !isNoop(target, source: source) {
            withTransaction(Transaction(animation: nil)) {
                pane.moveTab(from: source, to: target)
            }
        }
        dropIndex = nil
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil
        // The drag source (a row in this sheet) must stay alive until AppKit
        // finishes the drag session, so the teardown is deferred.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: onDropped)
        return true
    }
}
