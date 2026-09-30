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

    var body: some View {
        let tooltips = appearance.splitButtonTooltips
        let canClosePane = controller.allPaneIds.count > 1
            || controller.configuration.allowCloseLastPane
        HStack(spacing: 4) {
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

            Spacer(minLength: 8)

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
        .padding(.horizontal, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
