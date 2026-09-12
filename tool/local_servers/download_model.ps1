# 单模型下载脚本（curl 断点续传，直连 hf-mirror，完成后写 .ok 标记）
# 用法：powershell -ExecutionPolicy Bypass -File download_model.ps1 -Repo "org/repo" -Dir "目标目录" -Files "a,b,c"
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Dir,
    [Parameter(Mandatory = $true)][string]$Files
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$ok = Join-Path $Dir 'download.ok'
if (Test-Path $ok) {
    Write-Host 'already done'
    exit 0
}

foreach ($f in ($Files -split ',')) {
    $url = "https://hf-mirror.com/$Repo/resolve/main/$f"
    $out = Join-Path $Dir $f
    # --http1.1 关键：HTTP/2 协商时镜像重定向到美国 xet 桥（挂死）
    curl.exe -L --http1.1 -C - --retry 200 --retry-all-errors --retry-delay 5 `
        --connect-timeout 30 --speed-limit 1024 --speed-time 30 `
        -A "sync-translate-downloader" -o $out $url
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $f"
        exit 1
    }
}
Set-Content -Path $ok -Value (Get-Date -Format o) -Encoding UTF8
Write-Host 'DONE'
exit 0
