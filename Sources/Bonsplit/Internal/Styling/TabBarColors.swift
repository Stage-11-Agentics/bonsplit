import SwiftUI
import AppKit

/// Native macOS colors for the tab bar
enum TabBarColors {
    private enum Constants {
        static let darkTextAlpha: CGFloat = 0.82
        static let darkSecondaryTextAlpha: CGFloat = 0.62
        static let lightTextAlpha: CGFloat = 0.82
        static let lightSecondaryTextAlpha: CGFloat = 0.68
    }

    private static func chromeBackgroundColor(
        for appearance: BonsplitConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.backgroundHex else { return nil }
        return NSColor(bonsplitHex: value)
    }

    private static func chromeBorderColor(
        for appearance: BonsplitConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.borderHex else { return nil }
        return NSColor(bonsplitHex: value)
    }

    private static func chromeActiveIndicatorColor(
        for appearance: BonsplitConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.activeIndicatorHex else { return nil }
        return NSColor(bonsplitHex: value)
    }

    private static func effectiveBackgroundColor(
        for appearance: BonsplitConfiguration.Appearance,
        fallback fallbackColor: NSColor
    ) -> NSColor {
        chromeBackgroundColor(for: appearance) ?? fallbackColor
    }

    private static func effectiveTextColor(
        for appearance: BonsplitConfiguration.Appearance,
        secondary: Bool
    ) -> NSColor {
        guard let custom = chromeBackgroundColor(for: appearance) else {
            return secondary ? .secondaryLabelColor : .labelColor
        }

        if custom.isBonsplitLightColor {
            let alpha = secondary ? Constants.darkSecondaryTextAlpha : Constants.darkTextAlpha
            return NSColor.black.withAlphaComponent(alpha)
        }

        let alpha = secondary ? Constants.lightSecondaryTextAlpha : Constants.lightTextAlpha
        return NSColor.white.withAlphaComponent(alpha)
    }

