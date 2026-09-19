# 身份方案预览生成器（改名 / 改图标）
#
# 用途：在**不改动任何应用代码**的前提下，把候选图标与候选名字渲染成一张对照图，
#       供用户先看后选。选定之后再改 App.xaml / csproj / make-app-icon.ps1。
#
# 图形语言（按用户给的参照图定）：**圆形满底 + 白色描边线稿**，圆头圆角、不填充。
# 两套底色同时出：设计系统的品牌蓝 #2F6FB5，以及参照图里采样的薄荷绿 #54CAB2。
#
# 为什么用 PowerShell + GDI+ 而不是复用 make-app-icon.ps1：
#   正式图标要走 .ico 多尺寸容器，这个脚本只出 PNG 对照图，两者输出格式不同。
#   图标本身的几何形状两边必须一致——选定后我会把这里的绘制函数原样搬进 make-app-icon.ps1。
#
# 注意：PowerShell 调 GDI+ 有两个坑，本脚本已按可用写法固定下来：
#   1) 传给方法的数组必须先赋给**显式类型化**的变量（[System.Drawing.PointF[]]@(...)），
#      行内数组字面量会让 PowerShell 的方法绑定错乱；
#   2) 画笔宽度等数值参数统一 [single] 强转，否则会被当成 Color 去解析。

[CmdletBinding()]
param(
    [string] $OutPath = 'D:\Workspace\webvpn\docs\screenshots\_identity-preview.png'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$WHITE   = [System.Drawing.Color]::White
$INK     = [System.Drawing.Color]::FromArgb(255, 0x1A, 0x1C, 0x1E)
$SEC     = [System.Drawing.Color]::FromArgb(255, 0x6C, 0x72, 0x78)
$LINE    = [System.Drawing.Color]::FromArgb(255, 0xE3, 0xE3, 0xE3)
$NEUTRAL = [System.Drawing.Color]::FromArgb(255, 0xF5, 0xF7, 0xFA)
$BRAND   = [System.Drawing.Color]::FromArgb(255, 0x2F, 0x6F, 0xB5)
$MINT    = [System.Drawing.Color]::FromArgb(255, 0x54, 0xCA, 0xB2)
# 参照图的薄荷绿上画白线稿只有 2.0:1（低于 WCAG 图形元素 3:1 的要求），
# 这个加深版保住同一色相，白色对它的对比度约 3.2:1。
$TEAL    = [System.Drawing.Color]::FromArgb(255, 0x2A, 0xA0, 0x89)

# 字号一律用**像素**单位：默认构造函数用的是点（1pt=4/3px），按像素排版时行距会算不准。
function New-PxFont {
    param([string]$name, [single]$px, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular)
    return [System.Drawing.Font]::new($name, $px, $style, [System.Drawing.GraphicsUnit]::Pixel)
}

function New-MarkPen {    param([int]$s, [double]$factor, [double]$min)
    $pen = [System.Drawing.Pen]::new($WHITE, [single][math]::Max($s * $factor, $min))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    return $pen
}

function New-RoundPath {
    param([single]$x, [single]$y, [single]$w, [single]$h, [single]$r)
    $p = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# 1) 日历 / 课表
function Draw-Cal {
    param($g, [int]$s)
    $pen = New-MarkPen $s 0.062 1.0
    $l = $s * 0.20; $r = $s * 0.80; $t = $s * 0.28; $b = $s * 0.82
    $p = New-RoundPath ([single]$l) ([single]$t) ([single]($r - $l)) ([single]($b - $t)) ([single]($s * 0.08))
    $g.DrawPath($pen, $p); $p.Dispose()
    $g.DrawLine($pen, [single]$l, [single]($s * 0.45), [single]$r, [single]($s * 0.45))
    $g.DrawLine($pen, [single]($s * 0.35), [single]($s * 0.20), [single]($s * 0.35), [single]($s * 0.31))
    $g.DrawLine($pen, [single]($s * 0.65), [single]($s * 0.20), [single]($s * 0.65), [single]($s * 0.31))
    $g.DrawLine($pen, [single]($s * 0.50), [single]($s * 0.56), [single]($s * 0.50), [single]($s * 0.74))
    $pen.Dispose()
}

# 2) 成绩单（折角的纸）
function Draw-Sheet {
    param($g, [int]$s)
    $pen = New-MarkPen $s 0.062 1.0
    $outline = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($s * 0.26), [single]($s * 0.18)),
        [System.Drawing.PointF]::new([single]($s * 0.60), [single]($s * 0.18)),
        [System.Drawing.PointF]::new([single]($s * 0.78), [single]($s * 0.36)),
        [System.Drawing.PointF]::new([single]($s * 0.78), [single]($s * 0.82)),
        [System.Drawing.PointF]::new([single]($s * 0.26), [single]($s * 0.82)))
    $g.DrawLines($pen, $outline)
    $g.DrawLine($pen, [single]($s * 0.26), [single]($s * 0.82), [single]($s * 0.26), [single]($s * 0.18))
    $fold = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($s * 0.60), [single]($s * 0.18)),
        [System.Drawing.PointF]::new([single]($s * 0.60), [single]($s * 0.36)),
        [System.Drawing.PointF]::new([single]($s * 0.78), [single]($s * 0.36)))
    $g.DrawLines($pen, $fold)
    $g.DrawLine($pen, [single]($s * 0.37), [single]($s * 0.56), [single]($s * 0.67), [single]($s * 0.56))
    $g.DrawLine($pen, [single]($s * 0.37), [single]($s * 0.68), [single]($s * 0.55), [single]($s * 0.68))
    $pen.Dispose()
}

