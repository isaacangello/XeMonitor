@echo off
title XeMonitor - Instalar Autostart
setlocal

:: ------- Auto-elevacao para Admin -------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [setup] Solicitando privilegios de administrador...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\" %*' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
pushd ..
set "ROOT=%CD%"
popd

echo ==========================================
echo  Instalando autostart do XeMonitor
echo ==========================================
echo.
echo Raiz do projeto: %ROOT%
echo.

echo [1/3] Tarefa: XeMonitor-USB-Attach (attach CH340 ao WSL no logon)...
schtasks /Create /F /TN "XeMonitor-USB-Attach" /TR "\"%ROOT%\setup_usb.bat\"" /SC ONLOGON /RL HIGHEST
if %errorlevel% neq 0 ( echo        [ERRO] falha ao criar. & goto :fail )

echo [2/3] Tarefa: XeMonitor-Bridge (inicia servico systemd no WSL, +30s)...
schtasks /Create /F /TN "XeMonitor-Bridge" /TR "cmd /c \"wsl -d Arch -u root systemctl start xemonitor-bridge\"" /SC ONLOGON /DELAY 0000:30
if %errorlevel% neq 0 ( echo        [ERRO] falha ao criar. & goto :fail )

echo [3/3] Tarefa: XeMonitor-App (inicia xemonitor TCP, +45s)...
schtasks /Create /F /TN "XeMonitor-App" /TR "\"%ROOT%\zig-out\bin\xemonitor.exe\" --tcp 127.0.0.1:9000 --no-tray" /SC ONLOGON /DELAY 0000:45 /RL LIMITED
if %errorlevel% neq 0 ( echo        [ERRO] falha ao criar. & goto :fail )

echo.
echo ==========================================
echo  Tarefas criadas com sucesso!
echo  Para remover: scripts\uninstall_autostart.bat
echo ==========================================
pause
exit /b 0

:fail
echo.
echo [ERRO] Nem todas as tarefas foram criadas. Verifique acima.
pause
exit /b 1
