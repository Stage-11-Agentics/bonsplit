import SwiftUI

/// A CRT scanline overlay: a 1pt dark line every 3pt at `opacity`. Drawn over
/// chrome only (the host never lays it over terminal cells), never hit-tested,
/// and it takes no layout space of its own.
public struct BonsplitScanlines: View {
    public static let pitch: CGFloat = 3
    public static let lineHeight: CGFloat = 1

    let opacity: Double

    public init(opacity: Double) {
        self.opacity = opacity
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: Self.lineHeight))
                y += Self.pitch
            }
            context.fill(path, with: .color(.black.opacity(opacity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
