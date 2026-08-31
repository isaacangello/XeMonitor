@echo off
:: ============================================================
:: install_windows.bat v0.8.0 - Instalador Windows do XeMonitor.
:: Fluxo: sanitizacao pre-instalacao -> golden image -> bridge -> final.
::
::  SANIT    Pre-flight: remove estado residual de instalacao anterior
::           (distro WSL 'Alpine', %APPDATA%\xemonitor, tarefas) -> fresh.
::  FASE 1   Dependencias Windows + import do MINIROOT Alpine
::           (imagem pre-fabricada e testada com o bridge versionado:
::            openrc, kmod, eudev, udev rule CH340, wsl.conf, init script
::            e /usr/local/bin/xemonitor-bridge).
::  FASE 2   (removida) Deps Alpine ja vem pre-baked no miniroot.
::  FASE 3   (removida) Bridge nao eh mais copiado para o VHD; vem no miniroot.
::  FASE 4   Servico (svc_enable -> porta 9000) + binarios Windows + tarefas + USB.
::
:: Uso: install_windows.bat [/silent]
::   /silent  — Inno Setup ([Run]): nao faz pause. Instalacao existente = auto-reparo.
:: ============================================================
setlocal enabledelayedexpansion
title XeMonitor - Instalar v0.8.0 (Windows)
set "_FATAL=0"

:: ------- Config -------
set "SILENT=%~1"
:: %APP_DIR% = raiz da instalacao = %CD%. Em producao, o Inno Setup roda
:: este script com WorkingDir={app}. Em testes (staging), scripts\run_install_test.bat
:: faz cd para o staging root antes de chamar. SEMPRE invocacao explicita;
:: nenhum auto-detect por path relativo.
set "APP_DIR=%CD%"
if not exist "%APP_DIR%\packaging\windows\install_windows.bat" (
    echo [ERRO] Este script deve ser executado a partir de %%APP_DIR%%.
    echo        Ex.: C:\Program Files\XeMonitor\packaging\windows\install_windows.bat
    echo        Em testes: scripts\run_install_test.bat monta o staging e invoca.
    exit /b 1
)
set "INSTALL_DIR=%ProgramFiles%\XeMonitor"
set "LOG_DIR=%APPDATA%\xemonitor\logs"
:: LOGFILE e o log oficial (em %APPDATA%). Antes de escrever nele,
:: precisamos garantir que a pasta %LOG_DIR% existe; mas tambem queremos
:: poder apagar %APPDATA%\xemonitor na SANITIZACAO. Truque: escrever
:: num arquivo temporario e copiar para LOGFILE no final.
set "LOGFILE=%LOG_DIR%\install.log"
set "TEMP_LOG=%TEMP%\xemonitor-install-%RANDOM%.log"
set "LOCKFILE=%TEMP%\xemonitor-install.lock"
call :log "=== XeMonitor installer v0.8.0 iniciado (silent=%SILENT%, pid=%INSTALL_PID%) ==="

:: ------- PID do processo -------
set "INSTALL_PID="
for /f "delims=" %%p in ('powershell -NoProfile -Command "[System.Diagnostics.Process]::GetCurrentProcess().Id"') do set "INSTALL_PID=%%p"

:: ------- Log helper -------
call :log "=== XeMonitor installer v0.8.0 iniciado (silent=%SILENT%, pid=%INSTALL_PID%) ==="

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
echo  XeMonitor v0.8.0 - Instalador Windows
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

:: ============================================================
:: 0.5  SANITIZACAO PRE-INSTALACAO (estado limpo)
:: ============================================================
:: Todo novo fluxo (install OU repair) comeca por limpar os canais de estado
:: residual de uma instalacao anterior, para nao interferir na atual:
::   - processos do app (arquivos podem estar locked)
::   - distro WSL 'Alpine' (registro + VHD em C:\wsl\Alpine) -> wsl --unregister
::   - %APPDATA%\xemonitor (conf -> dispara EXISTING=1; logs; pids) -> fresh total
::   - tarefas agendadas XeMonitor-*
:: Cada passo e logado e VALIDADO; falha de remocao vira _FATAL (nao trava mudo).
echo TRACE-SANITIZE-ENTRY
call :log "=== SANITIZACAO PRE-INSTALACAO iniciada ==="
set "SAN_ERR=0"

