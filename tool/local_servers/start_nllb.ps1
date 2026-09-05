# 启动 NLLB-200 本地翻译服务（前台运行，Ctrl+C 停止）
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = Join-Path $root 'venv\Scripts\python.exe'
if (-not (Test-Path $py)) { Write-Error '未安装依赖，请先运行 setup.ps1'; exit 1 }
$env:HF_ENDPOINT = 'https://hf-mirror.com'
& $py (Join-Path $root 'nllb_server.py') --model 'JustFrederik/nllb-200-distilled-600M-ct2-int8' --port 8765 --device auto
