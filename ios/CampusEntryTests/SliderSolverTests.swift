import XCTest
@testable import CampusEntry

// 由 `pc/tests/CampusEntry.Tests/SliderSolverTests.cs` 逐条翻译而来（权威来源是 C#）。
// 用例数：C# 1 个 [Theory]（5 条 InlineData）+ 3 个 [Fact] = 8 条向量，
// 这里同样是 1 个循环 + 3 个 func，总共 8 条向量。

// ── 像素通道换算（C# → Swift，这一步必须显式换算，不能照抄）────────────────────
//
// C# 的 `int[]` 里每个元素是**一个像素**，打包顺序 0xAARRGGBB：
//     R = (p >> 16) & 0xFF，G = (p >> 8) & 0xFF，B = p & 0xFF，A = (p >> 24) & 0xFF
// iOS 的 `RgbaImage.pixels` 是**字节缓冲**，每像素 4 字节、顺序 R,G,B,A、行优先
// （`SliderSolver.pack` 就是按这个顺序打包回 0xAARRGGBB 的，文档见 SliderSolver.swift 文件头）。
//
// 所以 C# 的一个 int 在这里对应 4 个连续字节，映射是：
//     pixels[i*4 + 0] = R
//     pixels[i*4 + 1] = G
//     pixels[i*4 + 2] = B
//     pixels[i*4 + 3] = A      （C# 里是 `0xFF << 24`；两端算法都不读 alpha，
//                               这里仍按原样写 0xFF，保持与 C# 逐字节对应）
//
// `i` 都是行优先的下标（i = y * width + x），两端的行主序一致。

/// 有种子、可复现的随机数源。
///
/// C# 用 `new Random(seed)`（.NET 的伪随机算法），Swift 标准库没有等价的可复现实现
///（`SystemRandomNumberGenerator` 用的是系统熵源，跑两次结果不同，不能用于断言）。
/// 所以这里自带一个 SplitMix64：**目的只是「同一批像素每次跑都一样」**，
/// 与被测算法的正确性无关——这条用例要验证的是「背景在 x0 处的原样裁剪能被找回 x0」，
/// 而不是某个特定随机数列。
///
/// 值域刻意与 C# 的 `rng.Next(256)` 一致（三通道各自在 0…255 上均匀），
/// 这样掩码 `299R + 587G + 114B > 12000` 放过的像素数量级也一致：
/// 加权和均值约 127500、阈值 12000，只会筛掉约 1% 的像素，远多于「掩码内至少 64 个」的要求。
private struct SeededRandom {

    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    private mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0…255 的均匀字节（对应 C# 的 `rng.Next(256)`）。
    mutating func nextByte() -> UInt8 {
        UInt8(truncatingIfNeeded: next() >> 8)
    }
}

/// 滑块定位（docs/CORE-SPEC.md §5.2/§7 合成用例，与 Android 端 SliderSolverTest 等价）。
final class SliderSolverTests: XCTestCase {

    private let bgW = 220
    private let bgH = 60
    private let slW = 30
    private let slH = 60

    /// 220×60 背景（随机但有种子），30×60 模板 = 背景在 x0 处的原样裁剪。
    /// 返回 RGBA 字节缓冲（通道映射见文件头）。
    private func makePair(_ x0: Int, seed: UInt64) -> (bg: RgbaImage, slider: RgbaImage) {
        var rng = SeededRandom(seed: seed)
        var background = [UInt8](repeating: 0, count: bgW * bgH * 4)
        for i in 0..<(bgW * bgH) {
            let o = i * 4
            background[o] = rng.nextByte()        // R
            background[o + 1] = rng.nextByte()    // G
            background[o + 2] = rng.nextByte()    // B
            background[o + 3] = 0xFF              // A（C# 也是 0xFF << 24）
        }
        var slider = [UInt8](repeating: 0, count: slW * slH * 4)
        for y in 0..<slH {
            for x in 0..<slW {
                let from = (y * bgW + x0 + x) * 4
                let to = (y * slW + x) * 4
                for channel in 0..<4 {
                    slider[to + channel] = background[from + channel]
                }
            }
        }
        return (
            RgbaImage(width: bgW, height: bgH, pixels: background),
            RgbaImage(width: slW, height: slH, pixels: slider))
    }

