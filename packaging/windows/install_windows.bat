@echo off
:: ============================================================
:: install_windows.bat v0.7.2 — Instalador Windows do XeMonitor.
:: 4 fases claras: Windows deps -> Alpine deps -> Alpine config -> Final.
::
::  FASE 1  Dependencias Windows + Alpine (WSL2, winget, wget, usbipd, Alpine)
::  FASE 2  Dependencias Alpine (openrc, kmod, eudev — verificado ANTES de usar)
::  FASE 3  Copia de arquivos + config Alpine (bridge, init script, udev, wsl.conf)
::  FASE 4  Configuracao final (servico, binarios, tarefas, USB, scanner)
::
:: Uso: install_windows.bat [/silent]
::   /silent  — Inno Setup ([Run]): nao faz pause. Instalacao existente = auto-reparo.
:: ============================================================
setlocal enabledelayedexpansion
title XeMonitor - Instalar v0.7.2 (Windows)
set "_FATAL=0"

:: ------- Config -------
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
set "LOG_DIR=%APPDATA%\xemonitor\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "LOGFILE=%LOG_DIR%\install.log"
echo DEBUG-LOGFILE=!LOGFILE!>>"%LOG_DIR%\install.log"
set "LOCKFILE=%TEMP%\xemonitor-install.lock"

:: ------- PID do processo -------
set "INSTALL_PID="
for /f "delims=" %%p in ('powershell -NoProfile -Command "[System.Diagnostics.Process]::GetCurrentProcess().Id"') do set "INSTALL_PID=%%p"

:: ------- Log helper -------
call :log "=== XeMonitor installer v0.7.2 iniciado (silent=%SILENT%, pid=%INSTALL_PID%) ==="

:: ------- Auto-elevacao para Admin -------
:: NOTA: `net session` pode falhar mesmo para admins (servico SMB/LanmanServer parado).
:: Usa `fltmc` (Filter Manager) como check alternativo — requer admin.
set "IS_ADMIN=1"
fltmc >nul 2>&1 || set "IS_ADMIN=0"
if "%IS_ADMIN%"=="0" (
    call :log "Solicitando privilegios de administrador..."
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\" %*' -Verb RunAs"
    set "_DIE_RC=0"
)
if "%IS_ADMIN%"=="0" goto :die

:: ------- Lockfile -------
if exist "%LOCKFILE%" (
    set "OLD_PID="
    set /p OLD_PID=<"%LOCKFILE%" 2>nul
    if defined OLD_PID (
        tasklist /FI "PID eq !OLD_PID!" 2>nul | findstr /I "!OLD_PID!" >nul 2>&1
        if !errorlevel! equ 0 (
            call :log "Lockfile presente e processo !OLD_PID! ativo. Matando..."
            taskkill /PID !OLD_PID! /F >nul 2>&1
            timeout /t 2 /nobreak >nul 2>&1
        ) else (
            call :log "Lockfile presente mas processo !OLD_PID! morto. Limpando."
        )
    )
    del "%LOCKFILE%" >nul 2>&1
)
echo %INSTALL_PID%>"%LOCKFILE%"

echo ==========================================
echo  XeMonitor v0.7.2 - Instalador Windows
echo ==========================================
echo.
call :log "TRACE: Admin OK. IS_ADMIN=%IS_ADMIN%, SILENT=%SILENT%"
ECHO DEBUG-BEFORE-82

echo TRACE-82-BEFORE
call :log "TRACE: pos-header, entrando Fase 0"
echo TRACE-82-AFTER
:: ============================================================
:: 0. Modo: instalacao existente -> Reparo / Cancelar
:: ============================================================
echo TRACE-PHASE0-ENTRY
set "MODE=install"
set "EXISTING=0"
if exist "%INSTALL_DIR%\xemonitor-gui.exe" set "EXISTING=1"
if exist "%APPDATA%\xemonitor\xemonitor-gui.conf" set "EXISTING=1"
echo TRACE-EXISTING=%EXISTING%
if %EXISTING% equ 1 (
    if /i "%SILENT%"=="/silent" (
        call :log "Instalacao existente; modo /silent = auto-reparo."
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
        echo   C - Cancelar.
        echo.
        choice /C RC /N /M "Escolha [R]eparo ou [C]ancelar: "
        if errorlevel 2 (
            call :log "Instalacao cancelada."
            set "_DIE_RC=0"
            set "_FATAL=1"
        )
        set "MODE=repair"
    )
)
if "!_FATAL!"=="1" goto :die
if /i "%MODE%"=="repair" (
    taskkill /F /IM xemonitor-gui.exe >nul 2>&1
    taskkill /F /IM xemonitor.exe >nul 2>&1
    call :log "Processos antigos encerrados."
    echo       Instancias antigas encerradas.
)
echo TRACE-121-BEFORE
call :log "TRACE: Fase 0 concluida. MODE=%MODE%, EXISTING=%EXISTING%"
echo TRACE-121-AFTER