# 3) 翻开的书
function Draw-Book {
    param($g, [int]$s)
    $pen = New-MarkPen $s 0.062 1.0
    $left = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($s * 0.50), [single]($s * 0.32)),
        [System.Drawing.PointF]::new([single]($s * 0.16), [single]($s * 0.24)),
        [System.Drawing.PointF]::new([single]($s * 0.16), [single]($s * 0.70)),
        [System.Drawing.PointF]::new([single]($s * 0.50), [single]($s * 0.78)))
    $g.DrawLines($pen, $left)
    $right = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($s * 0.50), [single]($s * 0.32)),
        [System.Drawing.PointF]::new([single]($s * 0.84), [single]($s * 0.24)),
        [System.Drawing.PointF]::new([single]($s * 0.84), [single]($s * 0.70)),
        [System.Drawing.PointF]::new([single]($s * 0.50), [single]($s * 0.78)))
    $g.DrawLines($pen, $right)
    $mid = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($s * 0.50), [single]($s * 0.32)),
        [System.Drawing.PointF]::new([single]($s * 0.50), [single]($s * 0.78)))
    $g.DrawLines($pen, $mid)
    $pen.Dispose()
}

# 4) 学士帽
function Draw-Cap {
    param($g, [int]$s)
    $pen = New-MarkPen $s 0.062 1.0
    $cx = $s * 0.5; $top = $s * 0.30; $mid = $s * 0.42; $bot = $s * 0.54
    $board = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]$cx, [single]$top),
        [System.Drawing.PointF]::new([single]($s * 0.88), [single]$mid),
        [System.Drawing.PointF]::new([single]$cx, [single]$bot),
        [System.Drawing.PointF]::new([single]($s * 0.12), [single]$mid),
        [System.Drawing.PointF]::new([single]$cx, [single]$top))
    $g.DrawLines($pen, $board)
    $bowl = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($s * 0.31), [single]($s * 0.48)),
        [System.Drawing.PointF]::new([single]($s * 0.34), [single]($s * 0.68)),
        [System.Drawing.PointF]::new([single]($s * 0.66), [single]($s * 0.68)),
        [System.Drawing.PointF]::new([single]($s * 0.69), [single]($s * 0.48)))
    $g.DrawLines($pen, $bowl)
    $g.DrawLine($pen, [single]($s * 0.88), [single]$mid, [single]($s * 0.88), [single]($s * 0.72))
    $pen.Dispose()
    $br = [System.Drawing.SolidBrush]::new($WHITE)
    $g.FillEllipse($br, [single]($s * 0.84), [single]($s * 0.70), [single]($s * 0.08), [single]($s * 0.08))
    $br.Dispose()
}

