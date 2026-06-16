@echo off
title XeMonitor Bridge + Scanner
setlocal enabledelayedexpansion

cd /d "%~dp0"

echo ========================================
echo  Iniciando XeMonitor via WSL2 bridge
echo ========================================
echo.

:: 0. Verifica se o WSL esta rodando
wsl echo ok >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] WSL nao disponivel. Verifique se o WSL2 esta instalado.
    pause
    exit /b 1
)

:: 1. Verifica se /dev/ttyUSB0 existe no WSL
wsl test -c /dev/ttyUSB0 2>nul
if %errorlevel% neq 0 (
    echo [AVISO] /dev/ttyUSB0 nao encontrado no WSL.
    echo.
    echo        Deseja executar o setup automatico do USB?
    echo        (vai pedir privilegios de administrador para usbipd)
    echo.
    choice /C SN /M "Executar setup_usb.bat? (S)im / (N)ao"
    if errorlevel 2 goto skip_usb_setup

    call setup_usb.bat
    if %errorlevel% neq 0 (
        echo [ERRO] Setup USB falhou. Resolva e tente novamente.
        pause
        exit /b 1
    )

    :: Verifica novamente
    wsl test -c /dev/ttyUSB0 2>nul
    if %errorlevel% neq 0 (
        echo [ERRO] /dev/ttyUSB0 continua indisponivel apos setup.
        pause
        exit /b 1
    )
)

:skip_usb_setup

:: 2. Verifica permissao de leitura
wsl test -r /dev/ttyUSB0 2>nul
if %errorlevel% neq 0 (
    echo [AVISO] /dev/ttyUSB0 sem permissao de leitura.
    echo        Execute no WSL2: bash setup_wsl.sh
    pause
    exit /b 1
)

:: 3. Mata bridge anterior se houver
wsl pkill -f bridge 2>nul

:: 4. Determina o caminho do bridge
set BRIDGE_PATH=%CD:\=/%/zig-out/bin/bridge

:: 5. Verifica se o binario existe
if not exist "zig-out\bin\bridge" (
    echo [INFO] Compilando bridge para Linux...
    zig build bridge
    if !errorlevel! neq 0 (
        echo [ERRO] Falha na compilacao do bridge.
        pause
        exit /b 1
    )
)

echo [1/3] Iniciando bridge serial-TCP no WSL2...
echo        Binario: %BRIDGE_PATH%
echo        Modo: raw TCP (porta 9000)
echo.

start "Bridge WSL2" cmd /c "wsl %BRIDGE_PATH%"

echo        Aguardando 3s para o bridge iniciar...
ping -n 4 127.0.0.1 >nul

:: 6. Verifica se o bridge esta rodando
wsl pgrep -f "^bridge$" >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Bridge rodando no WSL2.
) else (
    echo [AVISO] Bridge pode nao ter iniciado.
)

:: 7. Inicia o xemonitor no Windows
echo [2/3] Iniciando xemonitor (TCP bridge)...
start "XeMonitor" cmd /c "zig-out\bin\xemonitor.exe --tcp 127.0.0.1:9000"

:: 8. Abre o Bloco de Notas
echo [3/3] Abrindo Bloco de Notas para teste...
start notepad.exe

echo.
echo ========================================
echo  XeMonitor rodando via TCP bridge WSL2!
echo  Teste escaneando um codigo de barras.
echo  Para encerrar: stop_bridge.bat
echo ========================================
echo.
pause
