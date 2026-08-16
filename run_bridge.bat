@echo off
title XeMonitor Bridge + Scanner
setlocal enabledelayedexpansion

cd /d "%~dp0"

echo ========================================
echo  Iniciando XeMonitor via WSL2 bridge
echo ========================================
echo.

:: ---- Detecta distro WSL (Alpine OBRIGATORIA; instalador define como padrao) ----
set "DISTRO="
wsl -d Alpine echo ok >nul 2>&1
if %errorlevel% equ 0 ( set "DISTRO=Alpine" )
if not defined DISTRO (
    echo [ERRO] Nenhuma distro WSL encontrada - o instalador define o Alpine como padrao.
    echo        Rode o instalador setup.exe: ele baixa o Alpine e o define como padrao.
    wsl -l -v
    pause
    exit /b 1
)
echo [INFO] Distro WSL: %DISTRO%
echo.

:: 0. Verifica se o WSL esta rodando
wsl -d %DISTRO% echo ok >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] WSL nao disponivel. Verifique se o WSL2 esta instalado.
    pause
    exit /b 1
)

:: 1. Verifica se /dev/ttyUSB0 existe no WSL
wsl -d %DISTRO% test -c /dev/ttyUSB0 2>nul
if %errorlevel% neq 0 (
    echo [AVISO] /dev/ttyUSB0 nao encontrado. Executando setup USB...
    echo.
    call setup_usb.bat
    if %errorlevel% neq 0 (
        echo [ERRO] Setup USB falhou. Resolva e tente novamente.
        pause
        exit /b 1
    )

    wsl -d %DISTRO% test -c /dev/ttyUSB0 2>nul
    if %errorlevel% neq 0 (
        echo [ERRO] /dev/ttyUSB0 continua indisponivel apos setup.
        pause
        exit /b 1
    )
)

:: 2. Verifica permissao de leitura
wsl -d %DISTRO% test -r /dev/ttyUSB0 2>nul
if %errorlevel% neq 0 (
    echo [AVISO] /dev/ttyUSB0 sem permissao de leitura.
    echo        Execute no WSL: sh setup_wsl.sh
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

:: 4. Instala o servico do bridge (se necessario) e inicia
echo [1/3] Verificando servico 'xemonitor-bridge' (%DISTRO%)...
call scripts\bridge_ctl.bat status >nul 2>&1
if %errorlevel% neq 0 (
    call scripts\bridge_ctl.bat enable >nul 2>&1
    if %errorlevel% neq 0 (
        echo [INFO] Instalando servico do bridge (copia para /usr/local/bin)...
        wsl -d %DISTRO% -u root bash scripts/install_bridge_service.sh
        if !errorlevel! neq 0 (
            echo [ERRO] Falha ao instalar o servico do bridge.
            pause
            exit /b 1
        )
    )
    echo [INFO] Iniciando servico 'xemonitor-bridge'...
    call scripts\bridge_ctl.bat start
    if !errorlevel! neq 0 (
        echo [AVISO] O servico pode estar aguardando /dev/ttyUSB0 no start-pre.
    )
)

call scripts\bridge_ctl.bat status >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Bridge rodando no WSL2 (%DISTRO%).
) else (
    echo [AVISO] Bridge pode nao ter iniciado: servico ativando ou aguardando.
)

:: 5. Inicia o xemonitor no Windows
echo [2/3] Iniciando xemonitor (TCP bridge)...
start "XeMonitor" cmd /c "zig-out\bin\xemonitor.exe --tcp 127.0.0.1:9000"

:: 6. Abre o editor para teste
echo [3/3] Abrindo Notepad++ para teste...
set "NPP=C:\Program Files\Notepad++\notepad++.exe"
if not exist "%NPP%" set "NPP=%LOCALAPPDATA%\Programs\Notepad++\notepad++.exe"
if not exist "%NPP%" set "NPP=notepad.exe"
start "" "%NPP%"

echo.
echo ========================================
echo  XeMonitor rodando via TCP bridge WSL2!
echo  Teste escaneando um codigo de barras.
echo  Para encerrar: stop_bridge.bat
echo ========================================
echo.
pause