# 5) 一键进入：方框留口 + 箭头穿入
function Draw-Enter {
    param($g, [int]$s)
    $pen = New-MarkPen $s 0.062 1.0
    $l = $s * 0.42; $r = $s * 0.84; $t = $s * 0.24; $b = $s * 0.76
    $box = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]$l, [single]$t),
        [System.Drawing.PointF]::new([single]$r, [single]$t),
        [System.Drawing.PointF]::new([single]$r, [single]$b),
        [System.Drawing.PointF]::new([single]$l, [single]$b))
    $g.DrawLines($pen, $box)
    $ay = $s * 0.50
    $g.DrawLine($pen, [single]($s * 0.14), [single]$ay, [single]($s * 0.60), [single]$ay)
    $g.DrawLine($pen, [single]($s * 0.49), [single]($ay - $s * 0.10), [single]($s * 0.60), [single]$ay)
    $g.DrawLine($pen, [single]($s * 0.49), [single]($ay + $s * 0.10), [single]($s * 0.60), [single]$ay)
    $pen.Dispose()
}

# 6) 成绩趋势：上升折线 + 箭头
function Draw-Chart {
    param($g, [int]$s)
    $pen = New-MarkPen $s 0.065 1.0
    $line = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new([single]($s * 0.18), [single]($s * 0.70)),
        [System.Drawing.PointF]::new([single]($s * 0.38), [single]($s * 0.52)),
        [System.Drawing.PointF]::new([single]($s * 0.54), [single]($s * 0.62)),
        [System.Drawing.PointF]::new([single]($s * 0.78), [single]($s * 0.32)))
    $g.DrawLines($pen, $line)
    $g.DrawLine($pen, [single]($s * 0.60), [single]($s * 0.30), [single]($s * 0.78), [single]($s * 0.32))
    $g.DrawLine($pen, [single]($s * 0.76), [single]($s * 0.50), [single]($s * 0.78), [single]($s * 0.32))
    $pen.Dispose()
}

