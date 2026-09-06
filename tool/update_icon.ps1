# 项目图标生成脚本：SVG -> PNG/ICO 全套替换
# 用法：powershell -ExecutionPolicy Bypass -File tool\update_icon.ps1 <svg路径>
param(
    [Parameter(Mandatory = $true)][string]$SvgPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$tmp = Join-Path $env:TEMP 'sync_translate_icon'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

Add-Type -AssemblyName System.Drawing

# 1) SVG -> 1024x1024 PNG（Edge headless 渲染，透明背景）
$html = Join-Path $tmp 'icon.html'
@"
<!DOCTYPE html><html><head><style>
html,body{margin:0;padding:0;width:1024px;height:1024px;background:transparent}
img{width:1024px;height:1024px;display:block}
</style></head><body>
<img src="file:///$($SvgPath -replace '\\','/')">
</body></html>
"@ | Set-Content $html -Encoding UTF8

$master = Join-Path $tmp 'master.png'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
# Edge 会输出无害的 stderr 噪声，临时放宽错误策略
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $edge --headless --disable-gpu --default-background-color=00000000 `
    --screenshot="$master" --window-size=1024,1024 "file:///$($html -replace '\\','/')" 2>$null
$ErrorActionPreference = $oldEap
Start-Sleep -Seconds 2
if (-not (Test-Path $master)) { Write-Error 'Edge 渲染失败' }

$bmp = [System.Drawing.Bitmap]::FromFile($master)

# 2) 白底兜底转透明（若 Edge 未输出 alpha，把白色像素变透明）
$anyAlpha = $false
for ($x = 0; $x -lt 64; $x++) { for ($y = 0; $y -lt 64; $y++) {
    if ($bmp.GetPixel($x, $y).A -lt 255) { $anyAlpha = $true; break } }; if ($anyAlpha) { break } }
if (-not $anyAlpha) {
    Write-Host 'Edge 未输出透明通道，执行白色转透明…'
    for ($x = 0; $x -lt $bmp.Width; $x++) { for ($y = 0; $y -lt $bmp.Height; $y++) {
        $p = $bmp.GetPixel($x, $y)
        if ($p.R -gt 245 -and $p.G -gt 245 -and $p.B -gt 245) {
            $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $p.R, $p.G, $p.B))
        } } }
    $bmp.Save($master, [System.Drawing.Imaging.ImageFormat]::Png)
}

function Resize-Png([int]$size, [string]$outPath) {
    $b = New-Object System.Drawing.Bitmap($size, $size)
    $g2 = [System.Drawing.Graphics]::FromImage($b)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g2.DrawImage($bmp, 0, 0, $size, $size)
    $b.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g2.Dispose(); $b.Dispose()
}

# 3) 生成多尺寸 ICO（PNG 内嵌格式，Vista+ 通用）
function New-Ico([int[]]$sizes, [string]$outPath) {
    $pngs = foreach ($s in $sizes) {
        $p = Join-Path $tmp "icon_$s.png"
        Resize-Png $s $p
        , $p
    }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count) # 头
    $offset = 6 + 16 * $pngs.Count
    $entries = @()
    foreach ($p in $pngs) {
        $data = [System.IO.File]::ReadAllBytes($p)
        $entries += , @{ Size = $sizes[[array]::IndexOf($pngs, $p)]; Data = $data; Offset = $offset }
        $offset += $data.Length
    }
    foreach ($e in $entries) {
        $bw.Write([byte]($(if ($e.Size -ge 256) { 0 } else { $e.Size })))
        $bw.Write([byte]($(if ($e.Size -ge 256) { 0 } else { $e.Size })))
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$e.Data.Length)
        $bw.Write([uint32]$e.Offset)
    }
    foreach ($e in $entries) { $bw.Write($e.Data) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($outPath, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
    Write-Host "  ICO 生成: $outPath"
}

$icoSizes = @(16, 24, 32, 48, 64, 128, 256)

# 4) Windows：应用图标 + 托盘图标
New-Ico $icoSizes (Join-Path $projectRoot 'windows\runner\resources\app_icon.ico')
Copy-Item (Join-Path $projectRoot 'windows\runner\resources\app_icon.ico') `
    (Join-Path $projectRoot 'assets\tray_icon.ico') -Force
Write-Host '  Windows 图标已替换'

# 5) Android：mipmap 各密度启动图标 + 自适应前景图
$androidRes = Join-Path $projectRoot 'android\app\src\main\res'
$mipmaps = @{ 'mipmap-mdpi' = 48; 'mipmap-hdpi' = 72; 'mipmap-xhdpi' = 96;
              'mipmap-xxhdpi' = 144; 'mipmap-xxxhdpi' = 192 }
foreach ($dir in $mipmaps.Keys) {
    Resize-Png $mipmaps[$dir] (Join-Path $androidRes "$dir\ic_launcher.png")
    Write-Host "  Android $dir -> $($mipmaps[$dir])px"
}
# 自适应图标前景（432x432，内容约占 66%，居中留边）
$anydpiDir = Join-Path $androidRes 'mipmap-anydpi-v26'
New-Item -ItemType Directory -Force -Path $anydpiDir | Out-Null
$fg = New-Object System.Drawing.Bitmap(432, 432)
$g = [System.Drawing.Graphics]::FromImage($fg)
$g.Clear([System.Drawing.Color]::Transparent)
$inner = New-Object System.Drawing.Bitmap($bmp, 288, 288)
$g.DrawImage($inner, 72, 72, 288, 288)
$fg.Save((Join-Path $anydpiDir 'ic_launcher_foreground.png'),
         [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $fg.Dispose(); $inner.Dispose()
Write-Host '  Android 自适应前景图已替换'

# 6) macOS：AppIcon.appiconset 全套（新模板命名 app_icon_*.png）
$macIcons = Join-Path $projectRoot 'macos\Runner\Assets.xcassets\AppIcon.appiconset'
$macSizes = @{
    'app_icon_16.png' = 16; 'app_icon_32.png' = 32
    'app_icon_64.png' = 64; 'app_icon_128.png' = 128
    'app_icon_256.png' = 256; 'app_icon_512.png' = 512
    'app_icon_1024.png' = 1024
}
foreach ($f in $macSizes.Keys) {
    $dest = Join-Path $macIcons $f
    if (Test-Path $dest) {
        Resize-Png $macSizes[$f] $dest
        Write-Host "  macOS $f -> $($macSizes[$f])px"
    }
}

$bmp.Dispose()
Write-Host '完成。Windows 需重新构建生效；托盘图标随应用重启生效。'
