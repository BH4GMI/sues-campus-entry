#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

/// Generates `CampusEntry.icns` using the #2F6FB5 rounded-square macOS app icon plate
/// and white folded-paper vector geometry matching `make-app-icon.ps1` / `AppIconDrawer.swift`.
enum IconGenerator {
    static let specs: [(filename: String, pixelSize: Int)] = [
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

    /// Draws the macOS rounded-square icon in a top-down `(0, 0, size, size)` coordinate space.
    static func drawTopDown(in ctx: CGContext, size: CGFloat) {
        guard size > 0 else { return }
        ctx.saveGState()

        // Standard macOS Big Sur+ icon canvas margin (100/1024 per side at >= 32px; reduced at 16px for legibility)
        let insetRatio: CGFloat = size <= 20.0 ? 0.04 : (100.0 / 1024.0)
        let inset = size * insetRatio
        let plateRect = CGRect(
            x: inset,
            y: inset,
            width: size - inset * 2.0,
            height: size - inset * 2.0
        )
        let cornerRadius = plateRect.width * 0.2237

        // Continuous squircle approximation via CGPath roundedRect, filled with #2F6FB5
        let plateColor = CGColor(
            srgbRed: 47.0 / 255.0,
            green: 111.0 / 255.0,
            blue: 181.0 / 255.0,
            alpha: 1.0
        )
        let platePath = CGPath(
            roundedRect: plateRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        ctx.addPath(platePath)
        ctx.setFillColor(plateColor)
        ctx.fillPath()

        // White folded-paper vector geometry scaled to plateRect
        let plateSize = plateRect.width
        let ox = plateRect.minX
        let oy = plateRect.minY

        let stroke = max(plateSize * 0.062, 1.0)
        ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let lean = size <= 20.0
        let l = ox + plateSize * (lean ? 0.22 : 0.26)
        let r = ox + plateSize * (lean ? 0.80 : 0.78)
        let t = oy + plateSize * (lean ? 0.15 : 0.18)
        let b = oy + plateSize * (lean ? 0.85 : 0.82)
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

        // Inner text lines at >= 32px
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

    static func renderPNGData(pixelSize: Int) -> Data? {
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
        cg.translateBy(x: 0, y: s)
        cg.scaleBy(x: 1, y: -1)
        drawTopDown(in: cg, size: s)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    static func generateICNS(outputURL: URL) throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("CampusEntryIcon-\(UUID().uuidString)", isDirectory: true)
        let iconsetURL = tempRoot.appendingPathComponent("CampusEntry.iconset", isDirectory: true)
        try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        for spec in specs {
            guard let png = renderPNGData(pixelSize: spec.pixelSize) else {
                throw NSError(domain: "IconGenerator", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to render \(spec.filename) at \(spec.pixelSize)px",
                ])
            }
            try png.write(to: iconsetURL.appendingPathComponent(spec.filename), options: .atomic)
        }

        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "IconGenerator", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "iconutil failed: \(errMsg)",
            ])
        }
    }
}

let outputPath = CommandLine.arguments.dropFirst().first ?? "CampusEntry.icns"
let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
do {
    try IconGenerator.generateICNS(outputURL: outputURL)
    print("Generated icon: \(outputURL.path)")
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
