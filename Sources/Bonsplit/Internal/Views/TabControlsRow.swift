import SwiftUI

/// The tab bar's trailing controls (agent spawn, new terminal/browser/markdown,
/// split right/down, new tab, close pane) laid out as a row, for surfaces that
/// fold them away from the bar: the narrow-tier sheet and the rail.
struct TabControlsRow: View {
    let pane: PaneState
    let controller: BonsplitController
    let appearance: BonsplitConfiguration.Appearance
    let height: CGFloat
    /// Runs after each action (the sheet dismisses itself).
    var afterAction: () -> Void = {}
    /// How much room there is: one row, two rows, or the agent spawn button plus
    /// a menu holding the rest (the narrowest rail).
    enum Style { case oneLine, twoLines, menu }
    var style: Style = .oneLine

    var body: some View {
        if style == .menu {
            HStack(spacing: 4) {
                AgentSpawnButtonCluster(
                    controller: controller,
                    paneId: pane.id,
                    appearance: appearance,
                    afterAction: afterAction
                )
                overflowMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if style == .twoLines {
            VStack(spacing: 0) {
                HStack(spacing: 4) { creationGroup; Spacer(minLength: 0) }
                    .frame(height: height / 2)
                HStack(spacing: 4) { layoutGroup; Spacer(minLength: 0) }
                    .frame(height: height / 2)
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 4) {
                creationGroup
                Spacer(minLength: 8)
                layoutGroup
            }
            .padding(.horizontal, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var overflowMenu: some View {
        let tooltips = appearance.splitButtonTooltips
        let canClosePane = controller.allPaneIds.count > 1
            || controller.configuration.allowCloseLastPane
        return Menu {
            Button(tooltips.newTerminal) { controller.requestNewTab(kind: "terminal", inPane: pane.id); afterAction() }
            Button(tooltips.newBrowser) { controller.requestNewTab(kind: "browser", inPane: pane.id); afterAction() }
            Button(tooltips.newMarkdown) { controller.requestNewTab(kind: "markdown", inPane: pane.id); afterAction() }
            Divider()
            Button(tooltips.splitRight) { controller.splitPane(pane.id, orientation: .horizontal); afterAction() }
            Button(tooltips.splitDown) { controller.splitPane(pane.id, orientation: .vertical); afterAction() }
            Button(tooltips.newTab) { controller.requestNewTab(kind: "newTab", inPane: pane.id); afterAction() }
            Divider()
            Button(tooltips.closePane) { controller.requestClosePane(pane.id); afterAction() }
                .disabled(!canClosePane)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: appearance.splitToolbarButtonFrameSize, height: appearance.splitToolbarButtonFrameSize)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var creationGroup: some View {
        let tooltips = appearance.splitButtonTooltips
        AgentSpawnButtonCluster(
            controller: controller,
            paneId: pane.id,
            appearance: appearance,
            afterAction: afterAction
        )
        SplitToolbarButton(systemImage: "terminal", tooltip: tooltips.newTerminal, appearance: appearance) {
            controller.requestNewTab(kind: "terminal", inPane: pane.id)
            afterAction()
        }
        SplitToolbarButton(systemImage: "globe", tooltip: tooltips.newBrowser, appearance: appearance) {
            controller.requestNewTab(kind: "browser", inPane: pane.id)
            afterAction()
        }
        SplitToolbarButton(systemImage: "doc.text", tooltip: tooltips.newMarkdown, appearance: appearance) {
            controller.requestNewTab(kind: "markdown", inPane: pane.id)
            afterAction()
        }
    }

    @ViewBuilder
    private var layoutGroup: some View {
        let tooltips = appearance.splitButtonTooltips
        let canClosePane = controller.allPaneIds.count > 1
            || controller.configuration.allowCloseLastPane
        SplitToolbarButton(systemImage: "square.split.2x1", tooltip: tooltips.splitRight, appearance: appearance) {
            controller.splitPane(pane.id, orientation: .horizontal)
            afterAction()
        }
        SplitToolbarButton(systemImage: "square.split.1x2", tooltip: tooltips.splitDown, appearance: appearance) {
            controller.splitPane(pane.id, orientation: .vertical)
            afterAction()
        }
        SplitToolbarButton(systemImage: "plus", tooltip: tooltips.newTab, appearance: appearance) {
            controller.requestNewTab(kind: "newTab", inPane: pane.id)
            afterAction()
        }
        SplitToolbarButton(systemImage: "xmark", tooltip: tooltips.closePane, appearance: appearance, isEnabled: canClosePane) {
            controller.requestClosePane(pane.id)
            afterAction()
        }
    }
}
