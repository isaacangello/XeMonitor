@echo off
cd /d "%~dp0"

echo ==========================================
echo   XeMonitor - Leitor Serial Honeywell 1900
echo ==========================================
echo.
echo Escolha o modo de execucao:
echo.
echo   [1] Com icone na bandeja (systray) - o terminal fica oculto
echo   [2] Apenas terminal - logs visiveis, sem icone na bandeja
echo.
choice /C 12 /M "Digite 1 ou 2"
if errorlevel 2 set NO_TRAY=--no-tray
if errorlevel 1 set NO_TRAY=

echo.
echo Compilando...
zig build
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERRO] Falha na compilacao.
    pause
    exit /b %ERRORLEVEL%
)

echo.
echo ==========================================
echo  Iniciando XeMonitor... %NO_TRAY%
echo  Logs: xemonitor-YYYY-MM-DD.log (na pasta de config)
echo  Para sair: Ctrl+C
echo ==========================================
echo.

.\zig-out\bin\xemonitor.exe %NO_TRAY% %*

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Tente com --winapi:
    echo .\zig-out\bin\xemonitor.exe --winapi
)

echo.
echo ==========================================
echo  XeMonitor encerrado.
echo ==========================================
pause
