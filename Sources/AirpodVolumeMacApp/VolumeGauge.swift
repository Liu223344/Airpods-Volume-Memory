import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Draws the volume ring used by the app icon and the notification image, so
/// both read as the same thing: a gauge with the percentage in the middle.
enum VolumeGauge {
    enum Center {
        /// The app icon: a drawn percent sign, no font involved.
        case percentSign
        case percent(Int)
        case text(String)
    }

    struct Style {
        /// The macOS icon grid: a rounded square inset from the canvas with a soft shadow.
        var iconShape: Bool
        var fraction: Double
        var center: Center
        var colors: [CGColor]
    }

    static func color(for fraction: Double) -> [CGColor] {
        switch fraction {
        case ..<0.5: return [rgb(0x34, 0xC8, 0xFF), rgb(0x30, 0xD1, 0x58)]
        case ..<0.75: return [rgb(0xFF, 0xD6, 0x0A), rgb(0xFF, 0x9F, 0x0A)]
        default: return [rgb(0xFF, 0x9F, 0x0A), rgb(0xFF, 0x45, 0x3A)]
        }
    }

    static func notificationStyle(volume: Float?, muted: Bool) -> Style {
        let fraction = Double(min(max(volume ?? 0, 0), 1))
        let center: Center
        if muted {
            center = .text("静音")
        } else if volume != nil {
            center = .percent(Int((fraction * 100).rounded()))
        } else {
            center = .text("--")
        }
        let colors = muted || volume == nil
            ? [rgb(0x8E, 0x8E, 0x93), rgb(0x63, 0x63, 0x66)]
            : color(for: fraction)
        return Style(iconShape: false, fraction: muted ? 0 : fraction, center: center, colors: colors)
    }

    static let appIconStyle = Style(
        iconShape: true,
        fraction: 0.68,
        center: .percentSign,
        colors: [rgb(0x34, 0xC8, 0xFF), rgb(0x30, 0xD1, 0x58)]
    )

