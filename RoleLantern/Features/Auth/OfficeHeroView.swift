import SwiftUI

/// The website hero recreated natively: a pendant lamp switches on and its
/// beam illuminates a desk scene (laptop, chair, plants, skyline).
/// Design space is 310 x 300; everything scales off the actual width.
struct OfficeHeroView: View {
    @State private var lit = false

    // Palette sampled from the website artwork.
    private let mint = Color(hex: 0xE9F2F1)
    private let skyline = Color(hex: 0xD5E6E4)
    private let beamCream = Color(hex: 0xF7EFC6)
    private let lampNavy = Color(hex: 0x12212F)
    private let lampGold = Color(hex: 0xC9A23B)
    private let bulbWarm = Color(hex: 0xFFF6D9)
    private let deskWood = Color(hex: 0xDFA84E)
    private let deskTeal = Color(hex: 0x2C7D75)
    private let laptopTeal = Color(hex: 0x2C8C82)
    private let screenPale = Color(hex: 0xDFF0EC)
    private let chairMustard = Color(hex: 0xD9A441)
    private let chairDark = Color(hex: 0x8A6A2A)
    private let leafLight = Color(hex: 0xAFD6CC)
    private let leafMid = Color(hex: 0x9CCCC0)
    private let potTeal = Color(hex: 0x8FBFB4)

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 310

