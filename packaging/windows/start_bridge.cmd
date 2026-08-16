@echo off
:: start_bridge.cmd - wrapper da tarefa agendada XeMonitor-Bridge.
:: Habilita e inicia o servico do bridge no WSL (detecta Alpine/OpenRC ou
:: Arch/systemd). Redireciona stdout/stderr para arquivo (evita corromper
:: bytes na sessao da tarefa).
setlocal
set "APP_DIR=%~dp0..\.."
set "LOG=%APPDATA%\xemonitor\bridge-task.log"
if not exist "%APPDATA%\xemonitor" mkdir "%APPDATA%\xemonitor"
call "%APP_DIR%\scripts\bridge_ctl.bat" enable >> "%LOG%" 2>&1
call "%APP_DIR%\scripts\bridge_ctl.bat" start >> "%LOG%" 2>&1
exit /b %errorlevel%
