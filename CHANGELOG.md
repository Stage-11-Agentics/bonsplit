# Changelog

All notable changes to Bonsplit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `BonsplitView` initializer parameter `trailingAccessory: (PaneID, Double) -> View` — host-provided trailing-edge accessory rendered inside the tab bar alongside the internal default chrome. The builder receives the pane ID and a `chromeSaturation` scalar (matching bonsplit's internal `tabBarSaturation`, including drag-source nuance).
- `@Environment(\.bonsplitTabBarHover)` — boolean value published by the tab bar indicating whether the pointer is currently over the tab-bar region. Consumers can read this from a `trailingAccessory` to replicate hover-fade behavior in minimal-mode presentations.

### Changed
- Trailing chrome width is now measured per-layout via a new `TrailingAccessoryWidthKey` / `SplitButtonsIntrinsicWidthKey` PreferenceKey pair. The static `TabBarStyling.splitButtonsBackdropWidth` constant becomes an initial-render fallback and will be removed in a future release.
- Backdrop frame sizing now includes the 24pt leading fade width in addition to the measured chrome width, eliminating the fade/backdrop misalignment that could allow bright tabs to bleed under the leftmost portion of the chrome row.
- Moved `splitButtonsBackdropWidth` from `TabBarStyling` (in `TabBarView.swift`) to `TabBarMetrics` (in `TabBarMetrics.swift`) to live alongside its sibling sizing constants.

### Fixed
- Tab close-X on the rightmost tab no longer gets intercepted by the trailing split-buttons cluster in standard mode. The reserved trailing inset (`TabBarMetrics.splitButtonsBackdropWidth`) was sized for an older 3-button row and overhung by ~61pt after the row grew to 6 buttons + a separator. Bumped to 184pt to cover the current ~175pt intrinsic width with 9pt headroom. (Stage 11 CMUX-22.)

### Preserved
- All existing `BonsplitView` initializers continue to compile and render identically. The new `trailingAccessory:` parameter is opt-in; callers that do not supply one receive the built-in `splitButtons` row exactly as today.

## [1.1.1] - 2025-01-29

### Fixed
- Fixed delegate notifications not being sent when closing tabs ([#2](https://github.com/almonk/bonsplit/issues/2))
  - Tabs now correctly communicate through `BonsplitController` for proper delegate callbacks

### Added
- New public method `closeTab(_ tabId: TabID, inPane paneId: PaneID) -> Bool` for efficient tab closing when pane is known

## [1.1.0] - 2025-01-26

### Added

#### Two-Way Synchronization API
- **Geometry Query**: Query pane layout with pixel coordinates for integration with external programs
  - `layoutSnapshot()` - Get flat list of pane geometries with pixel coordinates
  - `treeSnapshot()` - Get full tree structure for external consumption
  - `findSplit(_:)` - Check if a split exists by UUID

- **Programmatic Updates**: Control divider positions from external sources
  - `setDividerPosition(_:forSplit:fromExternal:)` - Set divider position with loop prevention
  - `setContainerFrame(_:)` - Update container frame when window moves/resizes

- **Geometry Notifications**: Receive callbacks when geometry changes
  - `didChangeGeometry` delegate callback - Notified when any pane geometry changes
  - `shouldNotifyDuringDrag` delegate callback - Opt-in to real-time notifications during divider drag

#### New Types
- `LayoutSnapshot` - Full tree snapshot with pixel coordinates and timestamp
- `PixelRect` - Pixel rectangle for external consumption (Codable, Sendable)
- `PaneGeometry` - Geometry for a single pane including frame and tab info
- `ExternalTreeNode` - Recursive tree representation (enum: pane or split)
- `ExternalPaneNode` - Pane node for external consumption
- `ExternalSplitNode` - Split node with orientation and divider position
- `ExternalTab` - Tab info for external consumption

#### Debug Tools
- Debug window in Example app for testing synchronization features

## [1.0.0] - Initial Release

### Added
- Tab bar with drag-and-drop reordering
- Horizontal and vertical split panes
- 120fps animations
- Configurable appearance and behavior
- Delegate callbacks for all tab and pane events
- Keyboard navigation between panes
- Content view lifecycle options (recreateOnSwitch, keepAllAlive)
- Configuration presets (default, singlePane, readOnly)
