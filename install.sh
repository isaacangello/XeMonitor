#!/usr/bin/env bash
# XeMonitor - instalador Linux
#
# Uso:
#   curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash
#
# Instala o bridge (servidor serial->TCP) e o xemonitor (cliente teclado virtual)
# em /usr/local/bin, configura a regra udev do CH340, adiciona o usuario aos
# grupos de acesso serial (uucp/dialout) e instala o servico do bridge:
#   - systemd  (Arch/CachyOS/Debian...) -> xemonitor-bridge.service
#   - OpenRC   (Alpine WSL...)          -> /etc/init.d/xemonitor-bridge
#
# Opcoes:
#   --prefix <dir>   prefixo de instalacao (padrao: /usr/local)
#   --no-service     nao instala/inicia o servico (so binarios + udev)
#   --help           mostra esta ajuda
#
# Variaveis uteis (para testes/avancado):
#   XEMONITOR_VERSION    tag do release (padrao: latest)
#   XEMONITOR_BASE_URL   URL base de download (padrao: github releases)

set -euo pipefail

REPO="isaacangello/XeMonitor"
TARBALL="xemonitor-linux-x86_64.tar.gz"
VERSION="${XEMONITOR_VERSION:-latest}"
PREFIX="/usr/local"
SERVICE=1
REAL_USER="${SUDO_USER:-${USER:-}}"

usage() {
    cat <<'HELP'
XeMonitor - instalador Linux

Uso:
  curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash

Instala o bridge (servidor serial->TCP) e o xemonitor (cliente teclado virtual)
em /usr/local/bin, configura a regra udev do CH340, adiciona o usuario aos
grupos de acesso serial (uucp/dialout) e instala o servico do bridge:
  - systemd  (Arch/CachyOS/Debian...) -> xemonitor-bridge.service
  - OpenRC   (Alpine WSL...)          -> /etc/init.d/xemonitor-bridge

Opcoes:
  --prefix <dir>   prefixo de instalacao (padrao: /usr/local)
  --no-service     nao instala/inicia o servico (so binarios + udev)
  --help           mostra esta ajuda

Variaveis uteis (para testes/avancado):
  XEMONITOR_VERSION    tag do release (padrao: latest)
  XEMONITOR_BASE_URL   URL base de download (padrao: github releases)
HELP
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:-/usr/local}"; shift 2 ;;
        --no-service) SERVICE=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) shift ;;
    esac
done

BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/${VERSION}/download}"
[ "$VERSION" = "latest" ] && BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/latest/download}"

log()  { printf '\033[1;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[aviso]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[erro]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. requisitos ----------
[ "$(uname -m)" = "x86_64" ] || die "suporte apenas a arquitetura x86_64 por enquanto."

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        log "elevando para root (necessario para udev + grupos + servico)..."
        exec sudo -E bash "$0" "$@"
    else
        die "rode como root ou instale sudo."
    fi
fi

command -v curl >/dev/null 2>&1 || die "curl nao encontrado. Instale-o (pacman -S curl / apt install curl / apk add curl)."

# ---------- 2. detectar init ----------
INIT="none"
if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif [ -f /etc/openrc ] || command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
fi

# ---------- 3. baixar binarios ----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "baixando ${TARBALL} (v${VERSION})..."
curl -fsSL "${BASE_URL}/${TARBALL}" -o "${TMP}/${TARBALL}" || die "falha no download de ${BASE_URL}/${TARBALL}"
tar -xzf "${TMP}/${TARBALL}" -C "$TMP" || die "falha ao extrair o tarball (arquivo corrompido?)."

BIN_DIR="${PREFIX}/bin"
mkdir -p "$BIN_DIR"
install -m 0755 "$TMP/xemonitor"      "$BIN_DIR/xemonitor"
install -m 0755 "$TMP/xemonitor-bridge" "$BIN_DIR/xemonitor-bridge"
log "binarios instalados em ${BIN_DIR}/ (xemonitor, xemonitor-bridge)"

mkdir -p "${PREFIX}/share/xemonitor"
printf '%s\n' "$VERSION" > "${PREFIX}/share/xemonitor/VERSION"

# ---------- 4. regra udev CH340 ----------
UDEV_RULE='SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"'
if [ -d /etc/udev/rules.d ]; then
    printf '%s\n' "$UDEV_RULE" > /etc/udev/rules.d/99-ch340.rules
    log "regra udev do CH340 instalada (99-ch340.rules)."
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules || true
        udevadm trigger || true
    fi
else
    warn "diretorio /etc/udev/rules.d nao encontrado; pule a regra udev."
fi

# ---------- 5. grupos de acesso serial ----------
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
    usermod -aG uucp,dialout "$REAL_USER" || true
    log "usuario '${REAL_USER}' adicionado aos grupos uucp e dialout."
    warn "efetivo apenas apos novo login (ou use 'sg uucp -c ...')."
fi

# ---------- 6. servico do bridge ----------
if [ "$SERVICE" = "1" ]; then
    if [ "$INIT" = "systemd" ]; then
        cat > /etc/systemd/system/xemonitor-bridge.service <<EOF
[Unit]
Description=XeMonitor serial-to-TCP bridge (Honeywell 1900 / CH340)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/bin/bash -c 'for i in \$(seq 1 60); do [ -c /dev/ttyUSB0 ] && exit 0; sleep 1; done; exit 1'
ExecStart=${BIN_DIR}/xemonitor-bridge
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xemonitor-bridge >/dev/null 2>&1 || true
        systemctl restart xemonitor-bridge 2>/dev/null || systemctl start xemonitor-bridge || true
        log "servico systemd 'xemonitor-bridge' instalado e iniciado."
    elif [ "$INIT" = "openrc" ]; then
        cat > /etc/init.d/xemonitor-bridge <<EOF
#!/sbin/openrc-run
description="XeMonitor serial-to-TCP bridge (Honeywell 1900 / CH340)"
command="${BIN_DIR}/xemonitor-bridge"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
        chmod 0755 /etc/init.d/xemonitor-bridge
        rc-update add xemonitor-bridge default 2>/dev/null || true
        rc-service xemonitor-bridge start || true
        log "servico OpenRC 'xemonitor-bridge' instalado e iniciado."
    else
        warn "init nao identificado; servico nao instalado. Rode o bridge manualmente: ${BIN_DIR}/xemonitor-bridge"
    fi
fi

# ---------- 7. dependencia de injecao (cliente) ----------
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    command -v ydotool >/dev/null 2>&1 || warn "ydotool nao encontrado (injeção Wayland). Instale: pacman -S ydotool / apk add ydotool."
else
    command -v xdotool >/dev/null 2>&1 || warn "xdotool nao encontrado (injeção X11). Instale: pacman -S xdotool / apt install xdotool / apk add xdotool."
fi

# ---------- 8. resumo ----------
cat <<EOF

============================================================
  XeMonitor instalado!
  Versao: ${VERSION} (veja ${PREFIX}/share/xemonitor/VERSION)
  Init:   ${INIT}
------------------------------------------------------------
  Bridge:  ${BIN_DIR}/xemonitor-bridge   (serial -> TCP :9000)
  Cliente: ${BIN_DIR}/xemonitor

  O servico do bridge ja esta ativo. Escaneie um codigo:
    echo 'exemplo' | ${BIN_DIR}/xemonitor --stdin
  ou conecte via TCP (ex.: com o scanner no /dev/ttyUSB0):
    ${BIN_DIR}/xemonitor --tcp 127.0.0.1:9000

  Para reconfigurar o scanner: ver AGENTS.md / TODO.md
============================================================
EOF
