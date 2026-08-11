@echo off
title XeMonitor - Remover Autostart
setlocal

:: ------- Auto-elevacao para Admin -------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [setup] Solicitando privilegios de administrador...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\" %*' -Verb RunAs"
    exit /b
)

echo ==========================================
echo  Removendo autostart do XeMonitor
echo ==========================================
echo.

schtasks /Delete /F /TN "XeMonitor-USB-Attach"
schtasks /Delete /F /TN "XeMonitor-Bridge"
schtasks /Delete /F /TN "XeMonitor-App"

echo.
echo Tarefas removidas.
pause
