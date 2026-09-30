import SwiftUI

/// Geometry of the SimpleToken mark (same shape as the app icon: thin outer ring + a thick ¾ arc running clockwise
/// from 6 o'clock to 3 o'clock + ticks). Proportions follow designs/logo/glyph-source.png; at small sizes line widths
/// have a floor and the ticks are dropped, so it stays crisp in the 16 pt menu bar.
public struct BrandMarkGeometry: Sendable {
    public let radius: CGFloat        // outer ring centreline radius
    public let ringWidth: CGFloat
    public let arcRadius: CGFloat     // thick arc centreline radius
    public let arcWidth: CGFloat
    public let showTicks: Bool
    public let tickInner: CGFloat
    public let tickOuter: CGFloat
    public let tickWidth: CGFloat

    /// Start and end of the thick arc (angles in flipped / SwiftUI coordinates: 0° at 3 o'clock, increasing clockwise): 6 o'clock → 3 o'clock
    public static let arcStart: Double = 90
    public static let arcEnd: Double = 360

    public init(size: CGFloat) {
        let outer = size / 2
        showTicks = size >= 40
        let ring = max(outer * 0.079, 1.1)
        ringWidth = ring
        radius = outer - ring / 2
        arcWidth = max(outer * 0.154, 1.9)
        arcRadius = showTicks ? outer * 0.63 : outer * 0.56
        tickInner = outer * 0.75
        tickOuter = outer * 0.86
        tickWidth = max(outer * 0.043, 0.8)
    }
}

/// The SimpleToken mark (for the UI; the menu bar draws the same geometry via MenuBarRenderer).
/// Faint ring, bright arc: fully bright while collecting, slightly dimmer when idle.
public struct BrandMark: View {
    public var size: CGFloat
    public var lit: Bool

    public init(size: CGFloat = 24, lit: Bool = true) {
        self.size = size
        self.lit = lit
    }

    public var body: some View {
        let g = BrandMarkGeometry(size: size)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: g.ringWidth)
                .frame(width: g.radius * 2, height: g.radius * 2)
            if g.showTicks {
                ForEach(0..<12, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: g.tickWidth, height: g.tickOuter - g.tickInner)
                        .offset(y: -(g.tickInner + g.tickOuter) / 2)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
            }
            // trim starts at 3 o'clock and runs clockwise: 0.25 = 6 o'clock, 1.0 = back at 3 o'clock
            Circle()
                .trim(from: BrandMarkGeometry.arcStart / 360, to: BrandMarkGeometry.arcEnd / 360)
                .stroke(Color.white.opacity(lit ? 1 : 0.78), style: StrokeStyle(lineWidth: g.arcWidth, lineCap: .round))
                .frame(width: g.arcRadius * 2, height: g.arcRadius * 2)
                .animation(.easeInOut(duration: 0.4), value: lit)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
