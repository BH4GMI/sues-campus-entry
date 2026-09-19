<#
.SYNOPSIS
    抓取 CampusEntry 窗口截图，用于人工与模型逐项核验显示效果。

.DESCRIPTION
    源码级核验（单元测试）证明不了「显示效果」，所以显示这一层用真实截图核验。

    默认用 **PrintWindow(PW_RENDERFULLCONTENT)** 而不是抓屏幕，理由有三条：

      1. **被遮挡也能拿到正确内容**：抓屏幕会把当时盖在上面的任何窗口一起拍进去，
         核验直接失效（实测踩过一次）。
      2. **只包含本窗口**：抓屏幕会把用户当时开着的一切——别的应用、聊天记录——
         一起落成文件。截图是要进仓库的附件，不该带这些东西。
      3. 不受鼠标位置、虚拟桌面、其他显示器影响。

    注意返回的矩形是**物理像素**：在 200% 缩放的显示器上，1080 DIP 的窗口会得到
    2160 像素宽，这是预期结果，不是 bug。

.PARAMETER OutPath
    输出 PNG 路径。

.PARAMETER ProcessName
    进程名，默认 CampusEntry。

.PARAMETER Start
    加这个开关时，若进程未运行则先启动 exe（默认启动 bin\Debug 下的构建产物）。

.PARAMETER ExePath
    与 -Start 搭配，指定要启动的 exe（例如发布出来的便携单文件版）。

.PARAMETER WaitSeconds
    启动或置前之后等待的秒数，让页面与动画稳定下来。

.PARAMETER CropTop
    只保留窗口顶部若干物理像素（核验标题栏/工具栏细节时很有用）。

.PARAMETER Screen
    退回「抓屏幕」。只有在 PrintWindow 拿不到内容时才需要（例如某些 GPU 合成的子窗口），
    且要自己确保没有别的窗口遮挡。

.EXAMPLE
    pwsh -File pc/tools/capture-window.ps1 -Start -WaitSeconds 12
    pwsh -File pc/tools/capture-window.ps1 -CropTop 160 -OutPath docs/screenshots/_top.png
    pwsh -File pc/tools/capture-window.ps1 -Start -ExePath pc/dist/CampusEntry.exe
#>
[CmdletBinding()]
param(
    [string] $OutPath = 'D:\Workspace\webvpn\docs\screenshots\pc-window.png',
    [string] $ProcessName = 'CampusEntry',
    [switch] $Start,
    [string] $ExePath,
    [int] $WaitSeconds = 3,
    [int] $CropTop = 0,
    [switch] $Screen
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CaptureWin {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@

# PW_RENDERFULLCONTENT：让 DWM 合成的窗口（WPF 就是）也能被 PrintWindow 正确渲染
$PwRenderFullContent = 0x00000002

$process = Get-Process $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $process -and $Start) {
    $exe = $ExePath
    if (-not $exe) {
        $exe = Join-Path $PSScriptRoot '..\src\CampusEntry\bin\Debug\net8.0-windows\CampusEntry.exe'
    }
    $exe = [System.IO.Path]::GetFullPath($exe)
    if (-not (Test-Path $exe)) { throw "找不到可执行文件：$exe" }
    Start-Process -FilePath $exe | Out-Null
    Start-Sleep -Seconds $WaitSeconds
    $process = Get-Process $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $process) { throw "进程 $ProcessName 未在运行，且没有加 -Start" }

$handle = $process.MainWindowHandle
if ($handle -eq [IntPtr]::Zero) {
    Start-Sleep -Seconds 2
    $process.Refresh()
    $handle = $process.MainWindowHandle
    if ($handle -eq [IntPtr]::Zero) { throw "进程 $ProcessName 还没有主窗口" }
}

[CaptureWin]::ShowWindow($handle, 9) | Out-Null          # SW_RESTORE
[CaptureWin]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 900

$rect = New-Object CaptureWin+RECT
[CaptureWin]::GetWindowRect($handle, [ref]$rect) | Out-Null
$width = $rect.R - $rect.L
$height = $rect.B - $rect.T

function Test-Blank([System.Drawing.Bitmap] $Bitmap) {
    # 只采样网格；整幅同色就认为没抓到内容（PrintWindow 对个别窗口会返回纯黑）
    $first = $Bitmap.GetPixel(0, 0)
    for ($y = 0; $y -lt $Bitmap.Height; $y += [Math]::Max(1, [int]($Bitmap.Height / 12))) {
        for ($x = 0; $x -lt $Bitmap.Width; $x += [Math]::Max(1, [int]($Bitmap.Width / 12))) {
            $c = $Bitmap.GetPixel($x, $y)
            if ($c.R -ne $first.R -or $c.G -ne $first.G -or $c.B -ne $first.B) { return $false }
        }
    }
    return $true
}

$bitmap = [System.Drawing.Bitmap]::new($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$method = 'PrintWindow'
try {
    if (-not $Screen) {
        $hdc = $graphics.GetHdc()
        try {
            [CaptureWin]::PrintWindow($handle, $hdc, $PwRenderFullContent) | Out-Null
        }
        finally {
            $graphics.ReleaseHdc($hdc)
        }
        if (Test-Blank $bitmap) {
            Write-Warning 'PrintWindow 返回了空白内容，退回抓屏幕（请确保没有别的窗口遮挡）'
            $method = 'Screen'
        }
    }
    else {
        $method = 'Screen'
    }
    if ($method -eq 'Screen') {
        $graphics.CopyFromScreen($rect.L, $rect.T, 0, 0, [System.Drawing.Size]::new($width, $height))
    }
}
finally {
    $graphics.Dispose()
}

if ($CropTop -gt 0 -and $CropTop -lt $height) {
    $cropped = [System.Drawing.Bitmap]::new($width, $CropTop)
    $gc = [System.Drawing.Graphics]::FromImage($cropped)
    $gc.DrawImage($bitmap, [System.Drawing.Rectangle]::new(0, 0, $width, $CropTop),
                  [System.Drawing.Rectangle]::new(0, 0, $width, $CropTop), [System.Drawing.GraphicsUnit]::Pixel)
    $gc.Dispose()
    $bitmap.Dispose()
    $bitmap = $cropped
    $height = $CropTop
}

$directory = Split-Path -Parent $OutPath
if ($directory -and -not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$bitmap.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()

Write-Host ("已抓取 {0}：窗口 {1}x{2} 物理像素 @ ({3},{4})，方式={5}，标题「{6}」" -f `
        $OutPath, $width, $height, $rect.L, $rect.T, $method, $process.MainWindowTitle)