    /// C# 的 `[Theory]` + 5 条 `[InlineData]`。XCTest 没有内建参数化，用循环逐条断言：
    /// 失败消息里带上 x0，一条失败就能定位到具体向量，且 5 条向量都真的被断言过。
    func test合成背景上定位精确() {
        let cases = [0, 1, 37, 100, 190]
        for x0 in cases {
            let pair = makePair(x0, seed: UInt64(42 + x0))
            XCTAssertEqual(
                x0, SliderSolver.solve(pair.bg, pair.slider), "用例: x0=\(x0)")
        }
    }

    func test模板全黑_掩码为零_放弃() {
        let pair = makePair(100, seed: 7)
        // 全 0：RGB 全 0，掩码（299R+587G+114B > 12000）内一个像素都没有 → m < 64 → 放弃。
        // 对应 C# 的 `new int[30 * 60]`（每个 int 都是 0）→ 这里每个字节都是 0。
        let slider = RgbaImage(
            width: slW, height: slH,
            pixels: [UInt8](repeating: 0, count: slW * slH * 4))
        XCTAssertNil(SliderSolver.solve(pair.bg, slider))
    }

    /// 纯白模板（掩码内每个像素都是 255）：**给出候选，而不是放弃**。
    ///
    /// 旧实现做的是逐通道减均值（ccoeff）：方差为 0 就无从归一化，只能放弃。
    /// 2026-09 换成不减均值的度量（ccorr）后，纯白模板有非零能量，因此会正常给出候选——
    /// 参考实现同样是这个行为。语料依据见 `D:\webvpn\lab\bench_campusentry_csharp`。
    ///
    /// **为什么只断言非空、不断言具体列号**：纯白模板是退化输入。模板均匀时，背景里任何一个
    /// "内部均匀"的窗口都恰好与模板成正比、相关度精确等于 1.0，度量在这里没有分辨力，
    /// 谁赢只取决于扫描顺序与浮点舍入。有分辨力的用例是 `test合成背景上定位精确`。
    func test模板纯白_仍有能量_给出候选而非放弃() {
        let pair = makePair(100, seed: 7)
        // 对应 C# 的 `Array.Fill(slider, 0xFFFFFFFF)` → 这里 R/G/B/A 四个字节全是 0xFF。
        let slider = RgbaImage(
            width: slW, height: slH,
            pixels: [UInt8](repeating: 0xFF, count: slW * slH * 4))
        XCTAssertNotNil(SliderSolver.solve(pair.bg, slider))
    }

    func test尺寸不合法_放弃() {
        let pair = makePair(10, seed: 3)
        // C# 传的是「背景数组 + bgW=20、bgH=60」，即尺寸声明与实际缓冲不一致。
        // RgbaImage 入口的 `pack` 只打包 width×height 个像素（按可用字节截断），
        // 但 `solve` 里的尺寸判据（`slW > bgW`）在这之前就先命中了，所以结论与 C# 相同。
        XCTAssertNil(SliderSolver.solve(
            RgbaImage(width: 20, height: bgH, pixels: pair.bg.pixels), pair.slider)) // 模板比背景宽
        // C# 这里把滑块宽度声明成 31（缓冲仍只有 30×60 像素）：
        // 打包后是 1800 个像素，而 n = 31×60 = 1860 → 命中 C# 的长度判据 `slider.Length < n` → nil。
        XCTAssertNil(SliderSolver.solve(
            pair.bg, RgbaImage(width: 31, height: slH, pixels: pair.slider.pixels)))
        // 背景为空数组：打包结果是空缓冲 → 同样命中长度判据 → nil。
        XCTAssertNil(SliderSolver.solve(
            RgbaImage(width: bgW, height: bgH, pixels: []), pair.slider))
    }
}
