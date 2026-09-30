import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Motion

/// Debug-only knob: stretches the sheet's unroll so a screenshot can catch it
/// mid-flight. 1 in normal use.
public enum BonsplitDebug {
    nonisolated(unsafe) public static var tabSheetMotionScale: Double = 1
}

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
    /// The full tier's count cell. When set, the sheet's right edge aligns to
    /// this cell's right edge and clicks on the cell are its own toggle.
    /// Collapsed tiers leave it nil and anchor flush-left under the bar.
    weak var trailingAnchorView: NSView?
    /// Width of the collapsed header block. Clicks inside it are the header's
    /// own toggle, so the click-outside monitor leaves them alone.
    var blockWidth: CGFloat = 0
    var onDismiss: (() -> Void)?

    private var panel: CollapsedSheetPanel?
    private var hosting: CollapsedSheetHostingView?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var dragTimer: Timer?
    private var isHiddenForDrag = false
    private var releasedPolls = 0
    private var repositionScheduled = false
    /// A roll-up is running; the panel goes away when it lands.
    private var isRollingUp = false
    /// A drag that started from a row is in flight: the (possibly invisible)
    /// panel is its drag source and must not be torn down until it ends.
    private(set) var isDragging = false

    var isPresented: Bool { panel != nil }

    deinit {
        dragTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    func present(rootView: AnyView) {
        if isRollingUp { cancelRollUp() }
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
        runUnroll(opening: true)
    }

    // MARK: Unroll motion

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// One axis only: the sheet slides down out of the bar in ~120ms (a
    /// top-anchored clip reveal plus a 6pt translate) and rolls back up in
    /// ~90ms. Core Animation on the hosting layer, transform and mask only, so
    /// no SwiftUI layout runs per frame and input is never blocked: the mask
    /// does not affect hit testing, and a roll-up flips the panel click-through.
    /// Skipped entirely under Reduce Motion.
    private func runUnroll(opening: Bool, completion: (() -> Void)? = nil) {
        guard let layer = hosting?.layer, !Self.reduceMotion else {
            completion?()
            return
        }
        let scale = max(0.1, BonsplitDebug.tabSheetMotionScale)
        let duration = (opening ? 0.120 : 0.090) * scale
        let flipped = layer.isGeometryFlipped
        let bounds = layer.bounds
        let up: CGFloat = flipped ? -6 : 6

        let mask = CALayer()
        mask.backgroundColor = NSColor.white.cgColor
        mask.bounds = bounds
        mask.anchorPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        mask.position = CGPoint(x: bounds.midX, y: flipped ? bounds.minY : bounds.maxY)
        layer.mask = mask

        let clip = CABasicAnimation(keyPath: "transform.scale.y")
        clip.fromValue = opening ? 0.0001 : 1
        clip.toValue = opening ? 1 : 0.0001
        let shift = CABasicAnimation(keyPath: "transform.translation.y")
        shift.fromValue = opening ? up : 0
        shift.toValue = opening ? 0 : up
        let timing = opening
            ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            : CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        for animation in [clip, shift] {
            animation.duration = duration
            animation.timingFunction = timing
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak layer] in
            layer?.mask = nil
            layer?.removeAnimation(forKey: "sheet.shift")
            mask.removeAllAnimations()
            MainActor.assumeIsolated {
                guard let self else { return }
                if opening || self.isRollingUp { completion?() }
            }
        }
        // Pin the end state so the layer rests where the animation ends.
        mask.transform = CATransform3DMakeScale(1, opening ? 1 : 0.0001, 1)
        layer.add(shift, forKey: "sheet.shift")
        mask.add(clip, forKey: "sheet.clip")
        CATransaction.commit()
    }

    private func cancelRollUp() {
        isRollingUp = false
        hosting?.layer?.mask = nil
        hosting?.layer?.removeAnimation(forKey: "sheet.shift")
        panel?.ignoresMouseEvents = false
    }

    /// Rolls the sheet up (when motion is allowed), then tears it down. The
    /// panel stops taking clicks the moment it starts closing.
    func dismissAnimated() {
        if isDragging, panel != nil { return }
        guard panel != nil, !isRollingUp else { return }
        guard hosting?.layer != nil, !Self.reduceMotion else {
            forceDismiss()
            return
        }
        isRollingUp = true
        panel?.ignoresMouseEvents = true
        runUnroll(opening: false) { [weak self] in
            guard let self, self.isRollingUp else { return }
            self.isRollingUp = false
            self.forceDismiss()
        }
    }

    /// Asks the sheet to go away. While a row drag is in flight the request is
    /// held until the drag ends: tearing down the hosting view would kill the
    /// drag source (tier changes and title churn can request this mid-drag).
    func dismiss() {
        if isDragging, panel != nil { return }
        forceDismiss()
    }

    /// Tears the sheet down without notifying `onDismiss`.
    private func forceDismiss() {
        isRollingUp = false
        dragTimer?.invalidate()
        dragTimer = nil
        isDragging = false
        releasedPolls = 0
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

    private func dismissAndNotify(animated: Bool = false) {
        if animated { dismissAnimated() } else { forceDismiss() }
        onDismiss?()
    }

    // MARK: Drag tracking

    /// Called when a tab drag starts while the sheet is up (the only source of
    /// such a drag is a row in the sheet). Hides the sheet the moment the
    /// cursor leaves it.
    func beginDragTracking() {
        guard panel != nil, dragTimer == nil else { return }
        isDragging = true
        releasedPolls = 0
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDragCursor() }
        }
        // Drags run the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    /// The model reports the drag over (drop applied, cancelled, or landed
    /// elsewhere). AppKit is still finishing the drag session inside the drop
    /// callbacks, so the source view is released a beat later.
    func dragEnded() {
        guard panel != nil else {
            isDragging = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel != nil else { return }
            self.dismissAndNotify()
        }
    }

    private func pollDragCursor() {
        guard let panel else { return }
        // Backstop for drag end: the drag session is over once the button has
        // been up for a few polls, whether it dropped, was cancelled, or landed
        // somewhere that never reports back. The drop delegates clear the
        // model's drag state; the sheet does not depend on that to go away.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            releasedPolls += 1
            if releasedPolls >= 4 {
#if DEBUG
                dlog("tab.sheet.dragEnd fallbackDismiss hidden=\(isHiddenForDrag ? 1 : 0)")
#endif
                dismissAndNotify()
            }
            return
        }
        releasedPolls = 0
        guard !isHiddenForDrag else { return }
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

    private var trailingAnchorScreenRect: NSRect? {
        guard let cell = trailingAnchorView, let window = cell.window else { return nil }
        return window.convertToScreen(cell.convert(cell.bounds, to: nil))
    }

    private func reposition() {
        guard let panel, let hosting, let rect = anchorScreenRect,
              let aw = anchorView?.window else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        // Hang below the bar; flip above it when the screen would clip the
        // bottom, and keep the sheet inside the visible frame either way.
        let visible = (aw.screen ?? NSScreen.main)?.visibleFrame
        // The sheet is its area's width: flush under the bar, left edges aligned.
        var origin = NSPoint(x: rect.minX, y: rect.minY - size.height)
        if let visible {
            if origin.y < visible.minY {
                let above = rect.maxY
                origin.y = above + size.height <= visible.maxY ? above : max(visible.minY, origin.y)
            }
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        }
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Dismissal triggers

    private func installMonitors(hostWindow: NSWindow) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.keyCode == 53,
                  NSApp.keyWindow === panel.parent else { return event }
            MainActor.assumeIsolated { self.dismissAndNotify(animated: true) }
            return nil
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
                ?? NSEvent.mouseLocation
            if let cell = self.trailingAnchorScreenRect {
                // The count cell's own tap toggles the sheet.
                if cell.contains(location) { return event }
            } else if let bar = self.anchorScreenRect,
               NSRect(x: bar.minX, y: bar.minY, width: max(self.blockWidth, 1), height: bar.height)
                .contains(location) {
                // The header's own tap toggles the sheet.
                return event
            }
            MainActor.assumeIsolated { self.dismissAndNotify(animated: true) }
            return event
        }

        let center = NotificationCenter.default
        // The bar can move inside the window while the sheet is up (sidebar
        // toggle, split/close/zoom): follow whichever ancestor frame changed.
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil,
                      let changed = note.object as? NSView,
                      let anchor = self.anchorView,
                      anchor.isDescendant(of: changed) else { return }
                self.scheduleReposition()
            }
        })
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
            // A removal also lands here; never resolve to a detached view.
            guard window != nil else { return }
            onResolve?(self)
        }
    }
}

