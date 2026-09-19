import Foundation

//  SliderSolver.swift —— 从 pc/src/CampusEntry/Core/SliderSolver.cs 逐条移植（docs/CORE-SPEC.md §5.2）。
//
//  ## 图像层映射（本文件唯一的非机械转换；算法本体一个数字都没改）
//
//  | C# / Android                                        | 本文件                                        |
//  | --------------------------------------------------- | --------------------------------------------- |
//  | `int[] bg` / `int[] slider`，一个 int 就是一个像素    | `[Int32]`，**同样是 0xAARRGGBB 打包**（主入口） |
//  | `(p >> 16) & 0xFF` → R                               | `Int((p >> 16) & 0xFF)`                        |
//  | `(p >> 8) & 0xFF`  → G                               | `Int((p >> 8) & 0xFF)`                         |
//  | `p & 0xFF`         → B                               | `Int(p & 0xFF)`                                |
//  | 最高 8 位的 alpha 被忽略                              | 同样被忽略（只取 R/G/B）                        |
//
//  主入口 `solve(_:_:_:_:_:_:)` 收的就是宿主解码出来的**打包像素**，与 Android 的
//  `Bitmap.getPixels`（ARGB_8888，`inPremultiplied = false`）/ C# 的
//  `PixelFormat.Format32bppArgb` / iOS 宿主 `EntryHost.SliderImage.pixels` 是同一套布局：
//  参数顺序也与 C# 一模一样（背景、背景宽、背景高、滑块、滑块宽、滑块高）。
//
//  ## 第二条入口：`RgbaImage`（RGBA、8 位每通道）
//
//  iOS 侧另外提供「已解码的 RGBA 字节缓冲」形态：
//
//  ```swift
//  public struct RgbaImage { let width: Int; let height: Int; let pixels: [UInt8] }   // 行优先、RGBA
//  ```
//
//  通道顺序是硬约定：`pixels[i*4 + 0] = R`、`+1 = G`、`+2 = B`、`+3 = A`。
//  `solve(_ bg: RgbaImage, _ slider: RgbaImage)` 只做一件事——把 RGBA 按顺序打包成
//  0xAARRGGBB，然后调用同一条算法路径（**不另写一份相关度计算**）；alpha 只是原样带进打包值，
//  算法依旧不读它。
//
//  > 调用方用 CGImage 解码时有两条硬要求（docs/CORE-SPEC.md §5.2）：
//  > 1. **不得预乘 alpha** —— 预乘会把滑块 PNG 半透明边缘的 RGB 改掉（R' = R × A / 255），
//  >    掩码与相关度都会跟着偏，候选表就与参考实现不一致；
//  > 2. 通道顺序必须是上面那两种之一，BGRA 不能直接喂进来。
//
//  参数量纲：C# 的 `int` 是 32 位，这里用 Swift 的 `Int`（64 位）。像素值域、掩码、坐标都远在
//  32 位以内，只有「刻意构造超范围输入」才可能观感不同，正常路径完全一致。

/// 已解码的图像：**RGBA、8 位每通道**、行优先紧密排列（`pixels.count` 应为 `width * height * 4`）。
///
/// 这里不做任何校验或拷贝：尺寸是否自洽由 `SliderSolver.solve` 按 C# 的原判据检查后决定放弃。
public struct RgbaImage {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// 滑块缺口定位：**整幅**滑块图作模板，在背景图上按列滑窗，取相关度最高的列。
/// 与 Android 端 `SliderSolver.kt`、PC 端 `SliderSolver.cs` 逐条一致（docs/CORE-SPEC.md §5.2）：
/// 亮度掩码 299R+587G+114B>12000、掩码内**三通道展平且不减均值**的归一化互相关（参考实现里叫
/// `ccorr`，等价 `cv2.TM_CCORR_NORMED`）、只搜 1.0 档。
/// 服务端容差 ±2px，返回的列号可以直接交给页面提交。
///
/// ## 度量为什么是「不减均值」这一版（2026-09 修正）
///
/// 此前三端做的都是**逐通道减均值再归一化**（`ccoeff`）。真值语料一量就露了：
///
/// | 度量 | 首选命中（80 例，只搜 1.0 档） |
/// | --- | --- |
/// | `ccorr`（不减均值，三通道展平） | **77/80（96.2%）** |
/// | `ccoeff`（逐通道减均值） | 64/80（80.0%） |
///
/// 对照基准在 `D:\webvpn\lab\bench_campusentry_csharp`；PC 端换度量后与参考实现
/// **逐例一致 80/80**，三端必须给出同一张答案表。
///
/// 原因：服务端把缺口画成了拼图块的**逐通道仿射变换**（实测 `bg ≈ a·piece + b`），
/// 展平后的归一化互相关只能归一化倍数、归一化不了平移，减均值会把这条平移当噪声压掉，
/// 连真值处的优势一起压没。**合成图单测下两种度量给出同一答案，所以单测全绿也发现不了它**——
/// 改这个度量必须回到上面那个语料基准复跑。
public enum SliderSolver {

