@echo off
title XeMonitor Bridge + Scanner

echo ========================================
echo  Iniciando XeMonitor via WSL2 bridge
echo ========================================
echo.

:: 0. Verifica se /dev/ttyUSB0 esta acessivel
wsl bash -c "test -r /dev/ttyUSB0" 2>nul
if errorlevel 1 (
    echo [AVISO] /dev/ttyUSB0 sem permissao de leitura.
    echo        Execute no WSL2: bash setup_wsl.sh
    goto :EOF
)

:: 1. Mata bridge anterior se houver
wsl pkill -f bridge 2>nul

:: 2. Determina o caminho do bridge
set BRIDGE_PATH=%CD%\zig-out\bin\bridge

echo [1/3] Iniciando bridge serial-TCP no WSL2 (Zig)...
echo Usando modo raw TCP padrao (porta 9000)
echo Para modo HTTP: bridge -s http://0.0.0.0:8080
echo.

start "Bridge WSL2" cmd /c "wsl %BRIDGE_PATH%"

echo        Aguardando 3s para o bridge iniciar...
ping -n 4 127.0.0.1 >nul

:: 3. Verifica se o bridge esta rodando
wsl pgrep -f "^bridge$" >nul 2>&1
if errorlevel 1 (
    echo [AVISO] Bridge pode nao ter iniciado.
) else (
    echo [OK] Bridge rodando no WSL2.
)

:: 4. Inicia o xemonitor no Windows
echo [2/3] Iniciando xemonitor (TCP bridge)...
start "XeMonitor" cmd /c "zig-out\bin\xemonitor.exe --tcp 127.0.0.1:9000"

:: 5. Abre o Bloco de Notas
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
