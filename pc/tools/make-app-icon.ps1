<#
.SYNOPSIS
    生成 教务直达 的应用图标（多尺寸 .ico）。

.DESCRIPTION
    图标的唯一事实来源是这个脚本，不是仓库里的二进制：改设计就改这里再跑一次。

    图形：primary (#2F6FB5) **圆形满底** + 白色**描边（不填充）折角纸**。
    这是 2026-09 定的新身份——产品名由「校园入口」改为「教务直达」，标记由
    「门洞」改为「折角纸」，图形语言由「实心几何」改为「圆形底 + 细描边线稿」。
    刻意不含任何校徽、校名、印章元素：这是一个个人做的快捷入口，不能看着像官方应用。

    白色对 #2F6FB5 的对比度是 5.2:1，远高于 WCAG 对图形元素要求的 3:1
    （曾评估过参照图的薄荷绿 #54CAB2，只有 2.0:1，未采用）。

    **小尺寸做光学简化**：<= 20px 时纸面放大、内部两条文字线去掉。
    缩小不等于等比缩放——1px 的线挤进 8px 宽的纸面只会糊成一团，
    这是图标设计的常规做法，不是特例补丁。

    ICO 容器按 Windows 约定混用两种编码：<= 48px 用 32bpp BMP（资源管理器与
    任务栏在最小尺寸下对 BMP 的兼容性最好），>= 64px 用 PNG（体积小、支持 alpha）。

    每个尺寸都是「按该尺寸原生绘制」而不是缩放大图，这样 1~2px 的描边在各尺寸下
    都落在像素边界上，不会糊。

.PARAMETER OutPath
    输出的 .ico 路径，默认写到 pc/src/CampusEntry/Assets/CampusEntry.ico。

.EXAMPLE
    pwsh -File pc/tools/make-app-icon.ps1
#>
[CmdletBinding()]
param(
    [string] $OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutPath) {
    $OutPath = Join-Path $PSScriptRoot '..\src\CampusEntry\Assets\CampusEntry.ico'
}
$OutPath = [System.IO.Path]::GetFullPath($OutPath)
$outDir = Split-Path -Parent $OutPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# ---------------------------------------------------------------- 颜色与几何（与 DESIGN.md 对齐）
$PrimaryColor   = [System.Drawing.Color]::FromArgb(255, 0x2F, 0x6F, 0xB5)
$MarkColor      = [System.Drawing.Color]::White
$Transparent    = [System.Drawing.Color]::Transparent

function New-CampusMark {
    param([int] $Size)

    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($Transparent)

        # 圆形满底（不是圆角方底：新版图形语言是圆底 + 线稿）
        $plateBrush = [System.Drawing.SolidBrush]::new($PrimaryColor)
        $g.FillEllipse($plateBrush, 0, 0, $Size, $Size)
        $plateBrush.Dispose()

        # 描边随尺寸等比，但不低于 1px
        $stroke = [single]([math]::Max($Size * 0.062, 1.0))
        $pen = [System.Drawing.Pen]::new($MarkColor, $stroke)
        try {
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

            # 光学简化：<= 20px 时把纸面撑大一点，否则四条边加描边会互相吃掉
            $lean = $Size -le 20
            $l = $Size * $(if ($lean) { 0.22 } else { 0.26 })
            $r = $Size * $(if ($lean) { 0.80 } else { 0.78 })
            $t = $Size * $(if ($lean) { 0.15 } else { 0.18 })
            $b = $Size * $(if ($lean) { 0.85 } else { 0.82 })
            $foldX = $l + ($r - $l) * 0.66     # 折角的位置
            $foldY = $t + ($b - $t) * 0.28

            # 纸的轮廓：左上起，到右上，斜下折角，再到底边、左边
            $outline = [System.Drawing.PointF[]]@(
                [System.Drawing.PointF]::new([single]$l, [single]$t),
                [System.Drawing.PointF]::new([single]$foldX, [single]$t),
                [System.Drawing.PointF]::new([single]$r, [single]$foldY),
                [System.Drawing.PointF]::new([single]$r, [single]$b),
                [System.Drawing.PointF]::new([single]$l, [single]$b),
                [System.Drawing.PointF]::new([single]$l, [single]$t))
            $g.DrawLines($pen, $outline)

            # 折角的两条边
            $fold = [System.Drawing.PointF[]]@(
                [System.Drawing.PointF]::new([single]$foldX, [single]$t),
                [System.Drawing.PointF]::new([single]$foldX, [single]$foldY),
                [System.Drawing.PointF]::new([single]$r, [single]$foldY))
            $g.DrawLines($pen, $fold)

            # 内部两条文字线：只在 >= 32px 时画（小尺寸下它们是纯噪声）
            if ($Size -ge 32) {
                $lineX0 = $l + ($r - $l) * 0.22
                $lineX1 = $l + ($r - $l) * 0.80
                $lineX2 = $l + ($r - $l) * 0.58
                $lineY0 = $t + ($b - $t) * 0.60
                $lineY1 = $t + ($b - $t) * 0.79
                $g.DrawLine($pen, [single]$lineX0, [single]$lineY0, [single]$lineX1, [single]$lineY0)
                $g.DrawLine($pen, [single]$lineX0, [single]$lineY1, [single]$lineX2, [single]$lineY1)
            }
        }
        finally {
            $pen.Dispose()
        }
    }
    finally {
        $g.Dispose()
    }
    return $bitmap
}

