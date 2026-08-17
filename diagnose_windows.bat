@echo off
title XeMonitor - Diagnostico Windows
setlocal enabledelayedexpansion

:: ============================================================
:: diagnose_windows.bat - diagnostico / auto-recuperacao no Windows.
::
:: Uso:
::   diagnose_windows.bat              -> --check (padrao)
::   diagnose_windows.bat --check
::   diagnose_windows.bat --fix        -> reattach USB + reinicia bridge + relanca GUI
::   diagnose_windows.bat --test-serial-> teste live da serial (para o bridge temporariamente)
::   diagnose_windows.bat --help
::
:: Cada camada e verificada e reportada com OK/ERRO/AVISO + correcao sugerida.
:: Exit code: 0 = tudo OK; 1 = algum problema encontrado.
:: ============================================================

set "MODE=check"
set "FAIL=0"
set "PORT=9000"
set "CFG_DIR=%APPDATA%\xemonitor"
set "LOG=%CFG_DIR%\xemonitor-%date:~10,4%-%date:~4,2%-%date:~7,2%.log"
if not exist "%LOG%" set "LOG=%CFG_DIR%\xemonitor.log"

set "USBIPD="
for /f "delims=" %%P in ('where usbipd 2^>nul') do if not defined USBIPD set "USBIPD=%%P"
if not defined USBIPD if exist "C:\Program Files\usbipd-win\usbipd.exe" set "USBIPD=C:\Program Files\usbipd-win\usbipd.exe"
if not defined USBIPD set "USBIPD=usbipd"

goto :main

:: ============================================================
:: report <nivel> <msg>  (OK|OFF|AVISO|ERRO|INFO)
:: ============================================================
:report
set "LEVEL=%~1"
set "MSG=%~2"
if "%LEVEL%"=="OK" echo [OK]    %MSG%
if "%LEVEL%"=="OFF" echo [OFF]   %MSG%
if "%LEVEL%"=="OFF" set "FAIL=1"
if "%LEVEL%"=="AVISO" echo [AVISO] %MSG%
if "%LEVEL%"=="ERRO" echo [ERRO]  %MSG%
if "%LEVEL%"=="ERRO" set "FAIL=1"
if "%LEVEL%"=="INFO" echo [INFO]  %MSG%
exit /b 0

:: ============================================================
:: check_wsl - distro WSL Alpine presente
:: ============================================================
:check_wsl
echo --- WSL (Alpine) ---
wsl -d Alpine echo ok >nul 2>&1
if %errorlevel% equ 0 (
    call :report OK "distro Alpine WSL presente."
) else (
    call :report ERRO "Alpine WSL ausente. Rode o instalador setup.exe (baixa o Alpine e o define como padrao)."
    wsl -l -v
)
echo.
exit /b 0

:: ============================================================
:: check_usb - usbipd + CH340 bound/attached
:: ============================================================
:check_usb
echo --- usbipd / CH340 ---
if not exist "%USBIPD%" (
    call :report ERRO "usbipd nao encontrado. Instale com: winget install usbipd"
    echo.
    exit /b 0
)
call :report OK "usbipd encontrado (%USBIPD%)."

set "BOUND="
for /f "tokens=*" %%L in ('"%USBIPD%" list 2^>nul') do (
    echo %%L | findstr /i "1a86:7523" >nul 2>&1
    if !errorlevel! equ 0 set "BOUND=yes"
)
if defined BOUND (
    call :report OK "CH340 (1a86:7523) presente no usbipd list."
) else (
    call :report ERRO "CH340 (1a86:7523) nao listado no usbipd. Scanner conectado? Honeywell 1900 via CH340"
    call :report INFO "Correcao: rode setup_usb.bat ou o botao Reparar na GUI."
)
echo.
exit /b 0

:: ============================================================
:: check_ch341 - driver ch341 (CH340) carregado no WSL
:: ============================================================
:check_ch341
echo --- driver ch341 (WSL) ---
set "CTL=%~dp0scripts\bridge_ctl.bat"
if not exist "%CTL%" set "CTL=%ProgramFiles%\XeMonitor\scripts\bridge_ctl.bat"
if not exist "%CTL%" (
    call :report ERRO "bridge_ctl.bat nao encontrado (necessario p/ check ch341)."
    echo.
    exit /b 0
)
call "%CTL%" ch341 2>nul
if %errorlevel% equ 0 (
    call :report OK "ch341 carregado e /dev/ttyUSB0 presente."
) else (
    call :report ERRO "ch341 nao carregado ou /dev/ttyUSB0 ausente. Correcao: scripts\bridge_ctl.bat ch341"
)
echo.
exit /b 0

