#!/usr/bin/env bash
# XeMonitor — encerra GUI + cliente + bridge (espelho do stop_bridge.bat).
# Default: unit de USUÁRIO (sem sudo). Use --system p/ unit de sistema.
# Uso: ./stop_xemonitor.sh [--system]
set -euo pipefail

SYSTEM_MODE=0
[ "${1:-}" = "--system" ] && SYSTEM_MODE=1

echo "Encerrando XeMonitor..."
pkill -TERM -x xemonitor-gui 2>/dev/null || true
sleep 1
pkill -KILL -x xemonitor-gui 2>/dev/null || true
pkill -TERM -x xemonitor 2>/dev/null || true

if [ "$SYSTEM_MODE" = "1" ]; then
    # Unit de sistema (root). Requer sudo.
    sudo systemctl stop xemonitor-bridge 2>/dev/null || true
else
    # Unit de usuário (padrão, sem sudo). Também tenta a de sistema (best-effort).
    systemctl --user stop xemonitor-bridge 2>/dev/null || true
    if systemctl is-active --quiet xemonitor-bridge 2>/dev/null; then
        sudo systemctl stop xemonitor-bridge 2>/dev/null || true
    fi
fi

echo "XeMonitor encerrado."