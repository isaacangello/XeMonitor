@echo off
title XeMonitor - Instalar Autostart
setlocal

:: ------- /silent: sem pause (usado pelo install_windows.bat) -------
set "SILENT=%~1"

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

:: 1. USB attach (logon). Auto-eleva (usbipd precisa de admin p/ bind/attach).
echo [1/3] Tarefa: XeMonitor-USB-Attach (attach CH340 ao WSL no logon)...
schtasks /Create /F /TN "XeMonitor-USB-Attach" /TR "\"%ROOT%\setup_usb.bat\"" /SC ONLOGON /RL HIGHEST
if %errorlevel% neq 0 ( echo        [ERRO] falha ao criar. & goto :fail )

:: 2. Bridge (logon, +30s). bridge_ctl.bat detecta Alpine(OpenRC)/Arch(systemd)
::    e habilita+inicia o servico.
echo [2/3] Tarefa: XeMonitor-Bridge (inicia servico do bridge, +30s)...
schtasks /Create /F /TN "XeMonitor-Bridge" /TR "cmd /c \"\"%ROOT%\scripts\bridge_ctl.bat\" enable\"" /SC ONLOGON /DELAY 0000:30
if %errorlevel% neq 0 ( echo        [ERRO] falha ao criar. & goto :fail )

:: 3. GUI principal (logon, +45s). /RL LIMITED p/ manter UIPI em integridade Media.
::    xemonitor-gui.exe le a config (server_mode=wsl, auto_start=true) e
::    inicia bridge + cliente. Usa o wrapper .cmd (packaging\windows).
echo [3/3] Tarefa: XeMonitor-App (inicia o GUI, +45s)...
schtasks /Create /F /TN "XeMonitor-App" /TR "\"%ROOT%\packaging\windows\start_xemonitor.cmd\"" /SC ONLOGON /DELAY 0000:45 /RL LIMITED
if %errorlevel% neq 0 ( echo        [ERRO] falha ao criar. & goto :fail )

echo.
echo ==========================================
echo  Tarefas criadas com sucesso!
echo  Para remover: scripts\uninstall_autostart.bat
echo ==========================================
if /i not "%SILENT%"=="/silent" pause
exit /b 0

:fail
echo.
echo [ERRO] Nem todas as tarefas foram criadas. Verifique acima.
if /i not "%SILENT%"=="/silent" pause
exit /b 1