:: ============================================================
:: check_dev - /dev/ttyUSB0 no WSL
:: ============================================================
:check_dev
echo --- /dev/ttyUSB0 (no WSL) ---
wsl -d Alpine sh -c "test -c /dev/ttyUSB0" >nul 2>&1
if %errorlevel% equ 0 (
    call :report OK "/dev/ttyUSB0 presente no WSL (CH340 attached)."
) else (
    call :report ERRO "/dev/ttyUSB0 ausente no WSL. Rode setup_usb.bat ou o botao Reparar na GUI."
)
echo.
exit /b 0

:: ============================================================
:: check_bridge - servico do bridge no WSL
:: ============================================================
:check_bridge
echo --- servico do bridge (WSL) ---
set "CTL=%~dp0scripts\bridge_ctl.bat"
if not exist "%CTL%" set "CTL=%ProgramFiles%\XeMonitor\scripts\bridge_ctl.bat"
if not exist "%CTL%" (
    call :report ERRO "bridge_ctl.bat nao encontrado."
    echo.
    exit /b 0
)
call "%CTL%" status 2>nul
if %errorlevel% equ 0 (
    call :report OK "bridge ativo no WSL."
) else (
    call :report ERRO "bridge nao esta ativo no WSL. Correcao: scripts\bridge_ctl.bat start"
)
echo.
exit /b 0

:: ============================================================
:: check_port - porta TCP 9000
:: ============================================================
:check_port
echo --- porta TCP %PORT% ---
netstat -ano 2>nul | findstr ":%PORT%" | findstr "LISTENING" >nul 2>&1
if %errorlevel% equ 0 (
    call :report OK "porta %PORT% escutando."
) else (
    call :report ERRO "porta %PORT% nao esta escutando. Correcao: scripts\bridge_ctl.bat restart"
)
echo.
exit /b 0

:: ============================================================
:: check_client - xemonitor.exe
:: ============================================================
:check_client
echo --- cliente (xemonitor.exe) ---
set "N_CLIENT=0"
for /f %%P in ('tasklist /FI "IMAGENAME eq xemonitor.exe" /NH 2^>nul') do set /a N_CLIENT+=1
if %N_CLIENT% equ 0 (
    call :report OFF "cliente nao esta rodando. Correcao: inicio via GUI (botao Iniciar do cliente) ou XeMonitor-App."
) else (
    call :report OK "%N_CLIENT% instancia(s) de xemonitor.exe."
)
netstat -ano 2>nul | findstr ":%PORT%" | findstr "ESTABLISHED" >nul 2>&1
if %errorlevel% equ 0 (
    call :report OK "conexao ESTABLISHED em :%PORT%."
) else (
    call :report AVISO "cliente sem conexao ESTABLISHED em :%PORT% (reconecta a cada 2s)."
)
echo.
exit /b 0

:: ============================================================
:: check_gui - xemonitor-gui.exe
:: ============================================================
:check_gui
echo --- xemonitor-gui ---
set "N_GUI=0"
for /f %%P in ('tasklist /FI "IMAGENAME eq xemonitor-gui.exe" /NH 2^>nul') do set /a N_GUI+=1
if %N_GUI% equ 0 (
    call :report OFF "xemonitor-gui.exe nao esta rodando. Correcao: packaging\windows\start_xemonitor.cmd"
) else if %N_GUI% gtr 1 (
    call :report AVISO "%N_GUI% instancias de xemonitor-gui (esperado 1)."
) else (
    call :report OK "1 instancia de xemonitor-gui rodando."
)
echo.
exit /b 0

