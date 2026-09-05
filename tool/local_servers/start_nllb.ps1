# 启动 NLLB-200 本地翻译服务（前台运行，Ctrl+C 停止）
# 依赖 PyTorch + transformers，模型为官方 facebook/nllb-200-distilled-600M
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = Join-Path $root 'venv\Scripts\python.exe'
if (-not (Test-Path $py)) { Write-Error '未安装依赖，请先运行 setup.ps1'; exit 1 }
$modelBin = Join-Path $root 'models\facebook--nllb-200-distilled-600M\pytorch_model.bin'
if (-not (Test-Path $modelBin)) {
    Write-Host '模型未下载，先执行下载脚本（可断点续传）…'
    powershell -ExecutionPolicy Bypass -File (Join-Path $root 'download_models.ps1')
}
& $py (Join-Path $root 'nllb_server.py') --port 8765 --device auto