    /// 亮度掩码阈值（加权和，不是平均值）。
    public static let dimThreshold = 12000

    /// 定位缺口左边界（**打包像素入口**，与 C# 的 `Solve` 逐参数对应）。
    ///
    /// - Parameters:
    ///   - bg: 背景图，`0xAARRGGBB` 打包，行优先。
    ///   - bgW / bgH: 背景图的自然宽高。
    ///   - slider: 整幅滑块图（**不许裁剪**，裁剪会整体偏 +19px），同样打包。
    ///   - slW / slH: 滑块图的自然宽高。
    /// - Returns: 缺口左边界在背景图上的列号；无法定位（尺寸不合法、长度不够、模板几乎全透明、
    ///   掩码内像素少于 64、或模板能量为 0）时返回 `nil`。**绝不猜**。
    public static func solve(
        _ bg: [Int32], _ bgW: Int, _ bgH: Int,
        _ slider: [Int32], _ slW: Int, _ slH: Int
    ) -> Int? {
        if slW <= 0 || slH <= 0 || bgW <= 0 || bgH <= 0 { return nil }
        if slW > bgW || slH > bgH { return nil }
        let n = slW * slH
        if slider.count < n || bg.count < bgW * bgH { return nil }

        var mx = [Int](repeating: 0, count: n)
        var my = [Int](repeating: 0, count: n)
        var tr = [Int](repeating: 0, count: n)
        var tg = [Int](repeating: 0, count: n)
        var tb = [Int](repeating: 0, count: n)
        var m = 0
        var energyT = 0.0               // Σ(r² + g² + b²)：展平后的模板能量，滑窗里是常量
        for y in 0..<slH {
            for x in 0..<slW {
                let p = slider[y * slW + x]
                let r = Int((p >> 16) & 0xFF)
                let g = Int((p >> 8) & 0xFF)
                let b = Int(p & 0xFF)
                if 299 * r + 587 * g + 114 * b <= dimThreshold { continue }
                mx[m] = x
                my[m] = y
                tr[m] = r
                tg[m] = g
                tb[m] = b
                energyT += Double(r) * Double(r) + Double(g) * Double(g) + Double(b) * Double(b)
                m += 1
            }
        }
        // 掩码内像素太少时统计量不可靠；这个下界在 80 例语料上没有触发过，保留它只是防御退化模板。
        if m < 64 { return nil }

        let normT = sqrt(energyT)
        if normT <= 0.0 { return nil }

        var bestX = -1
        var bestScore = -Double.infinity
        let maxX = bgW - slW
        for ox in 0...maxX {
            var num = 0.0
            var den = 0.0
            for i in 0..<m {
                let p = bg[my[i] * bgW + ox + mx[i]]
                let ir = Int((p >> 16) & 0xFF)
                let ig = Int((p >> 8) & 0xFF)
                let ib = Int(p & 0xFF)
                num += Double(tr[i]) * Double(ir) + Double(tg[i]) * Double(ig) + Double(tb[i]) * Double(ib)
                den += Double(ir) * Double(ir) + Double(ig) * Double(ig) + Double(ib) * Double(ib)
            }
            if den <= 0.0 { continue }
            let score = num / (normT * sqrt(den))
            // 严格大于：并列时保留更小的 x，与参考实现「按分值降序稳定排序」的结果一致
            if score > bestScore {
                bestScore = score
                bestX = ox
            }
        }
        return bestX >= 0 ? bestX : nil
    }

    /// 定位缺口左边界（**RGBA 字节缓冲入口**）。
    ///
    /// 只是把 `RgbaImage` 打包成 `0xAARRGGBB` 再走上面那条路径：相关度计算只有一份实现。
    /// 参数顺序与打包入口一致（背景在前、滑块在后）。
    /// 长度不合法时同样返回 `nil`（打包时按可用像素截断，`solve` 的 `count < n` 判据照旧生效）。
    public static func solve(_ bg: RgbaImage, _ slider: RgbaImage) -> Int? {
        return solve(
            pack(bg), bg.width, bg.height,
            pack(slider), slider.width, slider.height)
    }

    /// RGBA → `0xAARRGGBB`。
    ///
    /// 只打包**确实存在**的像素：缓冲比 `width × height × 4` 短时，打包结果也短，
    /// 于是 `solve` 里那条 C# 的长度判据（`slider.Length < n` / `bg.Length < bgW * bgH`）
    /// 会以同样的方式命中并返回 nil，不会因为补齐零像素而改变结论。
    private static func pack(_ image: RgbaImage) -> [Int32] {
        let n = max(0, image.width * image.height)
        let available = min(n, image.pixels.count / 4)
        var packed = [Int32](repeating: 0, count: available)
        for i in 0..<available {
            let o = i * 4
            let r = Int32(image.pixels[o])
            let g = Int32(image.pixels[o + 1])
            let b = Int32(image.pixels[o + 2])
            let a = Int32(image.pixels[o + 3])
            packed[i] = (a << 24) | (r << 16) | (g << 8) | b
        }
        return packed
    }
}
