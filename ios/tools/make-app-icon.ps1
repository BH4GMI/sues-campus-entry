<#
.SYNOPSIS
    生成 iOS 应用图标（AppIcon.appiconset）。

.DESCRIPTION
    与 pc/tools/make-app-icon.ps1、android/.../drawable/ic_launcher.xml 共用**同一个标记**：
    白色描边（不填充）的折角纸。刻意不含校徽、校名、印章——这是个人做的快捷入口，
    不能看着像学校官方应用。

    三端的差别只在**底板形状**，这是平台惯例而不是不一致：
      - Windows 直接把图片画到桌面/任务栏，所以自己做完整外形（圆形满底）；
      - iOS 与 Android 由系统给图标施加外形遮罩，所以画**满幅方形**，
        自己再画圆角或圆形会得到"圆套圆"的脏边。

    iOS 另有两条例外规则，必须按 iOS 来：

      - **满幅正方形，不要圆角**：圆角与遮罩由系统在运行时施加。自己画圆角会得到"圆角套圆角"。
      - **不能有 alpha 通道**：App Store 与 Xcode 都会拒绝带透明的应用图标。
      - 现代 Xcode（14+）只需要一张 1024×1024，其余尺寸由系统缩放，不再逐尺寸出图。

    Xcode 工程把本脚本生成的 PNG 当作资产用，所以**脚本仍然是图标的唯一事实来源**。

.EXAMPLE
    pwsh -File ios/tools/make-app-icon.ps1
#>
[CmdletBinding()]
param(
    [string] $OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutDir) {
    $OutDir = Join-Path $PSScriptRoot '..\CampusEntry\Assets.xcassets\AppIcon.appiconset'
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$PrimaryColor = [System.Drawing.Color]::FromArgb(255, 0x2F, 0x6F, 0xB5)
$MarkColor    = [System.Drawing.Color]::White

$size = 1024

# 满幅正方形，不透明——iOS 会自己施加圆角遮罩
$bitmap = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($PrimaryColor)

    # 与 PC / Android 同一套比例：白色描边（不填充）的折角纸
    $stroke = [single]($size * 0.062)
    $pen = [System.Drawing.Pen]::new($MarkColor, $stroke)
    try {
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

        $l = $size * 0.26; $r = $size * 0.78
        $t = $size * 0.18; $b = $size * 0.82
        $foldX = $l + ($r - $l) * 0.66
        $foldY = $t + ($b - $t) * 0.28

        $outline = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new([single]$l, [single]$t),
            [System.Drawing.PointF]::new([single]$foldX, [single]$t),
            [System.Drawing.PointF]::new([single]$r, [single]$foldY),
            [System.Drawing.PointF]::new([single]$r, [single]$b),
            [System.Drawing.PointF]::new([single]$l, [single]$b),
            [System.Drawing.PointF]::new([single]$l, [single]$t))
        $g.DrawLines($pen, $outline)

        $fold = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new([single]$foldX, [single]$t),
            [System.Drawing.PointF]::new([single]$foldX, [single]$foldY),
            [System.Drawing.PointF]::new([single]$r, [single]$foldY))
        $g.DrawLines($pen, $fold)

        $lineX0 = $l + ($r - $l) * 0.22
        $lineX1 = $l + ($r - $l) * 0.80
        $lineX2 = $l + ($r - $l) * 0.58
        $lineY0 = $t + ($b - $t) * 0.60
        $lineY1 = $t + ($b - $t) * 0.79
        $g.DrawLine($pen, [single]$lineX0, [single]$lineY0, [single]$lineX1, [single]$lineY0)
        $g.DrawLine($pen, [single]$lineX0, [single]$lineY1, [single]$lineX2, [single]$lineY1)
    }
    finally {
        $pen.Dispose()
    }
}
finally {
    $g.Dispose()
}

$target = Join-Path $OutDir 'AppIcon-1024.png'
$bitmap.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()

# 自检：确认没有 alpha 通道（iOS 硬要求）
$check = [System.Drawing.Bitmap]::new($target)
$hasAlpha = ($check.PixelFormat -band [System.Drawing.Imaging.PixelFormat]::Alpha) -ne 0
Write-Host ("已生成 {0}（{1}x{1}，{2} 字节）" -f $target, $check.Width, (Get-Item $target).Length)
Write-Host ("  像素格式 {0}；含 alpha：{1}" -f $check.PixelFormat, $hasAlpha)
$check.Dispose()
if ($hasAlpha) { throw "iOS 应用图标不能带 alpha 通道" }
