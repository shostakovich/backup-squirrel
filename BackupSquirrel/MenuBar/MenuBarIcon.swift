import AppKit

/// The squirrel is a custom SF Symbol (Regular-M template in the asset catalog), so it matches system glyphs.
@MainActor
enum MenuBarIcon {
    /// The size AppKit gives a symbol in a status item without configuration: the menu bar font's 13 pt.
    static let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .medium)
    /// Every state's image has this size, so the status item never changes width; the templates are laid out for it.
    static let pointSize = NSSize(width: 18, height: 17)
    /// The room the templates leave for a badge, top-down in points; whole points, so the ring stays sharp at 1x.
    static let badgeRect = CGRect(x: 10, y: 8, width: 8, height: 8)
    static let minimumProgress = 0.1
    /// The system dims a disabled status item; snapshots imitate it with this alpha.
    static let dimmedAlpha: CGFloat = 0.35

    private static let progressWidth: CGFloat = 2

    static func image(for state: MenuBarIconState) -> NSImage {
        let image: NSImage
        if case .running = state {
            image = NSImage(size: pointSize)
            for scale in [1.0, 2.0] {
                guard let cgImage = render(state, scale: scale) else { continue }
                let representation = NSBitmapImageRep(cgImage: cgImage)
                representation.size = pointSize
                image.addRepresentation(representation)
            }
            // The status bar centres images by their alignment rect; a symbol's is its cap-height band.
            image.alignmentRect = symbol(for: state).alignmentRect
        } else {
            image = symbol(for: state)
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(for: state)
        return image
    }

    static func render(_ state: MenuBarIconState, scale: CGFloat) -> CGImage? {
        guard let context = makeContext(size: pointSize, scale: scale) else { return nil }
        draw(symbol(for: state), in: context)
        if case .running(let fraction) = state {
            drawProgress(fraction, in: context, scale: scale)
        }
        return context.makeImage()
    }

    /// For snapshots that compare the squirrel with system symbols.
    static func render(_ image: NSImage, scale: CGFloat) -> CGImage? {
        guard let context = makeContext(size: image.size, scale: scale) else { return nil }
        draw(image, in: context)
        return context.makeImage()
    }

    static func accessibilityDescription(for state: MenuBarIconState) -> String {
        switch state {
        case .idle: "Backup-Squirrel"
        case .running: "Backup-Squirrel – Sicherung läuft"
        case .warning: "Backup-Squirrel – Warnung"
        case .error: "Backup-Squirrel – Fehler"
        case .notSetUp: "Backup-Squirrel – nicht eingerichtet"
        }
    }

    static func symbolName(for state: MenuBarIconState) -> String {
        switch state {
        case .idle, .notSetUp: "menubar.squirrel"
        case .running: "menubar.squirrel.cutout"
        case .warning: "menubar.squirrel.warning"
        case .error: "menubar.squirrel.error"
        }
    }

    private static func symbol(for state: MenuBarIconState) -> NSImage {
        NSImage(symbolName: symbolName(for: state), variableValue: 1)?.withSymbolConfiguration(configuration)
            ?? NSImage(size: pointSize)
    }

    private static func makeContext(size: NSSize, scale: CGFloat) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int((size.width * scale).rounded(.up)),
                height: Int((size.height * scale).rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private static func draw(_ image: NSImage, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Black only, as the HIG asks of menu bar icons: a hairline track and a heavier arc that share the outer edge.
    private static func drawProgress(_ fraction: Double?, in context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.translateBy(x: 0, y: pointSize.height)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(NSColor.black.cgColor)
        let trackWidth = max(1 / scale, 0.75)
        context.setLineWidth(trackWidth)
        context.strokeEllipse(in: badgeRect.insetBy(dx: trackWidth / 2, dy: trackWidth / 2))

        let visible = min(max(fraction ?? 0, minimumProgress), 1)
        let start = -CGFloat.pi / 2
        context.setLineWidth(progressWidth)
        context.addArc(
            center: CGPoint(x: badgeRect.midX, y: badgeRect.midY), radius: (badgeRect.width - progressWidth) / 2,
            startAngle: start, endAngle: start + 2 * .pi * visible, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }
}
