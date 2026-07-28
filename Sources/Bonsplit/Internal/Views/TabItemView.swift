import SwiftUI
import AppKit

/// File-private cache for tab-color palette swatches. The Tab Color submenu
/// renders one icon per palette entry inside a SwiftUI `Menu`, and SwiftUI
/// re-evaluates the enclosing view body on every selection / hover / dirty /
/// notification update. Keying the rendered NSImage by hex means each entry
/// is drawn at most once per process — not once per re-render per tab.
/// NSCache is thread-safe, so this is safe to share across TabItemView
/// instances on the main thread.
private let tabColorSwatchCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 64
    return cache
}()

private enum TabControlShortcutHintDebugSettings {
    static let xKey = "shortcutHintPaneTabXOffset"
    static let yKey = "shortcutHintPaneTabYOffset"
    static let alwaysShowKey = "shortcutHintAlwaysShow"
    static let defaultX = 0.0
    static let defaultY = 0.0
    static let defaultAlwaysShow = false
    static let range: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Fade-in / hold / fade-out opacity envelope used by the per-tab flash overlay.
///
/// Total duration ~2s (0.5s fade-in, 1.0s hold, 0.5s fade-out). Long enough
/// for the operator to glance at the workspace and locate the flashed tab
/// without missing it; gentle on the eyes because the hold doesn't exceed
/// peakOpacity and the entrance/exit are eased.
enum TabFlashPattern {
    static let values: [Double] = [0, 1, 1, 0]
    static let keyTimes: [Double] = [0, 0.25, 0.75, 1]
    static let duration: TimeInterval = 2.0
    static let peakOpacity: Double = 0.55

    enum Curve {
        case easeIn
        case easeOut
    }

    struct Segment {
        let delay: TimeInterval
        let duration: TimeInterval
        let targetOpacity: Double
        let curve: Curve
    }

    /// .easeOut on the way up, .easeIn on the way down. The middle (hold)
    /// segment animates a no-op opacity assignment; SwiftUI sees no value
    /// change so it doesn't render an animation, but the asyncAfter delay
    /// preserves the timing before the fade-out fires.
    static let curves: [Curve] = [.easeOut, .easeOut, .easeIn]

    static var segments: [Segment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return Segment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1] * peakOpacity,
                curve: curves[index]
            )
        }
    }
}

enum TabItemStyling {
    static func iconSaturation(hasRasterIcon: Bool, tabSaturation: Double) -> Double {
        hasRasterIcon ? 1.0 : tabSaturation
    }

    static func shouldShowHoverBackground(isHovered: Bool, isSelected: Bool) -> Bool {
        isHovered && !isSelected
    }

    static func widthRange(for appearance: BonsplitConfiguration.Appearance) -> ClosedRange<CGFloat> {
        let minWidth = max(1, appearance.tabMinWidth)
        let maxWidth = max(minWidth, appearance.tabMaxWidth)
        return minWidth...maxWidth
    }

    static func resolvedFaviconImage(existing: NSImage?, incomingData: Data?) -> NSImage? {
        guard let incomingData else { return nil }
        if let decoded = NSImage(data: incomingData) {
            // Favicon bitmaps must never be treated as template/tintable symbols.
            decoded.isTemplate = false
            return decoded
        }
        return existing
    }
}

enum TabActivityMarkMetrics {
    /// Side of the drawn cell, and the thickness of the `cold` line.
    static let cellSide: CGFloat = 9
    static let coldLineThickness: CGFloat = 2
    static let waitingFrameThickness: CGFloat = 1.5
    static let waitingCoreSide: CGFloat = 4
    static let workingDotSide: CGFloat = 2
    static let workingDotSpacing: CGFloat = 1

    /// Every state occupies the same slot, so a tab's title never shifts
    /// horizontally when its surface changes state.
    static func visibleSize(for state: BonsplitTabActivityState) -> CGFloat {
        _ = state
        return 10
    }

    static func leadingEdgeInset(for state: BonsplitTabActivityState) -> CGFloat {
        _ = state
        return 4
    }

    static func titleSpacing(for state: BonsplitTabActivityState) -> CGFloat {
        leadingEdgeInset(for: state)
    }

    static func leadingAccessoryWidth(for state: BonsplitTabActivityState) -> CGFloat {
        leadingEdgeInset(for: state) + visibleSize(for: state) + titleSpacing(for: state)
    }
}

enum TabActivityAccessibility {
    static func value(for state: BonsplitTabActivityState?) -> String {
        switch state {
        case .running:
            return localizedString("tab.activity.running", default: "Running")
        case .idle:
            return localizedString("tab.activity.idle", default: "Idle")
        case .cold:
            return localizedString("tab.activity.cold", default: "Cold")
        case .waiting:
            return localizedString("tab.activity.waiting", default: "Waiting for your response")
        case nil:
            return ""
        }
    }

    static func help(for state: BonsplitTabActivityState?) -> String {
        guard state == .waiting else { return "" }
        return localizedString("tab.activity.waiting.help", default: "This surface needs your response.")
    }

