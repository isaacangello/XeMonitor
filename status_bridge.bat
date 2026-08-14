@echo off
title XeMonitor - Status
echo ========================================
echo  Status do Bridge (WSL2) e XeMonitor
echo ========================================
echo.

echo --- Pasta central de config/log (%%APPDATA%%\xemonitor) ---
if exist "%APPDATA%\xemonitor" (
    echo [OK] %APPDATA%\xemonitor
    dir /b "%APPDATA%\xemonitor" 2>nul | findstr /R "xemonitor-.log xemonitor.log xemonitor.pid xemonitor_tray.pid" >nul 2>&1
    if %errorlevel% equ 0 (echo [OK] arquivos de log/pid presentes.) else (echo [INFO] ainda sem log/pid (rode o xemonitor).)
    rem Log rotativo por data: xemonitor-YYYY-MM-DD.log (fallback p/ legado)
    powershell -NoProfile -Command "$d='%APPDATA%\xemonitor\xemonitor-'+(Get-Date -Format 'yyyy-MM-dd')+'.log'; if(-not (Test-Path $d)){$d='%APPDATA%\xemonitor\xemonitor.log'}; if(Test-Path $d){Write-Host '--- ultimas linhas do log ---'; Get-Content $d -Tail 5} else {Write-Host '[INFO] log ainda nao criado.'}"
) else (
    echo [AVISO] %%APPDATA%%\xemonitor nao existe ainda (rode o xemonitor.exe).
)
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
