# 启动 faster-whisper 本地语音识别服务（前台运行，Ctrl+C 停止）
# 默认模型 deepdml/faster-whisper-large-v3-turbo-ct2（GPU 极快）
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = Join-Path $root 'venv\Scripts\python.exe'
if (-not (Test-Path $py)) { Write-Error '未安装依赖，请先运行 setup.ps1'; exit 1 }
$env:HF_ENDPOINT = 'https://hf-mirror.com'
& $py (Join-Path $root 'whisper_server.py') --model 'deepdml/faster-whisper-large-v3-turbo-ct2' --port 8000 --device auto