    private static func localizedString(_ key: String, default value: String) -> String {
        Bundle.module.localizedString(forKey: key, value: value, table: nil)
    }
}

enum SimplifiedTabGeometry {
    static let unmarkedLeadingInset: CGFloat = 6
    static let closeHitSize = CGSize(width: 28, height: 29)
    static let closeTrailingInset: CGFloat = 3
}

/// Agent-state mark: a hard-edged terminal cell whose shape alone carries the
/// lifecycle — a typed dot grid for running, frame plus payload for waiting,
/// an empty frame for idle, and a collapsed line for cold.
///
/// Animation is leaf-isolated here. The process-wide clock is shared with host
/// renderers, so no tab owns a timer and no clock tick reaches the tab row.
/// Hosts inject the already-resolved tint and motion channel; Bonsplit does not
/// interpret downstream attention modifiers or application policy.
struct TabActivityMark: View {
    private static let defaultPhaseId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let state: BonsplitTabActivityState
    let appearance: BonsplitConfiguration.Appearance
    let phaseId: UUID
    let colorOverride: Color?
    let motion: BonsplitActivityMarkMotion?
    let alternateCoreColor: Color?

    init(
        state: BonsplitTabActivityState,
        appearance: BonsplitConfiguration.Appearance,
        phaseId: UUID = Self.defaultPhaseId,
        colorOverride: Color? = nil,
        motion: BonsplitActivityMarkMotion? = nil,
        alternateCoreColor: Color? = nil
    ) {
        self.state = state
        self.appearance = appearance
        self.phaseId = phaseId
        self.colorOverride = colorOverride
        self.motion = motion
        self.alternateCoreColor = alternateCoreColor
    }

    var body: some View {
        TabActivityMarkLeaf(
            state: state,
            color: colorOverride ?? TabBarColors.activity(state, for: appearance),
            phaseId: phaseId,
            motion: motion,
            alternateCoreColor: alternateCoreColor
        )
    }
}

enum TabActivityMarkMotionPolicy {
    static func defaultMotion(
        for state: BonsplitTabActivityState,
        isEnabled: Bool
    ) -> BonsplitActivityMarkMotion? {
        guard isEnabled else { return nil }
        switch state {
        case .running: return .steppedFill
        case .waiting: return .easedDip
        case .idle, .cold: return nil
        }
    }
}

private struct TabActivityMarkLeaf: View {
    let state: BonsplitTabActivityState
    let color: Color
    let phaseId: UUID
    let motion: BonsplitActivityMarkMotion?
    let alternateCoreColor: Color?

    @State private var clockToken: UUID?
    @State private var visibleWorkingDots = 9
    @State private var waitingCoreOpacity = 1.0
    @State private var showsAlternateCore = false

    private var motionSignature: Int {
        switch motion {
        case .steppedFill: return 1
        case .easedDip: return 2
        case .binaryFlash: return 3
        case nil: return 0
        }
    }

    var body: some View {
        let size = TabActivityMarkMetrics.visibleSize(for: state)
        markShape
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .onAppear { refreshClockSubscription() }
            .onChange(of: motionSignature) { _, _ in refreshClockSubscription() }
            .onChange(of: phaseId) { _, _ in refreshClockSubscription() }
            .onDisappear { unsubscribeFromClock() }
    }