echo TRACE-PHASE1-ENTRY
:: ============================================================
:: FASE 1/4: Dependencias Windows + Alpine
:: ============================================================
echo.
echo ==========================================
echo  FASE 1/4: Dependencias Windows + Alpine
echo ==========================================
echo.

:: [1] WSL2
echo [1/6] Verificando WSL2...
call :runwsl status 30 status
if !WSL_RC! equ 0 (
    call :log "WSL presente."
    echo       WSL presente.
    call :runwsl update 30 update
) else if !WSL_RC! equ 200 (
    call :log "AVISO: wsl --status TIMEOUT em contexto elevado. Continuando..."
    echo       [AVISO] wsl --status travou por timeout. Seguindo...
) else (
    call :log "WSL nao detectado rc=!WSL_RC! Instalando..."
    echo       WSL nao detectado. Instalando sem distro padrao...
    call :runwsl install_wsl 180 install_wsl
    if !WSL_RC! neq 0 (
        call :log "ERRO: falha ao instalar WSL rc=!WSL_RC!"
        echo [ERRO] Falha ao instalar WSL. Instale: wsl --install
        set "_DIE_RC=1"
        set "_FATAL=1"
    )
    if not "!_FATAL!"=="1" (
        call :log "WSL instalado. Pode ser necessario reiniciar."
        echo       WSL instalado. REINICIE o Windows e rode o instalador novamente.
        set "_DIE_RC=1"
        set "_FATAL=1"
    )
)
if "!_FATAL!"=="1" goto :die
echo       OK.
echo.

:: [2] winget
echo [2/6] Verificando winget...
set "HAS_WINGET=0"
where winget >nul 2>&1
if %errorlevel% equ 0 (
    set "HAS_WINGET=1"
    call :log "winget presente via PATH."
    echo       winget presente.
) else (
    call :log "winget nao encontrado via PATH."
    echo       [AVISO] winget nao encontrado. Tentando instalar App Installer...
    :: Tentar instalar App Installer (winget) via PowerShell
    powershell -NoProfile -Command "Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" >nul 2>&1
    timeout /t 3 /nobreak >nul 2>&1
    where winget >nul 2>&1
    if %errorlevel% equ 0 (
        set "HAS_WINGET=1"
        call :log "winget instalado com sucesso via App Installer."
        echo       winget instalado.
    ) else (
        call :log "AVISO: falha ao instalar winget. wget/usbipd usarao fallbacks."
        echo       [AVISO] winget nao instalado. wget/usbipd usarao fallbacks.
    )
)
echo.

