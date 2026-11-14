import AppKit
import CoreGraphics

/// Renders the 教务直达 brand mark (circular #2F6FB5 plate + white stroked folded paper).
/// Geometry matches `pc/tools/make-app-icon.ps1` and `DESIGN.md` with optical simplification at small sizes.
enum AppIconDrawer {
    static let icnsPixelSizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]

    /// Draws the icon in a top-down coordinate space of `(0, 0, size, size)`.
    static func drawTopDown(in ctx: CGContext, size: CGFloat) {
        guard size > 0 else { return }
        ctx.saveGState()

        // Circular plate in #2F6FB5
        ctx.setFillColor(Theme.Colors.iconPlate.cgColor)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))

        // White stroke (unfilled), proportional with 1px minimum
        let stroke = max(size * 0.062, 1.0)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Optical simplification for <= 20px: expand paper slightly so strokes don't collapse
        let lean = size <= 20.0
        let l = size * (lean ? 0.22 : 0.26)
        let r = size * (lean ? 0.80 : 0.78)
        let t = size * (lean ? 0.15 : 0.18)
        let b = size * (lean ? 0.85 : 0.82)
        let foldX = l + (r - l) * 0.66
        let foldY = t + (b - t) * 0.28

        // Paper outline
        ctx.beginPath()
        ctx.move(to: CGPoint(x: l, y: t))
        ctx.addLine(to: CGPoint(x: foldX, y: t))
        ctx.addLine(to: CGPoint(x: r, y: foldY))
        ctx.addLine(to: CGPoint(x: r, y: b))
        ctx.addLine(to: CGPoint(x: l, y: b))
        ctx.closePath()
        ctx.strokePath()

        // Inner corner fold lines
        ctx.beginPath()
        ctx.move(to: CGPoint(x: foldX, y: t))
        ctx.addLine(to: CGPoint(x: foldX, y: foldY))
        ctx.addLine(to: CGPoint(x: r, y: foldY))
        ctx.strokePath()

        // Inner text lines only at >= 32px
        if size >= 32.0 {
            let lineX0 = l + (r - l) * 0.22
            let lineX1 = l + (r - l) * 0.80
            let lineX2 = l + (r - l) * 0.58
            let lineY0 = t + (b - t) * 0.60
            let lineY1 = t + (b - t) * 0.79

            ctx.beginPath()
            ctx.move(to: CGPoint(x: lineX0, y: lineY0))
            ctx.addLine(to: CGPoint(x: lineX1, y: lineY0))
            ctx.move(to: CGPoint(x: lineX0, y: lineY1))
            ctx.addLine(to: CGPoint(x: lineX2, y: lineY1))
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    /// Renders a crisp 1x bitmap representation at the exact pixel dimensions.
    static func renderBitmapRep(pixelSize: Int) -> NSBitmapImageRep? {
        guard pixelSize > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelSize,
                  pixelsHigh: pixelSize,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else {
            return nil
        }

        rep.size = NSSize(width: pixelSize, height: pixelSize)
        guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        let cg = nsContext.cgContext
        let s = CGFloat(pixelSize)
        cg.clear(CGRect(x: 0, y: 0, width: s, height: s))
        // Flip CG context to top-down coordinates
        cg.translateBy(x: 0, y: s)
        cg.scaleBy(x: 1, y: -1)
        drawTopDown(in: cg, size: s)
        NSGraphicsContext.restoreGraphicsState()

        return rep
    }

    /// Renders an `NSImage` at the requested pixel size.
    static func renderImage(pixelSize: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        if let rep = renderBitmapRep(pixelSize: pixelSize) {
            image.addRepresentation(rep)
        }
        return image
    }

    /// Encodes the icon at `pixelSize` as PNG data.
    static func renderPNGData(pixelSize: Int) -> Data? {
        renderBitmapRep(pixelSize: pixelSize)?.representation(using: .png, properties: [:])
    }

    /// Multi-representation `NSImage` suitable for `NSApp.applicationIconImage`.
    static func applicationIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        for size in icnsPixelSizes {
            if let rep = renderBitmapRep(pixelSize: size) {
                image.addRepresentation(rep)
            }
        }
        return image
    }

    /// Writes a standard `.iconset` directory containing all macOS `.icns` asset sizes.
    static func writeIconset(to iconsetURL: URL) throws {
        try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for (filename, px) in specs {
            if let data = renderPNGData(pixelSize: px) {
                try data.write(to: iconsetURL.appendingPathComponent(filename), options: .atomic)
            }
        }
    }
}

/// Inline 20x20 vector view for the toolbar/header.
final class AppIconView: NSView {
    private let dimension: CGFloat

    init(size: CGFloat = 20) {
        self.dimension = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: dimension, height: dimension)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height)
        AppIconDrawer.drawTopDown(in: ctx, size: s)
    }
}
