@echo off
rem 一键启动本地模型服务（faster-whisper + NLLB-200），各开一个窗口显示日志。
rem 注意：应用现在会自动拉起这两个服务，本脚本仅在需要手动管理时使用。
cd /d "%~dp0"

if not exist "venv\Scripts\python.exe" (
    echo [错误] 未安装依赖，请先运行 setup.ps1
    pause
    exit /b 1
)

if not exist "models\faster-whisper-large-v3-turbo-ct2\model.bin" (
    echo [提示] whisper 模型未下载，开始下载（可断点续传）…
    powershell -ExecutionPolicy Bypass -File download_models.ps1
)

start "sync-translate whisper" powershell -NoExit -ExecutionPolicy Bypass -File start_whisper.ps1
start "sync-translate nllb" powershell -NoExit -ExecutionPolicy Bypass -File start_nllb.ps1

echo 两个服务已在独立窗口启动：
echo   STT  : http://127.0.0.1:8000/v1
echo   翻译 : http://127.0.0.1:8765
echo 关闭对应窗口即停止服务。
