#!/bin/bash
# Instala o bridge do XeMonitor como servico no WSL (systemd ou OpenRC).
# Uso: bash scripts/install_bridge_service.sh [--reinstall]
# Detecta o init do distro: Arch/CachyOS -> systemd, Alpine -> OpenRC.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_BIN="$REPO_DIR/zig-out/bin/bridge"
TARGET_BIN="/usr/local/bin/xemonitor-bridge"

REINSTALL=0
if [ "${1:-}" = "--reinstall" ]; then
    REINSTALL=1
fi

if [ ! -f "$BRIDGE_BIN" ]; then
    echo "[install] ERRO: '$BRIDGE_BIN' nao encontrado. Compile com 'zig build bridge'."
    exit 1
fi

# ---- Detecta init (systemd | openrc) ----
INIT="none"
if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif [ -f /etc/openrc ] || [ -d /etc/init.d ] && command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
fi

if [ "$INIT" = "none" ]; then
    echo "[install] ERRO: init nao identificado (systemd nem OpenRC) no WSL."
    exit 1
fi

echo "[install] Init detectado: $INIT"
echo "[install] Instalando binario em $TARGET_BIN"
install -m 0755 "$BRIDGE_BIN" "$TARGET_BIN"

if [ "$INIT" = "systemd" ]; then
    UNIT_NAME="xemonitor-bridge.service"
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
else
    INIT_NAME="xemonitor-bridge"
    echo "[install] Instalando init OpenRC: /etc/init.d/$INIT_NAME"
    install -m 0755 "$REPO_DIR/openrc/$INIT_NAME" "/etc/init.d/$INIT_NAME"

    # No WSL/container o OpenRC nao e o init real; softlevel libera o rc-service.
    mkdir -p /run/openrc
    touch /run/openrc/softlevel

    if [ "$REINSTALL" = "1" ]; then
        rc-service "$INIT_NAME" restart || true
        echo "[install] Servico reiniciado."
    else
        rc-update add "$INIT_NAME" default 2>/dev/null || true
        rc-service "$INIT_NAME" start || true
        echo "[install] Servico habilitado e iniciado."
    fi
    rc-service "$INIT_NAME" status || true
fi
