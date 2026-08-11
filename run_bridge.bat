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
    echo [AVISO] /dev/ttyUSB0 nao encontrado. Executando setup USB...
    echo.
    call setup_usb.bat
    if %errorlevel% neq 0 (
        echo [ERRO] Setup USB falhou. Resolva e tente novamente.
        pause
        exit /b 1
    )

    wsl test -c /dev/ttyUSB0 2>nul
    if %errorlevel% neq 0 (
        echo [ERRO] /dev/ttyUSB0 continua indisponivel apos setup.
        pause
        exit /b 1
    )
)

:: 2. Verifica permissao de leitura
wsl test -r /dev/ttyUSB0 2>nul
if %errorlevel% neq 0 (
    echo [AVISO] /dev/ttyUSB0 sem permissao de leitura.
    echo        Execute no WSL2: bash setup_wsl.sh
    pause
    exit /b 1
)

:: 3. Garante o binario do bridge compilado
if not exist "zig-out\bin\bridge" (
    echo [INFO] Compilando bridge para Linux...
    zig build bridge
    if !errorlevel! neq 0 (
        echo [ERRO] Falha na compilacao do bridge.
        pause
        exit /b 1
    )
)

:: 4. Instala o servico systemd (se necessario) e inicia
echo [1/3] Verificando servico systemd 'xemonitor-bridge'...
wsl systemctl is-active xemonitor-bridge >nul 2>&1
if %errorlevel% neq 0 (
    wsl systemctl is-enabled xemonitor-bridge >nul 2>&1
    if %errorlevel% neq 0 (
        echo [INFO] Instalando servico systemd (copia para /usr/local/bin)...
        wsl bash scripts/install_bridge_service.sh
        if !errorlevel! neq 0 (
            echo [ERRO] Falha ao instalar o servico do bridge.
            pause
            exit /b 1
        )
    )
    echo [INFO] Iniciando servico 'xemonitor-bridge'...
    wsl systemctl start xemonitor-bridge
    if !errorlevel! neq 0 (
        echo [AVISO] O servico pode estar aguardando /dev/ttyUSB0 (start-pre).
    )
)

wsl systemctl is-active xemonitor-bridge >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Bridge rodando no WSL2 (systemd).
) else (
    echo [AVISO] Bridge pode nao ter iniciado (servico ativando/aguardando).
)

:: 5. Inicia o xemonitor no Windows
echo [2/3] Iniciando xemonitor (TCP bridge)...
start "XeMonitor" cmd /c "zig-out\bin\xemonitor.exe --tcp 127.0.0.1:9000"

:: 6. Abre o Bloco de Notas
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
