@echo off
title XeMonitor - Status
setlocal
echo ========================================
echo  Status do Bridge (WSL2) e XeMonitor
echo ========================================
echo.

:: ---- Detecta distro WSL (Alpine padrao; Arch fallback) ----
set "DISTRO="
wsl -d Alpine echo ok >nul 2>&1
if %errorlevel% equ 0 ( set "DISTRO=Alpine" )
if not defined DISTRO (
    wsl -d Arch echo ok >nul 2>&1
    if %errorlevel% equ 0 ( set "DISTRO=Arch" )
)
if defined DISTRO ( echo --- Distro WSL: %DISTRO% --- ) else ( echo --- Distro WSL: nao detectada --- )

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

echo --- Servico 'xemonitor-bridge' ---
if defined DISTRO (
    call scripts\bridge_ctl.bat status 2>&1 | findstr /C:"active" /C:"running" /C:"started" /C:"loaded" /C:"status" /C:"stopped" /C:"dead" /C:"inactive"
) else (
    echo [OFF] distro nao detectada; servico nao consultado.
)
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
if defined DISTRO ( wsl -d %DISTRO% ls -la /dev/ttyUSB0 2>&1 ) else ( echo [OFF] distro nao detectada. )
echo.
pause