    static func image(size: Int, style: Style) -> CGImage? {
        let side = CGFloat(size)
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var plate = CGRect(x: 0, y: 0, width: side, height: side)
        if style.iconShape {
            // 824/1024 content area and ~22.5% corner radius, as in Apple's icon template.
            plate = plate.insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024)
            context.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.03,
                              color: CGColor(gray: 0, alpha: 0.35))
        }
        let platePath = CGPath(
            roundedRect: plate,
            cornerWidth: style.iconShape ? plate.width * 0.225 : 0,
            cornerHeight: style.iconShape ? plate.width * 0.225 : 0,
            transform: nil
        )
        context.addPath(platePath)
        context.setFillColor(rgb(0x12, 0x18, 0x26))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        context.saveGState()
        context.addPath(platePath)
        context.clip()
        drawGradient(context, colors: [rgb(0x2C, 0x36, 0x52), rgb(0x10, 0x14, 0x22)],
                     from: CGPoint(x: plate.midX, y: plate.maxY), to: CGPoint(x: plate.midX, y: plate.minY))
        context.restoreGState()

        let center = CGPoint(x: plate.midX, y: plate.midY - plate.height * 0.01)
        let radius = plate.width * 0.33
        let lineWidth = plate.width * 0.095
        // A 270° gauge open at the bottom, filled clockwise from the lower left.
        let start = CGFloat.pi * 1.25
        let sweep = CGFloat.pi * 1.5

        let track = CGMutablePath()
        track.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
        context.addPath(track)
        context.strokePath()

        if style.fraction > 0.001 {
            let value = CGMutablePath()
            value.addArc(center: center, radius: radius, startAngle: start,
                         endAngle: start - sweep * CGFloat(min(style.fraction, 1)), clockwise: true)
            context.saveGState()
            context.addPath(value.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1))
            context.clip()
            drawGradient(context, colors: style.colors,
                         from: CGPoint(x: center.x - radius, y: center.y - radius),
                         to: CGPoint(x: center.x + radius, y: center.y + radius))
            context.restoreGState()
        }

        switch style.center {
        case .percentSign:
            drawPercentSign(context, center: center, size: radius * 1.05)
        case .percent(let value):
            drawText(context, "\(value)", suffix: "%", center: center, size: radius * (value >= 100 ? 0.58 : 0.76))
        case .text(let text):
            drawText(context, text, suffix: nil, center: center, size: radius * (text.count > 2 ? 0.55 : 0.7))
        }
        return context.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func drawPercentSign(_ context: CGContext, center: CGPoint, size: CGFloat) {
        let ring = size * 0.2
        let stroke = size * 0.11
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(stroke)
        context.setLineCap(.round)
        context.strokeEllipse(in: CGRect(x: center.x - size * 0.42, y: center.y + size * 0.1,
                                         width: ring * 1.6, height: ring * 1.6))
        context.strokeEllipse(in: CGRect(x: center.x + size * 0.42 - ring * 1.6, y: center.y - size * 0.1 - ring * 1.6,
                                         width: ring * 1.6, height: ring * 1.6))
        context.move(to: CGPoint(x: center.x + size * 0.32, y: center.y + size * 0.44))
        context.addLine(to: CGPoint(x: center.x - size * 0.32, y: center.y - size * 0.44))
        context.strokePath()
    }

    private static func drawText(_ context: CGContext, _ text: String, suffix: String?, center: CGPoint, size: CGFloat) {
        func font(_ pointSize: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: pointSize, weight: weight)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? base
        }
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: font(size, .bold), .foregroundColor: NSColor.white
        ])
        if let suffix {
            string.append(NSAttributedString(string: suffix, attributes: [
                .font: font(size * 0.45, .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.75)
            ]))
        }
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(line, context)
    }

    private static func drawGradient(_ context: CGContext, colors: [CGColor], from: CGPoint, to: CGPoint) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors as CFArray, locations: nil) else { return }
        context.drawLinearGradient(gradient, start: from, end: to,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

/// A simple silhouette that stays readable at notification thumbnail size.
enum RestoreResultIcon {
    case success
    case failure

    private static let successImage = RestoreResultIcon.success.render()
    private static let failureImage = RestoreResultIcon.failure.render()

    var image: CGImage? {
        self == .success ? Self.successImage : Self.failureImage
    }

    private func render() -> CGImage? {
        let side = 128
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(self == .success
            ? CGColor(srgbRed: 0.02, green: 0.59, blue: 0.30, alpha: 1)
            : CGColor(srgbRed: 0.88, green: 0.09, blue: 0.20, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 3, y: 3, width: 122, height: 122),
                               cornerWidth: 26, cornerHeight: 26, transform: nil))
        context.fillPath()

        let shell = CGColor(srgbRed: 0.98, green: 0.98, blue: 0.96, alpha: 1)
        let tip = CGColor(srgbRed: 0.76, green: 0.78, blue: 0.76, alpha: 1)
        let opening = CGColor(srgbRed: 0.40, green: 0.43, blue: 0.42, alpha: 1)
        for (x, direction) in [(CGFloat(46), CGFloat(1)), (CGFloat(82), CGFloat(-1))] {
            context.saveGState()
            context.translateBy(x: x, y: 77)
            context.scaleBy(x: direction, y: 1)

            context.setFillColor(shell)
            context.addPath(CGPath(roundedRect: CGRect(x: -4, y: -41, width: 12, height: 40),
                                   cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            context.saveGState()
            context.rotate(by: -.pi / 6)
            context.fillEllipse(in: CGRect(x: -16, y: -13, width: 34, height: 30))
            context.restoreGState()

            context.setFillColor(opening)
            context.addPath(CGPath(roundedRect: CGRect(x: 3, y: 7, width: 10, height: 4),
                                   cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()

            context.saveGState()
            context.translateBy(x: -19, y: -4)
            context.rotate(by: -.pi / 5)
            context.setFillColor(tip)
            context.fillEllipse(in: CGRect(x: -9, y: -11, width: 19, height: 22))
            context.setStrokeColor(opening)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: CGRect(x: -5, y: -7, width: 10, height: 14))
            context.restoreGState()
            context.restoreGState()
        }
        return context.makeImage()
    }
}
