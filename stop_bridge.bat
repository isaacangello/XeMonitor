@echo off
title XeMonitor Stop
taskkill /F /IM xemonitor.exe 2>nul
call scripts\bridge_ctl.bat stop 2>nul
echo Bridge e xemonitor encerrados.