/// Same as `CollapsedSheetAnchorReader`, for the full tier's count cell.
struct CollapsedSheetTrailingAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> CollapsedSheetAnchorReader.AnchorView {
        let view = CollapsedSheetAnchorReader.AnchorView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: CollapsedSheetAnchorReader.AnchorView, context: Context) {
        nsView.onResolve = onResolve
        onResolve(nsView)
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

/// The tab sheet: a fixed grid of two-line rows. Every column but the title has
/// a fixed width, so nothing moves when text changes length or a clock ticks.
struct CollapsedTabSheetView: View {
    let pane: PaneState
    let controller: BonsplitController
    let splitViewController: SplitViewController
    let appearance: BonsplitConfiguration.Appearance
    /// Narrow tier: the controls fold into the top of the sheet.
    let includesControls: Bool
    /// Columns and widths for this sheet's width tier.
    let layout: TabSheetLayout
    /// Height of the folded controls row (narrow tier).
    let controlsRowHeight: CGFloat
    /// Host-supplied header titles by clock name; missing entries use bonsplit's built-ins.
    let clockTitles: [String: String]
    let activityAnimationEnabled: Bool
    let explicitActivityAnimationEnabled: Bool
    let makeItemProvider: (TabItem) -> NSItemProvider
    let dismiss: () -> Void

    @State private var dropIndex: Int?
    @State private var hoveredTabId: UUID?

    private typealias M = TabSheetMetrics

    /// Cached per chrome background, so this is a lookup, not a rebuild.
    private var palette: TabBarColors.SheetPalette { TabBarColors.sheetPalette(for: appearance) }

    private var width: CGFloat { layout.width }
    private var clocks: [String] { layout.clocks }
    private var titleColumnWidth: CGFloat { layout.titleWidth }

    /// The one ticker for the whole sheet: every relative time reads the same
    /// `now`, and about every five seconds the host re-supplies its detail so
    /// the clocks and state start times keep advancing while the sheet is open.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            sheet(now: context.date)
                .onChange(of: Int(context.date.timeIntervalSinceReferenceDate / 5)) { _, _ in
                    controller.refreshTabDetails(inPane: pane.id)
                }
        }
    }

    private func sheet(now: Date) -> some View {
        VStack(spacing: 0) {
            if includesControls {
                controlsRow
                Rectangle().fill(palette.separator).frame(height: 1)
            }
            headerRow
            if pane.tabs.count > M.maxVisibleRows {
                ScrollView { rows(now: now) }
                    .frame(maxHeight: M.rowHeight * CGFloat(M.maxVisibleRows))
            } else {
                rows(now: now)
            }
            footerRow
        }
        .frame(width: width)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TabBarColors.activeIndicator(for: appearance))
                .frame(height: 2)
                .allowsHitTesting(false)
        }
        .overlay {
            Rectangle()
                .strokeBorder(palette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Bundle.module.localizedString(
            forKey: "tabBar.collapsedList.accessibilityLabel",
            value: "Tab list",
            table: nil
        ))
    }

    private func rows(now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                row(tab, at: index, now: now)
            }
        }
    }

    // MARK: Header and footer

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: M.leadingRule)
            headerLabel(TabSheetFormat.localized("tabBar.sheet.column.tab", "Tab"), width: layout.numberWidth, alignment: .trailing, trailingInset: layout.numberTrailingInset)
            Color.clear.frame(width: M.markWidth)
            headerLabel(TabSheetFormat.localized("tabBar.sheet.column.title", "Title"), width: titleColumnWidth, alignment: .leading)
            if layout.showsAgentColumn {
                headerLabel(TabSheetFormat.localized("tabBar.sheet.column.agent", "Agent"), width: M.agentWidth, alignment: .leading, leadingInset: 10)
            }
            headerLabel(TabSheetFormat.localized("tabBar.sheet.column.status", "Status"), width: M.statusWidth, alignment: .leading, leadingInset: 10)
            ForEach(clocks, id: \.self) { name in
                headerLabel(TabSheetFormat.clockTitle(name, hostTitle: clockTitles[name]) ?? name, width: M.clockWidth, alignment: .trailing, trailingInset: 8)
            }
            Color.clear.frame(width: (layout.showsClose ? M.closeWidth : 0) + M.gripWidth + M.trailingPadding)
        }
        .frame(height: M.headerHeight)
        .background(palette.header)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.separator).frame(height: 1) }
    }

    private func headerLabel(
        _ text: String,
        width: CGFloat,
        alignment: Alignment,
        leadingInset: CGFloat = 0,
        trailingInset: CGFloat = 0
    ) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(palette.faintText)
            .lineLimit(1)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .frame(width: width, alignment: alignment)
    }

    private var footerRow: some View {
        let needYou = TabSheetFormat.needYouCount(pane.tabs)
        return HStack(spacing: 14) {
            Text(TabSheetFormat.tabsFooter(count: pane.tabs.count))
                .foregroundStyle(palette.faintText)
            if needYou > 0 {
                Text(TabSheetFormat.needYouFooter(count: needYou))
                    .foregroundStyle(TabBarColors.activity(.waiting, for: appearance))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .frame(height: M.footerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.header)
        .overlay(alignment: .top) { Rectangle().fill(palette.separator).frame(height: 1) }
    }

    // MARK: Row

    /// One column of a two-line row: `top` on line one, `bottom` on line two,
    /// vertically centered in the row. Empty lines still reserve their height.
    private func column<Top: View, Bottom: View>(
        width: CGFloat? = nil,
        alignment: Alignment = .leading,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom = { Color.clear }
    ) -> some View {
        VStack(spacing: 0) {
            top().frame(maxWidth: .infinity, alignment: alignment).frame(height: M.lineHeight)
            bottom().frame(maxWidth: .infinity, alignment: alignment).frame(height: M.lineHeight)
        }
        .frame(width: width, height: M.rowHeight)
    }

    private func dash() -> some View {
        Text("—")
            .font(.system(size: 12))
            .foregroundStyle(palette.dash)
            .lineLimit(1)
    }

    @ViewBuilder
    private func row(_ tab: TabItem, at index: Int, now: Date) -> some View {
        let isSelected = pane.selectedTabId == tab.id
        // Hovering a tab in the strip lights its row, and the row lights its tab.
        let isHovered = hoveredTabId == tab.id || controller.linkedHoverTabId == tab.id
        let gold = TabBarColors.activeIndicator(for: appearance)
        let title = tab.detail?.title.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
        HStack(spacing: 0) {
            Color.clear.frame(width: M.leadingRule)

            column(width: layout.numberWidth, alignment: .trailing) {
                if let ordinal = tab.displayOrdinal {
                    Text(String(format: TabSheetFormat.localized("tabBar.sheet.tabNumber", "Tab %lld"), Int64(ordinal)))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? gold : palette.faintText)
                        .lineLimit(1)
                        .padding(.trailing, layout.numberTrailingInset)
                } else {
                    dash().padding(.trailing, layout.numberTrailingInset)
                }
            }

            column(width: M.markWidth, alignment: .leading) {
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
            }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: appearance.tabTitleFontSize + 1, weight: isSelected ? .bold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? palette.text : (isHovered ? palette.text : palette.dimText))
                        .frame(width: titleColumnWidth, alignment: .leading)
                    if layout.showsAgentColumn {
                        agentCell(tab)
                            .padding(.leading, 10)
                            .frame(width: M.agentWidth, alignment: .leading)
                    }
                    statusCell(tab, now: now)
                        .padding(.leading, 10)
                        .frame(width: M.statusWidth, alignment: .leading)
                }
                .frame(height: M.lineHeight)
                HStack(spacing: 4) {
                    if layout.agentOnLineTwo, let agent = tab.detail?.agentLabel, !agent.isEmpty {
                        Text(agent + " ·")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.faintText)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    subtitleCell(tab, emphasized: isSelected || isHovered)
                    Spacer(minLength: 0)
                }
                .frame(width: layout.mainWidth, height: M.lineHeight, alignment: .leading)
            }
            .frame(width: layout.mainWidth, height: M.rowHeight)

            ForEach(clocks, id: \.self) { name in
                column(width: M.clockWidth, alignment: .trailing) {
                    Group {
                        switch TabSheetFormat.clockValue(name, in: tab) {
                        case .age(let date):
                            TabSheetAgeText(since: date, now: now)
                                .foregroundStyle(palette.dimText)
                        case .text(let text):
                            Text(text)
                                .font(.system(size: 11, design: .monospaced))
                                .monospacedDigit()
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(palette.dimText)
                        case .none:
                            dash()
                        }
                    }
                    .padding(.trailing, 8)
                }
            }

            if layout.showsClose {
                column(width: M.closeWidth, alignment: .center) {
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
            }

            column(width: M.gripWidth, alignment: .center) {
                Text("\u{22EE}\u{22EE}")
                    .font(.system(size: 13))
                    .tracking(-2)
                    .foregroundStyle(isHovered || isSelected ? palette.dimText : palette.faintText.opacity(0.7))
                    .help(TabSheetFormat.localized("tabBar.sheet.dragHandle.help", "Drag to reorder or move"))
            }

            Color.clear.frame(width: M.trailingPadding)
        }
        .frame(width: width, height: M.rowHeight, alignment: .leading)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .overlay(alignment: .bottom) {
            if index < pane.tabs.count - 1 {
                Rectangle().fill(palette.separator).frame(height: 1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(gold)
                    .frame(width: M.leadingRule)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if dropIndex == index { insertionRule }
        }
        .overlay(alignment: .bottom) {
            if index == pane.tabs.count - 1, dropIndex == pane.tabs.count { insertionRule }
        }
        .opacity(splitViewController.draggingTab?.id == tab.id ? 0.35 : 1)
        .contentShape(Rectangle())
        // One drag source per row: a click selects, a press-drag starts the
        // standard tab drag. Deliberately not a Button with `.onDrag` bolted
        // on: the Button owns the mouse-down and the drag never starts. The
        // grip is the visible affordance; the whole row stays draggable.
        .onTapGesture { select(tab) }
        .onDrag {
            makeItemProvider(tab)
        } preview: {
            TabDragPreview(tab: tab, appearance: appearance)
        }
        .onDrop(of: [.tabTransfer], delegate: CollapsedSheetRowDropDelegate(
            rowIndex: index,
            rowHeight: M.rowHeight,
            pane: pane,
            controller: splitViewController,
            dropIndex: $dropIndex,
            onDropped: dismiss
        ))
        .onHover { inside in
            if inside {
                hoveredTabId = tab.id
                controller.setLinkedHover(tab.id, fromSheet: true)
            } else if hoveredTabId == tab.id {
                hoveredTabId = nil
                controller.clearLinkedHover(ifSheet: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        // `.combine` folds the visible close button into the row, so the actions
        // are exposed explicitly.
        .accessibilityAction(named: Text(Bundle.module.localizedString(
            forKey: "tabBar.collapsedList.selectAction",
            value: "Select",
            table: nil
        ))) { select(tab) }
        .accessibilityAction(named: Text(Bundle.module.localizedString(
            forKey: "command.closeTab.title",
            value: "Close Tab",
            table: nil
        ))) {
            guard !tab.isPinned else { return }
            CollapsedTabCloseButton.close(tab: tab, pane: pane, controller: controller)
        }
        .accessibilityValue([
            tab.activityPresentation?.accessibilityValue,
            TabActivityAccessibility.value(for: tab.activityState),
        ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(TabActivityAccessibility.help(for: tab.activityState))
    }

    // MARK: Cells

    @ViewBuilder
    private func agentCell(_ tab: TabItem) -> some View {
        if let label = tab.detail?.agentLabel, !label.isEmpty {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.chipText)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
                .frame(height: 16)
                .background(palette.chipFill)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.chipBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(maxWidth: M.agentWidth - 12, alignment: .leading)
        } else {
            dash()
        }
    }

    @ViewBuilder
    private func statusCell(_ tab: TabItem, now: Date) -> some View {
        if let status = tab.detail?.status {
            let color = statusColor(status.kind, tab: tab)
            HStack(spacing: 4) {
                Text(TabSheetFormat.statusWord(status.kind))
                    .lineLimit(1)
                if let since = status.since {
                    TabSheetAgeText(since: since, now: now, font: .system(size: 11, weight: status.kind == .idle || status.kind == .cold ? .semibold : .bold))
                }
            }
            .font(.system(size: 11, weight: status.kind == .idle || status.kind == .cold ? .semibold : .bold))
            .foregroundStyle(color)
        } else {
            dash()
        }
    }

    private func statusColor(_ kind: BonsplitTabDetail.StatusKind, tab: TabItem) -> Color {
        switch kind {
        case .working: return TabBarColors.activity(.running, for: appearance)
        case .waiting: return TabBarColors.activity(.waiting, for: appearance)
        case .flagged:
            // The tab's own flag colour, deepened on a light sheet until it reads.
            let mark = tab.activityPresentation?.colorOverrideHex.flatMap(NSColor.init(bonsplitHex:))
                ?? NSColor(bonsplitHex: "#9D8AD9")!
            return TabBarColors.readableInk(mark, for: appearance)
        case .idle, .cold: return palette.faintText
        }
    }

    @ViewBuilder
    private func subtitleCell(_ tab: TabItem, emphasized: Bool) -> some View {
        if let subtitle = tab.detail?.subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(emphasized ? palette.dimText : palette.faintText)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            dash()
        }
    }

    private func select(_ tab: TabItem) {
        withTransaction(Transaction(animation: nil)) {
            pane.selectTab(tab.id)
            controller.focusPane(pane.id)
        }
        dismiss()
    }

    private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
        // The visible tab keeps its own fill under the pointer.
        if isSelected { return palette.rowActive }
        if isHovered { return palette.rowHover }
        return .clear
    }

    private var insertionRule: some View {
        Rectangle()
            .fill(TabBarColors.activeIndicator(for: appearance))
            .frame(height: 3)
            .allowsHitTesting(false)
    }

    // MARK: Controls (narrow tier)

    @ViewBuilder
    private var controlsRow: some View {
        TabControlsRow(
            pane: pane,
            controller: controller,
            appearance: appearance,
            height: controlsRowHeight,
            afterAction: dismiss
        )
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
