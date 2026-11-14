import Foundation
import Testing
@testable import CampusEntryCore

/// Verifies `ImageDecoder` returns non-premultiplied `0xAARRGGBB` pixels for semi-transparent PNGs.
@Suite("ImageDecoder")
struct ImageDecoderTests {
    /// Synthesizes a valid uncompressed 8-bit RGBA PNG in memory with exact pixel bytes.
    private static func makeRGBAPNG(width: Int, height: Int, rgba: [UInt8]) -> Data {
        precondition(rgba.count == width * height * 4)

        // Build raw scanlines: filter byte 0x00 followed by width*4 RGBA bytes per row.
        var raw = [UInt8]()
        raw.reserveCapacity((1 + width * 4) * height)
        for y in 0..<height {
            raw.append(0)
            let rowStart = y * width * 4
            raw.append(contentsOf: rgba[rowStart..<(rowStart + width * 4)])
        }

        // Wrap raw scanlines in a valid zlib stream with uncompressed DEFLATE blocks.
        let zlibData = makeUncompressedZlib(raw)

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data(capacity: 13)
        appendUInt32BE(&ihdr, UInt32(width))
        appendUInt32BE(&ihdr, UInt32(height))
        ihdr.append(8) // bit depth
        ihdr.append(6) // color type: RGBA (non-premultiplied)
        ihdr.append(0) // compression method
        ihdr.append(0) // filter method
        ihdr.append(0) // interlace method

        appendChunk(&png, type: "IHDR", payload: ihdr)
        appendChunk(&png, type: "IDAT", payload: zlibData)
        appendChunk(&png, type: "IEND", payload: Data())
        return png
    }

    private static func makeUncompressedZlib(_ payload: [UInt8]) -> Data {
        var out = Data()
        // zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (FCHECK makes 0x7801 % 31 == 0).
        out.append(0x78)
        out.append(0x01)

        var offset = 0
        let maxBlock = 65535
        while true {
            let remaining = payload.count - offset
            let blockLen = min(remaining, maxBlock)
            let isFinal: UInt8 = (offset + blockLen >= payload.count) ? 0x01 : 0x00
            out.append(isFinal) // BFINAL | BTYPE=00 (stored)
            let len = UInt16(blockLen)
            let nlen = ~len
            out.append(UInt8(len & 0xFF))
            out.append(UInt8(len >> 8))
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8(nlen >> 8))
            if blockLen > 0 {
                out.append(contentsOf: payload[offset..<(offset + blockLen)])
            }
            offset += blockLen
            if isFinal == 0x01 { break }
        }

        appendUInt32BE(&out, adler32(payload))
        return out
    }

    private static func appendChunk(_ out: inout Data, type: String, payload: Data) {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4)
        appendUInt32BE(&out, UInt32(payload.count))
        var body = Data(capacity: 4 + payload.count)
        body.append(contentsOf: typeBytes)
        body.append(payload)
        out.append(body)
        appendUInt32BE(&out, crc32(body))
    }

    private static func appendUInt32BE(_ out: inout Data, _ value: UInt32) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let mod: UInt32 = 65521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % mod
            b = (b + a) % mod
        }
        return (b << 16) | a
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return ~crc
    }

    @Test("半透明 PNG 解码保留非预乘 RGB 通道")
    func decodesSemiTransparentPNGAsNonPremultipliedARGB() throws {
        // 2x2 image: semi-transparent (200, 100, 50, alpha=128) + opaque/transparent neighbors
        let rgba: [UInt8] = [
            200, 100, 50, 128,
            200, 100, 50, 128,
            10,  20,  30, 255,
            0,   0,   0,  0,
        ]
        let pngData = Self.makeRGBAPNG(width: 2, height: 2, rgba: rgba)

        let decodedFromData = try #require(ImageDecoder.decode(data: pngData))
        let dataURL = "data:image/png;base64," + pngData.base64EncodedString()
        let decodedFromURL = try #require(ImageDecoder.decodeDataURL(dataURL))

        for decoded in [decodedFromData, decodedFromURL] {
            #expect(decoded.width == 2)
            #expect(decoded.height == 2)
            #expect(decoded.pixels.count == 4)

            let p0 = decoded.pixels[0]
            let a0 = Int((p0 >> 24) & 0xFF)
            let r0 = Int((p0 >> 16) & 0xFF)
            let g0 = Int((p0 >> 8) & 0xFF)
            let b0 = Int(p0 & 0xFF)

            #expect(a0 == 128)
            #expect(abs(r0 - 200) <= 1, "Expected non-premultiplied R ~200, got \(r0)")
            #expect(abs(g0 - 100) <= 1, "Expected non-premultiplied G ~100, got \(g0)")
            #expect(abs(b0 - 50) <= 1, "Expected non-premultiplied B ~50, got \(b0)")

            // Ensure opaque and transparent pixels also decode in 0xAARRGGBB order.
            #expect(decoded.pixels[2] == 0xFF0A141E)
            #expect(decoded.pixels[3] == 0x00000000)
        }
    }
}
