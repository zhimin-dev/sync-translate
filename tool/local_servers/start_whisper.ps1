# 启动 faster-whisper 本地语音识别服务（前台运行，Ctrl+C 停止）
# 默认模型 Systran/faster-whisper-large-v3（完整版，准确率最高；速度优先可换
# deepdml/faster-whisper-large-v3-turbo-ct2）
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = Join-Path $root 'venv\Scripts\python.exe'
if (-not (Test-Path $py)) { Write-Error '未安装依赖，请先运行 setup.ps1'; exit 1 }
$modelBin = Join-Path $root 'models\faster-whisper-large-v3\model.bin'
if (-not (Test-Path $modelBin)) {
    Write-Host '模型未下载，先执行下载脚本（可断点续传）…'
    powershell -ExecutionPolicy Bypass -File (Join-Path $root 'download_models.ps1')
}
$env:HF_ENDPOINT = 'https://hf-mirror.com'
& $py (Join-Path $root 'whisper_server.py') --model 'Systran/faster-whisper-large-v3' --port 8000 --device auto