:: ============================================================
:: check_tasks - tarefas agendadas
:: ============================================================
:check_tasks
echo --- tarefas agendadas ---
schtasks /Query /TN "XeMonitor-USB-Attach" >nul 2>&1
if %errorlevel% equ 0 ( call :report OK "tarefa XeMonitor-USB-Attach existe." ) else ( call :report ERRO "tarefa XeMonitor-USB-Attach ausente. Correcao: scripts\install_autostart.bat" )
schtasks /Query /TN "XeMonitor-Bridge" >nul 2>&1
if %errorlevel% equ 0 ( call :report OK "tarefa XeMonitor-Bridge existe." ) else ( call :report ERRO "tarefa XeMonitor-Bridge ausente. Correcao: scripts\install_autostart.bat" )
schtasks /Query /TN "XeMonitor-App" >nul 2>&1
if %errorlevel% equ 0 ( call :report OK "tarefa XeMonitor-App existe." ) else ( call :report ERRO "tarefa XeMonitor-App ausente. Correcao: scripts\install_autostart.bat" )
echo.
exit /b 0

:: ============================================================
:: check_integ - nivel de integridade (UIPI)
:: ============================================================
:check_integ
echo --- nivel de integridade (UIPI) ---
whoami /groups 2>nul | findstr /i "S-1-16-12288 High" >nul 2>&1
if %errorlevel% equ 0 (
    call :report AVISO "rodando elevado (High). SendInput nao injeta em janelas nao-elevadas. Rode nao-elevado."
) else (
    call :report OK "nivel de integridade Medio (adequado p/ SendInput)."
)
echo.
exit /b 0

:: ============================================================
:: check_log - ultimo scan
:: ============================================================
:check_log
echo --- log (ultimo scan) ---
if not exist "%LOG%" (
    call :report AVISO "log nao existe ainda (%LOG%)."
    echo.
    exit /b 0
)
set "LAST_SCAN="
for /f "tokens=*" %%L in ('findstr /c:"[scan]" "%LOG%" 2^>nul') do set "LAST_SCAN=%%L"
if defined LAST_SCAN (
    call :report OK "ultimo scan: !LAST_SCAN!"
) else (
    call :report AVISO "nenhum [scan] registrado ainda."
)
call :report INFO "log: %LOG%"
echo.
exit /b 0

:: ============================================================
:: do_check
:: ============================================================
:do_check
echo ========================================
echo  Diagnostico do XeMonitor Windows (%date% %time%)
echo ========================================
echo.
call :check_wsl
call :check_usb
call :check_dev
call :check_ch341
call :check_bridge
call :check_port
call :check_client
call :check_gui
call :check_tasks
call :check_integ
call :check_log
if %FAIL% equ 0 (
    echo ========================================
    echo  TUDO OK. Escaneie e confira o editor focado.
    echo ========================================
) else (
    echo ========================================
    echo  PROBLEMAS ENCONTRADOS. Corrija ou rode: diagnose_windows.bat --fix
    echo ========================================
)
exit /b %FAIL%

:: ============================================================
:: do_fix - reattach USB + restart bridge + relanca GUI/cliente
:: ============================================================
:do_fix
echo ========================================
echo  Aplicando correcoes (--fix)
echo ========================================
echo.
taskkill /F /IM xemonitor-gui.exe >nul 2>&1
taskkill /F /IM xemonitor.exe >nul 2>&1
timeout /t 1 /nobreak >nul
echo [INFO] instancias antigas de xemonitor-gui/xemonitor encerradas.
echo.

:: Reattach USB via tarefa elevada (sem popup UAC na hora; tarefa ja eh HIGHEST)
echo [INFO] parando bridge (libera /dev/ttyUSB0)...
call "%~dp0scripts\bridge_ctl.bat" stop >nul 2>&1
echo [INFO] reattach CH340 via tarefa XeMonitor-USB-Attach...
schtasks /Run /TN "XeMonitor-USB-Attach" >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] tarefa XeMonitor-USB-Attach falhou. Rode setup_usb.bat manualmente.
    set "FAIL=1"
)
echo [INFO] garantindo driver ch341 carregado (modprobe + test)...
call "%~dp0scripts\bridge_ctl.bat" ch341 >nul 2>&1

