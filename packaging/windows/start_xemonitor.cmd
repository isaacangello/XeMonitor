@echo off
:: start_xemonitor.cmd - wrapper da tarefa agendada XeMonitor-App.
:: Roda o GUI principal (xemonitor-gui.exe), que le a config em
:: %APPDATA%\xemonitor\xemonitor-gui.conf (server_mode=wsl, auto_start=true)
:: e inicia bridge + cliente automaticamente.
:: Redireciona stdout/stderr para arquivo (evita corromper bytes na sessao).
setlocal
set "APP_DIR=%~dp0..\.."
set "LOG=%APPDATA%\xemonitor\logs\app-task.log"
if not exist "%APPDATA%\xemonitor\logs" mkdir "%APPDATA%\xemonitor\logs"
"%APP_DIR%\xemonitor-gui.exe" >> "%LOG%" 2>&1
exit /b %errorlevel%
