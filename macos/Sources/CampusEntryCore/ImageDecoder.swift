import CoreGraphics
import Foundation
import ImageIO

/// Decoded image buffer in non-premultiplied `0xAARRGGBB` pixel order.
public struct DecodedImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt32]

    public init(width: Int, height: Int, pixels: [UInt32]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Decodes `data:image/...;base64,...` strings into non-premultiplied `0xAARRGGBB` `[UInt32]` buffers
/// without drawing through a premultiplied `CGContext` (preserving exact edge RGB values for `SliderSolver`).
public enum ImageDecoder {
    /// Decodes a `data:image/...;base64,...` URL into a non-premultiplied `DecodedImage`.
    public static func decodeDataURL(_ dataURL: String) -> DecodedImage? {
        let lower = dataURL.lowercased()
        guard lower.hasPrefix("data:image/"),
              let marker = lower.range(of: ";base64,")
        else {
            return nil
        }
        let base64Start = dataURL.index(dataURL.startIndex, offsetBy: dataURL.distance(from: lower.startIndex, to: marker.upperBound))
        let base64String = String(dataURL[base64Start...])
        guard let rawData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
              !rawData.isEmpty
        else {
            return nil
        }
        return decode(data: rawData)
    }

    /// Decodes raw encoded image bytes (PNG, JPEG, WebP, etc.) via `CGImageSource`.
    public static func decode(data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return decode(cgImage: cgImage)
    }

    /// Extracts non-premultiplied `0xAARRGGBB` pixels directly from a `CGImage`'s `dataProvider`.
    public static func decode(cgImage: CGImage) -> DecodedImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        guard cgImage.bitsPerComponent == 8 else { return nil }
        guard !cgImage.bitmapInfo.contains(.floatComponents) else { return nil }
        guard let provider = cgImage.dataProvider,
              let cfData = provider.data
        else {
            return nil
        }

        let rawData = cfData as Data
        let bytesPerRow = cgImage.bytesPerRow
        let bitsPerPixel = cgImage.bitsPerPixel
        let alphaInfo = cgImage.alphaInfo
        let byteOrder = cgImage.bitmapInfo.intersection(.byteOrderMask)
        let colorModel = cgImage.colorSpace?.model

        let bytesPerPixel = bitsPerPixel / 8
        guard bitsPerPixel % 8 == 0, bytesPerPixel > 0 else { return nil }
        guard bytesPerRow >= width * bytesPerPixel else { return nil }
        guard rawData.count >= (height - 1) * bytesPerRow + width * bytesPerPixel else { return nil }

        var pixels = [UInt32](repeating: 0, count: width * height)

        return rawData.withUnsafeBytes { rawBuffer -> DecodedImage? in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            if colorModel == .rgb || colorModel == nil {
                if bytesPerPixel == 4 {
                    decodeRGBA32(
                        base: base,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        alphaInfo: alphaInfo,
                        byteOrder: byteOrder,
                        into: &pixels
                    )
                    return DecodedImage(width: width, height: height, pixels: pixels)
                }
                if bytesPerPixel == 3 && alphaInfo == .none {
                    decodeRGB24(
                        base: base,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        byteOrder: byteOrder,
                        into: &pixels
                    )
                    return DecodedImage(width: width, height: height, pixels: pixels)
                }
            }

            if colorModel == .monochrome {
                if bytesPerPixel == 1 {
                    for y in 0..<height {
                        let row = base + y * bytesPerRow
                        let outRow = y * width
                        for x in 0..<width {
                            let v = UInt32(row[x])
                            pixels[outRow + x] = 0xFF000000 | (v << 16) | (v << 8) | v
                        }
                    }
                    return DecodedImage(width: width, height: height, pixels: pixels)
                }
                if bytesPerPixel == 2 {
                    decodeGrayAlpha16(
                        base: base,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        alphaInfo: alphaInfo,
                        into: &pixels
                    )
                    return DecodedImage(width: width, height: height, pixels: pixels)
                }
            }

            if colorModel == .indexed, bytesPerPixel == 1,
               let cs = cgImage.colorSpace,
               let table = cs.colorTable,
               cs.baseColorSpace?.model == .rgb
            {
                let entryCount = table.count / 3
                for y in 0..<height {
                    let row = base + y * bytesPerRow
                    let outRow = y * width
                    for x in 0..<width {
                        let idx = Int(row[x])
                        guard idx < entryCount else { return nil }
                        let t = idx * 3
                        pixels[outRow + x] = pack(a: 255, r: table[t], g: table[t + 1], b: table[t + 2])
                    }
                }
                return DecodedImage(width: width, height: height, pixels: pixels)
            }

            return nil
        }
    }

    private static func decodeRGBA32(
        base: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        alphaInfo: CGImageAlphaInfo,
        byteOrder: CGBitmapInfo,
        into pixels: inout [UInt32]
    ) {
        let isLittle = byteOrder == .byteOrder32Little
        let alphaFirst: Bool
        switch alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst:
            alphaFirst = true
        default:
            alphaFirst = false
        }
        let premultiplied = (alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast)
        let opaque = (alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast)

        for y in 0..<height {
            let row = base + y * bytesPerRow
            let outRow = y * width
            for x in 0..<width {
                let p = row + x * 4
                var r: UInt8
                var g: UInt8
                var b: UInt8
                var a: UInt8

                if isLittle {
                    if alphaFirst {
                        // 32-bit little endian ARGB -> memory order B, G, R, A
                        b = p[0]; g = p[1]; r = p[2]; a = p[3]
                    } else {
                        // 32-bit little endian RGBA -> memory order A, B, G, R
                        a = p[0]; b = p[1]; g = p[2]; r = p[3]
                    }
                } else {
                    if alphaFirst {
                        // Big/default ARGB -> memory order A, R, G, B
                        a = p[0]; r = p[1]; g = p[2]; b = p[3]
                    } else {
                        // Big/default RGBA -> memory order R, G, B, A
                        r = p[0]; g = p[1]; b = p[2]; a = p[3]
                    }
                }

                if opaque {
                    a = 255
                } else if premultiplied {
                    (r, g, b) = unpremultiply(r: r, g: g, b: b, a: a)
                }
                pixels[outRow + x] = pack(a: a, r: r, g: g, b: b)
            }
        }
    }

    private static func decodeRGB24(
        base: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        byteOrder: CGBitmapInfo,
        into pixels: inout [UInt32]
    ) {
        let isLittle = byteOrder == .byteOrder32Little
        for y in 0..<height {
            let row = base + y * bytesPerRow
            let outRow = y * width
            for x in 0..<width {
                let p = row + x * 3
                let r = isLittle ? p[2] : p[0]
                let g = p[1]
                let b = isLittle ? p[0] : p[2]
                pixels[outRow + x] = pack(a: 255, r: r, g: g, b: b)
            }
        }
    }

    private static func decodeGrayAlpha16(
        base: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        alphaInfo: CGImageAlphaInfo,
        into pixels: inout [UInt32]
    ) {
        let alphaFirst = (alphaInfo == .first || alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst)
        let premultiplied = (alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast)
        let opaque = (alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast)

        for y in 0..<height {
            let row = base + y * bytesPerRow
            let outRow = y * width
            for x in 0..<width {
                let p = row + x * 2
                var v = alphaFirst ? p[1] : p[0]
                var a = alphaFirst ? p[0] : p[1]
                if opaque {
                    a = 255
                } else if premultiplied {
                    (v, _, _) = unpremultiply(r: v, g: v, b: v, a: a)
                }
                pixels[outRow + x] = pack(a: a, r: v, g: v, b: v)
            }
        }
    }

    @inline(__always)
    private static func unpremultiply(r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> (UInt8, UInt8, UInt8) {
        if a == 255 { return (r, g, b) }
        if a == 0 { return (0, 0, 0) }
        let ai = Int(a)
        let half = ai / 2
        let ur = UInt8(min(255, (Int(r) * 255 + half) / ai))
        let ug = UInt8(min(255, (Int(g) * 255 + half) / ai))
        let ub = UInt8(min(255, (Int(b) * 255 + half) / ai))
        return (ur, ug, ub)
    }

    @inline(__always)
    private static func pack(a: UInt8, r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
        (UInt32(a) << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }
}