    @ViewBuilder
    private var markShape: some View {
        switch state {
        case .running:
            ZStack {
                Rectangle()
                    .fill(color.opacity(0.25))
                    .frame(
                        width: TabActivityMarkMetrics.cellSide,
                        height: TabActivityMarkMetrics.cellSide
                    )
                VStack(spacing: TabActivityMarkMetrics.workingDotSpacing) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: TabActivityMarkMetrics.workingDotSpacing) {
                            ForEach(0..<3, id: \.self) { column in
                                let rank = (2 - row) * 3 + column
                                Rectangle()
                                    .fill(color)
                                    .frame(
                                        width: TabActivityMarkMetrics.workingDotSide,
                                        height: TabActivityMarkMetrics.workingDotSide
                                    )
                                    .opacity(rank < visibleWorkingDots ? 1 : 0)
                            }
                        }
                    }
                }
            }
            .frame(
                width: TabActivityMarkMetrics.cellSide,
                height: TabActivityMarkMetrics.cellSide
            )

        case .waiting:
            ZStack {
                Rectangle()
                    .strokeBorder(
                        color,
                        lineWidth: TabActivityMarkMetrics.waitingFrameThickness
                    )
                Rectangle()
                    .fill(color)
                    .frame(
                        width: TabActivityMarkMetrics.waitingCoreSide,
                        height: TabActivityMarkMetrics.waitingCoreSide
                    )
                    .opacity(motion == .binaryFlash ? 1 : waitingCoreOpacity)
                if let alternateCoreColor {
                    Rectangle()
                        .fill(alternateCoreColor)
                        .frame(
                            width: TabActivityMarkMetrics.waitingCoreSide,
                            height: TabActivityMarkMetrics.waitingCoreSide
                        )
                        .opacity(showsAlternateCore ? 1 : 0)
                }
            }
            .frame(
                width: TabActivityMarkMetrics.cellSide,
                height: TabActivityMarkMetrics.cellSide
            )

        case .idle:
            Rectangle()
                .strokeBorder(color, lineWidth: 1)
                .frame(
                    width: TabActivityMarkMetrics.cellSide,
                    height: TabActivityMarkMetrics.cellSide
                )

        case .cold:
            Rectangle()
                .fill(color)
                .frame(
                    width: TabActivityMarkMetrics.cellSide,
                    height: TabActivityMarkMetrics.coldLineThickness
                )
        }
    }

    private func refreshClockSubscription() {
        unsubscribeFromClock()
        guard let motion else {
            resetToStaticState()
            return
        }
        clockToken = BonsplitActivityAnimationClock.shared.subscribe { elapsed in
            apply(elapsed: elapsed, motion: motion)
        }
    }

    private func unsubscribeFromClock() {
        guard let clockToken else { return }
        BonsplitActivityAnimationClock.shared.unsubscribe(clockToken)
        self.clockToken = nil
    }

    private func resetToStaticState() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleWorkingDots = 9
            waitingCoreOpacity = 1
            showsAlternateCore = false
        }
    }

    private func apply(elapsed: TimeInterval, motion: BonsplitActivityMarkMotion) {
        switch motion {
        case .steppedFill:
            let dots = BonsplitActivityMarkAnimation.visibleWorkingDots(
                at: elapsed,
                id: phaseId
            )
            guard dots != visibleWorkingDots else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visibleWorkingDots = dots
            }

        case .easedDip:
            let opacity = BonsplitActivityMarkAnimation.waitingCoreOpacity(
                at: elapsed,
                id: phaseId
            )
            withAnimation(.linear(duration: BonsplitActivityMarkAnimation.clockInterval)) {
                waitingCoreOpacity = opacity
            }

        case .binaryFlash:
            let showsAlternate = BonsplitActivityMarkAnimation.binaryFlashShowsAlternate(
                at: elapsed,
                id: phaseId
            )
            guard showsAlternate != showsAlternateCore else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                showsAlternateCore = showsAlternate
            }
        }
    }
}

/// Individual tab view with icon, title, close button, and dirty indicator
struct TabItemView: View {
    @Environment(\.bonsplitActivityAnimationEnabled)
    private var activityAnimationEnabled

    let tab: TabItem
    let isSelected: Bool
    let showsZoomIndicator: Bool
    let appearance: BonsplitConfiguration.Appearance
    let saturation: Double
    let controlShortcutDigit: Int?
    let showsControlShortcutHint: Bool
    let shortcutModifierSymbol: String
    let contextMenuState: TabContextMenuState
    /// Right edge of the actually visible tab-scroll content. Activity motion
    /// registers only while this mark intersects the unobscured interval.
    let activityAnimationVisibleRightEdge: CGFloat
    /// Render the always-visible close X on the trailing edge of the tab,
    /// and collapse the right-click menu to Close Tab / Close Pane.
    /// Hosts that want the legacy hover-trailing X + full menu leave this
    /// off (default behaviour for new embedders).
    let useSimplifiedTabUX: Bool
    /// Monotonic flash generation for this tab. Non-zero only on the tab a
    /// flash request is currently targeting; bumping this value plays a
    /// single pulse on the tab. Selection is unaffected.
    let flashGeneration: Int
    let onSelect: () -> Void
    let onClose: () -> Void
    let onZoomToggle: () -> Void
    let onContextAction: (TabContextAction) -> Void
    let onSetTabColor: (String) -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var isZoomHovered = false
    @State private var flashOpacity: Double = 0
    @State private var lastObservedFlashGeneration: Int = 0
    @State private var showGlobeFallback = true
    @State private var globeFallbackWorkItem: DispatchWorkItem?
    @State private var lastIsLoadingObserved = false
    @State private var lastLoadingStoppedAt: Date?
    @State private var renderedFaviconData: Data?
    @State private var renderedFaviconImage: NSImage?
    @State private var isActivityMarkVisible = false
    @AppStorage(TabControlShortcutHintDebugSettings.xKey) private var controlShortcutHintXOffset = TabControlShortcutHintDebugSettings.defaultX
    @AppStorage(TabControlShortcutHintDebugSettings.yKey) private var controlShortcutHintYOffset = TabControlShortcutHintDebugSettings.defaultY
    @AppStorage(TabControlShortcutHintDebugSettings.alwaysShowKey) private var alwaysShowShortcutHints = TabControlShortcutHintDebugSettings.defaultAlwaysShow

    var body: some View {
        accessibleTabContent
    }

