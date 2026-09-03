@echo off
:: ============================================================
:: build_installer.bat - Compila o instalador Windows (Inno Setup)
:: com a versao lida do arquivo VERSION na raiz do repo (fonte unica).
::
;; Uso (a partir da raiz do repo):
;;   packaging\windows\build_installer.bat
;;
;; Requer ISCC.exe no PATH ou em:
;;   C:\Program Files\Inno Setup 6\ISCC.exe
;;   C:\Program Files (x86)\Inno Setup 6\ISCC.exe
;; Pre-requisitos: zig build (Windows) e zig build gui (Windows) ja rodados,
;; e o miniroot copiado como alpine-bridge-current.tar.gz.
:: ============================================================
setlocal

set "ROOT=%~dp0..\.."
for /d %%D in ("%ROOT%") do set "ROOT=%%~fD"

if not exist "%ROOT%\VERSION" (
    echo [ERRO] VERSION nao encontrado em %ROOT%
    exit /b 1
)

set "VER="
for /f "usebackq delims=" %%v in ("%ROOT%\VERSION") do set "VER=%%v"

if "%VER%"=="" (
    echo [ERRO] VERSION vazio
    exit /b 1
)

set "ISCC=ISCC.exe"
where ISCC.exe >nul 2>&1 || set "ISCC="
if not defined ISCC (
    if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
)
if "%ISCC%"=="" if exist "C:\Program Files\Inno Setup 6\ISCC.exe" set "ISCC=C:\Program Files\Inno Setup 6\ISCC.exe"
if "%ISCC%"=="" (
    echo [ERRO] ISCC.exe nao encontrado
    exit /b 1
)

echo [build] versao = %VER%
echo [build] iscc   = %ISCC%
"%ISCC%" "/DMyAppVersion=%VER%" "%ROOT%\packaging\windows\xemonitor.iss"
exit /b %errorlevel%
