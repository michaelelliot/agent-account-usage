import AppKit

/// The menu bar glyph: the plush toy from the app icon hugging a gauge whose needle points at `percent`, or where the
/// artwork draws it when that's nil. A template image, drawn in the menu bar's own colour, unless `color` tints it.
enum MenuBarIcon {
    static func image(percent: Double?, color: NSColor?) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The shapes below are in the pixels of the 1254 px artwork the glyph was traced from, centred on (625, 660).
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: 0.0172, y: 0.0172)
            context.translateBy(x: -625, y: -660)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(in: context, percent: percent, color: (color ?? .black).cgColor)
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "SubSmasher"
        return image
    }

    /// System yellow on a dark menu bar, and a darker gold on a light one, where system yellow is too faint to see.
    static var yellow: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .systemYellow : NSColor(srgbRed: 0.8, green: 0.6, blue: 0, alpha: 1)
        }
    }

    private static func draw(in context: CGContext, percent: Double?, color: CGColor) {
        let center = CGPoint(x: 619, y: 964)
        func dome(radius: CGFloat, bottom: CGFloat, corner: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addArc(center: center, radius: radius, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            path.addArc(
                tangent1End: CGPoint(x: center.x + radius, y: bottom),
                tangent2End: CGPoint(x: center.x - radius, y: bottom), radius: corner)
            path.addArc(
                tangent1End: CGPoint(x: center.x - radius, y: bottom),
                tangent2End: CGPoint(x: center.x - radius, y: center.y), radius: corner)
            path.closeSubpath()
            return path
        }
        context.setFillColor(color)
        context.setStrokeColor(color)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 252, y: 228, width: 748, height: 430), cornerWidth: 130, cornerHeight: 130,
                transform: nil))
        context.addPath(dome(radius: 456, bottom: 1092, corner: 112))
        context.fillPath()

        // The gauge's face and the eyes are holes in the body.
        context.setBlendMode(.clear)
        context.addPath(dome(radius: 399, bottom: 1030, corner: 55))
        for x in [444.0, 735.0] {
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: x, y: 372, width: 76, height: 143), cornerWidth: 30, cornerHeight: 30,
                    transform: nil))
        }
        context.fillPath()
        context.setBlendMode(.normal)

        context.fillEllipse(in: CGRect(x: 163, y: 548, width: 204, height: 204))
        context.fillEllipse(in: CGRect(x: 883, y: 548, width: 204, height: 204))

        // The scale runs from 158.8° (0%) to 21.2° (100%), counting anticlockwise from the right.
        let start = 158.8, sweep = 137.6
        context.setLineCap(.round)
        context.setLineWidth(55)
        context.addArc(
            center: CGPoint(x: 619, y: 993), radius: 346, startAngle: -start * .pi / 180,
            endAngle: -(start - sweep) * .pi / 180, clockwise: false)
        context.strokePath()

        let pivot = CGPoint(x: 616, y: 955)
        let degrees = percent.map { start - sweep * min(max($0 / 100, 0), 1) } ?? 49.3
        let angle = -degrees * .pi / 180
        context.setLineWidth(52)
        context.move(to: pivot)
        context.addLine(to: CGPoint(x: pivot.x + 255 * cos(angle), y: pivot.y + 255 * sin(angle)))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: pivot.x - 68, y: pivot.y - 68, width: 136, height: 136))
    }
}
