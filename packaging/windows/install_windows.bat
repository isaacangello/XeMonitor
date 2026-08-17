@echo off
:: ============================================================
:: install_windows.bat - instalador Windows do XeMonitor.
:: Instala TUDO o necessario para o fluxo funcionar e INICIA
:: automaticamente o bridge (WSL) + o xemonitor (GUI/bandeja).
::
::  1. WSL2        (verifica com timeout; nao trava no wsl.exe elevado)
::  2. usbipd-win  (winget install usbipd se faltar)
::  3. Alpine      (distro WSL OBRIGATORIA + padrao; baixa o minirootfs do site
::                  da Alpine e importa - NAO esta na lista do wsl --install)
::  4. Bridge      (binario + servico OpenRC no Alpine)
::  5. Binarios    (xemonitor-gui.exe + xemonitor.exe p/ %ProgramFiles%)
::  5b. Config GUI (xemonitor-gui.conf em %APPDATA%: wsl + auto_start)
::  6. Tarefas     (USB-Attach, Bridge, App - espelho do autostart)
::  7. Inicio      (inicia bridge no WSL + verifica scanner USB-Serial)
::
:: Todas as chamadas wsl.exe passam por scripts\wsl_timeout.ps1 (:runwsl):
:: rodam com timeout (kill) e registram o resultado no log - o wsl.exe pode
:: travar/morrer em silencio em contexto elevado (microsoft/WSL#4144/#9032).
::
:: Uso: install_windows.bat [/silent]
::   /silent  - usado pelo instalador Inno ([Run]): nao faz pause/exit.
::             Instalacao existente + /silent = auto-reparo.
:: ============================================================
setlocal enabledelayedexpansion
title XeMonitor - Instalar (Windows)

:: ------- Config -------
:: Raiz do app: o script roda de packaging\windows\ (instalado) ou da raiz (dev).
set "SILENT=%~1"
set "APP_DIR=%~dp0"
if "%APP_DIR:~-1%"=="\" set "APP_DIR=%APP_DIR:~0,-1%"
if not exist "%APP_DIR%\xemonitor.exe" (
    if exist "%APP_DIR%\..\..\xemonitor.exe" (
        pushd "%APP_DIR%\..\.."
        set "APP_DIR=%CD%"
        popd
    ) else if exist "%APP_DIR%\..\..\build.zig" (
        pushd "%APP_DIR%\..\.."
        set "APP_DIR=%CD%"
        popd
    )
)
set "INSTALL_DIR=%ProgramFiles%\XeMonitor"
set "LOGFILE=%TEMP%\xemonitor-install.log"
set "LOCKFILE=%TEMP%\xemonitor-install.lock"

:: ------- PID do processo (para o log) -------
set "INSTALL_PID="
for /f "delims=" %%p in ('powershell -NoProfile -Command "[System.Diagnostics.Process]::GetCurrentProcess().Id"') do set "INSTALL_PID=%%p"

:: ------- Pausa condicional (interativo) -------
call :pause_helper
:: ------- Log helper -------
call :log "=== XeMonitor installer iniciado (silent=%SILENT%, pid=%INSTALL_PID%) ==="

:: ------- Auto-elevacao para Admin -------
net session >nul 2>&1
if %errorlevel% neq 0 (
    call :log "Solicitando privilegios de administrador..."
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

:: ------- Lockfile single-instance (evita 2 instaladores concorrentes) -------
if exist "%LOCKFILE%" (
    call :log "Lockfile presente: %LOCKFILE%. Outra instancia do instalador pode estar rodando."
    echo.
    echo [ERRO] Outra instancia do instalador parece estar em execucao.
    echo        Se nao houver, apague: %LOCKFILE%
    echo.
    call :pause_helper
    exit /b 1
)
echo %INSTALL_PID%>"%LOCKFILE%"

echo ==========================================
echo  XeMonitor - Instalador Windows
echo ==========================================
echo.

call :log "Admin OK"

:: ============================================================
:: 0. Modo: instalacao existente detectada? -> Reparo / Cancelar
:: ============================================================
set "MODE=install"
set "EXISTING=0"
if exist "%INSTALL_DIR%\xemonitor-gui.exe" set "EXISTING=1"
if exist "%APPDATA%\xemonitor\xemonitor-gui.conf" set "EXISTING=1"
if %EXISTING% equ 1 (
    if /i "%SILENT%"=="/silent" (
        call :log "Instalacao existente detectada; modo /silent = auto-reparo."
        echo       Instalacao existente detectada. Reparando...
        set "MODE=repair"
    ) else (
        echo.
        echo  ==========================================
        echo   Instalacao existente detectada.
        echo  ==========================================
        echo.
        echo   R - Reparo: recopia binarios, reconfigura
        echo       WSL/bridge/USB e inicia o XeMonitor.
        echo       Preserva o Alpine WSL. A config do GUI
        echo       e resetada com backup.
        echo   C - Cancelar.
        echo.
        choice /C RC /N /M "Escolha [R]eparo ou [C]ancelar: "
        if errorlevel 2 (
            call :log "Instalacao cancelada pelo usuario."
            del "%LOCKFILE%" >nul 2>&1
            exit /b 0
        )
        call :log "Modo Reparo selecionado."
        echo       Reparando instalacao existente...
        set "MODE=repair"
    )
)

:: No modo Reparo, para GUI/cliente/bridge antes de recopiar arquivos
if /i "%MODE%"=="repair" (
    taskkill /F /IM xemonitor-gui.exe >nul 2>&1
    taskkill /F /IM xemonitor.exe >nul 2>&1
    call :log "Processos xemonitor-gui/xemonitor encerrados."
    echo       Instancias antigas de xemonitor encerradas.
)

:: ============================================================
:: 1. WSL2
:: ============================================================
echo [1/7] Verificando WSL2...
call :runwsl status 30 status
if !WSL_RC! equ 0 (
    call :log "WSL presente."
    echo       WSL presente.
    call :runwsl update 30 update
) else if !WSL_RC! equ 200 (
    call :log "AVISO: wsl --status deu TIMEOUT em contexto elevado. Continuando..."
    echo       [AVISO] wsl --status travou por timeout. Seguindo para o passo 3...
) else (
    call :log "WSL nao detectado com rc=!WSL_RC!. Instalando WSL..."
    echo       WSL nao detectado. Instalando WSL sem distro padrao...
    call :runwsl install_wsl 180 install_wsl
    if !WSL_RC! equ 0 (
        call :log "WSL instalado. Pode ser necessario reiniciar para concluir."
        echo       WSL instalado. REINICIE o Windows e rode o instalador novamente.
        del "%LOCKFILE%" >nul 2>&1
        call :pause_helper
        exit /b 1
    ) else (
        call :log "ERRO: falha ao instalar WSL com rc=!WSL_RC!."
        echo [ERRO] Falha ao instalar WSL. Instale manualmente: wsl --install
        del "%LOCKFILE%" >nul 2>&1
        call :pause_helper
        exit /b 1
    )
)
echo       OK.
echo.

:: ============================================================
:: 2. usbipd-win
:: ============================================================
echo [2/7] Verificando usbipd-win...
set "USBIPD=usbipd"
where usbipd >nul 2>&1
if %errorlevel% neq 0 (
    if exist "C:\Program Files\usbipd-win\usbipd.exe" (
        set "USBIPD=C:\Program Files\usbipd-win\usbipd.exe"
        call :log "usbipd presente."
        echo       usbipd presente.
    ) else (
        call :log "usbipd ausente. Instalando via winget..."
        echo       usbipd ausente. Instalando via winget...
        winget install usbipd --accept-package-agreements --accept-source-agreements
        if !errorlevel! equ 0 (
            if exist "C:\Program Files\usbipd-win\usbipd.exe" set "USBIPD=C:\Program Files\usbipd-win\usbipd.exe"
            call :log "usbipd instalado."
            echo       usbipd instalado.
        ) else (
            call :log "AVISO: nao foi possivel instalar usbipd via winget."
            echo [AVISO] Nao foi possivel instalar usbipd. Instale manualmente:
            echo         winget install usbipd
        )
    )
) else (
    call :log "usbipd presente via PATH."
    echo       usbipd presente.
)
echo.

:: ============================================================
:: 3. Distro WSL: Alpine (OBRIGATORIA + PADRAO)
:: ============================================================
echo [3/7] Verificando distro WSL (Alpine obrigatoria + padrao)...
set "DISTRO=Alpine"
call :runwsl alpine_ok 60 distro_ok
if !WSL_RC! neq 0 (
    if !WSL_RC! equ 200 (
        call :log "AVISO: wsl -d Alpine deu TIMEOUT. Tentando import..."
    ) else (
        call :log "Alpine ausente. Baixando e importando do site oficial..."
    )
    echo       Alpine ausente. Baixando do site oficial e importando no WSL...
    echo.
    echo       O Alpine NAO esta na lista padrao do wsl --install. O instalador
    echo       baixa o minirootfs de dl-cdn.alpinelinux.org e importa como
    echo       distro WSL. Isso pode levar alguns minutos.
    call :runwsl install_alpine 300 install_alpine
    if !WSL_RC! equ 200 (
        call :log "AVISO: import do Alpine deu TIMEOUT."
    ) else if !WSL_RC! neq 0 (
        call :log "AVISO: import do Alpine falhou com rc=!WSL_RC!."
    )
    call :runwsl alpine_ok2 60 distro_ok
    if !WSL_RC! neq 0 (
        call :log "ERRO: Alpine indisponivel apos import com rc=!WSL_RC!."
        echo.
        echo [ERRO] Nao foi possivel instalar o Alpine via download/import.
        echo        Opcao manual:
        echo        1. Baixe de dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/
        echo           o arquivo alpine-minirootfs-*.x86_64.tar.gz
        echo        2. wsl --import Alpine C:\wsl\Alpine alpine-minirootfs-*.tar.gz --version 2
        echo        3. Depois rode este instalador novamente.
        del "%LOCKFILE%" >nul 2>&1
        call :pause_helper
        exit /b 1
    )
)
call :runwsl set_default 60 set_default
if !WSL_RC! equ 0 (
    call :log "Alpine definido como distribuicao padrao."
    echo       Alpine definido como distribuicao padrao.
) else (
    call :log "AVISO: wsl --set-default falhou com rc=!WSL_RC!; tentando mesmo assim."
    echo       [AVISO] Falha ao definir Alpine como padrao. Prosseguindo.
)
call :log "Distro WSL: %DISTRO%"
echo       Distro WSL: %DISTRO%.
echo.

:: ============================================================
:: 4. Bridge: binario + setup WSL + servico
:: ============================================================
:: Valida %DISTRO% antes de qualquer `wsl -d` (um DISTRO vazio vira
:: 'wsl -d  -u root' -> rc=-1 e falha silenciosa em TODOS os passos).
if "%DISTRO%"=="" (
    call :log "ERRO: DISTRO vazio apos o passo 3; abortando."
    echo.
    echo [ERRO] Distro WSL nao determinada. Abortando instalacao.
    echo.
    del "%LOCKFILE%" >nul 2>&1
    call :pause_helper
    exit /b 1
)
echo [4/7] Configurando WSL (udev/usbip/servico)...

:: 4a. Envia setup_wsl.sh para o WSL e executa
if exist "%APP_DIR%\setup_wsl.sh" (
    call :log "Rodando setup_wsl.sh no %DISTRO%..."
    call :to_wsl_path "%APP_DIR%\setup_wsl.sh" S_WSL
    set "XEMONITOR_SRC=!S_WSL!"
    call :runwsl setup_wsl 120 setup_wsl
    if !WSL_RC! neq 0 (
        call :log "AVISO: setup_wsl.sh falhou com rc=!WSL_RC!. Ignore se jah configurado."
        echo       [AVISO] setup_wsl.sh falhou. Prosseguindo.
    ) else (
        echo       setup_wsl.sh aplicado: udev + modulos usbip.
    )
) else (
    call :log "AVISO: setup_wsl.sh nao encontrado."
    echo [AVISO] setup_wsl.sh nao encontrado.
)

:: 4b. Copia o bridge (Linux, musl estatico) para o WSL
if exist "%APP_DIR%\bridge" (
    call :log "Copiando bridge para %DISTRO%:/usr/local/bin/xemonitor-bridge"
    call :to_wsl_path "%APP_DIR%\bridge" B_WSL
    set "XEMONITOR_SRC=!B_WSL!"
    call :runwsl copy_bridge 120 copy_bridge
    if !WSL_RC! neq 0 (
        call :log "AVISO: falha ao copiar bridge com rc=!WSL_RC!. Verifique se /mnt esta acessivel."
        echo [AVISO] Falha ao copiar bridge para o WSL.
    ) else (
        call :log "bridge copiado para /usr/local/bin/xemonitor-bridge."
        echo       bridge copiado para o WSL.
    )
) else (
    call :log "AVISO: '%APP_DIR%\bridge' nao encontrado."
    echo [AVISO] bridge binario nao encontrado na pasta de instalacao.
)

:: 4c. Instala o init script do bridge (OpenRC no Alpine) e habilita/inicia.
::     Sem isso o rc-update/rc-service abaixo nao encontra a unit num WSL
::     recem-instalado.
if exist "%APP_DIR%\openrc\xemonitor-bridge" (
    call :log "Instalando init script OpenRC do bridge no %DISTRO%..."
    call :to_wsl_path "%APP_DIR%\openrc\xemonitor-bridge" O_WSL
    set "XEMONITOR_SRC=!O_WSL!"
    call :runwsl copy_openrc 120 copy_openrc
    if !WSL_RC! neq 0 (
        call :log "AVISO: falha ao copiar init script OpenRC com rc=!WSL_RC!."
        echo [AVISO] Falha ao copiar init script OpenRC.
    )
) else (
    call :log "AVISO: openrc/xemonitor-bridge nao encontrado."
)
if exist "%APP_DIR%\systemd\xemonitor-bridge.service" (
    call :to_wsl_path "%APP_DIR%\systemd\xemonitor-bridge.service" S_WSL
    set "XEMONITOR_SRC=!S_WSL!"
    call :runwsl copy_systemd 120 copy_systemd
)
call :runwsl svc_enable 120 svc_enable
call :log "Servico do bridge instalado/iniciado no %DISTRO%."
echo       Servico do bridge instalado e iniciado.
echo.

:: ============================================================
:: 5. Binarios Windows para %ProgramFiles%\XeMonitor
:: ============================================================
echo [5/7] Instalando xemonitor-gui.exe + xemonitor.exe em %INSTALL_DIR%...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if exist "%APP_DIR%\xemonitor-gui.exe" (
    copy /y "%APP_DIR%\xemonitor-gui.exe" "%INSTALL_DIR%\xemonitor-gui.exe" >nul
    call :log "xemonitor-gui.exe copiado para %INSTALL_DIR%."
    echo       xemonitor-gui.exe instalado.
) else (
    call :log "AVISO: '%APP_DIR%\xemonitor-gui.exe' nao encontrado."
    echo [AVISO] xemonitor-gui.exe nao encontrado em %APP_DIR%.
)
if exist "%APP_DIR%\xemonitor.exe" (
    copy /y "%APP_DIR%\xemonitor.exe" "%INSTALL_DIR%\xemonitor.exe" >nul
    call :log "xemonitor.exe copiado para %INSTALL_DIR%."
    echo       xemonitor.exe instalado.
) else (
    call :log "AVISO: '%APP_DIR%\xemonitor.exe' nao encontrado."
    echo [AVISO] xemonitor.exe nao encontrado em %APP_DIR%.
)
echo.

:: ============================================================
:: 5b. Config padrao do GUI (xemonitor-gui.conf) em %APPDATA%\xemonitor
:: ============================================================
echo [5b] Gravando config do GUI (wsl + auto_start)...
set "CFG_DIR=%APPDATA%\xemonitor"
set "CFG_FILE=%CFG_DIR%\xemonitor-gui.conf"
if /i "%MODE%"=="repair" (
    call :log "Modo Reparo: resetando config do GUI com backup."
    echo       [Reparo] Resetando config do GUI (backup em xemonitor-gui.conf.bak).
    if exist "%CFG_FILE%" (
        copy /y "%CFG_FILE%" "%CFG_FILE%.bak" >nul 2>&1
        del "%CFG_FILE%" >nul 2>&1
    )
)
call :ensure_gui_cfg "%CFG_DIR%"
echo.

:: ============================================================
:: 6. Tarefas agendadas (boot/logon)
:: ============================================================
echo [6/7] Criando tarefas agendadas...
if exist "%APP_DIR%\scripts\install_autostart.bat" (
    call "%APP_DIR%\scripts\install_autostart.bat" /silent
    call :log "install_autostart.bat executado: tarefas criadas."
    echo       Tarefas agendadas criadas: USB-Attach, Bridge, App.
) else (
    call :log "AVISO: scripts/install_autostart.bat nao encontrado; criando via schtasks..."
    schtasks /Create /F /TN "XeMonitor-USB-Attach" /TR "\"%INSTALL_DIR%\setup_usb.bat\" /silent" /SC ONLOGON /RL HIGHEST >nul 2>&1
    schtasks /Create /F /TN "XeMonitor-Bridge" /TR "cmd /c \"\"%INSTALL_DIR%\packaging\windows\start_bridge.cmd\"\"" /SC ONLOGON /DELAY 0000:30 >nul 2>&1
    schtasks /Create /F /TN "XeMonitor-App" /TR "\"%INSTALL_DIR%\xemonitor-gui.exe\"" /SC ONLOGON /DELAY 0000:45 /RL LIMITED >nul 2>&1
    call :log "Tarefas criadas via schtasks."
)
echo.

:: ============================================================
:: 7. Inicio automatico: bridge + verificacao do scanner USB-Serial
:: ============================================================
echo [7/7] Iniciando XeMonitor...

:: 7a. Garante bridge ativo no WSL
call :runwsl svc_start 120 svc_start
if !WSL_RC! neq 0 (
    call :log "AVISO: bridge pode nao ter iniciado com rc=!WSL_RC!. Servico re-tenta /dev/ttyUSB0."
)
call :log "Bridge iniciado no %DISTRO%."
echo       Bridge iniciado.

:: 7b. Setup USB: chama setup_usb.bat (bind/attach do CH340 ao WSL)
if exist "%APP_DIR%\setup_usb.bat" (
    echo [7b] Executando setup_usb.bat - attach CH340 ao WSL...
    call "%APP_DIR%\setup_usb.bat" /silent
) else (
    call :log "AVISO: setup_usb.bat nao encontrado."
    echo [AVISO] setup_usb.bat nao encontrado.
)
echo.

:: 7c. Verifica scanner USB-Serial (CH340) conectado: feedback claro para o
::     usuario, ja que sem o Honeywell 1900 USB-SERIAL nada funciona.
set "SCANNER_STATUS=nao verificado"
ping -n 4 127.0.0.1 >nul
call :runwsl tty_check 30 tty_check
if !WSL_RC! equ 0 (
    set "SCANNER_STATUS=detectado - /dev/ttyUSB0"
    call :log "Scanner USB-Serial detectado: /dev/ttyUSB0 no %DISTRO%."
    echo.
    echo       [OK] Scanner USB-Serial detectado - /dev/ttyUSB0.
) else (
    set "SCANNER_STATUS=NAO detectado - conecte o USB-SERIAL"
    call :log "AVISO: scanner USB-Serial NAO detectado. Conecte o Honeywell 1900 USB-SERIAL CH340 e rode setup_usb.bat."
    echo.
    echo  ============================================================
    echo  [IMPORTANTE] Scanner USB-Serial NAO detectado.
    echo  ============================================================
    echo.
    echo   Este app le o Honeywell 1900 via USB-SERIAL adaptador CH340.
    echo   Por favor:
    echo.
    echo   1. Conecte o scanner ou adaptador CH340 em uma porta USB
    echo   2. Rode: setup_usb.bat   - faz o bind/attach via usbipd
    echo   3. Ou clique em 'Reparar' na GUI depois de conectar
    echo.
    echo   O bridge esta ativo e re-tenta a cada 2s - assim que o
    echo   scanner for attachado, os scans comecam a funcionar.
    echo  ============================================================
    echo.
)
echo.

:: ------- Resumo -------
echo ==========================================
echo  Instalacao concluida!
echo.
echo   Instalado em:   %INSTALL_DIR%
echo   Distro WSL:     %DISTRO%  (Alpine/OpenRC padrao)
echo   Bridge:         /usr/local/bin/xemonitor-bridge
echo   Tarefas:        XeMonitor-USB-Attach / Bridge / App
echo   Iniciado:       bridge (WSL) + xemonitor-gui (janela + bandeja)
echo   Scanner:        %SCANNER_STATUS%
echo.
echo  Para encerrar:   stop_bridge.bat
echo  Para remover:    scripts\uninstall_autostart.bat + apagar %INSTALL_DIR%
echo ==========================================
del "%LOCKFILE%" >nul 2>&1
call :log "Instalador concluido (pid=%INSTALL_PID%, modo=%MODE%)."
call :pause_helper
exit /b 0

:: ============================================================
:: :runwsl <label> <timeout_s> <task>
:: Roda um comando wsl via scripts\wsl_timeout.ps1 (timeout + kill + log).
:: Define WSL_RC (rc do wsl; 200=TIMEOUT, 201=erro). Usa XEMONITOR_DISTRO/
:: XEMONITOR_SRC se as tarefas precisarem. NUNCA trava o instalador.
:: ============================================================
:runwsl
set "WSL_RC=1"
set "XEMONITOR_DISTRO=%DISTRO%"
call :log "wsl %1 (%2s) ..."
powershell -NoProfile -ExecutionPolicy Bypass -File "%APP_DIR%\scripts\wsl_timeout.ps1" -Timeout %2 -Task %3
set "WSL_RC=!errorlevel!"
if !WSL_RC! equ 0 (
    call :log "wsl %1: OK"
) else if !WSL_RC! equ 200 (
    call :log "wsl %1: TIMEOUT"
) else if !WSL_RC! equ 201 (
    call :log "wsl %1: ERRO de processo"
) else (
    call :log "wsl %1: rc=!WSL_RC!"
)
set "XEMONITOR_SRC="
exit /b 0

:: ============================================================
:: :log - append de mensagem no LOGFILE
:: ============================================================
:log
if defined LOGFILE (
    echo %date% %time%  %*>>"%LOGFILE%"
)
exit /b 0

:: ============================================================
:: :pause_helper - pausa so em modo interativo (sem /silent)
:: ============================================================
:pause_helper
if /i not "%SILENT%"=="/silent" pause
exit /b 0

:: ============================================================
:: :ensure_gui_cfg <cfg_dir>
:: Garante que xemonitor-gui.conf exista e use server_mode=wsl (unico modo
:: valido no Windows: bridge via bridge_ctl.bat). Se existir config antiga com
:: server_mode invalido (ex.: subprocess), faz backup (.bak) e regrava so a
:: linha server_mode=wsl, preservando as demais preferencias do usuario.
:: ============================================================
:ensure_gui_cfg
set "CFG_DIR=%~1"
set "CFG_FILE=%CFG_DIR%\xemonitor-gui.conf"
if not exist "%CFG_DIR%" mkdir "%CFG_DIR%"
if not exist "%CFG_FILE%" goto :cfg_write_new
findstr /B /I "server_mode=wsl" "%CFG_FILE%" >nul 2>&1
if not errorlevel 1 goto :cfg_keep
call :log "xemonitor-gui.conf com server_mode invalido; backup e migrando para wsl."
copy /y "%CFG_FILE%" "%CFG_FILE%.bak" >nul 2>&1
call :log "Backup: %CFG_FILE%.bak"
echo       Config antiga detectada; backup em xemonitor-gui.conf.bak.
findstr /V /B /I "server_mode=" "%CFG_FILE%" > "%CFG_DIR%\gui-cfg.tmp"
echo server_mode=wsl>>"%CFG_DIR%\gui-cfg.tmp"
move /y "%CFG_DIR%\gui-cfg.tmp" "%CFG_FILE%" >nul 2>&1
call :log "server_mode=wsl gravado em %CFG_FILE%."
echo       Config migrada para wsl.
goto :cfg_done

:cfg_write_new
(
    echo tcp_host=127.0.0.1
    echo tcp_port=9000
    echo server_mode=wsl
    echo bridge_path=
    echo client_path=
    echo log_path=
    echo auto_start=true
    echo tray_enabled=true
    echo lang=pt_br
)>"%CFG_FILE%"
call :log "xemonitor-gui.conf gravado em %CFG_DIR%."
echo       Config do GUI gravada.
goto :cfg_done

:cfg_keep
call :log "xemonitor-gui.conf ja existe e valida (server_mode=wsl); mantido."
echo       Config do GUI valida; mantida.

:cfg_done
exit /b 0

:: ============================================================
:: :to_wsl_path <caminho_windows> <out_var>
:: Converte C:\Program Files\XeMonitor\bridge em /mnt/c/Program Files/...
:: (drive lowercase, como o WSL monta)
:: ============================================================
:to_wsl_path
set "%~2="
for /f "delims=" %%p in ('powershell -NoProfile -Command "$p='%~1'; $p=$p -replace '\\','/'; $d=$p.Substring(0,1).ToLower(); $rest=$p.Substring(3); Write-Output ('/mnt/'+$d+'/'+$rest)"') do set "%~2=%%p"
exit /b 0
