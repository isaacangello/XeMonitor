@echo off
title XeMonitor - Setup USB CH340 p/ WSL
setlocal enabledelayedexpansion

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
echo ==========================================
echo  XeMonitor - Setup USB CH340 para WSL
echo ==========================================
echo.

:: ---- Detecta distro WSL (Alpine OBRIGATORIA) ----
set "DISTRO="
wsl -d Alpine echo ok >nul 2>&1
if %errorlevel% equ 0 ( set "DISTRO=Alpine" )
if not defined DISTRO (
    echo [ERRO] Nenhuma distro WSL encontrada - o instalador define o Alpine como padrao.
    echo        Rode o instalador install_windows.bat / setup.exe: ele baixa o Alpine
    echo        e o define como distribuicao padrao. Alternativa manual: wsl --install -d Alpine
    wsl -l -v
    call :pause_helper
    exit /b 1
)
echo [INFO] Distro WSL: %DISTRO%
echo.

:: ------- Verifica usbipd -------
set "USBIPD=usbipd"
where usbipd >nul 2>&1
if %errorlevel% neq 0 (
    if exist "C:\Program Files\usbipd-win\usbipd.exe" (
        set "USBIPD=C:\Program Files\usbipd-win\usbipd.exe"
    ) else (
        echo [ERRO] usbipd nao encontrado.
        echo        Instale com: winget install usbipd
        call :pause_helper
        exit /b 1
    )
)
echo [OK] usbipd encontrado (%USBIPD%).

:: ------- Remove binding persistente antigo (COM4) -------
echo.
echo [1/4] Removendo binding persistente antigo...
"%USBIPD%" unbind -g "21402a02-b0bf-4121-9134-359bbe6ab18a" >nul 2>&1
if %errorlevel% equ 0 (
    echo        Binding antigo removido.
) else (
    echo        Nenhum binding pendente encontrado.
)

:: ------- Bind CH340 por hardware ID -------
echo.
echo [2/4] Compartilhando CH340 (1a86:7523)...
"%USBIPD%" bind --hardware-id 1a86:7523
if %errorlevel% neq 0 (
    echo [ERRO] Falha ao compartilhar CH340.
    echo        Tente manualmente: usbipd bind --hardware-id 1a86:7523
    call :pause_helper
    exit /b 1
)
echo        OK - CH340 compartilhado (Ready for attach).

:: ------- Attach ao WSL -------
:: No logon o WSL pode ainda estar subindo -> espera o Alpine responder antes
:: do attach (um attach com a distro parada falha em silencio na tarefa
:: XeMonitor-USB-Attach).
echo.
echo [3/4] Aguardando WSL %DISTRO% pronto...
set "WSL_OK=0"
for /l %%I in (1,1,30) do (
    wsl -d %DISTRO% echo ok >nul 2>&1
    if !errorlevel! equ 0 set "WSL_OK=1"
    if !WSL_OK! equ 1 goto :wsl_ok
    timeout /t 1 /nobreak >nul
)
:wsl_ok
if !WSL_OK! neq 1 (
    echo [ERRO] WSL %DISTRO% nao respondeu apos 30s.
    call :pause_helper
    exit /b 1
)
echo        OK - WSL pronto.

echo.
echo Attachando CH340 ao WSL (%DISTRO%)...
"%USBIPD%" attach -w %DISTRO% --hardware-id 1a86:7523
if %errorlevel% neq 0 (
    echo.
    echo [AVISO] Falha no attach. Tentando novamente em 5s...
    timeout /t 5 /nobreak >nul
    "%USBIPD%" attach -w %DISTRO% --hardware-id 1a86:7523
    if %errorlevel% neq 0 (
        echo [ERRO] Continua falhando.
        echo        Verifique:
        echo        1. WSL esta atualizado: wsl --update
        echo        2. O CH340 esta conectado em outra COM
        echo        3. Tempo: aguarde 10s e tente novamente
        call :pause_helper
        exit /b 1
    )
)
echo        OK - CH340 attachado ao WSL.

:: ------- Garante o modulo ch341 carregado no WSL -------
echo.
echo [4/4] Verificando modulo ch341 + /dev/ttyUSB0...
wsl -d %DISTRO% -u root modprobe ch341 >nul 2>&1
wsl -d %DISTRO% -u root sh -c "lsmod | grep ch341" >nul 2>&1
if %errorlevel% equ 0 (
    echo        OK - modulo ch341 carregado.
) else (
    echo        [AVISO] modulo ch341 nao confirmado. Verifique: wsl -d %DISTRO% -u root modprobe ch341
)

:: ------- Poll do /dev/ttyUSB0 (ate ~15s) -------
set "TTY_OK=0"
for /l %%I in (1,1,15) do (
    wsl -d %DISTRO% test -c /dev/ttyUSB0 >nul 2>&1
    if !errorlevel! equ 0 set "TTY_OK=1"
    if !TTY_OK! equ 1 goto :tty_ok
    timeout /t 1 /nobreak >nul
)
:tty_ok
if !TTY_OK! equ 1 (
    echo [OK] /dev/ttyUSB0 disponivel!
    wsl -d %DISTRO% ls -la /dev/ttyUSB0
    if not exist "%APPDATA%\xemonitor\logs" mkdir "%APPDATA%\xemonitor\logs" >nul 2>&1
    echo %date% %time%  setup_usb: /dev/ttyUSB0 detectado - OK>>"%APPDATA%\xemonitor\logs\setup-usb.log"
    echo.
    echo ==========================================
    echo  Setup USB concluido!
    echo  Agora execute: run_bridge.bat
    echo ==========================================
    echo.
    call :pause_helper
    exit /b 0
)

:: ------- Falha: tty ausente -------
echo [ERRO] /dev/ttyUSB0 nao encontrado apos 15s.
echo         Execute manualmente: wsl -d %DISTRO% ls -la /dev/ttyUSB0
echo.
echo         Se persistir, tente:
echo         1. wsl --shutdown
echo         2. Execute este script novamente
echo         3. Verifique se os modulos do kernel estao carregados:
echo            wsl -d %DISTRO% -u root modprobe usbip-core
echo            wsl -d %DISTRO% -u root modprobe vhci-hcd
echo            wsl -d %DISTRO% -u root modprobe ch341
echo.
echo ==========================================
echo  Setup USB falhou.
echo ==========================================
echo.
if not exist "%APPDATA%\xemonitor\logs" mkdir "%APPDATA%\xemonitor\logs" >nul 2>&1
echo %date% %time%  setup_usb: /dev/ttyUSB0 NAO detectado apos attach>>"%APPDATA%\xemonitor\logs\setup-usb.log"
call :pause_helper
exit /b 1

:: ============================================================
:: :pause_helper - pausa so em modo interativo (sem /silent)
:: ============================================================
:pause_helper
if /i not "%SILENT%"=="/silent" pause
exit /b 0