:: [1] Matar processos
taskkill /F /IM xemonitor-gui.exe >nul 2>&1
taskkill /F /IM xemonitor.exe >nul 2>&1
:: Esperar os handles serem liberados antes de tentar rd /s /q.
ping -n 2 127.0.0.1 >nul
call :log "Sanitize: processos encerrados (se havia)."

:: [2] Remover distro WSL 'Alpine' + VHD residual
echo       Sanitizando distro WSL...
wsl --terminate Alpine >nul 2>&1
wsl --unregister Alpine >nul 2>&1
if exist "C:\wsl\Alpine" rd /s /q "C:\wsl\Alpine" >nul 2>&1
set "SAN_ALPINE=1"
set "SAN_CMD="
for /f "delims=" %%l in ('wsl -l -q 2^>nul') do if /i "%%l"=="Alpine" set "SAN_CMD=found"
if defined SAN_CMD (
    call :log "SANITIZE-ERRO: distro Alpine ainda registrada apos unregister."
    echo [ERRO] Nao foi possivel remover a distro WSL 'Alpine'.
    set "SAN_ERR=1"
) else (
    call :log "Sanitize: distro WSL 'Alpine' removida."
)
if "!SAN_ERR!"=="1" set "_SAN_FATAL=1"

:: [3] Apagar pasta de config do app (fresh total)
if exist "%APPDATA%\xemonitor" (
    rd /s /q "%APPDATA%\xemonitor" >nul 2>&1
    if exist "%APPDATA%\xemonitor" (
        call :log "SANITIZE-ERRO: nao foi possivel apagar %APPDATA%\xemonitor."
        echo [ERRO] Nao foi possivel limpar a config antiga.
        set "SAN_ERR=1"
        set "_SAN_FATAL=1"
    ) else (
        call :log "Sanitize: %APPDATA%\xemonitor apagado (fresh)."
    )
) else (
    call :log "Sanitize: %APPDATA%\xemonitor inexistente (nada a limpar)."
)
:: Recriar pasta de logs (a pasta de config foi apagada; manter log de instalacao)
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
call :log "Sanitize: pasta de logs recriada."

:: [4] Remover tarefas agendadas (idempotente)
schtasks /Delete /F /TN "XeMonitor-USB-Attach" >nul 2>&1
schtasks /Delete /F /TN "XeMonitor-Bridge" >nul 2>&1
schtasks /Delete /F /TN "XeMonitor-App" >nul 2>&1
schtasks /Delete /F /TN "XeMonitor-Bridge-Watchdog" >nul 2>&1
call :log "Sanitize: tarefas XeMonitor-* removidas (se havia)."

if "!_SAN_FATAL!"=="1" (
    call :log "=== SANITIZACAO FALHOU (residuo nao removido) ==="
    set "_DIE_RC=1"
    set "_FATAL=1"
    goto :die
)
call :log "=== SANITIZACAO concluida: estado limpo ==="
:: Apos limpar config/distro, o modo vira instalacao fresh
set "EXISTING=0"
set "MODE=install"
call :log "TRACE: pos-sanitizacao MODE=%MODE%, EXISTING=%EXISTING%"
echo TRACE-SANITIZE-DONE

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

:: [5] Obter miniroot Alpine pre-fabricado (bridge versionado embarcado)
:: O miniroot vem embutido em %APP_DIR%\packaging\windows\miniroots\ (o Inno
:: empacota o tarball mais recente). Nome: alpine-bridge-<ver>.<build>-x86_64.tar.gz
echo [5/6] Obtendo miniroot Alpine (bridge pre-baked)...
set "MINIROOT_DIR=%APP_DIR%\packaging\windows\miniroots"
set "TARBALL="