    static func paneBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveBackgroundColor(for: appearance, fallback: .textBackgroundColor))
    }

    static func nsColorPaneBackground(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        effectiveBackgroundColor(for: appearance, fallback: .textBackgroundColor)
    }

    // MARK: - Tab Bar Background

    static var barBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static func barBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveBackgroundColor(for: appearance, fallback: .windowBackgroundColor))
    }

    static var barMaterial: Material {
        .bar
    }

    // MARK: - Tab States

    static var activeTabBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static func activeTabBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        guard let custom = chromeBackgroundColor(for: appearance) else {
            return activeTabBackground
        }
        let adjusted = custom.isBonsplitLightColor
            ? custom.bonsplitDarken(by: 0.065)
            : custom.bonsplitLighten(by: 0.12)
        return Color(nsColor: adjusted)
    }

    static var hoveredTabBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    static func hoveredTabBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        guard let custom = chromeBackgroundColor(for: appearance) else {
            return hoveredTabBackground
        }
        let adjusted = custom.isBonsplitLightColor
            ? custom.bonsplitDarken(by: 0.03)
            : custom.bonsplitLighten(by: 0.07)
        return Color(nsColor: adjusted.withAlphaComponent(0.78))
    }

    static var inactiveTabBackground: Color {
        .clear
    }

    // MARK: - Text Colors

    static var activeText: Color {
        Color(nsColor: .labelColor)
    }

    static func activeText(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveTextColor(for: appearance, secondary: false))
    }

    static func nsColorActiveText(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        effectiveTextColor(for: appearance, secondary: false)
    }

    static var inactiveText: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static func inactiveText(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveTextColor(for: appearance, secondary: true))
    }

    static func nsColorInactiveText(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        effectiveTextColor(for: appearance, secondary: true)
    }

    static func splitActionIcon(for appearance: BonsplitConfiguration.Appearance, isPressed: Bool) -> Color {
        Color(nsColor: nsColorSplitActionIcon(for: appearance, isPressed: isPressed))
    }

    static func nsColorSplitActionIcon(
        for appearance: BonsplitConfiguration.Appearance,
        isPressed: Bool
    ) -> NSColor {
        isPressed ? nsColorActiveText(for: appearance) : nsColorInactiveText(for: appearance)
    }

    // MARK: - Borders & Indicators

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static func separator(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: nsColorSeparator(for: appearance))
    }

    static func nsColorSeparator(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        if let explicit = chromeBorderColor(for: appearance) {
            return explicit
        }

        guard let custom = chromeBackgroundColor(for: appearance) else {
            return .separatorColor
        }
        let alpha: CGFloat = custom.isBonsplitLightColor ? 0.26 : 0.36
        let tone = custom.isBonsplitLightColor
            ? custom.bonsplitDarken(by: 0.12)
            : custom.bonsplitLighten(by: 0.16)
        return tone.withAlphaComponent(alpha)
    }

    static func activeIndicator(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: nsColorActiveIndicator(for: appearance))
    }

    static func nsColorActiveIndicator(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        chromeActiveIndicatorColor(for: appearance) ?? .controlAccentColor
    }

    static var dropIndicator: Color {
        Color.accentColor
    }

    static func dropIndicator(for appearance: BonsplitConfiguration.Appearance) -> Color {
        _ = appearance
        return dropIndicator
    }

    static var focusRing: Color {
        Color.accentColor.opacity(0.5)
    }

    static var dirtyIndicator: Color {
        Color(nsColor: .labelColor).opacity(0.6)
    }

    static func dirtyIndicator(for appearance: BonsplitConfiguration.Appearance) -> Color {
        guard chromeBackgroundColor(for: appearance) != nil else { return dirtyIndicator }
        return activeText(for: appearance).opacity(0.72)
    }

    static var notificationBadge: Color {
        Color(nsColor: .systemBlue)
    }

    static func notificationBadge(for appearance: BonsplitConfiguration.Appearance) -> Color {
        _ = appearance
        return notificationBadge
    }

    static func activity(
        _ state: BonsplitTabActivityState,
        for appearance: BonsplitConfiguration.Appearance
    ) -> Color {
        let colors = appearance.tabActivityColors
        let override: String?
        let fallback: NSColor
        switch state {
        case .running:
            override = colors.runningHex
            fallback = .systemBlue
        case .idle:
            override = colors.idleHex
            fallback = .systemGreen
        case .cold:
            override = colors.coldHex
            fallback = .secondaryLabelColor
        case .waiting:
            override = colors.waitingHex
            fallback = .systemYellow
        }
        return Color(nsColor: override.flatMap { NSColor(bonsplitHex: $0) } ?? fallback)
    }

    static func waitingInk(for appearance: BonsplitConfiguration.Appearance) -> Color {
        let colors = appearance.tabActivityColors
        if let override = colors.waitingInkHex.flatMap({ NSColor(bonsplitHex: $0) }) {
            return Color(nsColor: override)
        }
        let background = colors.waitingHex.flatMap { NSColor(bonsplitHex: $0) } ?? .systemYellow
        return Color(nsColor: background.isBonsplitLightColor ? .black : .white)
    }

    // MARK: - Tab sheet

    /// The sheet, the collapsed header block and the count cell share one
    /// palette: the highest-contrast surface on the bar. Dark themes get a
    /// near-black family, light themes the equivalent near-white family.
    /// Follows the c11 theme slot: a custom chrome background decides by its
    /// luminance; otherwise the panel's appearance decides.
    struct SheetPalette {
        let background: Color
        let rowHover: Color
        let rowActive: Color
        let header: Color
        let separator: Color
        let border: Color
        let block: Color
        let blockHover: Color
        let countCell: Color
        let text: Color
        let dimText: Color
        let faintText: Color
        let dash: Color
        let chipFill: Color
        let chipBorder: Color
        let chipText: Color
    }

    private static let paletteCacheLock = NSLock()
    nonisolated(unsafe) private static var paletteCache: [String: SheetPalette] = [:]

    /// One palette per chrome background (or per system appearance when there is
    /// none). Cached so a sheet body evaluates against stable colors instead of
    /// rebuilding dynamic NSColors for every row and cell.
    static func sheetPalette(for appearance: BonsplitConfiguration.Appearance) -> SheetPalette {
        let key = appearance.chromeColors.backgroundHex?.lowercased() ?? ""
        paletteCacheLock.lock()
        defer { paletteCacheLock.unlock() }
        if let cached = paletteCache[key] { return cached }
        let built = buildSheetPalette(for: appearance)
        paletteCache[key] = built
        return built
    }

    private static func buildSheetPalette(for appearance: BonsplitConfiguration.Appearance) -> SheetPalette {
        let forced: Bool? = chromeBackgroundColor(for: appearance).map { !$0.isBonsplitLightColor }
        func pick(_ dark: UInt32, _ light: UInt32) -> Color {
            if let forced { return Color(nsColor: hex(forced ? dark : light)) }
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return hex(isDark ? dark : light)
            })
        }
        return SheetPalette(
            background: pick(0x0e0f12, 0xffffff),
            rowHover: pick(0x1b1d22, 0xeef0f4),
            rowActive: pick(0x17181c, 0xf4f5f8),
            header: pick(0x0a0b0d, 0xf1f2f5),
            separator: pick(0x202227, 0xe2e4e9),
            border: pick(0x3a3c44, 0xc3c6ce),
            block: pick(0x111215, 0xfbfbfc),
            blockHover: pick(0x1a1b1f, 0xeef0f4),
            countCell: pick(0x07080a, 0xffffff),
            text: pick(0xe8e8ea, 0x16171b),
            dimText: pick(0x9a9ca3, 0x55585f),
            faintText: pick(0x6f727a, 0x7d8088),
            dash: pick(0x4b4e56, 0xb9bcc3),
            chipFill: pick(0x1d1f24, 0xeceef2),
            chipBorder: pick(0x33353c, 0xd3d6dc),
            chipText: pick(0xb9bbc2, 0x3c3f46)
        )
    }

    // MARK: Readable ink

    /// `base` as text on the sheet: unchanged on a dark sheet, and on a light
    /// one darkened until it reaches 4.5:1 against the sheet background.
    static func readableInk(_ base: NSColor, for appearance: BonsplitConfiguration.Appearance) -> Color {
        let deep = inkDeepened(base, against: NSColor.white, minRatio: 4.5)
        if let custom = chromeBackgroundColor(for: appearance) {
            return Color(nsColor: custom.isBonsplitLightColor ? deep : base)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? base : deep
        })
    }

    static func inkDeepened(_ base: NSColor, against background: NSColor, minRatio: CGFloat) -> NSColor {
        var ink = base
        var steps = 0
        while contrastRatio(ink, background) < minRatio, steps < 40 {
            ink = ink.bonsplitDarken(by: 0.02)
            steps += 1
        }
        return ink
    }

    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: - Shadows

    static var tabShadow: Color {
        Color.black.opacity(0.08)
    }
}

extension NSColor {
    private static let bonsplitHexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    convenience init?(bonsplitHex value: String) {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        guard hex.unicodeScalars.allSatisfy({ Self.bonsplitHexDigits.contains($0) }) else { return nil }
        guard let rgba = UInt64(hex, radix: 16) else { return nil }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if hex.count == 8 {
            red = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
            green = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
            blue = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
            alpha = CGFloat(rgba & 0x000000FF) / 255.0
        } else {
            red = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
            green = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
            blue = CGFloat(rgba & 0x0000FF) / 255.0
            alpha = 1.0
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    var isBonsplitLightColor: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.5
    }

    func bonsplitLighten(by amount: CGFloat) -> NSColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(
            red: min(1.0, red + amount),
            green: min(1.0, green + amount),
            blue: min(1.0, blue + amount),
            alpha: alpha
        )
    }

    func bonsplitDarken(by amount: CGFloat) -> NSColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(
            red: max(0.0, red - amount),
            green: max(0.0, green - amount),
            blue: max(0.0, blue - amount),
            alpha: alpha
        )
    }
}
