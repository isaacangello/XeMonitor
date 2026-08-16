#!/usr/bin/env bash
# XeMonitor - desinstalador Linux
#
# Instalado pelo install.sh como /usr/local/bin/xemonitor-uninstall (ou rode
# direto do repositorio: ./uninstall.sh).
#
# Uso:
#   xemonitor-uninstall            # remove binarios, servicos, regras udev,
#                                  # desktop/autostart e icone. MANTEM ~/.config/xemonitor.
#   xemonitor-uninstall --purge    # alem disso, remove ~/.config/xemonitor (config, logs e pids)
#   xemonitor-uninstall --help
#
# Variaveis uteis (para testes/avancado):
#   XEMONITOR_CONFIG_DIR      diretorio de config usado no --purge

set -euo pipefail

PREFIX="/usr/local"
PURGE=0
REAL_USER="${SUDO_USER:-${USER:-}}"
SELF="$(basename "$0")"

# quando instalado em <prefixo>/bin, descobre o prefixo automaticamente
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ "${SCRIPT_DIR%/bin}" != "$SCRIPT_DIR" ] && [ "$SELF" = "xemonitor-uninstall" ]; then
    PREFIX="${SCRIPT_DIR%/bin}"
fi

usage() {
    cat <<HELP
XeMonitor - desinstalador Linux

Uso:
  ${SELF}            remove binarios, servicos, regras udev, desktop/autostart
                            e icone. MANTEM ~/.config/xemonitor (config + logs).
  ${SELF} --purge    remove tambem ~/.config/xemonitor (config, logs e pids)
  ${SELF} --help

Variaveis uteis:
  XEMONITOR_CONFIG_DIR      diretorio de config usado no --purge
HELP
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:-/usr/local}"; shift 2 ;;
        --purge) PURGE=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) shift ;;
    esac
done

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    echo "[erro] rode como root ou instale sudo." >&2
    exit 1
fi

log()  { printf '[uninstall] %s\n' "$*"; }
warn() { printf '[aviso] %s\n' "$*"; }

# roda um comando com privilegios (sudo quando nao for root); sem re-exec
sudo_run() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# detectar init
INIT="none"
if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif [ -f /etc/openrc ] || command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
fi

BIN_DIR="${PREFIX}/bin"
USER_HOME="${USER_HOME:-$HOME}"
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
    USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    [ -n "$USER_HOME" ] || USER_HOME="$HOME"
fi

# ---------- 1. encerrar processos em execucao ----------
log "encerrando instancias de xemonitor/xemonitor-gui..."
pkill -TERM -x xemonitor-gui 2>/dev/null || true
pkill -TERM -x xemonitor 2>/dev/null || true
sleep 1
pkill -KILL -x xemonitor-gui 2>/dev/null || true
pkill -KILL -x xemonitor 2>/dev/null || true

# ---------- 2. servicos ----------
if [ "$INIT" = "systemd" ]; then
    if [ -f /etc/systemd/system/xemonitor-bridge.service ]; then
        log "parando e removendo o servico systemd 'xemonitor-bridge'..."
        sudo_run systemctl stop xemonitor-bridge 2>/dev/null || true
        sudo_run systemctl disable xemonitor-bridge 2>/dev/null || true
        sudo_run rm -f /etc/systemd/system/xemonitor-bridge.service
    fi
    if [ -f /etc/systemd/user/xemonitor-gui.service ]; then
        log "removendo a unit systemd de usuario 'xemonitor-gui'..."
        sudo_run systemctl --user disable xemonitor-gui 2>/dev/null || true
        sudo_run rm -f /etc/systemd/user/xemonitor-gui.service
    fi
    sudo_run systemctl daemon-reload >/dev/null 2>&1 || true
elif [ "$INIT" = "openrc" ]; then
    if [ -f /etc/init.d/xemonitor-bridge ]; then
        log "parando e removendo o servico OpenRC 'xemonitor-bridge'..."
        sudo_run rc-service xemonitor-bridge stop 2>/dev/null || true
        sudo_run rc-update del xemonitor-bridge default 2>/dev/null || true
        sudo_run rm -f /etc/init.d/xemonitor-bridge
    fi