            ZStack(alignment: .topLeading) {
                mint

                // Skyline + plants (always visible, muted)
                Canvas { ctx, _ in
                    for r in [(18, 105, 52, 195), (228, 70, 46, 230), (264, 130, 34, 170), (70, 150, 38, 150)] {
                        ctx.fill(Path(CGRect(x: CGFloat(r.0) * s, y: CGFloat(r.1) * s,
                                             width: CGFloat(r.2) * s, height: CGFloat(r.3) * s)),
                                 with: .color(skyline))
                    }
                    drawPlant(ctx, s: s, baseX: 18, baseY: 258, flip: false)
                    drawPlant(ctx, s: s, baseX: 252, baseY: 254, flip: true)
                }

                // Beam (animated: grows from the lamp)
                BeamShape()
                    .fill(beamCream)
                    .opacity(lit ? 0.9 : 0)
                    .scaleEffect(y: lit ? 1 : 0.04, anchor: .top)
                    .frame(width: geo.size.width, height: geo.size.height)

                // Desk scene (brightens when the beam lands)
                Canvas { ctx, _ in
                    // Desk
                    ctx.fill(Path(roundedRect: CGRect(x: 106 * s, y: 230 * s, width: 98 * s, height: 9 * s), cornerRadius: 2 * s), with: .color(deskWood))
                    ctx.fill(Path(CGRect(x: 112 * s, y: 239 * s, width: 7 * s, height: 48 * s)), with: .color(deskTeal))
                    ctx.fill(Path(CGRect(x: 191 * s, y: 239 * s, width: 7 * s, height: 48 * s)), with: .color(deskTeal))
                    // Laptop
                    ctx.fill(Path(CGRect(x: 133 * s, y: 196 * s, width: 44 * s, height: 32 * s)), with: .color(laptopTeal))
                    ctx.fill(Path(CGRect(x: 137 * s, y: 200 * s, width: 36 * s, height: 24 * s)), with: .color(screenPale))
                    ctx.fill(Path(roundedRect: CGRect(x: 127 * s, y: 228 * s, width: 56 * s, height: 4 * s), cornerRadius: 2 * s), with: .color(Color(hex: 0x1F6B63)))
                    // Chair
                    ctx.fill(Path(roundedRect: CGRect(x: 206 * s, y: 206 * s, width: 34 * s, height: 46 * s), cornerRadius: 6 * s), with: .color(chairMustard))
                    ctx.fill(Path(roundedRect: CGRect(x: 206 * s, y: 248 * s, width: 42 * s, height: 8 * s), cornerRadius: 4 * s), with: .color(chairMustard))
                    ctx.fill(Path(CGRect(x: 222 * s, y: 256 * s, width: 7 * s, height: 22 * s)), with: .color(chairDark))
                    var base = Path()
                    base.move(to: CGPoint(x: 208 * s, y: 282 * s))
                    base.addLine(to: CGPoint(x: 244 * s, y: 282 * s))
                    ctx.stroke(base, with: .color(chairDark), style: StrokeStyle(lineWidth: 6 * s, lineCap: .round))
                }
                .opacity(lit ? 1 : 0.35)

                // Pendant lamp (drawn last, above the beam)
                Canvas { ctx, _ in
                    ctx.fill(Path(CGRect(x: 152 * s, y: 0, width: 6 * s, height: 16 * s)), with: .color(lampNavy))
                    var shade = Path()
                    shade.move(to: CGPoint(x: 123 * s, y: 14 * s))
                    shade.addLine(to: CGPoint(x: 187 * s, y: 14 * s))
                    shade.addLine(to: CGPoint(x: 195 * s, y: 38 * s))
                    shade.addLine(to: CGPoint(x: 115 * s, y: 38 * s))
                    shade.closeSubpath()
                    ctx.fill(shade, with: .color(lampNavy))
                    ctx.fill(Path(ellipseIn: CGRect(x: 115 * s, y: 28 * s, width: 80 * s, height: 20 * s)), with: .color(lampGold))
                }

                // Warm bulb glow
                Ellipse()
                    .fill(bulbWarm)
                    .frame(width: 60 * s, height: 14 * s)
                    .position(x: 155 * s, y: 38 * s)
                    .opacity(lit ? 1 : 0.35)
            }
            .clipped()
        }
        .aspectRatio(310.0 / 300.0, contentMode: .fit)
        .onAppear {
            guard !lit else { return }
            withAnimation(.easeOut(duration: 1.2).delay(0.4)) {
                lit = true
            }
        }
        .accessibilityHidden(true)
    }

    private func drawPlant(_ ctx: GraphicsContext, s: CGFloat, baseX: CGFloat, baseY: CGFloat, flip: Bool) {
        let x = baseX * s
        let y = baseY * s
        var leaf1 = Path()
        leaf1.move(to: CGPoint(x: x + 16 * s, y: y + 4 * s))
        leaf1.addCurve(to: CGPoint(x: x + 6 * s, y: y - 52 * s),
                       control1: CGPoint(x: x + 2 * s, y: y - 18 * s),
                       control2: CGPoint(x: x - 2 * s, y: y - 34 * s))
        leaf1.addCurve(to: CGPoint(x: x + 22 * s, y: y + 4 * s),
                       control1: CGPoint(x: x + 16 * s, y: y - 34 * s),
                       control2: CGPoint(x: x + 20 * s, y: y - 18 * s))
        leaf1.closeSubpath()
        ctx.fill(leaf1, with: .color(leafLight))

        var leaf2 = Path()
        leaf2.move(to: CGPoint(x: x + 26 * s, y: y + 4 * s))
        leaf2.addCurve(to: CGPoint(x: x + 36 * s, y: y - 44 * s),
                       control1: CGPoint(x: x + 32 * s, y: y - 16 * s),
                       control2: CGPoint(x: x + 40 * s, y: y - 26 * s))
        leaf2.addCurve(to: CGPoint(x: x + 20 * s, y: y + 4 * s),
                       control1: CGPoint(x: x + 24 * s, y: y - 28 * s),
                       control2: CGPoint(x: x + 20 * s, y: y - 12 * s))
        leaf2.closeSubpath()
        ctx.fill(leaf2, with: .color(leafMid))

        ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: 32 * s, height: 27 * s), cornerRadius: 3 * s),
                 with: .color(potTeal))
    }
}

/// The light cone from the pendant lamp down past the bottom edge.
struct BeamShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 310
        var p = Path()
        p.move(to: CGPoint(x: 155 * s, y: 42 * s))
        p.addLine(to: CGPoint(x: 62 * s, y: rect.height))
        p.addLine(to: CGPoint(x: 248 * s, y: rect.height))
        p.closeSubpath()
        return p
    }
}