:: [3] wget
echo [3/6] Verificando wget...
set "WGET="
where wget >nul 2>&1
if %errorlevel% equ 0 (
    set "WGET=wget"
    call :log "wget presente via PATH."
    echo       wget presente.
) else if exist "C:\Program Files\GnuWin32\bin\wget.exe" (
    set "WGET=C:\Program Files\GnuWin32\bin\wget.exe"
    call :log "wget encontrado em GnuWin32."
    echo       wget encontrado em GnuWin32.
) else (
    call :log "wget ausente."
    echo       wget ausente.
    if !HAS_WINGET! equ 1 (
        echo       Instalando wget via winget...
        call :log "Instalando wget via winget..."
        winget install JernejSimoncic.Wget --accept-package-agreements --accept-source-agreements >nul 2>&1
        if !errorlevel! equ 0 (
            where wget >nul 2>&1
            if !errorlevel! equ 0 (
                set "WGET=wget"
                call :log "wget instalado com sucesso."
                echo       wget instalado.
            ) else if exist "C:\Program Files\GnuWin32\bin\wget.exe" (
                set "WGET=C:\Program Files\GnuWin32\bin\wget.exe"
                call :log "wget instalado GnuWin32"
                echo       wget instalado.
            )
        ) else (
            call :log "AVISO: falha ao instalar wget via winget."
            echo       [AVISO] Falha ao instalar wget via winget. Tentando Chocolatey...
        )
    )
    if not defined WGET (
        :: Tentar instalar via Chocolatey se disponivel
        where choco >nul 2>&1
        if %errorlevel% equ 0 (
            echo       Instalando wget via Chocolatey...
            call :log "Instalando wget via Chocolatey..."
            choco install wget -y >nul 2>&1
            if !errorlevel! equ 0 (
                where wget >nul 2>&1
                if !errorlevel! equ 0 set "WGET=wget"
            )
        )
    )
    if not defined WGET (
        :: Tentar instalar via Scoop se disponivel
        where scoop >nul 2>&1
        if %errorlevel% equ 0 (
            echo       Instalando wget via Scoop...
            call :log "Instalando wget via Scoop..."
            scoop install wget >nul 2>&1
            if !errorlevel! equ 0 (
                where wget >nul 2>&1
                if !errorlevel! equ 0 set "WGET=wget"
            )
        )
    )
    if not defined WGET (
        call :log "wget indisponivel; usando Invoke-WebRequest como fallback."
        echo       wget indisponivel. Download usara PowerShell sem progresso.
    )
)
echo.

:: [4] usbipd-win
echo [4/6] Verificando usbipd-win...
set "USBIPD=usbipd"
where usbipd >nul 2>&1
if %errorlevel% neq 0 (
    if exist "C:\Program Files\usbipd-win\usbipd.exe" (
        set "USBIPD=C:\Program Files\usbipd-win\usbipd.exe"
        call :log "usbipd presente."
        echo       usbipd presente.
    ) else (
        call :log "usbipd ausente."
        echo       usbipd ausente.
        if !HAS_WINGET! equ 1 (
            echo       Instalando via winget...
            winget install usbipd --accept-package-agreements --accept-source-agreements
            if !errorlevel! equ 0 (
                if exist "C:\Program Files\usbipd-win\usbipd.exe" set "USBIPD=C:\Program Files\usbipd-win\usbipd.exe"
                call :log "usbipd instalado."
                echo       usbipd instalado.
            ) else (
                call :log "AVISO: falha ao instalar usbipd."
                echo [AVISO] Nao foi possivel instalar usbipd.
            )
        )
    )
) else (
    call :log "usbipd presente via PATH."
    echo       usbipd presente.
)
echo.

:: [5] Download Alpine minirootfs
echo [5/6] Baixando Alpine minirootfs...
set "ALPINE_BASE=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"
set "TARBALL=%TEMP%\alpine-minirootfs.tar.gz"

