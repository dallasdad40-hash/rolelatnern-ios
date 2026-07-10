import SwiftUI

/// The lantern brand mark (matches the app icon), drawn natively so it scales
/// crisply for the splash screen and empty states.
struct LanternMark: View {
    var size: CGFloat = 96

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 1024
            let stroke = StrokeStyle(lineWidth: 30 * s, lineJoin: .round)

            // Ring handle
            let ring = Path(ellipseIn: CGRect(x: 460 * s, y: 214 * s, width: 104 * s, height: 104 * s))
            context.fill(ring, with: .color(.white))
            context.stroke(ring, with: .color(Brand.navy), style: StrokeStyle(lineWidth: 42 * s))

            // Domed cap
            var cap = Path()
            cap.move(to: CGPoint(x: 380 * s, y: 462 * s))
            cap.addCurve(to: CGPoint(x: 512 * s, y: 336 * s),
                         control1: CGPoint(x: 380 * s, y: 384 * s),
                         control2: CGPoint(x: 434 * s, y: 336 * s))
            cap.addCurve(to: CGPoint(x: 644 * s, y: 462 * s),
                         control1: CGPoint(x: 590 * s, y: 336 * s),
                         control2: CGPoint(x: 644 * s, y: 384 * s))
            cap.closeSubpath()
            context.fill(cap, with: .color(Brand.teal))
            context.stroke(cap, with: .color(Brand.navy), style: stroke)

            // Collar band
            let collar = Path(roundedRect: CGRect(x: 356 * s, y: 458 * s, width: 312 * s, height: 40 * s), cornerRadius: 16 * s)
            context.fill(collar, with: .color(Brand.teal))
            context.stroke(collar, with: .color(Brand.navy), style: StrokeStyle(lineWidth: 28 * s, lineJoin: .round))

            // Barrel body
            var barrel = Path()
            barrel.move(to: CGPoint(x: 398 * s, y: 498 * s))
            barrel.addCurve(to: CGPoint(x: 340 * s, y: 624 * s),
                            control1: CGPoint(x: 356 * s, y: 540 * s),
                            control2: CGPoint(x: 340 * s, y: 590 * s))
            barrel.addCurve(to: CGPoint(x: 424 * s, y: 752 * s),
                            control1: CGPoint(x: 340 * s, y: 686 * s),
                            control2: CGPoint(x: 374 * s, y: 740 * s))
            barrel.addLine(to: CGPoint(x: 600 * s, y: 752 * s))
            barrel.addCurve(to: CGPoint(x: 684 * s, y: 624 * s),
                            control1: CGPoint(x: 650 * s, y: 740 * s),
                            control2: CGPoint(x: 684 * s, y: 686 * s))
            barrel.addCurve(to: CGPoint(x: 626 * s, y: 498 * s),
                            control1: CGPoint(x: 684 * s, y: 590 * s),
                            control2: CGPoint(x: 668 * s, y: 540 * s))
            barrel.closeSubpath()
            context.fill(barrel, with: .color(Brand.cream))
            context.stroke(barrel, with: .color(Brand.navy), style: stroke)

            // Gold sun with rays
            let rays: [(CGPoint, CGPoint)] = [
                (CGPoint(x: 512, y: 508), CGPoint(x: 512, y: 546)),
                (CGPoint(x: 512, y: 694), CGPoint(x: 512, y: 732)),
                (CGPoint(x: 398, y: 620), CGPoint(x: 436, y: 620)),
                (CGPoint(x: 588, y: 620), CGPoint(x: 626, y: 620)),
                (CGPoint(x: 434, y: 542), CGPoint(x: 460, y: 568)),
                (CGPoint(x: 564, y: 672), CGPoint(x: 590, y: 698)),
                (CGPoint(x: 590, y: 542), CGPoint(x: 564, y: 568)),
                (CGPoint(x: 460, y: 672), CGPoint(x: 434, y: 698)),
            ]
            for (a, b) in rays {
                var ray = Path()
                ray.move(to: CGPoint(x: a.x * s, y: a.y * s))
                ray.addLine(to: CGPoint(x: b.x * s, y: b.y * s))
                context.stroke(ray, with: .color(Brand.gold), style: StrokeStyle(lineWidth: 28 * s, lineCap: .round))
            }
            let sun = Path(ellipseIn: CGRect(x: 454 * s, y: 562 * s, width: 116 * s, height: 116 * s))
            context.fill(sun, with: .color(Brand.gold))

            // Base: teal band + navy foot
            let band = Path(roundedRect: CGRect(x: 408 * s, y: 750 * s, width: 208 * s, height: 38 * s), cornerRadius: 14 * s)
            context.fill(band, with: .color(Brand.teal))
            context.stroke(band, with: .color(Brand.navy), style: StrokeStyle(lineWidth: 26 * s, lineJoin: .round))
            let foot = Path(roundedRect: CGRect(x: 376 * s, y: 786 * s, width: 272 * s, height: 44 * s), cornerRadius: 20 * s)
            context.fill(foot, with: .color(Brand.navy))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Lowercase wordmark: "role" in navy + "lantern" in teal.
struct Wordmark: View {
    var font: Font = .largeTitle.weight(.medium)
    var body: some View {
        (Text("role").foregroundColor(Brand.navy) + Text("lantern").foregroundColor(Brand.teal))
            .font(font)
    }
}