set /p "=aguardando /dev/ttyUSB0" <nul
set "I=0"
:fix_wait_dev
if %I% geq 20 goto :fix_wait_dev_done
set /a I+=1
wsl -d Alpine sh -c "test -c /dev/ttyUSB0" >nul 2>&1
if %errorlevel% equ 0 goto :fix_wait_dev_done
timeout /t 1 /nobreak >nul
set /p "=." <nul
goto :fix_wait_dev
:fix_wait_dev_done
echo.
wsl -d Alpine sh -c "test -c /dev/ttyUSB0" >nul 2>&1
if %errorlevel% equ 0 (
    call :report OK "/dev/ttyUSB0 presente."
) else (
    call :report ERRO "/dev/ttyUSB0 ausente apos 20s. Verifique o scanner (Honeywell 1900 CH340) e o setup_usb.bat."
    set "FAIL=1"
)

echo [INFO] reiniciando bridge...
call "%~dp0scripts\bridge_ctl.bat" restart
if %errorlevel% equ 0 ( call :report OK "bridge reiniciado." ) else ( call :report ERRO "bridge nao reiniciou." ; set "FAIL=1" )

echo.
echo [INFO] Diagnostico pos-fix:
call :do_check
echo.
if %FAIL% equ 0 (
    echo [INFO] Relancando GUI + cliente...
    start "" "%~dp0packaging\windows\start_xemonitor.cmd"
)
echo.
echo Para subir manualmente: run_bridge.bat
exit /b %FAIL%

:: ============================================================
:: do_test_serial - teste live da serial
:: ============================================================
:do_test_serial
echo ========================================
echo  Teste live da serial (--test-serial)
echo ========================================
echo.
wsl -d Alpine sh -c "test -c /dev/ttyUSB0" >nul 2>&1
if %errorlevel% neq 0 (
    call :report ERRO "/dev/ttyUSB0 nao existe. Rode setup_usb.bat primeiro."
    exit /b 1
)
echo [INFO] parando bridge temporariamente para liberar /dev/ttyUSB0...
call "%~dp0scripts\bridge_ctl.bat" stop >nul 2>&1
echo [INFO] lendo /dev/ttyUSB0 por 8s. DISPARE O SCANNER AGORA (ou digite no terminal).
echo ------------------------------------------------------------
set "OUT="
for /l %%I in (1,1,8) do (
    wsl -d Alpine sh -c "timeout 1 dd if=/dev/ttyUSB0 bs=1 count=200 2>/dev/null" > "%TEMP%\xemonitor-serial-test.bin" 2>nul
    if exist "%TEMP%\xemonitor-serial-test.bin" set /p OUT=<"%TEMP%\xemonitor-serial-test.bin"
    if defined OUT goto :serial_got
    timeout /t 1 /nobreak >nul
)
:serial_got
call "%~dp0scripts\bridge_ctl.bat" start >nul 2>&1
echo ------------------------------------------------------------
if defined OUT (
    echo [OK] bytes recebidos:
    echo     !OUT!
    call :report OK "hardware + serial OK (bytes chegaram)."
    exit /b 0
)
call :report ERRO "nenhum byte em 8s. Verifique: scanner ligado? gatilho dispara laser? CH340 reconectado?"
call :report INFO "Tente desconectar/reconectar o cabo USB do scanner (CH340) e repetir o teste."
exit /b 1

:: ============================================================
:: main
:: ============================================================
:main
if /i "%~1"=="--check" set "MODE=check"
if /i "%~1"=="--fix" set "MODE=fix"
if /i "%~1"=="--test-serial" set "MODE=test-serial"
if /i "%~1"=="--help" (
    echo Diagnostico do XeMonitor Windows.
    echo   diagnose_windows.bat            = --check  padrao
    echo   diagnose_windows.bat --fix      = reattach USB + restart bridge + relanca GUI
    echo   diagnose_windows.bat --test-serial = teste live da serial
    echo Exit code: 0 = OK, 1 = problema.
    exit /b 0
)
if /i "%~1"=="-h" (
    echo Diagnostico do XeMonitor Windows.
    echo   diagnose_windows.bat            = --check  padrao
    echo   diagnose_windows.bat --fix      = reattach USB + restart bridge + relanca GUI
    echo   diagnose_windows.bat --test-serial = teste live da serial
    echo Exit code: 0 = OK, 1 = problema.
    exit /b 0
)

if "%MODE%"=="check" call :do_check
if "%MODE%"=="fix" call :do_fix
if "%MODE%"=="test-serial" call :do_test_serial

exit /b %FAIL%
