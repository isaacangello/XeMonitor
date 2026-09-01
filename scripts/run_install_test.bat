@echo off
:: ============================================================
:: run_install_test.bat - Wrapper de teste E2E do instalador.
:: Monta o staging dir, faz cd para a raiz dele (= WorkingDir
:: que o Inno usa em producao) e chama install_windows.bat /silent
:: elevado, redirecionando stdout/stderr para um arquivo de log.
::
:: Uso (a partir da raiz do repo):
::   scripts\run_install_test.bat
::
:: Log gerado em:
::   %APPDATA%\xemonitor\logs\install-test-<YYYYMMDD-HHMMSS>.txt
:: ============================================================
setlocal enabledelayedexpansion

set "ROOT=%~dp0.."
pushd "%ROOT%"

echo [run_test] Root: %ROOT%

:: 1) Montar staging
echo [run_test] montando staging...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\make_install_staging.ps1" -Root "%ROOT%"
if errorlevel 1 (
    echo [run_test] ERRO: make_install_staging.ps1 falhou.
    popd
    exit /b 1
)

set "STAGING=%ROOT%\zig-out\staging\XeMonitor"
if not exist "%STAGING%\packaging\windows\install_windows.bat" (
    echo [run_test] ERRO: staging nao foi criado em %STAGING%
    popd
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
> "%WRAPPER%" echo @echo off
>>"%WRAPPER%" echo cd /d "%STAGING%"
>>"%WRAPPER%" echo set XM_SKIP_ELEVATE=1
>>"%WRAPPER%" echo call "%STAGING%\packaging\windows\install_windows.bat" /silent
>>"%WRAPPER%" echo echo EXIT=%%errorlevel%%

:: 4) Subir o wrapper com RunAs (admin). Para execucao interativa, o
:: UAC aparece. Em headless (CI), seria necessario outro mecanismo.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$p = Start-Process -FilePath '%WRAPPER%' -Verb RunAs -PassThru -Wait; exit $p.ExitCode" ^
    > "%LOGFILE%" 2>&1
set "RC=%errorlevel%"

:: Limpa wrapper
del "%WRAPPER%" 2>nul

echo [run_test] exit code: %RC%
echo [run_test] log:       %LOGFILE%

popd
exit /b %RC%
