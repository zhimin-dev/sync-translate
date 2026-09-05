# 模型下载脚本（curl 断点续传，直连 hf-mirror）
# 用法：powershell -ExecutionPolicy Bypass -File download_models.ps1
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelsDir = Join-Path $root 'models'

$targets = @(
    @{
        Repo = 'facebook/nllb-200-distilled-600M'
        Dir  = Join-Path $modelsDir 'facebook--nllb-200-distilled-600M'
        Files = @('config.json', 'generation_config.json', 'pytorch_model.bin',
                  'sentencepiece.bpe.model', 'special_tokens_map.json',
                  'tokenizer.json', 'tokenizer_config.json')
    },
    @{
        Repo = 'deepdml/faster-whisper-large-v3-turbo-ct2'
        Dir  = Join-Path $modelsDir 'faster-whisper-large-v3-turbo-ct2'
        Files = @('config.json', 'model.bin', 'preprocessor_config.json', 'tokenizer.json', 'vocabulary.json')
    }
)

foreach ($t in $targets) {
    New-Item -ItemType Directory -Force -Path $t.Dir | Out-Null
    Write-Host "== 下载 $($t.Repo) =="
    foreach ($f in $t.Files) {
        $url = "https://hf-mirror.com/$($t.Repo)/resolve/main/$f"
        $out = Join-Path $t.Dir $f
        if ((Test-Path $out) -and ((Get-Item $out).Length -gt 1MB)) {
            Write-Host "  跳过（已存在）: $f"
            continue
        }
        Write-Host "  下载: $f"
        # --http1.1 关键：HTTP/2 协商时 hf-mirror 会重定向到美国 xet 桥（挂死），
        # HTTP/1.1 则重定向到镜像自身缓存（国内快）；另加低速中断重试。
        curl.exe -L --http1.1 -C - --retry 100 --retry-all-errors --retry-delay 3 `
            --connect-timeout 30 --speed-limit 2048 --speed-time 20 `
            -A "sync-translate-downloader" -o $out $url
        if ($LASTEXITCODE -ne 0) { Write-Warning "  $f 下载失败（可重跑本脚本续传）" }
    }
}
Write-Host '完成。'
