#!/bin/bash
# Instala o bridge do XeMonitor como servico systemd no WSL (Arch).
# Uso: bash scripts/install_bridge_service.sh [--reinstall]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_BIN="$REPO_DIR/zig-out/bin/bridge"
TARGET_BIN="/usr/local/bin/xemonitor-bridge"
UNIT_NAME="xemonitor-bridge.service"

REINSTALL=0
if [ "${1:-}" = "--reinstall" ]; then
    REINSTALL=1
fi

if [ ! -f "$BRIDGE_BIN" ]; then
    echo "[install] ERRO: '$BRIDGE_BIN' nao encontrado. Compile com 'zig build bridge'."
    exit 1
fi

if [ ! -d /run/systemd/system ]; then
    echo "[install] ERRO: systemd nao esta rodando no WSL."
    exit 1
fi

echo "[install] Instalando binario em $TARGET_BIN"
install -m 0755 "$BRIDGE_BIN" "$TARGET_BIN"

echo "[install] Instalando unit systemd: $UNIT_NAME"
install -m 0644 "$REPO_DIR/systemd/$UNIT_NAME" "/etc/systemd/system/$UNIT_NAME"
systemctl daemon-reload

if [ "$REINSTALL" = "1" ]; then
    systemctl restart "$UNIT_NAME"
    echo "[install] Servico reiniciado."
else
    systemctl enable "$UNIT_NAME"
    systemctl start "$UNIT_NAME"
    echo "[install] Servico habilitado e iniciado."
fi

systemctl status "$UNIT_NAME" --no-pager || true
