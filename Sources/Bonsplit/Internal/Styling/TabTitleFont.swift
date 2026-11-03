import AppKit
import SwiftUI

/// The tab title's type, from `Appearance.tabTextStyle`. With `.unset` every
/// function returns exactly what the strip drew before the style existed:
/// the system font at `tabTitleFontSize`, semibold when selected.
enum TabTitleFont {
    static func size(for appearance: BonsplitConfiguration.Appearance) -> CGFloat {
        appearance.tabTitleFontSize * (appearance.tabTextStyle.scale ?? 1)
    }

    /// The style's weight, else the view's own (`defaultWeight`).
    static func weight(for appearance: BonsplitConfiguration.Appearance, defaultWeight: Font.Weight) -> Font.Weight {
        appearance.tabTextStyle.weight?.fontWeight ?? defaultWeight
    }

    static func font(for appearance: BonsplitConfiguration.Appearance, selected: Bool) -> Font {
        font(for: appearance, defaultWeight: selected ? .semibold : .regular)
    }

    static func font(for appearance: BonsplitConfiguration.Appearance, defaultWeight: Font.Weight) -> Font {
        let size = size(for: appearance)
        let weight = weight(for: appearance, defaultWeight: defaultWeight)
        switch appearance.tabTextStyle.familyName {
        case nil, "system":
            return .system(size: size, weight: weight)
        case "system-mono":
            return .system(size: size, weight: weight, design: .monospaced)
        case "system-rounded":
            return .system(size: size, weight: weight, design: .rounded)
        case "system-serif":
            return .system(size: size, weight: weight, design: .serif)
        case let name?:
            return Font.custom(name, size: size).weight(weight)
        }
    }

    static func nsFont(for appearance: BonsplitConfiguration.Appearance, selected: Bool) -> NSFont {
        let weight = appearance.tabTextStyle.weight?.nsFontWeight ?? (selected ? .semibold : .regular)
        return nsFont(for: appearance, weight: weight)
    }

    static func nsFont(for appearance: BonsplitConfiguration.Appearance, weight: NSFont.Weight) -> NSFont {
        let size = size(for: appearance)
        func system(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        switch appearance.tabTextStyle.familyName {
        case nil, "system":
            return .systemFont(ofSize: size, weight: weight)
        case "system-mono":
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case "system-rounded":
            return system(.rounded)
        case "system-serif":
            return system(.serif)
        case let name?:
            let descriptor = NSFontDescriptor(fontAttributes: [.family: name])
                .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
    }

    /// Letter spacing in points, or nil when the style sets none (so an unset
    /// style never adds a `.tracking` modifier).
    static func tracking(for appearance: BonsplitConfiguration.Appearance) -> CGFloat? {
        appearance.tabTextStyle.trackingEm.map { $0 * size(for: appearance) }
    }

    /// The title as the style shows it.
    static func display(_ title: String, for appearance: BonsplitConfiguration.Appearance) -> String {
        appearance.tabTextStyle.uppercase ? title.uppercased() : title
    }

    /// A styled title `Text`: font, case and tracking from the style.
    static func text(_ title: String, for appearance: BonsplitConfiguration.Appearance, selected: Bool) -> Text {
        text(title, for: appearance, defaultWeight: selected ? .semibold : .regular)
    }

    static func text(_ title: String, for appearance: BonsplitConfiguration.Appearance, defaultWeight: Font.Weight) -> Text {
        let text = Text(display(title, for: appearance)).font(font(for: appearance, defaultWeight: defaultWeight))
        guard let tracking = tracking(for: appearance) else { return text }
        return text.tracking(tracking)
    }

    /// Width of the title as drawn, for the strip's fit decision.
    static func measuredWidth(_ title: String, for appearance: BonsplitConfiguration.Appearance, selected: Bool) -> CGFloat {
        let shown = display(title, for: appearance)
        var attributes: [NSAttributedString.Key: Any] = [.font: nsFont(for: appearance, selected: selected)]
        if let tracking = tracking(for: appearance) {
            attributes[.kern] = tracking
        }
        return ceil((shown as NSString).size(withAttributes: attributes).width)
    }
}
