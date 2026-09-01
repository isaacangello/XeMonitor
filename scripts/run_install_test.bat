@echo off
:: ============================================================
:: run_install_test.bat - Wrapper de teste E2E do instalador.
:: Monta o staging dir, faz cd para a raiz dele (= WorkingDir
:: que o Inno usa em producao) e chama install_windows.bat /silent
:: em modo degradado (sem UAC), redirecionando stdout/stderr para arquivo de log.
::
:: Uso (a partir da raiz do repo):
::   scripts\run_install_test.bat
::
:: Log gerado em:
::   %TEMP%\xemonitor-install-test-<YYYYMMDD-HHMMSS>.txt
:: ============================================================
setlocal enabledelayedexpansion

set "ROOT=%~dp0.."
cd /d "%ROOT%"

echo [run_test] Root: %ROOT%

:: 1) Montar staging (se zig-out\staging\XeMonitor tem handle preso de
;; run anterior, cai automaticamente em zig-out\staging\test\XeMonitor)
set "STAGING=%ROOT%\zig-out\staging\XeMonitor"
if exist "%STAGING%\packaging\windows\install_windows.bat" (
    echo [run_test] staging existente em %STAGING% (reaproveitando)
) else (
    echo [run_test] montando staging em %STAGING%...
    powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\make_install_staging.ps1" -Root "%ROOT%" -StagingDir "%STAGING%" 2>nul
    if errorlevel 1 (
        echo [run_test] staging original locked; usando staging alternativo
        set "STAGING=%ROOT%\zig-out\staging\test\XeMonitor"
        if exist "%STAGING%\packaging\windows\install_windows.bat" (
            echo [run_test] staging alternativo existente (reaproveitando)
        ) else (
            echo [run_test] montando staging alternativo em %STAGING%...
            powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\make_install_staging.ps1" -Root "%ROOT%" -StagingDir "%STAGING%"
        )
    )
)
if not exist "%STAGING%\packaging\windows\install_windows.bat" (
    echo [run_test] ERRO: staging nao foi criado em %STAGING%
    exit /b 1
)

:: 2) Preparar log (em %TEMP%, NAO em %APPDATA% - o bat vai apagar %APPDATA%\xemonitor na sanitizacao)
for /f "delims=" %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%I"
set "LOGFILE=%TEMP%\xemonitor-install-test-%STAMP%.txt"

echo [run_test] staging: %STAGING%
echo [run_test] log:     %LOGFILE%

:: 3) Escrever wrapper .cmd que faz cd no staging e roda o bat.
:: XM_SKIP_ELEVATE=1 faz o install_windows.bat NAO tentar auto-elevar
;; (em headless o UAC prompt nao aparece). O caller (opencode) deve
;; garantir que ja esta rodando elevado quando necessario.
set "WRAPPER=%TEMP%\xm_run_install_test_%STAMP%.cmd"
echo @echo off>"%WRAPPER%"
echo cd /d "%STAGING%">>"%WRAPPER%"
echo set XM_SKIP_ELEVATE=1>>"%WRAPPER%"
echo call "%STAGING%\packaging\windows\install_windows.bat" /silent>>"%WRAPPER%"
echo echo EXIT=%%errorlevel%%>>"%WRAPPER%"

:: 4) Subir o wrapper. XM_NO_RUNAS=1 roda direto sem RunAs.
if defined XM_NO_RUNAS (
    cmd /c "%WRAPPER%" > "%LOGFILE%" 2>&1
    set "RC=%errorlevel%"
) else (
    :: Usar runas.exe nativo do Windows para elevacao
    runas /user:Administrator "%WRAPPER%" > "%LOGFILE%" 2>&1
    set "RC=%errorlevel%"
)

:: Limpa wrapper
del "%WRAPPER%" 2>nul

echo [run_test] exit code: %RC%
echo [run_test] log:       %LOGFILE%

exit /b %RC%