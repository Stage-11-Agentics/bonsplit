import AppKit
import SwiftUI

/// Host-set identity marker for a tab: a glyph (usually one emoji, or
/// `sf:<symbol>` for an SF Symbol) and/or a color. The tab strip pins it just
/// left of the close X; the sheet and rail rows show it after the title.
///
/// - glyph + color: the glyph on a rounded badge tinted with the color
/// - glyph only: the bare glyph
/// - color only: a small colored dot
/// - neither: nothing, and no slot is laid out
struct TabBadgeView: View {
    let glyph: String?
    let colorHex: String?
    /// Side of the square slot the badge occupies (the tab's icon size).
    let size: CGFloat
    /// Ink for an untinted text or symbol glyph.
    let foreground: Color

    /// Longest prefix the badge renders. Keeps a stray long value from eating
    /// the title; one emoji is one character.
    static let maxRenderedCharacters = 4

    /// The glyph as rendered: trimmed, capped, nil when blank.
    static func renderedGlyph(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sf:") {
            // An unknown symbol would render an empty tinted box; show nothing.
            let name = String(trimmed.dropFirst(3))
            guard !name.isEmpty,
                  NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
            return trimmed
        }
        return String(trimmed.prefix(maxRenderedCharacters))
    }

    static func isVisible(glyph: String?, colorHex: String?) -> Bool {
        renderedGlyph(glyph) != nil || tint(colorHex) != nil
    }

    /// Laid-out width of the badge (0 when nothing renders). The tab bar's
    /// fold decision adds it to a tab's natural width.
    static func layoutWidth(glyph: String?, colorHex: String?, size: CGFloat) -> CGFloat {
        guard let glyph = renderedGlyph(glyph) else {
            return tint(colorHex) == nil ? 0 : size
        }
        if glyph.hasPrefix("sf:") { return size + (tint(colorHex) == nil ? 0 : 4) }
        let font = NSFont.systemFont(ofSize: max(8, size * 0.78), weight: .semibold)
        let text = ceil((glyph as NSString).size(withAttributes: [.font: font]).width)
        return max(size, text + (tint(colorHex) == nil ? 0 : 4))
    }

    /// Emoji keep full color in inactive panes, like raster favicons; symbol
    /// glyphs and the tint follow the tab's saturation.
    static func keepsFullColor(glyph: String?) -> Bool {
        guard let glyph = renderedGlyph(glyph) else { return false }
        return !glyph.hasPrefix("sf:")
    }

    private static func tint(_ hex: String?) -> Color? {
        hex.flatMap { NSColor(bonsplitHex: $0) }.map { Color(nsColor: $0) }
    }

    var body: some View {
        let tint = Self.tint(colorHex)
        if let glyph = Self.renderedGlyph(glyph) {
            glyphContent(glyph, onTint: tint != nil)
                .padding(.horizontal, tint == nil ? 0 : 2)
                .frame(minWidth: size, minHeight: size)
                .background {
                    if let tint {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tint)
                    }
                }
                .fixedSize()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        } else if let tint {
            Circle()
                .fill(tint)
                .frame(width: max(6, size * 0.5), height: max(6, size * 0.5))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func glyphContent(_ glyph: String, onTint: Bool) -> some View {
        let ink = onTint ? Color.white : foreground
        if glyph.hasPrefix("sf:") {
            Image(systemName: String(glyph.dropFirst(3)))
                .font(.system(size: max(8, size * 0.7), weight: .semibold))
                .foregroundStyle(ink)
        } else {
            Text(glyph)
                .font(.system(size: max(8, size * 0.78), weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(ink)
        }
    }
}