    private var laidOutTabContent: some View {
        tabContent
            .padding(.leading, useSimplifiedTabUX ? 0 : appearance.tabHorizontalPadding)
            .padding(.trailing, useSimplifiedTabUX ? SimplifiedTabGeometry.closeTrailingInset : appearance.tabHorizontalPadding)
            .offset(y: isSelected ? 0.5 : 0)
            .frame(
                minWidth: tabWidthRange.lowerBound,
                maxWidth: tabWidthRange.upperBound,
                minHeight: appearance.tabItemHeight,
                maxHeight: appearance.tabItemHeight
            )
            .padding(.bottom, isSelected ? 1 : 0)
            .background(tabBackground.saturation(saturation))
            .overlay {
                Rectangle()
                    .fill(TabBarColors.activeIndicator(for: appearance).opacity(flashOpacity))
                    .allowsHitTesting(false)
            }
    }

    private var interactiveTabContent: some View {
        laidOutTabContent
            .onChange(of: flashGeneration) { _, newValue in
                guard newValue > 0, newValue != lastObservedFlashGeneration else { return }
                lastObservedFlashGeneration = newValue
                runFlashAnimation(generation: newValue)
            }
            .animation(.easeInOut(duration: 0.14), value: showsShortcutHint)
            .contentShape(Rectangle())
            .background(MiddleClickMonitorView(onMiddleClick: {
                guard !tab.isPinned else { return }
                onClose()
            }))
            .onTapGesture {
                onSelect()
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .contextMenu {
                contextMenuContent
            }
    }

    private var accessibleTabContent: some View {
        interactiveTabContent
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(activityAccessibilityHelp)
            .accessibilityAddTraits(accessibilityTraits)
    }

    private var tabContent: some View {
        HStack(spacing: 0) {
            if useSimplifiedTabUX {
                leadingActivityAccessory
            }
            // Icon + title block uses the standard spacing, but keep the close affordance tight.
            HStack(spacing: appearance.tabContentSpacing) {
                let iconSlotSize = appearance.tabIconSize
                let iconTint = isSelected
                    ? TabBarColors.activeText(for: appearance)
                    : TabBarColors.inactiveText(for: appearance)
                let faviconImage = renderedFaviconImage ?? tab.iconImageData.flatMap { NSImage(data: $0) }

                // Simplified tabs reserve the leading slot for host activity
                // state instead of per-surface glyphs and favicons.
                if !useSimplifiedTabUX {
                    Group {
                        if tab.isLoading {
                            // Slightly smaller than the icon slot so it reads cleaner at tab scale.
                            TabLoadingSpinner(size: iconSlotSize * 0.86, color: iconTint)
                        } else if let image = faviconImage {
                            FaviconIconView(image: image)
                                .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                                .clipped()
                        } else if let iconName = tab.icon {
                            if iconName == "globe", !showGlobeFallback {
                                // Avoid a distracting "globe -> favicon" flash: show a neutral placeholder
                                // briefly while the favicon fetch finishes. If no favicon arrives, we
                                // reveal the globe after a short delay.
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(iconTint.opacity(0.25), lineWidth: 1)
                            } else {
                                Image(systemName: iconName)
                                    .font(.system(size: glyphSize(for: iconName)))
                                    .foregroundStyle(iconTint)
                            }
                        }
                    }
                    // Keep downloaded favicon bitmaps in full color even for inactive tab bars.
                    .saturation(TabItemStyling.iconSaturation(hasRasterIcon: faviconImage != nil, tabSaturation: saturation))
                    .transaction { tx in
                        // Prevent incidental parent animations from briefly fading icon content.
                        tx.animation = nil
                    }
                    .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                    .onAppear {
                        updateRenderedFaviconImage()
                        updateGlobeFallback()
                    }
                    .onDisappear {
                        globeFallbackWorkItem?.cancel()
                        globeFallbackWorkItem = nil
                    }
                    .onChange(of: tab.isLoading) { _ in updateGlobeFallback() }
                    .onChange(of: tab.iconImageData) { _ in
                        updateRenderedFaviconImage()
                        updateGlobeFallback()
                    }
                    .onChange(of: tab.icon) { _ in updateGlobeFallback() }
                }

                Text(tab.displayedTitle(showOrdinals: appearance.showTabOrdinals))
                    .font(.system(size: appearance.tabTitleFontSize, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .saturation(saturation)

                if showsZoomIndicator {
                    Button {
                        onZoomToggle()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: accessoryFontSize, weight: .semibold))
                            .foregroundStyle(
                                isZoomHovered
                                    ? TabBarColors.activeText(for: appearance)
                                    : TabBarColors.inactiveText(for: appearance)
                            )
                            .frame(width: accessorySlotSize, height: accessorySlotSize)
                            .background(
                                Circle()
                                    .fill(
                                        isZoomHovered
                                            ? TabBarColors.hoveredTabBackground(for: appearance)
                                            : .clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isZoomHovered = hovering
                    }
                    .saturation(saturation)
                    .accessibilityLabel("Exit zoom")
                }
            }

            Spacer(minLength: 0)

            if useSimplifiedTabUX {
                simplifiedTrailingAccessory
            } else {
                trailingAccessory
            }
        }
    }

    private var tabWidthRange: ClosedRange<CGFloat> {
        TabItemStyling.widthRange(for: appearance)
    }

    private var accessibilityTraits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : .isButton
    }

    private func runFlashAnimation(generation: Int) {
        // Reset to the envelope's first value so the animation starts clean
        // even if a prior flash was mid-flight.
        flashOpacity = TabFlashPattern.values.first ?? 0
        for segment in TabFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                // Bail if a newer flash superseded this run (the most recent
                // generation owns the animation).
                guard generation == lastObservedFlashGeneration else { return }
                let animation: Animation
                switch segment.curve {
                case .easeIn:
                    animation = .easeIn(duration: segment.duration)
                case .easeOut:
                    animation = .easeOut(duration: segment.duration)
                }
                withAnimation(animation) {
                    flashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func glyphSize(for iconName: String) -> CGFloat {
        // `terminal.fill` reads visually heavier than most symbols at the same point size.
        // The -2.5 offset preserves the cross-glyph balance that the original
        // hard-coded sizes encoded; the appearance.tabIconSize knob makes both
        // sides scale together when chrome scale changes.
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return max(10, appearance.tabIconSize - 2.5)
        }
        return appearance.tabIconSize
    }

    private var shortcutHintLabel: String? {
        guard let controlShortcutDigit else { return nil }
        return "\(shortcutModifierSymbol)\(controlShortcutDigit)"
    }

    private var showsShortcutHint: Bool {
        (showsControlShortcutHint || alwaysShowShortcutHints) && shortcutHintLabel != nil
    }

    private var shortcutHintSlotWidth: CGFloat {
        guard let label = shortcutHintLabel else {
            return accessorySlotSize
        }
        let positiveDebugInset = max(0, CGFloat(TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset))) + 2
        return max(accessorySlotSize, shortcutHintWidth(for: label) + positiveDebugInset)
    }

    private var accessoryFontSize: CGFloat {
        max(8, appearance.tabTitleFontSize - 2)
    }

    private var accessorySlotSize: CGFloat {
        // Outer cap is the per-tab item height (was a constant 30, capped close/zoom/shortcut at 30pt).
        // Inner floor is "close icon + breathing room" — the +7 preserves today's
        // 16pt slot at the 9pt default close-icon size (9+7=16, byte-exact with the
        // old TabBarMetrics.closeButtonSize).
        min(appearance.tabItemHeight, max(appearance.tabCloseIconSize + 7, ceil(accessoryFontSize + 4)))
    }

    private func shortcutHintWidth(for label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: accessoryFontSize, weight: .semibold)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 8
    }

    @ViewBuilder
    private var leadingActivityAccessory: some View {
        if let state = tab.activityState {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: TabActivityMarkMetrics.leadingEdgeInset(for: state))
                TabActivityMark(
                    state: state,
                    appearance: appearance,
                    phaseId: tab.id,
                    motion: TabActivityMarkMotionPolicy.defaultMotion(
                        for: state,
                        isEnabled: activityAnimationEnabled && isActivityMarkVisible
                    )
                )
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .named("tabScroll"))
                        Color.clear
                            .onAppear {
                                updateActivityMarkVisibility(frame: frame)
                            }
                            .onChange(of: frame) { _, newFrame in
                                updateActivityMarkVisibility(frame: newFrame)
                            }
                    }
                }
                Color.clear
                    .frame(width: TabActivityMarkMetrics.titleSpacing(for: state))
            }
            .frame(
                width: TabActivityMarkMetrics.leadingAccessoryWidth(for: state),
                height: appearance.tabItemHeight
            )
        } else {
            Color.clear
                .frame(
                    width: SimplifiedTabGeometry.unmarkedLeadingInset,
                    height: appearance.tabItemHeight
                )
        }
    }

    private func updateActivityMarkVisibility(frame: CGRect) {
        let isVisible = TabBarStyling.isActivityMarkVisible(
            frame: frame,
            visibleRightEdge: activityAnimationVisibleRightEdge
        )
        guard isVisible != isActivityMarkVisible else { return }
        isActivityMarkVisible = isVisible
    }

    @ViewBuilder
    private var simplifiedTrailingAccessory: some View {
        HStack(spacing: 0) {
            if let shortcutHintLabel, showsShortcutHint {
                Text(shortcutHintLabel)
                    .font(.system(size: accessoryFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.30), lineWidth: 0.8)
                            )
                    )
                    .allowsHitTesting(false)
            }

            ZStack(alignment: .topLeading) {
                if !tab.isPinned {
                    Button {
                        onClose()
                    } label: {
                        Text("×")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(
                                isCloseHovered
                                    ? TabBarColors.activeText(for: appearance)
                                    : TabBarColors.inactiveText(for: appearance).opacity(0.7)
                            )
                            .frame(
                                width: SimplifiedTabGeometry.closeHitSize.width,
                                height: SimplifiedTabGeometry.closeHitSize.height
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        isCloseHovered
                                            ? TabBarColors.hoveredTabBackground(for: appearance)
                                            : .clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isCloseHovered = hovering
                    }
                    .saturation(saturation)
                    .accessibilityLabel(localizedString("command.closeTab.title", default: "Close Tab"))
                }

                if tab.isDirty || (tab.showsNotificationBadge && tab.activityState != .waiting) {
                    HStack(spacing: 2) {
                        if tab.showsNotificationBadge && tab.activityState != .waiting {
                            Circle()
                                .fill(TabBarColors.notificationBadge(for: appearance))
                                .frame(width: appearance.tabNotificationBadgeSize, height: appearance.tabNotificationBadgeSize)
                        }
                        if tab.isDirty {
                            Circle()
                                .fill(TabBarColors.dirtyIndicator(for: appearance))
                                .frame(width: appearance.tabDirtyIndicatorSize, height: appearance.tabDirtyIndicatorSize)
                        }
                    }
                    .offset(x: -1, y: 1)
                    .allowsHitTesting(false)
                }
            }
            .frame(
                width: SimplifiedTabGeometry.closeHitSize.width,
                height: SimplifiedTabGeometry.closeHitSize.height
            )
        }
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        ZStack(alignment: .center) {
            if let shortcutHintLabel {
                Text(shortcutHintLabel)
                    .font(.system(size: accessoryFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.30), lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.22), radius: 2, x: 0, y: 1)
                    )
                    .offset(
                        x: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset),
                        y: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintYOffset)
                    )
                    .opacity(showsShortcutHint ? 1 : 0)
                    .allowsHitTesting(false)
            }

            closeOrDirtyIndicator
                .opacity(showsShortcutHint ? 0 : 1)
                .allowsHitTesting(!showsShortcutHint)
        }
        .frame(width: shortcutHintSlotWidth, height: accessorySlotSize, alignment: .center)
        .animation(.easeInOut(duration: 0.14), value: showsShortcutHint)
    }

    private func updateGlobeFallback() {
        // Track load transitions so we can avoid an "empty placeholder -> globe" flash on brand-new tabs.
        if lastIsLoadingObserved && !tab.isLoading {
            lastLoadingStoppedAt = Date()
        }
        lastIsLoadingObserved = tab.isLoading

        globeFallbackWorkItem?.cancel()
        globeFallbackWorkItem = nil

        // Only delay the globe fallback right after a navigation completes, when a favicon is likely to
        // arrive soon. Otherwise (e.g. a brand-new tab), show the globe immediately.
        let recentlyStoppedLoading: Bool = {
            guard let t = lastLoadingStoppedAt else { return false }
            return Date().timeIntervalSince(t) < 1.5
        }()
        let shouldDelayGlobe = (tab.icon == "globe") && (tab.iconImageData == nil) && !tab.isLoading && recentlyStoppedLoading
        if !shouldDelayGlobe {
            showGlobeFallback = true
            return
        }

        showGlobeFallback = false
        let work = DispatchWorkItem {
            showGlobeFallback = true
        }
        globeFallbackWorkItem = work
        // Give favicon fetches a little longer before showing the globe fallback to reduce brief flashes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90, execute: work)
    }

    private func updateRenderedFaviconImage() {
        guard renderedFaviconData != tab.iconImageData ||
                (renderedFaviconImage == nil && tab.iconImageData != nil) else { return }
        renderedFaviconData = tab.iconImageData
        renderedFaviconImage = TabItemStyling.resolvedFaviconImage(
            existing: renderedFaviconImage,
            incomingData: tab.iconImageData
        )
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let activityAccessibilityValue { parts.append(activityAccessibilityValue) }
        if tab.isLoading { parts.append("Loading") }
        if tab.isPinned { parts.append("Pinned") }
        if tab.showsNotificationBadge { parts.append("Unread") }
        if tab.isDirty { parts.append("Modified") }
        if showsZoomIndicator { parts.append("Zoomed") }
        return parts.joined(separator: ", ")
    }

    private var activityAccessibilityValue: String? {
        let value = TabActivityAccessibility.value(for: tab.activityState)
        return value.isEmpty ? nil : value
    }

    private var activityAccessibilityHelp: String {
        TabActivityAccessibility.help(for: tab.activityState)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if useSimplifiedTabUX {
            simplifiedContextMenuContent
        } else {
            legacyContextMenuContent
        }
    }

    /// C11-26: minimal right-click menu — Close Tab + Close Pane. The
    /// reduced surface trades feature breadth for clarity; rename, pin,
    /// reorder, etc. are still reachable through the command palette,
    /// keyboard, or direct gestures.
    @ViewBuilder
    private var simplifiedContextMenuContent: some View {
        contextButton(
            localizedString("command.surfaceDetails.title", default: "Surface Details"),
            action: .surfaceDetails
        )
        if let surfaceRef = contextMenuState.surfaceRef {
            contextButton(
                "\(localizedString("command.copySurfaceRef.prefix", default: "Copy")) \(surfaceRef)",
                action: .copySurfaceRef
            )
        }
        Divider()
        contextButton(
            localizedString("command.closeTab.title", default: "Close Tab"),
            action: .closeTab
        )
        contextButton(
            localizedString("command.closePane.title", default: "Close Pane"),
            action: .closePane
        )
    }

    @ViewBuilder
    private var legacyContextMenuContent: some View {
        contextButton("Surface Details", action: .surfaceDetails)
        if let surfaceRef = contextMenuState.surfaceRef {
            contextButton("Copy \(surfaceRef)", action: .copySurfaceRef)
        }
        Divider()
        contextButton("Rename Tab…", action: .rename)

        if contextMenuState.hasCustomTitle {
            contextButton("Remove Custom Tab Name", action: .clearName)
        }

        Divider()

        contextButton("Close Tabs to Left", action: .closeToLeft)
            .disabled(!contextMenuState.canCloseToLeft)

        contextButton("Close Tabs to Right", action: .closeToRight)
            .disabled(!contextMenuState.canCloseToRight)

        contextButton("Close Other Tabs", action: .closeOthers)
            .disabled(!contextMenuState.canCloseOthers)

        contextButton("Move Tab…", action: .move)

        if contextMenuState.isTerminal {
            localizedContextButton(
                "command.moveTabToLeftPane.title",
                defaultValue: "Move to Left Pane",
                action: .moveToLeftPane
            )
                .disabled(!contextMenuState.canMoveToLeftPane)

            localizedContextButton(
                "command.moveTabToRightPane.title",
                defaultValue: "Move to Right Pane",
                action: .moveToRightPane
            )
                .disabled(!contextMenuState.canMoveToRightPane)
        }

        Divider()

        contextButton("New Terminal Tab to Right", action: .newTerminalToRight)

        contextButton("New Browser Tab to Right", action: .newBrowserToRight)

        if contextMenuState.isBrowser {
            Divider()

            contextButton("Reload Tab", action: .reload)

            contextButton("Duplicate Tab", action: .duplicate)
        }

        Divider()

        if contextMenuState.hasSplits {
            contextButton(
                contextMenuState.isZoomed ? "Exit Zoom" : "Zoom Pane",
                action: .toggleZoom
            )
        }

        contextButton(
            contextMenuState.isPinned ? "Unpin Tab" : "Pin Tab",
            action: .togglePin
        )

        if contextMenuState.isUnread {
            contextButton("Mark Tab as Read", action: .markAsRead)
                .disabled(!contextMenuState.canMarkAsRead)
        } else {
            contextButton("Mark Tab as Unread", action: .markAsUnread)
                .disabled(!contextMenuState.canMarkAsUnread)
        }

        Divider()

        Menu(localizedString("command.tabColor.title", default: "Tab Color")) {
            if contextMenuState.hasCustomColor {
                Button(localizedString("command.tabColor.clearColor", default: "Clear Color")) {
                    onContextAction(.clearColor)
                }
            }

            Button(localizedString("command.tabColor.chooseCustom", default: "Choose Custom Color…")) {
                onContextAction(.chooseCustomColor)
            }

            if !contextMenuState.tabColorPalette.isEmpty {
                Divider()
                ForEach(contextMenuState.tabColorPalette) { entry in
                    Button {
                        onSetTabColor(entry.hex)
                    } label: {
                        Label {
                            Text(entry.label)
                        } icon: {
                            if let nsColor = NSColor(bonsplitHex: entry.hex) {
                                Image(nsImage: tabColorSwatchImage(forHex: entry.hex, nsColor: nsColor))
                            } else {
                                Image(systemName: "circle")
                            }
                        }
                    }
                }
            }
        }
    }

    private func localizedString(_ key: String, default value: String) -> String {
        Bundle.module.localizedString(forKey: key, value: value, table: nil)
    }

    private func tabColorSwatchImage(forHex hex: String, nsColor: NSColor) -> NSImage {
        // The SwiftUI Menu re-evaluates this view's body on selection, hover,
        // dirty-state, and notification updates. Without caching, every
        // re-render allocates N palette entries × NSImage(lockFocus/fill) per
        // tab — wasteful AppKit drawing on a hot UI path. Key by hex so custom
        // user-added palette entries are cached too. NSCache is thread-safe.
        let key = hex as NSString
        if let cached = tabColorSwatchCache.object(forKey: key) {
            return cached
        }
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        nsColor.setFill()
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        path.fill()
        image.unlockFocus()
        image.isTemplate = false
        tabColorSwatchCache.setObject(image, forKey: key)
        return image
    }

    @ViewBuilder
    private func contextButton(_ title: String, action: TabContextAction) -> some View {
        if let shortcut = contextMenuState.shortcuts[action] {
            Button(title) {
                onContextAction(action)
            }
            .keyboardShortcut(shortcut)
        } else {
            Button(title) {
                onContextAction(action)
            }
        }
    }

    @ViewBuilder
    private func localizedContextButton(
        _ titleKey: String,
        defaultValue: String,
        action: TabContextAction
    ) -> some View {
        contextButton(
            Bundle.module.localizedString(forKey: titleKey, value: defaultValue, table: nil),
            action: action
        )
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        ZStack(alignment: .top) {
            // Background fill (selected / hover)
            if isSelected {
                Rectangle()
                    .fill(TabBarColors.activeTabBackground(for: appearance))
            } else if TabItemStyling.shouldShowHoverBackground(isHovered: isHovered, isSelected: isSelected) {
                Rectangle()
                    .fill(TabBarColors.hoveredTabBackground(for: appearance))
            } else {
                Color.clear
            }

            // Top accent indicator. Selected tabs always render a rail; if
            // the tab carries a customColorHex it overrides the default
            // `activeIndicator` color. Unselected tabs render a rail only
            // when a customColorHex is set, so the accent acts as a calm
            // identity marker without dominating chrome.
            if let accentNSColor = customAccentNSColor() {
                Rectangle()
                    .fill(Color(nsColor: accentNSColor))
                    .frame(height: appearance.tabActiveIndicatorHeight)
                    .opacity(isSelected ? 1.0 : 0.85)
            } else if isSelected {
                Rectangle()
                    .fill(TabBarColors.activeIndicator(for: appearance))
                    .frame(height: appearance.tabActiveIndicatorHeight)
            }

            // Right border separator
            HStack {
                Spacer()
                Rectangle()
                    .fill(TabBarColors.separator(for: appearance))
                    .frame(width: 1)
            }
        }
    }

    private func customAccentNSColor() -> NSColor? {
        guard let hex = tab.customColorHex else { return nil }
        return NSColor(bonsplitHex: hex)
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            // Dirty indicator (shown when dirty and not hovering, hidden for selected tab)
            if (!isSelected && !isHovered && !isCloseHovered)
                && (tab.isDirty || (tab.showsNotificationBadge && tab.activityState != .waiting)) {
                HStack(spacing: 2) {
                    if tab.showsNotificationBadge && tab.activityState != .waiting {
                        Circle()
                            .fill(TabBarColors.notificationBadge(for: appearance))
                            .frame(width: appearance.tabNotificationBadgeSize, height: appearance.tabNotificationBadgeSize)
                    }
                    if tab.isDirty {
                        Circle()
                            .fill(TabBarColors.dirtyIndicator(for: appearance))
                            .frame(width: appearance.tabDirtyIndicatorSize, height: appearance.tabDirtyIndicatorSize)
                            .saturation(saturation)
                    }
                }
            }

            if tab.isPinned {
                if isSelected || isHovered || isCloseHovered
                    || (!tab.isDirty && (!tab.showsNotificationBadge || tab.activityState == .waiting)) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: appearance.tabCloseIconSize, weight: .semibold))
                        .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                        .frame(width: accessorySlotSize, height: accessorySlotSize)
                        .saturation(saturation)
                }
            } else if !useSimplifiedTabUX && (isSelected || isHovered || isCloseHovered) {
                // Close button (always visible on active tab, shown on hover for others).
                // Simplified tabs render their always-visible close X in the
                // dedicated trailing slot. Don't double up here.
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: appearance.tabCloseIconSize, weight: .semibold))
                        .foregroundStyle(
                            isCloseHovered
                                ? TabBarColors.activeText(for: appearance)
                                : TabBarColors.inactiveText(for: appearance)
                        )
                        .frame(width: accessorySlotSize, height: accessorySlotSize)
                        .background(
                            Circle()
                                .fill(
                                    isCloseHovered
                                        ? TabBarColors.hoveredTabBackground(for: appearance)
                                        : .clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
                .saturation(saturation)
            }
        }
        .frame(width: accessorySlotSize, height: accessorySlotSize)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }
}

