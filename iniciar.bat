@echo off
title XeMonitor - Iniciar tudo
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ============================================================
echo   XeMonitor - Leitor de Codigo de Barras
echo.
echo   Este script inicia TUDO automaticamente:
echo   1. Conecta o scanner USB ao WSL2
echo   2. Liga o bridge (WSL2 - systemd)
echo   3. Abre o leitor e o Notepad++
echo.
echo   IMPORTANTE: rode por DUPLO CLIQUE (sem "Executar como
echo   administrador") para o texto ser digitado no editor.
echo ============================================================
echo.

:: ---------- 0. Se elevado, relanca sem elevacao ----------
net session >nul 2>&1
if %errorlevel% equ 0 (
    echo [INFO] Este script foi aberto como administrador.
    echo        Abrindo novamente SEM privilegios - necessario
    echo        para o texto ser digitado no editor...
    timeout /t 2 /nobreak >nul
    explorer.exe "%~f0"
    exit /b
)

:: ---------- 1. WSL disponivel ----------
wsl echo ok >nul 2>&1
if errorlevel 1 (
    echo [ERRO] WSL nao disponivel. Instale/atualize o WSL2.
    pause
    exit /b 1
)
echo [1/6] WSL2 OK.

:: ---------- 2. Scanner USB presente? ----------
wsl test -c /dev/ttyUSB0 >nul 2>&1
if errorlevel 1 (
    echo [2/6] Scanner nao conectado. Configurando USB...
    echo       Aceite o pedido de administrador que vai abrir.
    call setup_usb.bat
    echo.
    echo       Aguardando o scanner aparecer...
    timeout /t 8 /nobreak >nul
    wsl test -c /dev/ttyUSB0 >nul 2>&1
    if errorlevel 1 (
        echo [ERRO] Scanner nao apareceu no WSL.
        echo        - Verifique se o cabo USB esta bem encaixado.
        echo        - Se negou o pedido de admin, rode novamente.
        pause
        exit /b 1
    )
) else (
    echo [2/6] Scanner ja conectado. OK.
)

:: ---------- 3. Permissao de leitura ----------
wsl test -r /dev/ttyUSB0 >nul 2>&1
if errorlevel 1 (
    echo [ERRO] Sem permissao de leitura no dispositivo.
    echo        Execute no WSL2: bash setup_wsl.sh
    pause
    exit /b 1
)
echo [3/6] Permissao de leitura OK.

:: ---------- 4. Compilar o bridge (primeira vez) ----------
if not exist "zig-out\bin\bridge" (
    echo [4/6] Compilando o bridge - primeira execucao, demora um pouco...
    zig build bridge
    if errorlevel 1 (
        echo [ERRO] Falha ao compilar o bridge.
        pause
        exit /b 1
    )
) else (
    echo [4/6] Bridge compilado. OK.
)

:: ---------- 5. Servico do bridge (systemd) ----------
echo [5/6] Verificando servico do bridge...
wsl -u root systemctl is-active xemonitor-bridge >nul 2>&1
if errorlevel 1 (
    wsl -u root systemctl is-enabled xemonitor-bridge >nul 2>&1
    if errorlevel 1 (
        echo       Instalando servico - primeira vez...
        wsl -u root bash scripts/install_bridge_service.sh
        if errorlevel 1 (
            echo [ERRO] Falha ao instalar o servico do bridge.
            pause
            exit /b 1
        )
    )
    echo       Iniciando servico...
    wsl -u root systemctl start xemonitor-bridge >nul 2>&1
    timeout /t 3 /nobreak >nul
)
wsl -u root systemctl is-active xemonitor-bridge >nul 2>&1
if errorlevel 1 (
    echo [AVISO] Bridge ainda iniciando - aguardando o scanner. Continuando...
) else (
    echo [5/6] Bridge ativo. OK.
)

:: ---------- 6. Fechar leitor antigo e abrir tudo ----------
taskkill /f /im xemonitor.exe >nul 2>&1

set "NPP=C:\Program Files\Notepad++\notepad++.exe"
if not exist "%NPP%" set "NPP=%LOCALAPPDATA%\Programs\Notepad++\notepad++.exe"
if not exist "%NPP%" set "NPP=notepad.exe"

echo [6/6] Iniciando leitor e editor...
start "XeMonitor - Leitor" cmd /k zig-out\bin\xemonitor.exe --tcp 127.0.0.1:9000
timeout /t 2 /nobreak >nul
start "" "%NPP%"

echo.
echo ============================================================
echo   PRONTO!
echo.
echo   - A janela "XeMonitor - Leitor" mostra o log em tempo real.
echo   - O Notepad++ esta aberto e focado.
echo   - Escaneie um codigo de barras: ele aparece no Notepad++.
echo   - Para encerrar tudo depois: stop_bridge.bat
echo ============================================================
echo.
pause
exit /b 0
