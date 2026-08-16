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
echo.
echo [3/4] Attachando CH340 ao WSL (%DISTRO%)...
"%USBIPD%" attach -w %DISTRO% --hardware-id 1a86:7523
if %errorlevel% neq 0 (
    echo.
    echo [AVISO] Falha no attach. Tentando com shutdown do WSL...
    wsl --shutdown
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

:: ------- Verifica /dev/ttyUSB0 -------
echo.
echo [4/4] Aguardando dispositivo e verificando...
timeout /t 3 /nobreak >nul

wsl -d %DISTRO% test -c /dev/ttyUSB0 2>nul
if %errorlevel% equ 0 (
    echo [OK] /dev/ttyUSB0 disponivel!
    wsl -d %DISTRO% ls -la /dev/ttyUSB0
) else (
    echo [AVISO] /dev/ttyUSB0 nao encontrado.
    echo         Execute manualmente: wsl -d %DISTRO% ls -la /dev/ttyUSB0
    echo.
    echo         Se persistir, tente:
    echo         1. wsl --shutdown
    echo         2. Execute este script novamente
    echo         3. Verifique se os modulos do kernel estao carregados:
    echo            wsl -d %DISTRO% -u root modprobe usbip-core
    echo            wsl -d %DISTRO% -u root modprobe vhci-hcd
)

echo.
echo ==========================================
echo  Setup USB concluido!
echo  Agora execute: run_bridge.bat
echo ==========================================
echo.
call :pause_helper
exit /b 0

:: ============================================================
:: :pause_helper - pausa so em modo interativo (sem /silent)
:: ============================================================
:pause_helper
if /i not "%SILENT%"=="/silent" pause
exit /b 0
