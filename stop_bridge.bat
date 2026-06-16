@echo off
taskkill /F /IM xemonitor.exe 2>nul
wsl pkill -f "^bridge$" 2>nul
echo Bridge e xemonitor encerrados.