fi

# ---------- 3. binarios e dados de aplicativo ----------
for b in xemonitor xemonitor-bridge xemonitor-gui xemonitor-uninstall; do
    [ -f "${BIN_DIR}/${b}" ] || continue
    log "removendo ${BIN_DIR}/${b}..."
    sudo_run rm -f "${BIN_DIR}/${b}"
done
if [ -d "${PREFIX}/share/xemonitor" ]; then
    log "removendo ${PREFIX}/share/xemonitor..."
    sudo_run rm -rf "${PREFIX}/share/xemonitor"
fi

# ---------- 4. regras udev / modulo uinput ----------
for rule in 99-ch340.rules 99-xemonitor-uinput.rules; do
    if [ -f "/etc/udev/rules.d/${rule}" ]; then
        log "removendo regra udev ${rule}..."
        sudo_run rm -f "/etc/udev/rules.d/${rule}"
    fi
done
if [ -f /etc/modules-load.d/xemonitor-uinput.conf ]; then
    log "removendo /etc/modules-load.d/xemonitor-uinput.conf..."
    sudo_run rm -f /etc/modules-load.d/xemonitor-uinput.conf
fi
if command -v udevadm >/dev/null 2>&1; then
    sudo_run udevadm control --reload-rules || true
    sudo_run udevadm trigger || true
fi

# ---------- 5. desktop entry / autostart / icone ----------
if [ -f "${PREFIX}/share/applications/xemonitor.desktop" ]; then
    log "removendo desktop entry..."
    sudo_run rm -f "${PREFIX}/share/applications/xemonitor.desktop"
fi
if [ -f "$USER_HOME/.config/autostart/xemonitor.desktop" ]; then
    log "removendo autostart do usuario..."
    sudo_run rm -f "$USER_HOME/.config/autostart/xemonitor.desktop"
fi
ICON_DST="${PREFIX}/share/icons/hicolor/scalable/apps/xemonitor.svg"
ICON_PNG_DST="${PREFIX}/share/icons/hicolor/512x512/apps/xemonitor.png"
ICON_REMOVED=0
if [ -f "$ICON_DST" ]; then
    log "removendo icone..."
    sudo_run rm -f "$ICON_DST"
    ICON_REMOVED=1
fi
if [ -f "$ICON_PNG_DST" ]; then
    log "removendo icone (png)..."
    sudo_run rm -f "$ICON_PNG_DST"
    ICON_REMOVED=1
fi
if [ "$ICON_REMOVED" = "1" ] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    sudo_run gtk-update-icon-cache -f "${PREFIX}/share/icons/hicolor" >/dev/null 2>&1 || true
fi

# ---------- 6. purge: remover config + logs ----------
if [ "$PURGE" = "1" ]; then
    CFG_DIR="${XEMONITOR_CONFIG_DIR:-$USER_HOME/.config/xemonitor}"
    [ "${XEMONITOR_CONFIG_DIR:-}" != "" ] && CFG_DIR="${XEMONITOR_CONFIG_DIR}/xemonitor"
    if [ -d "$CFG_DIR" ]; then
        log "--purge: removendo ${CFG_DIR}/ (config, logs e pids)..."
        sudo_run rm -rf "$CFG_DIR"
    else
        warn "--purge: ${CFG_DIR}/ nao existe."
    fi
else
    log "config/log mantidos em ${XEMONITOR_CONFIG_DIR:-$USER_HOME/.config/xemonitor} (use --purge para remover)."
fi

# ---------- 7. resumo ----------
cat <<EOF

============================================================
  XeMonitor desinstalado (prefixo: ${PREFIX}, init: ${INIT})
  - Binarios, servicos, udev, desktop/autostart e icone removidos.
  - Os grupos uucp/dialout/input nao foram alterados.
EOF
if [ "$PURGE" = "1" ]; then
    cat <<EOF
  - Config, logs e pids removidos (--purge).
EOF
else
    cat <<EOF
  - Config e logs preservados em: ${XEMONITOR_CONFIG_DIR:-$USER_HOME/.config/xemonitor}
    (para remover junto: ${SELF} --purge)
EOF
fi
echo "============================================================"
