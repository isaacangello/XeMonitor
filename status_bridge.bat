@echo off
title XeMonitor - Status
echo ========================================
echo  Status do Bridge (WSL2) e XeMonitor
echo ========================================
echo.

echo --- Servico systemd 'xemonitor-bridge' ---
wsl systemctl status xemonitor-bridge --no-pager 2>&1 | findstr /C:"Loaded" /C:"Active" /C:"Main PID" /C:"CGroup"
echo.

echo --- xemonitor.exe (Windows) ---
tasklist /FI "IMAGENAME eq xemonitor.exe" 2>nul | findstr /I "xemonitor" >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] xemonitor.exe rodando.
) else (
    echo [OFF] xemonitor.exe nao esta rodando.
)

echo.
echo --- /dev/ttyUSB0 ---
wsl ls -la /dev/ttyUSB0 2>&1
echo.

echo --- Docker (WSL) ---
wsl systemctl is-active docker >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Docker ativo.
) else (
    echo [OFF] Docker inativo.
)
echo.
pause