function New-Icon {
    param([int]$s, [string]$kind, [System.Drawing.Color]$plate)
    $bmp = [System.Drawing.Bitmap]::new($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $br = [System.Drawing.SolidBrush]::new($plate)
    $g.FillEllipse($br, 0, 0, $s, $s)
    $br.Dispose()
    switch ($kind) {
        'cal'   { Draw-Cal $g $s }
        'sheet' { Draw-Sheet $g $s }
        'book'  { Draw-Book $g $s }
        'cap'   { Draw-Cap $g $s }
        'enter' { Draw-Enter $g $s }
        'chart' { Draw-Chart $g $s }
    }
    $g.Dispose()
    return $bmp
}

$candidates = @(
    @{ k = 'cal';   t = '1  日历 / 课表 —— 教务系统里最常点开的就是它' },
    @{ k = 'sheet'; t = '2  成绩单（折角纸）—— 查成绩' },
    @{ k = 'book';  t = '3  翻开的书 —— 中性学业符号' },
    @{ k = 'cap';   t = '4  学士帽 —— 线稿版，比实心版轻盈' },
    @{ k = 'enter'; t = '5  一键进入 —— 方框留口 + 箭头穿入，本应用实际在做的事' },
    @{ k = 'chart'; t = '6  成绩趋势 —— 折线向上，16 像素下也清楚' }
)

$rowH = 150
$canvas = [System.Drawing.Bitmap]::new(1500, (170 + $candidates.Count * $rowH + 400))
$gc = [System.Drawing.Graphics]::FromImage($canvas)
$gc.Clear($WHITE)
$gc.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$fH = New-PxFont 'Microsoft YaHei UI' 26 ([System.Drawing.FontStyle]::Bold)
$fL = New-PxFont 'Microsoft YaHei UI' 20
$fSm = New-PxFont 'Microsoft YaHei UI' 15
$bInk = [System.Drawing.SolidBrush]::new($INK)
$bSec = [System.Drawing.SolidBrush]::new($SEC)
$pLine = [System.Drawing.Pen]::new($LINE, 2)

$gc.DrawString('图形语言：圆形满底 + 白色描边线稿', $fH, $bInk, 30, 20)
$gc.DrawString('① 品牌蓝 #2F6FB5（设计系统主色，白线对其对比度 5.2:1）     ② 参照图薄荷绿 #54CAB2（2.0:1，偏低）     ③ 加深薄荷绿 #2AA089（3.2:1，过线）', $fSm, $bSec, 30, 60)
$gc.DrawString('每组依次是 96 / 64 / 48 / 32 / 16 像素，后两个就是任务栏与列表里的实际大小', $fSm, $bSec, 30, 84)

$y = 118
foreach ($c in $candidates) {
    $gc.DrawString($c.t, $fL, $bInk, 30, $y)
    $big = 88; $iy = $y + 24
    foreach ($pair in @(@{x = 30; c = $BRAND}, @{x = 430; c = $MINT}, @{x = 830; c = $TEAL})) {
        $x = $pair.x
        foreach ($sz in @($big, 64, 48, 32, 16)) {
            $ic = New-Icon $sz $c.k $pair.c
            $gc.DrawImage($ic, $x, ($iy + ($big - $sz) / 2)); $ic.Dispose()
            $x += $sz + 22
        }
    }
    $y += $rowH
    $gc.DrawLine($pLine, 30, ($y - 14), 1470, ($y - 14))
}

$y += 8
$gc.DrawString('已选定的名字：教务直达（拿候选 1 合成标题栏，2 倍像素）', $fH, $bInk, 30, $y)
$y += 50
$fName = New-PxFont 'Microsoft YaHei UI' 34 ([System.Drawing.FontStyle]::Bold)
$fPage = New-PxFont 'Microsoft YaHei UI' 31
$fIcon = New-PxFont 'Segoe Fluent Icons' 26
$pFrame = [System.Drawing.Pen]::new($LINE, 1)
$barW = 1310; $barH = 72; $barX = 160
$gc.DrawRectangle($pFrame, $barX, $y, ($barW - 1), ($barH - 1))
$mark = New-Icon 44 'cal' $BRAND
$gc.DrawImage($mark, ($barX + 28), ($y + 14)); $mark.Dispose()
$gc.DrawString('教务直达', $fName, $bInk, ($barX + 88), ($y + 16))
$nameW = $gc.MeasureString('教务直达', $fName).Width
$gc.DrawString('首页', $fPage, $bSec, ($barX + 88 + $nameW + 10), ($y + 19))
$bx = $barX + $barW - 92 * 3
foreach ($gl in @([char]0xE921, [char]0xE922, [char]0xE8BB)) {
    $gc.DrawString([string]$gl, $fIcon, $bInk, ($bx + 36), ($y + 24)); $bx += 92
}
$y += $barH + 22
$gc.DrawString('这里只是把候选 1 摆进标题栏看搭配，图标与底色都以你最终选的为准。', $fSm, $bSec, 160, $y)

$y += 48
$gc.DrawString('首次运行横幅 —— 补上"非官方"的交代', $fH, $bInk, 30, $y)
$y += 50
$bannerBrush = [System.Drawing.SolidBrush]::new($NEUTRAL)
$gc.FillRectangle($bannerBrush, 30, $y, 1410, 80)
$gc.DrawLine($pLine, 30, ($y + 80), 1440, ($y + 80))
$fBan = New-PxFont 'Microsoft YaHei UI' 20
$gc.DrawString('非官方：这是个人做的教务系统快捷入口，与学校无关。', $fBan, $bInk, 56, ($y + 16))
$gc.DrawString('登录后记住账号（加密存在本机），以后双击图标直接进教务系统。', $fBan, $bInk, 56, ($y + 46))
$gc.Dispose()
$canvas.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$canvas.Dispose()
Write-Host "已生成身份预览：$OutPath（$($candidates.Count) 个候选 × 3 种底色）"