private struct TabLoadingSpinner: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 0.9s per revolution feels a bit snappier at tab-icon scale.
            let angle = (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0

            ZStack {
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
        }
    }

    private var ringWidth: CGFloat {
        max(1.6, size * 0.14)
    }
}

private struct FaviconIconView: NSViewRepresentable {
    let image: NSImage

    final class ContainerView: NSView {
        let imageView = NSImageView(frame: .zero)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            imageView.animates = false
            imageView.contentTintColor = nil
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func layout() {
            super.layout()
            imageView.frame = bounds.integral
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        ContainerView(frame: .zero)
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        image.isTemplate = false
        if nsView.imageView.image !== image {
            nsView.imageView.image = image
        }
        nsView.imageView.contentTintColor = nil
    }
}

private struct MiddleClickMonitorView: NSViewRepresentable {
    let onMiddleClick: () -> Void

    final class Coordinator {
        var onMiddleClick: (() -> Void)?
        weak var view: NSView?
        var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view
        context.coordinator.onMiddleClick = onMiddleClick

        // Monitor only middle clicks so we don't break drag/reorder or normal selection.
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak coordinator] event in
            guard event.buttonNumber == 2 else { return event }
            guard let coordinator, let v = coordinator.view, let w = v.window else { return event }
            guard event.window === w else { return event }

            let p = v.convert(event.locationInWindow, from: nil)
            guard v.bounds.contains(p) else { return event }

            coordinator.onMiddleClick?()
            return nil // swallow so it doesn't also select the tab
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onMiddleClick = onMiddleClick
    }
}