function Get-TopDownBgra {
    param([System.Drawing.Bitmap] $Bitmap)
    $rect = [System.Drawing.Rectangle]::new(0, 0, $Bitmap.Width, $Bitmap.Height)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $length = $data.Stride * $Bitmap.Height
        $buffer = [byte[]]::new($length)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buffer, 0, $length)
        return @{ Bytes = $buffer; Stride = $data.Stride }
    }
    finally {
        $Bitmap.UnlockBits($data)
    }
}

function ConvertTo-IcoBmp {
    param([System.Drawing.Bitmap] $Bitmap)
    $w = $Bitmap.Width; $h = $Bitmap.Height
    $src = Get-TopDownBgra -Bitmap $Bitmap

    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        # BITMAPINFOHEADER（40 字节）：高度写 2 倍，因为后面还要跟 AND 掩码
        $writer.Write([int]40)              # biSize
        $writer.Write([int]$w)              # biWidth
        $writer.Write([int]($h * 2))        # biHeight
        $writer.Write([int16]1)             # biPlanes
        $writer.Write([int16]32)            # biBitCount
        $writer.Write([int]0)               # biCompression = BI_RGB
        $writer.Write([int]($w * $h * 4))   # biSizeImage
        $writer.Write([int]0)               # biXPelsPerMeter
        $writer.Write([int]0)               # biYPelsPerMeter
        $writer.Write([int]0)               # biClrUsed
        $writer.Write([int]0)               # biClrImportant

        # 像素：ICO 里的 BMP 是自下而上，直接按行取原生 BGRA
        for ($y = $h - 1; $y -ge 0; $y--) {
            $writer.Write($src.Bytes, $y * $src.Stride, $w * 4)
        }

        # AND 掩码：alpha 已经在 BGRA 里，掩码全 0 即可，但行必须按 4 字节对齐
        $maskStride = [int][math]::Ceiling($w / 8.0)
        $pad = (4 - ($maskStride % 4)) % 4
        $maskRow = [byte[]]::new($maskStride + $pad)
        for ($y = 0; $y -lt $h; $y++) { $writer.Write($maskRow, 0, $maskRow.Length) }

        $writer.Flush()
        return $stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-IcoPng {
    param([System.Drawing.Bitmap] $Bitmap)
    $stream = [System.IO.MemoryStream]::new()
    try {
        $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

# ---------------------------------------------------------------- 组装 .ico
# 16/20/24/32/40/48 覆盖任务栏、Alt+Tab、资源管理器所有常用尺寸；64+ 给大图标视图
$bmpSizes = @(16, 20, 24, 32, 40, 48)
$pngSizes = @(64, 128, 256)

$entries = [System.Collections.Generic.List[hashtable]]::new()
foreach ($size in ($bmpSizes + $pngSizes)) {
    $mark = New-CampusMark -Size $size
    try {
        if ($pngSizes -contains $size) {
            $entries.Add(@{ Size = $size; Bytes = (ConvertTo-IcoPng -Bitmap $mark) })
        }
        else {
            $entries.Add(@{ Size = $size; Bytes = (ConvertTo-IcoBmp -Bitmap $mark) })
        }
    }
    finally {
        $mark.Dispose()
    }
}

$stream = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($stream)
try {
    $writer.Write([int16]0)                        # reserved
    $writer.Write([int16]1)                        # type = icon
    $writer.Write([int16]$entries.Count)

    $offset = 6 + 16 * $entries.Count
    foreach ($entry in $entries) {
        $dim = if ($entry.Size -ge 256) { 0 } else { $entry.Size }   # 256 在目录项里写 0
        $writer.Write([byte]$dim)                  # bWidth
        $writer.Write([byte]$dim)                  # bHeight
        $writer.Write([byte]0)                     # bColorCount
        $writer.Write([byte]0)                     # bReserved
        $writer.Write([int16]1)                    # wPlanes
        $writer.Write([int16]32)                   # wBitCount
        $writer.Write([int]$entry.Bytes.Length)    # dwBytesInRes
        $writer.Write([int]$offset)                # dwImageOffset
        $offset += $entry.Bytes.Length
    }
    foreach ($entry in $entries) { $writer.Write([byte[]]$entry.Bytes) }

    $writer.Flush()
    [System.IO.File]::WriteAllBytes($OutPath, $stream.ToArray())
}
finally {
    $writer.Dispose()
    $stream.Dispose()
}

$total = (Get-Item $OutPath).Length
Write-Host ("已生成 {0}" -f $OutPath)
Write-Host ("  尺寸 {0}；共 {1} 字节（BMP {2} / PNG {3}）" -f (($entries | ForEach-Object { $_.Size }) -join '/'), $total, ($bmpSizes -join '/'), ($pngSizes -join '/'))

# 自检：能被 System.Drawing.Icon 解析，并列出全部包含的尺寸
$icon = [System.Drawing.Icon]::new($OutPath)
Write-Host ("  自检：Icon 解析成功，默认取 {0}x{1}" -f $icon.Width, $icon.Height)
$icon.Dispose()
