# 一键安装本地模型服务依赖（faster-whisper + NLLB-200）
# 用法：powershell -ExecutionPolicy Bypass -File setup.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$venvDir = Join-Path $root 'venv'
$venvPy = Join-Path $venvDir 'Scripts\python.exe'
$index = 'https://pypi.tuna.tsinghua.edu.cn/simple'

Write-Host '== 选择 Python（优先标准版，Anaconda 老版 ucrtbase 会导致 torch 加载失败）=='
$pythonExe = $null
$pyVer = $null
try { $pyVer = (& py -3.11 --version 2>$null); } catch {}
if ($pyVer -match 'Python 3\.1[12]') {
    $pythonExe = 'py -3.11'
    Write-Host "使用: $pyVer"
} else {
    python --version
    if ($LASTEXITCODE -ne 0) {
        Write-Error '未找到 Python。请先安装 Python 3.11（https://www.python.org/downloads/）'
    }
    $pythonExe = 'python'
    Write-Host '未找到标准版 3.11/3.12，回退到默认 python（若为 Anaconda 请留意 torch 问题）'
}

if (-not (Test-Path $venvPy)) {
    Write-Host "== 创建虚拟环境 $venvDir =="
    if ($pythonExe -eq 'py -3.11') {
        py -3.11 -m venv $venvDir
    } else {
        python -m venv $venvDir
    }
} else {
    Write-Host '== 虚拟环境已存在，复用 =='
}

Write-Host '== 升级 pip（清华源）=='
& $venvPy -m pip install -U pip -i $index

Write-Host '== 安装 faster-whisper（STT）、NLLB（PyTorch）与依赖 =='
# 注意：sentencepiece 锁定 0.2.0（0.2.2 的 Windows wheel 在 import 时段错误）；
# ctranslate2 锁定 4.5.0（4.8.2 的 Windows wheel 在 Translator 构造时段错误，
# 4.6+ 依赖已被移除的 pkg_resources）；NLLB 用 PyTorch 官方实现（CT2 跑 NLLB
# 在此环境存在解码退化问题，见 docs/architecture.md 备注）
& $venvPy -m pip install "setuptools<81" -i $index
& $venvPy -m pip install faster-whisper fastapi uvicorn "sentencepiece==0.2.0" huggingface_hub python-multipart "ctranslate2==4.5.0" nvidia-cudnn-cu12 nvidia-cublas-cu12 -i $index

Write-Host '== 安装 PyTorch（CUDA 版，失败则回退 CPU 版）=='
# 注意：清华/阿里 PyPI 镜像的 torch 是 CPU 版；CUDA 版需官方索引
& $venvPy -m pip install "torch==2.9.1+cu126" --index-url https://download.pytorch.org/whl/cu126
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'CUDA 版 torch 安装失败，回退 CPU 版（翻译会慢一些）'
    & $venvPy -m pip install torch -i $index
}
& $venvPy -m pip install transformers -i $index

# cuDNN 运行库必须与 torch 自带版本一致（9.10.2.21），否则 ctranslate2 与 torch
# 同进程加载时同名 DLL 版本冲突（WinError 127）；复制到 ctranslate2 包目录
# （其加载器只搜索自身目录）。版本取自 torch 安装后的实际文件，用脚本对齐：
Write-Host '== 对齐 cuDNN 版本（torch 与 ctranslate2 共用同一份）=='
$torchCudnn = Join-Path $venvDir 'Lib\site-packages\torch\lib\cudnn64_9.dll'
$ct2Dir = Join-Path $venvDir 'Lib\site-packages\ctranslate2'
if (Test-Path $torchCudnn) {
    $ver = (Get-Item $torchCudnn).VersionInfo.FileVersion
    & $venvPy -m pip install "nvidia-cudnn-cu12==$ver" -i $index
    Get-ChildItem $ct2Dir -Filter 'cudnn*' -ErrorAction SilentlyContinue | Remove-Item -Force
    Copy-Item (Join-Path $venvDir 'Lib\site-packages\nvidia\cudnn\bin\*.dll') $ct2Dir -Force
    Copy-Item (Join-Path $venvDir 'Lib\site-packages\nvidia\cublas\bin\*.dll') $ct2Dir -Force
    Write-Host "  cuDNN $ver 已对齐"
} else {
    Copy-Item (Join-Path $venvDir 'Lib\site-packages\nvidia\cudnn\bin\*.dll') $ct2Dir -Force
    Copy-Item (Join-Path $venvDir 'Lib\site-packages\nvidia\cublas\bin\*.dll') $ct2Dir -Force
}

Write-Host ''
Write-Host '完成！模型会在首次启动服务时自动下载（走 hf-mirror 镜像）。'
Write-Host '  启动 STT 服务：  .\start_whisper.ps1  （默认 http://127.0.0.1:8000/v1）'
Write-Host '  启动翻译服务：   .\start_nllb.ps1    （默认 http://127.0.0.1:8765）'
