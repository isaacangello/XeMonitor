@echo off
cd /d "%~dp0"

echo ==========================================
echo   XeMonitor - Leitor Serial Honeywell 1900
echo ==========================================
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
echo  Iniciando XeMonitor...
echo  Logs: xemonitor.log
echo  Para sair: Ctrl+C
echo ==========================================
echo.
echo  Tentando libserialport primeiro...
echo  Se falhar, tente --winapi manualmente
echo.

.\zig-out\bin\xemonitor.exe %*

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
