#!/usr/bin/env bash
# XeMonitor — encerra GUI + cliente + bridge (espelho do stop_bridge.bat).
# Uso: ./stop_xemonitor.sh
echo "Encerrando XeMonitor..."
pkill -TERM -x xemonitor-gui 2>/dev/null || true
sleep 1
pkill -KILL -x xemonitor-gui 2>/dev/null || true
pkill -TERM -x xemonitor 2>/dev/null || true
if command -v pkexec >/dev/null 2>&1; then
    pkexec systemctl stop xemonitor-bridge 2>/dev/null || true
else
    sudo systemctl stop xemonitor-bridge 2>/dev/null || true
fi
echo "XeMonitor encerrado."