:: Resolve versao mais recente via PowerShell (sem fallback hardcoded)
for /f "delims=" %%f in ('powershell -NoProfile -Command "try { $y = (Invoke-WebRequest -UseBasicParsing -Uri '%ALPINE_BASE%/latest-releases.yaml' -TimeoutSec 30).Content; if ($y -match 'file: (alpine-minirootfs-[\d.]+-x86_64\.tar\.gz)') { $Matches[1] } else { exit 1 } } catch { exit 1 }" 2^>nul') do set "ALPINE_FILE=%%f"
if not defined ALPINE_FILE (
    call :log "ERRO: falha ao resolver versao latest do Alpine."
    echo [ERRO] Nao foi possivel obter versao latest do Alpine.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
set "ALPINE_URL=%ALPINE_BASE%/%ALPINE_FILE%"
call :log "Alpine URL: %ALPINE_URL%"

if exist "%TARBALL%" (
    call :log "Tarball ja existe: %TARBALL%"
    echo       Tarball ja existe: %ALPINE_FILE%
) else (
    echo       Baixando %ALPINE_FILE%...
    if defined WGET (
        call :log "Download via wget: %ALPINE_URL%"
        "%WGET%" --progress=bar:force -c "%ALPINE_URL%" -O "%TARBALL%"
    ) else (
        call :log "Download via Invoke-WebRequest: %ALPINE_URL%"
        powershell -NoProfile -Command "Invoke-WebRequest -Uri '%ALPINE_URL%' -OutFile '%TARBALL%' -UseBasicParsing"
    )
    if !errorlevel! neq 0 (
        call :log "ERRO: falha no download do Alpine."
        echo [ERRO] Falha ao baixar Alpine. Verifique sua conexao.
        set "_DIE_RC=1"
        set "_FATAL=1"
    )
    if not "!_FATAL!"=="1" echo       Download concluido.
)
if "!_FATAL!"=="1" goto :die
echo.

:: [6] Import Alpine (sempre fresh)
echo [6/6] Preparando Alpine (fresh)...
:: Remove Alpine existente (se houver) para garantir estado limpo
call :runwsl alpine_check 60 distro_ok
if !WSL_RC! equ 0 (
    call :log "Alpine existente. Removendo para instalacao fresh..."
    echo       Removendo Alpine existente...
    wsl --unregister Alpine >nul 2>&1
)
:: Importa fresh
echo       Importando Alpine fresh...
set "XEMONITOR_TARBALL=%TARBALL%"
call :runwsl import_alpine 300 import_alpine
if !WSL_RC! neq 0 (
    call :log "ERRO: falha ao importar Alpine rc=!WSL_RC!"
    echo [ERRO] Nao foi possivel importar Alpine.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
call :runwsl alpine_ok2 60 distro_ok
if !WSL_RC! neq 0 (
    call :log "ERRO: Alpine indisponivel apos import."
    echo [ERRO] Alpine indisponivel apos import.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
set "DISTRO=Alpine"
call :runwsl set_default 60 set_default
call :log "Distro WSL: %DISTRO%"
echo       Alpine pronto (fresh).
echo.
call :log "=== FASE 1 concluida ==="

:: ============================================================
:: FASE 2/4: Dependencias Alpine (openrc, kmod, eudev)
:: ============================================================
echo ==========================================
echo  FASE 2/4: Dependencias Alpine
echo ==========================================
echo.

:: [1] Gerar script de deps via echo
set "DEPS_SH=%TEMP%\xemonitor-setup-deps.sh"
if "%TEMP%"=="" set "DEPS_SH=%USERPROFILE%\AppData\Local\Temp\xemonitor-setup-deps.sh"
call :log "Gerando %DEPS_SH% (TEMP=%TEMP%)..."
> "%DEPS_SH%" echo #!/bin/sh
>> "%DEPS_SH%" echo set -e
>> "%DEPS_SH%" echo echo '[deps] Instalando openrc, kmod, eudev...'
>> "%DEPS_SH%" echo apk update
>> "%DEPS_SH%" echo apk add --no-cache openrc kmod eudev
>> "%DEPS_SH%" echo echo '[deps] Criando /run/openrc/softlevel...'
>> "%DEPS_SH%" echo mkdir -p /run/openrc
>> "%DEPS_SH%" echo touch /run/openrc/softlevel
>> "%DEPS_SH%" echo echo '[deps] Verificando instalacao...'
>> "%DEPS_SH%" echo command -v rc-service ^> /dev/null 2^>^&1 ^|^| { echo 'ERRO: openrc nao instalado'; exit 1; }
>> "%DEPS_SH%" echo command -v modprobe ^> /dev/null 2^>^&1 ^|^| { echo 'ERRO: kmod nao instalado'; exit 1; }
>> "%DEPS_SH%" echo echo '[deps] OK: dependencias do Alpine instaladas.'
echo       Script gerado: %DEPS_SH%

:: [2] Copiar ao Alpine
call :log "TRACE: antes to_wsl_path. DEPS_SH='%DEPS_SH%'"
call :to_wsl_path "%DEPS_SH%" DEPS_WSL
if "!DEPS_WSL!"=="" (
    call :log "ERRO: to_wsl_path falhou para %DEPS_SH%."
    echo [ERRO] Falha ao converter caminho para WSL.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
set "XEMONITOR_SRC=!DEPS_WSL!"
set "XEMONITOR_DEST=/tmp/xemonitor-setup-deps.sh"
call :runwsl copy_deps 30 copy_file
if !WSL_RC! neq 0 (
    call :log "ERRO: falha ao copiar deps script rc=!WSL_RC!"
    echo [ERRO] Falha ao copiar script para Alpine.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die

:: [3] Executar - XEMONITOR_SRC deve ser o caminho DENTRO do Alpine
set "XEMONITOR_SRC=/tmp/xemonitor-setup-deps.sh"
call :runwsl exec_deps 120 run_script
if !WSL_RC! neq 0 (
    call :log "ERRO: deps script falhou rc=!WSL_RC!"
    echo [ERRO] Falha ao instalar dependencias no Alpine.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
echo       Dependencias Alpine instaladas: openrc, kmod, eudev.
echo.
call :log "=== FASE 2 concluida ==="

echo TRACE-PHASE3-ENTRY
:: ============================================================
:: FASE 3/4: Copia de Arquivos + Config Alpine
:: ============================================================
echo ==========================================
echo  FASE 3/4: Copia de Arquivos + Config
echo ==========================================
echo.

:: [1] Copiar bridge
echo [1/4] Copiando bridge para Alpine...
if exist "%APP_DIR%\bridge" (
    call :to_wsl_path "%APP_DIR%\bridge" BRIDGE_WSL
    if "!BRIDGE_WSL!"=="" (
        call :log "ERRO: to_wsl_path falhou para bridge."
        echo [ERRO] Falha ao converter caminho do bridge.
        set "_DIE_RC=1"
        set "_FATAL=1"
    ) else (
    set "XEMONITOR_SRC=!BRIDGE_WSL!"
    set "XEMONITOR_DEST=/usr/local/bin/xemonitor-bridge"
    call :runwsl copy_bridge 30 copy_file
    if !WSL_RC! neq 0 (
        call :log "ERRO: falha ao copiar bridge rc=!WSL_RC!"
        echo [ERRO] Falha ao copiar bridge - bridge nao podera rodar.
        set "_DIE_RC=1"
        set "_FATAL=1"
    ) else (
        call :log "Bridge copiado."
        echo       bridge copiado.
    )
    )
) else (
    call :log "ERRO: bridge nao encontrado em %APP_DIR%."
    echo [ERRO] bridge nao encontrado em %APP_DIR% - falta build do bridge.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die

:: [2] Copiar init script OpenRC
echo [2/4] Copiando init script OpenRC...
if exist "%APP_DIR%\openrc\xemonitor-bridge" (
    call :to_wsl_path "%APP_DIR%\openrc\xemonitor-bridge" O_WSL
    if "!O_WSL!"=="" (
        call :log "ERRO: to_wsl_path falhou para init script."
        echo [ERRO] Falha ao converter caminho do init script.
        set "_DIE_RC=1"
        set "_FATAL=1"
    ) else (
    set "XEMONITOR_SRC=!O_WSL!"
    set "XEMONITOR_DEST=/etc/init.d/xemonitor-bridge"
    call :runwsl copy_openrc 30 copy_file
    if !WSL_RC! neq 0 (
        call :log "ERRO: falha ao copiar init script rc=!WSL_RC!"
        echo [ERRO] Falha ao copiar init script OpenRC - servico nao podera iniciar.
        set "_DIE_RC=1"
        set "_FATAL=1"
    ) else (
        call :log "Init script OpenRC copiado."
        echo       init script copiado.
    )
    )
) else (
    call :log "AVISO: openrc/xemonitor-bridge nao encontrado."
    echo [AVISO] openrc/xemonitor-bridge nao encontrado - bridge nao tera init script.
)
if "!_FATAL!"=="1" goto :die

:: [3] Copiar systemd unit (fallback Arch/systemd)
if exist "%APP_DIR%\systemd\xemonitor-bridge.service" (
    call :to_wsl_path "%APP_DIR%\systemd\xemonitor-bridge.service" S_WSL
    if not "!S_WSL!"=="" (
        set "XEMONITOR_SRC=!S_WSL!"
        set "XEMONITOR_DEST=/etc/systemd/system/xemonitor-bridge.service"
        call :runwsl copy_systemd 30 copy_file
    )
)

:: [4] Gerar script de config + executar
echo [3/4] Gerando script de configuracao Alpine...
set "CFG_SH=%TEMP%\xemonitor-setup-config.sh"
if "%TEMP%"=="" set "CFG_SH=%USERPROFILE%\AppData\Local\Temp\xemonitor-setup-config.sh"
> "%CFG_SH%" echo #!/bin/sh
>> "%CFG_SH%" echo set -e
>> "%CFG_SH%" echo echo '[config] Criando regra udev CH340...'
>> "%CFG_SH%" echo mkdir -p /etc/udev/rules.d
>> "%CFG_SH%" echo echo 'SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE=="0666"' ^> /etc/udev/rules.d/99-ch340.rules
>> "%CFG_SH%" echo echo '[config] Configurando wsl.conf...'
>> "%CFG_SH%" echo printf '[boot]\ncommand = /sbin/modprobe usbip-core ^&^& /sbin/modprobe vhci-hcd ^&^& /sbin/modprobe ch341\n' ^> /etc/wsl.conf
>> "%CFG_SH%" echo echo '[config] Carregando modulos...'
>> "%CFG_SH%" echo modprobe usbip-core 2^>/dev/null ^|^| true
>> "%CFG_SH%" echo modprobe vhci-hcd 2^>/dev/null ^|^| true
>> "%CFG_SH%" echo modprobe ch341 2^>/dev/null ^|^| true
>> "%CFG_SH%" echo echo '[config] Reload udev...'
>> "%CFG_SH%" echo udevadm control --reload-rules 2^>/dev/null ^|^| true
>> "%CFG_SH%" echo udevadm trigger 2^>/dev/null ^|^| true
>> "%CFG_SH%" echo echo '[config] OK: configuracao do Alpine concluida.'

call :to_wsl_path "%CFG_SH%" CFG_WSL
if "!CFG_WSL!"=="" (
    call :log "ERRO: to_wsl_path falhou para config script."
    echo [ERRO] Falha ao converter caminho do script de configuracao.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
set "XEMONITOR_SRC=!CFG_WSL!"
set "XEMONITOR_DEST=/tmp/xemonitor-setup-config.sh"
call :runwsl copy_config 30 copy_file
if !WSL_RC! neq 0 (
    call :log "ERRO: falha ao copiar config script."
    echo [ERRO] Falha ao copiar script de configuracao.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die

echo [4/4] Executando configuracao Alpine...
set "XEMONITOR_SRC=/tmp/xemonitor-setup-config.sh"
call :runwsl exec_config 60 run_script
if !WSL_RC! neq 0 (
    call :log "ERRO: config script falhou rc=!WSL_RC!"
    echo [ERRO] Falha ao configurar Alpine.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
echo       Alpine configurado: udev + wsl.conf + modulos.
echo.
call :log "=== FASE 3 concluida ==="

:: ============================================================
:: FASE 4/4: Configuracao Final
:: ============================================================
echo ==========================================
echo  FASE 4/4: Configuracao Final
echo ==========================================
echo.

:: [1] Bridge service
echo [1/6] Iniciando bridge no WSL...
call :runwsl svc_enable 120 svc_enable
if !WSL_RC! neq 0 (
    call :log "ERRO: svc_enable falhou rc=!WSL_RC! - bridge nao subiu."
    echo [ERRO] Falha ao iniciar o servico do bridge no Alpine.
    echo        Verifique se o OpenRC e o init script estao corretos.
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
:: Verificacao real: rc-service status + porta 9000 ouvindo
call :runwsl svc_verify 30 svc_status
if !WSL_RC! neq 0 (
    call :log "ERRO: svc_status rc=!WSL_RC! - bridge nao esta listening na 9000."
    echo [ERRO] Bridge subiu mas a porta 9000 nao esta ouvindo.
    echo        Diagnostico: wsl -d %DISTRO% -u root -- rc-service xemonitor-bridge status
    set "_DIE_RC=1"
    set "_FATAL=1"
)
if "!_FATAL!"=="1" goto :die
call :log "Bridge habilitado/iniciado no %DISTRO% e ouvindo na 9000."
echo       Bridge iniciado e porta 9000 ouvindo.
echo.

:: [2] Binarios Windows
echo [2/6] Instalando binarios em %INSTALL_DIR%...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if exist "%APP_DIR%\xemonitor-gui.exe" (
    copy /y "%APP_DIR%\xemonitor-gui.exe" "%INSTALL_DIR%\xemonitor-gui.exe" >nul
    echo       xemonitor-gui.exe instalado.
)
if exist "%APP_DIR%\xemonitor.exe" (
    copy /y "%APP_DIR%\xemonitor.exe" "%INSTALL_DIR%\xemonitor.exe" >nul
    echo       xemonitor.exe instalado.
)
echo.

:: [2b] Config GUI
echo [2b] Gravando config do GUI...
set "CFG_DIR=%APPDATA%\xemonitor"
set "CFG_FILE=%CFG_DIR%\xemonitor-gui.conf"
if /i "%MODE%"=="repair" (
    echo       [Reparo] Resetando config - backup em .bak.
    if exist "%CFG_FILE%" (
        copy /y "%CFG_FILE%" "%CFG_FILE%.bak" >nul 2>&1
        del "%CFG_FILE%" >nul 2>&1
    )
)
call :ensure_gui_cfg "%CFG_DIR%"
echo.

:: [3] Tarefas agendadas
echo [3/6] Criando tarefas agendadas...
if exist "%APP_DIR%\scripts\install_autostart.bat" (
    call "%APP_DIR%\scripts\install_autostart.bat" /silent
    if !errorlevel! neq 0 (
        call :log "ERRO: install_autostart.bat falhou rc=!errorlevel!"
        echo [ERRO] Falha ao criar tarefas agendadas.
        set "_DIE_RC=1"
        set "_FATAL=1"
    ) else (
        call :log "Tarefas criadas via install_autostart.bat."
        echo       Tarefas criadas: USB-Attach, Bridge, App.
    )
) else (
    schtasks /Create /F /TN "XeMonitor-USB-Attach" /TR "\"%INSTALL_DIR%\setup_usb.bat\" /silent" /SC ONLOGON /RL HIGHEST >nul 2>&1
    if !errorlevel! neq 0 (
        call :log "ERRO: schtasks XeMonitor-USB-Attach falhou rc=!errorlevel!"
        set "_FATAL=1"
    )
    schtasks /Create /F /TN "XeMonitor-Bridge" /TR "cmd /c \"\"%INSTALL_DIR%\packaging\windows\start_bridge.cmd\"\"" /SC ONLOGON /DELAY 0000:30 >nul 2>&1
    if !errorlevel! neq 0 (
        call :log "ERRO: schtasks XeMonitor-Bridge falhou rc=!errorlevel!"
        set "_FATAL=1"
    )
    schtasks /Create /F /TN "XeMonitor-App" /TR "\"%INSTALL_DIR%\xemonitor-gui.exe\"" /SC ONLOGON /DELAY 0000:45 /RL LIMITED >nul 2>&1
    if !errorlevel! neq 0 (
        call :log "ERRO: schtasks XeMonitor-App falhou rc=!errorlevel!"
        set "_FATAL=1"
    )
    if "!_FATAL!"=="1" (
        echo [ERRO] Falha ao criar uma ou mais tarefas agendadas.
        set "_DIE_RC=1"
    ) else (
        call :log "Tarefas criadas via schtasks."
        echo       Tarefas criadas: USB-Attach, Bridge, App.
    )
)
if "!_FATAL!"=="1" goto :die
echo.

:: [4] USB attach
echo [4/6] Configurando USB CH340...
if exist "%APP_DIR%\setup_usb.bat" (
    call "%APP_DIR%\setup_usb.bat" /silent
) else (
    call :log "AVISO: setup_usb.bat nao encontrado."
    echo [AVISO] setup_usb.bat nao encontrado.
)
echo.

:: [5] Verifica scanner
echo [5/6] Verificando scanner USB-Serial...
set "SCANNER_STATUS=nao verificado"
ping -n 4 127.0.0.1 >nul
call :runwsl tty_check 30 tty_check
if !WSL_RC! equ 0 (
    set "SCANNER_STATUS=detectado - /dev/ttyUSB0"
    call :log "Scanner detectado: /dev/ttyUSB0."
    echo.
    echo       [OK] Scanner USB-Serial detectado - /dev/ttyUSB0.
) else (
    set "SCANNER_STATUS=NAO detectado"
    call :log "Scanner NAO detectado. Conecte o CH340 e rode setup_usb.bat."
    echo.
    echo  ============================================================
    echo  [IMPORTANTE] Scanner USB-Serial NAO detectado.
    echo  ============================================================
    echo.
    echo   1. Conecte o adaptador CH340 em uma porta USB
    echo   2. Rode: setup_usb.bat
    echo   3. Ou clique em 'Reparar' na GUI apos conectar
    echo.
    echo   O bridge re-tenta a cada 2s - quando o scanner for
    echo   attachado, os scans comecam a funcionar.
    echo  ============================================================
    echo.
)

:: [6] Resumo
echo ==========================================
echo  Instalacao v0.7.2 concluida!
echo.
echo   Instalado em:   %INSTALL_DIR%
echo   Distro WSL:     %DISTRO% (Alpine/OpenRC)
echo   Bridge:         /usr/local/bin/xemonitor-bridge
echo   Logs:           %LOG_DIR%
echo   Tarefas:        USB-Attach / Bridge / App
echo   Iniciado:       bridge (WSL) + xemonitor-gui
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
:: :die — cleanup + exit (goto-safe, never inside ( ... ) block)
:: ============================================================
:die
del "%LOCKFILE%" >nul 2>&1
call :pause_helper
if not defined _DIE_RC set "_DIE_RC=1"
exit /b %_DIE_RC%

:: ============================================================
:: :runwsl <label> <timeout_s> <task>
:: Roda comando wsl via wsl_timeout.ps1 (timeout + kill + log).
:: Define WSL_RC. Usa XEMONITOR_DISTRO/SRC/DEST/TARBALL.
:: ============================================================
:runwsl
set "WSL_RC=1"
set "XEMONITOR_DISTRO=%DISTRO%"
set "_rwl_skip=0"
if /i "%3"=="copy_file" if "!XEMONITOR_SRC!"=="" (
    call :log "ERRO runwsl %1: XEMONITOR_SRC vazio."
    set "_rwl_skip=1"
)
if /i "%3"=="run_script" if "!XEMONITOR_SRC!"=="" (
    call :log "ERRO runwsl %1: XEMONITOR_SRC vazio - run_script"
    set "_rwl_skip=1"
)
if "%_rwl_skip%"=="1" exit /b 0
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
set "XEMONITOR_DEST="
exit /b 0

:: ============================================================
:: :log - append de mensagem no LOGFILE
:: ============================================================
:log
if not defined LOGFILE exit /b 0
echo %date% %time%  %*>>"%LOGFILE%"
exit /b 0

:: ============================================================
:: :pause_helper - pausa so em modo interativo (sem /silent)
:: ============================================================
:pause_helper
if /i not "%SILENT%"=="/silent" pause
exit /b 0

:: ============================================================
:: :ensure_gui_cfg <cfg_dir>
:: Garante xemonitor-gui.conf com server_mode=wsl.
:: ============================================================
:ensure_gui_cfg
set "CFG_DIR=%~1"
set "CFG_FILE=%CFG_DIR%\xemonitor-gui.conf"
if not exist "%CFG_DIR%" mkdir "%CFG_DIR%"
if not exist "%CFG_FILE%" goto :cfg_write_new
findstr /B /I "server_mode=wsl" "%CFG_FILE%" >nul 2>&1
if not errorlevel 1 goto :cfg_keep
call :log "xemonitor-gui.conf com server_mode invalido; migrando para wsl."
copy /y "%CFG_FILE%" "%CFG_FILE%.bak" >nul 2>&1
findstr /V /B /I "server_mode=" "%CFG_FILE%" > "%CFG_DIR%\gui-cfg.tmp"
echo server_mode=wsl>>"%CFG_DIR%\gui-cfg.tmp"
move /y "%CFG_DIR%\gui-cfg.tmp" "%CFG_FILE%" >nul 2>&1
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
call :log "xemonitor-gui.conf gravado."
echo       Config do GUI gravada.
goto :cfg_done

:cfg_keep
call :log "xemonitor-gui.conf ja existe e valida."
echo       Config do GUI mantida.

:cfg_done
exit /b 0

:: ============================================================
:: :to_wsl_path <caminho_windows> <out_var>
:: Converte C:\Program Files\XeMonitor\bridge em
:: /mnt/c/Program Files/XeMonitor/bridge
:: ============================================================
:to_wsl_path
set "%~2="
set "_twp_rc=0"
call :log "TRACE: to_wsl_path(%~1)"
if "%~1"=="" (
    call :log "ERRO to_wsl_path: caminho vazio."
    set "_twp_rc=1"
)
if "%_twp_rc%"=="1" exit /b 1
for /f "delims=" %%p in ('powershell -NoProfile -Command "$p='%~1'; if(-not $p){Write-Output '';exit 1}; $p=$p -replace '\\','/'; $d=$p.Substring(0,1).ToLower(); $rest=$p.Substring(3); Write-Output ('/mnt/'+$d+'/'+$rest)" 2^>nul') do set "%~2=%%p"
if "%~2"=="" (
    call :log "ERRO to_wsl_path: falha ao converter '%~1'."
    set "_twp_rc=1"
)
if "%_twp_rc%"=="1" exit /b 1
exit /b 0
