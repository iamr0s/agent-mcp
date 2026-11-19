@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1" %*
if errorlevel 1 (
    echo.
    echo [Agent MCP] Installation failed with exit code %errorlevel%.
    pause
    exit /b %errorlevel%
)
echo.
pause