:: Procurar o tarball mais recente em %MINIROOT_DIR%
for /f "delims=" %%F in ('dir /b /od /a-d "%MINIROOT_DIR%\alpine-bridge-*.tar.gz" 2^>nul') do set "LATEST_MINIROOT=%%F"
if defined LATEST_MINIROOT (
    set "MINIROOT_IMG=%MINIROOT_DIR%\!LATEST_MINIROOT!"
    set "TARBALL=%TEMP%\!LATEST_MINIROOT!"
) else (
    call :log "ERRO: nenhum miniroot em %MINIROOT_DIR%."
    echo [ERRO] Miniroot Alpine nao encontrado. Reinstale o pacote.
    set "_DIE_RC=1"
    set "_FATAL=1"
    goto :skip_miniroot_select
)
call :log "Miniroot selecionado: !MINIROOT_IMG!"
echo       Usando miniroot !LATEST_MINIROOT! (bridge pre-baked).
copy /Y "!MINIROOT_IMG!" "!TARBALL!" >nul 2>&1
if !errorlevel! neq 0 (
    call :log "ERRO: nao foi possivel copiar miniroot para temp."
    set "_DIE_RC=1"
    set "_FATAL=1"
)
:skip_miniroot_select
call :log "Tarball miniroot: !TARBALL!"
if "!_FATAL!"=="1" goto :die
echo.
if "!_FATAL!"=="1" goto :die
echo.

:: [6] Import Alpine (imagem miniroot pre-fabricada e versionada pelo bridge)
echo [6/6] Importando Alpine miniroot (bridge pre-baked)...
set "DISTRO=Alpine"
set "XEMONITOR_TARBALL=%TARBALL%"
call :runwsl import_alpine 300 import_alpine
if !WSL_RC! neq 0 (
    call :log "ERRO: falha ao importar Alpine rc=!WSL_RC!"
    echo [ERRO] Nao foi possivel importar o miniroot Alpine.
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
call :runwsl set_default 60 set_default
call :log "Distro WSL: %DISTRO%"
echo       Alpine pronto (miniroot).
echo.
call :log "=== FASE 1 concluida ==="

:: ============================================================
:: (FASE 2 removida) Dependencias Alpine (openrc, kmod, eudev)
:: Ja vienen prontas na GOLDEN IMAGE (imagem pre-configurada e testada).
:: Nao roda mais apk durante a instalacao -> instalacao mais rapida e
:: menos sujeita a falhas de rede.
:: ============================================================

echo TRACE-PHASE3-ENTRY
:: ============================================================
:: FASE 3/4: REMOVIDA
:: O miniroot ja vem com a versao EXATA do bridge (pre-baked e validada
:: no build via scripts/build_miniroot.sh). Nao ha mais copia de bridge
:: para o VHD: o bridge dentro do Alpine eh o que vai rodar, e a Inno
:: Setup substituiu o bridge em %APP_DIR%\bridge pela mesma versao.
:: Bumps de bridge = nova compilacao + geracao de miniroot + nova release.
:: ============================================================
call :log "FASE 3 suprimida: bridge vem pre-baked no miniroot."
echo ==========================================
echo  FASE 3/4: (suprimida)
echo ==========================================
echo       bridge ja esta pre-baked no miniroot importado.
echo.
call :log "=== FASE 3 concluida (no-op) ==="

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
echo  Instalacao v0.8.0 concluida!
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
:: Move o log temporario para o log oficial (so agora, apos a sanitizacao).
if exist "%TEMP_LOG%" (
    if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" 2>nul
    move /Y "%TEMP_LOG%" "%LOGFILE%" >nul 2>&1
)
call :pause_helper
exit /b 0

:: ============================================================
:: :die — cleanup + exit (goto-safe, never inside ( ... ) block)
:: ============================================================
:die
del "%LOCKFILE%" >nul 2>&1
:: Move o log temporario para o oficial (mesmo em caso de erro).
if exist "%TEMP_LOG%" (
    if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" 2>nul
    move /Y "%TEMP_LOG%" "%LOGFILE%" >nul 2>&1
)
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
:: Escreve em %TEMP_LOG% (arquivo temporario) e so no final o conteudo
:: e movido para %LOGFILE%. Isso permite que a SANITIZACAO apague
:: %APPDATA%\xemonitor sem conflito com o bat tendo o log aberto.
:: ============================================================
:log
if not defined TEMP_LOG exit /b 0
echo %date% %time%  %*>>"%TEMP_LOG%"
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
