import SwiftUI

public extension View {
    /// Attaches a native SwiftUI tooltip via `.help`. Nil or whitespace-only
    /// text adds no tooltip.
    ///
    /// This used to host an AppKit `addToolTip` on a click-through background
    /// view (`hitTest` returning nil). macOS never queries an occluded view for
    /// its tooltip, so those tooltips silently never appeared. `.help` attaches
    /// the tooltip to the view itself, which is the only thing that works for an
    /// interactive control, and matches how the rest of the app shows tooltips.
    @ViewBuilder
    func safeHelp(_ text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.help(text)
        } else {
            self
        }
    }
}
