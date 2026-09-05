# 一键安装本地模型服务依赖（faster-whisper + NLLB-200）
# 用法：powershell -ExecutionPolicy Bypass -File setup.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$venvDir = Join-Path $root 'venv'
$venvPy = Join-Path $venvDir 'Scripts\python.exe'
$index = 'https://pypi.tuna.tsinghua.edu.cn/simple'

Write-Host '== 检查 Python =='
python --version
if ($LASTEXITCODE -ne 0) {
    Write-Error '未找到 Python。请先安装 Python 3.9–3.12（https://www.python.org/downloads/）'
}

if (-not (Test-Path $venvPy)) {
    Write-Host "== 创建虚拟环境 $venvDir =="
    python -m venv $venvDir
} else {
    Write-Host '== 虚拟环境已存在，复用 =='
}

Write-Host '== 升级 pip（清华源）=='
& $venvPy -m pip install -U pip -i $index

Write-Host '== 安装 faster-whisper（STT）与 NLLB 服务依赖 =='
# 注意：sentencepiece 锁定 0.2.0（0.2.2 的 Windows wheel 在 import 时段错误）；
# ctranslate2 锁定 4.5.0（4.8.2 的 Windows wheel 在 Translator 构造时段错误）
& $venvPy -m pip install faster-whisper fastapi uvicorn "sentencepiece==0.2.0" huggingface_hub python-multipart "ctranslate2==4.5.0" -i $index

Write-Host ''
Write-Host '完成！模型会在首次启动服务时自动下载（走 hf-mirror 镜像）。'
Write-Host '  启动 STT 服务：  .\start_whisper.ps1  （默认 http://127.0.0.1:8000/v1）'
Write-Host '  启动翻译服务：   .\start_nllb.ps1    （默认 http://127.0.0.1:8765）'
