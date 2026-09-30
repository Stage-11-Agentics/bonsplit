# Changelog

All notable changes to Bonsplit will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- The tab sheet and rail show the lifecycle mark under the tab number (one column, the title moves left; a tab with no state keeps the space); the label has no space (`Tab17`); reordering rows inside the sheet keeps it open, and it closes only when a drag ends outside it.
- Round five, tabs stay visible: the strip scrolls sideways when tabs overflow (edge fades, a vertical wheel or two-finger scroll remaps to horizontal, the strip auto-scrolls while a tab is dragged near either end) and folds into the block only when under 150pt remain for tabs. The old medium tier is gone.
- The tab sheet is exactly its area's width (320pt minimum) with columns that drop by width tier (>=820 all, 600-819 one clock, 440-599 agent on line 2, <440 Tab N, mark, title, status). Hovering a row lights its tab in the strip and the reverse. Opens with a ~120ms single-axis unroll (transform/mask only), skipped under Reduce Motion.
- Horizontal tabs show their number (`TabItem.numberLabel`) in mono, gold on the visible tab, in place of the `N: ` prefix.
- `BonsplitTabLayout` (`tabs` | `rail`) on `Appearance.tabLayout`. In `rail` the count cell toggles a vertical tab list docked on the area's left edge (`railOpenPaneIds`, `setRailOpen`, `onRailToggled`, `restoreRailOpen`, `isTabDetailVisible`); it slides in inside its own slot.
- Count cell redesign: attention dot (slot always reserved), a bold 12x8 chevron, then the number, 64pt wide, in the bar's own colour family; gold only while open.
- Automation seams: `setTabStripScrollOffset`, `setLinkedHover(tabId:fromSheet:)`, `BonsplitDebug.tabSheetMotionScale`.
- `BonsplitTabDetail` (agent label, subtitle, status with duration, named clocks) on `Tab`/`TabItem`, set by the host through `updateTab(_:detail:)` and refreshed when the tab sheet opens via `BonsplitController.tabDetailProvider`. `BonsplitController.sheetClockOrderProvider` orders the sheet's clock columns.
- The tab sheet is a fixed grid: 46pt two-line rows, a header row, a footer (`N tabs`, `K need you`), fixed column widths, and a live relative-time refresh that only runs while the sheet is open.
- A count cell (`N ▾`) on every tab bar tier, pinned at the left of the full tier's trailing chrome and folded into the tier width math. In the full tier the sheet anchors its right edge to it.
- `BonsplitController.setTabSheetOpen(_:inPane:)` opens or closes a pane's sheet without a click (automation).
- `TabBarColors.sheetPalette(for:)`: near-black (near-white in light themes) surface family shared by the sheet, the collapsed header block and the count cell.
- `BonsplitConfiguration.Appearance.DividerStyle` — sibling struct on `Appearance` that carries optional overrides for pane divider rendering. Ships with `thicknessPt: CGFloat?`; when non-nil, `ThemedSplitView` overrides `NSSplitView.dividerThickness` so the visible divider thickness can be customized independently of the structural `.thin` hint (which is preserved for AppKit's hit-test region sizing). Additive: `Appearance.init` gains a `dividerStyle:` parameter with a default value, and all existing callers continue to render identically.
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
