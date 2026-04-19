import SwiftUI

/// Main entry point for the Bonsplit library
///
/// Usage:
/// ```swift
/// struct MyApp: View {
///     @State private var controller = BonsplitController()
///
///     var body: some View {
///         BonsplitView(controller: controller) { tab, paneId in
///             MyContentView(for: tab)
///                 .onTapGesture { controller.focusPane(paneId) }
///         } emptyPane: { paneId in
///             Text("Empty pane")
///         }
///     }
/// }
/// ```
public struct BonsplitView<Content: View, EmptyContent: View, TrailingAccessory: View>: View {
    @Bindable private var controller: BonsplitController
    private let contentBuilder: (Tab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent
    private let trailingAccessoryBuilder: (PaneID, Double) -> TrailingAccessory

    /// Initialize with a controller, content builder, empty pane builder, and trailing accessory builder
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    ///   - trailingAccessory: A ViewBuilder closure that provides trailing tab-bar chrome. Receives the pane ID and chrome saturation.
    public init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent,
        @ViewBuilder trailingAccessory: @escaping (PaneID, Double) -> TrailingAccessory
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
        self.trailingAccessoryBuilder = trailingAccessory
    }

    public var body: some View {
        SplitViewContainer(
            contentBuilder: { tabItem, paneId in
                contentBuilder(Tab(from: tabItem), PaneID(id: paneId.id))
            },
            emptyPaneBuilder: { internalPaneId in
                emptyPaneBuilder(PaneID(id: internalPaneId.id))
            },
            trailingAccessoryBuilder: { internalPaneId, chromeSaturation in
                trailingAccessoryBuilder(PaneID(id: internalPaneId.id), chromeSaturation)
            },
            appearance: controller.configuration.appearance,
            showSplitButtons: controller.configuration.allowSplits && controller.configuration.appearance.showSplitButtons,
            contentViewLifecycle: controller.configuration.contentViewLifecycle,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            },
            enableAnimations: controller.configuration.appearance.enableAnimations,
            animationDuration: controller.configuration.appearance.animationDuration
        )
        .environment(controller)
        .environment(controller.internalController)
    }
}

// MARK: - Convenience initializer with default empty view

extension BonsplitView where TrailingAccessory == EmptyView {
    /// Initialize with a controller, content builder, and empty pane builder, using the built-in trailing chrome.
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    public init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.init(
            controller: controller,
            content: content,
            emptyPane: emptyPane,
            trailingAccessory: { _, _ in EmptyView() }
        )
    }
}

extension BonsplitView where EmptyContent == DefaultEmptyPaneView, TrailingAccessory == EmptyView {
    /// Initialize with a controller and content builder, using the default empty pane view
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    public init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content
    ) {
        self.init(
            controller: controller,
            content: content,
            emptyPane: { _ in DefaultEmptyPaneView() },
            trailingAccessory: { _, _ in EmptyView() }
        )
    }
}

/// Default view shown when a pane has no tabs
public struct DefaultEmptyPaneView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
