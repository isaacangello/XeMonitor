#!/usr/bin/env bash
# XeMonitor - instalador Linux
#
# Uso:
#   curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash
#
# Instala o bridge (servidor serial->TCP) e o xemonitor (cliente teclado virtual)
# em /usr/local/bin, configura as regras udev (CH340 + uinput), adiciona o
# usuario aos grupos de acesso serial/uinput (uucp/dialout/input) e instala o
# servico do bridge:
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
INSTALL_VERSION="1.2.2"
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
em /usr/local/bin, configura as regras udev (CH340 + uinput), adiciona o usuario
aos grupos de acesso serial/uinput (uucp/dialout/input) e instala o servico do bridge:
  - systemd  (Arch/CachyOS/Debian...) -> xemonitor-bridge.service
  - OpenRC   (Alpine WSL...)          -> /etc/init.d/xemonitor-bridge

O desinstalador tambem e instalado: /usr/local/bin/xemonitor-uninstall
  (use 'xemonitor-uninstall --purge' para remover config + logs).

Opcoes:
  --prefix <dir>   prefixo de instalacao (padrao: /usr/local)
  --no-service     nao instala/inicia o servico (so binarios + udev)
  --version|-V     mostra a versao do instalador e sai
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
        --version|-V) printf 'XeMonitor installer %s\n' "$INSTALL_VERSION"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) shift ;;
    esac
done

BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/${VERSION}/download}"
[ "$VERSION" = "latest" ] && BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/latest/download}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- 0. cores do terminal ----------
COLORS_LIB_URL="https://raw.githubusercontent.com/isaacangello/bash_colors_lib/refs/heads/main/bash_colors_lib.sh"

# baixa e ativa a biblioteca de cores (opcional: sem rede => mensagens sem cor)
load_colors() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsSL --max-time 8 "$COLORS_LIB_URL" -o "$TMP/bash_colors_lib.sh" 2>/dev/null || return 1
    # shellcheck source=/dev/null
    source "$TMP/bash_colors_lib.sh"
}

if load_colors; then
    C_GREEN="$(printf '%b' "${green:-}")"
    C_YELLOW="$(printf '%b' "${yellow:-}")"
    C_RED="$(printf '%b' "${red:-}")"
    C_BLUE="$(printf '%b' "${blue:-}")"
    C_CIANO="$(printf '%b' "${ciano:-}")"
    C_NC="$(printf '%b' "${NC:-}")"
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_CIANO=""; C_NC=""
fi

log()  { printf "${C_GREEN}[install]${C_NC} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[aviso]${C_NC} %s\n" "$*"; }
die()  { printf "${C_RED}[erro]${C_NC} %s\n" "$*" >&2; exit 1; }

# avisa (sem abortar) se existir uma versao mais nova deste instalador no repo
check_update() {
    command -v curl >/dev/null 2>&1 || return 0
    local remote
    remote="$(curl -fsSL --max-time 8 "https://raw.githubusercontent.com/${REPO}/main/install.sh" 2>/dev/null || true)"
    [ -n "$remote" ] || return 0
    local remote_ver
    remote_ver="$(printf '%s\n' "$remote" | sed -n 's/^INSTALL_VERSION="\([^"]*\)".*/\1/p' | head -n1)"
    [ -n "$remote_ver" ] || return 0
    if [ "$remote_ver" != "$INSTALL_VERSION" ]; then
        warn "existe uma versao mais nova do instalador (${remote_ver}); a sua e ${INSTALL_VERSION}."
        warn "atualize com: curl -LsSf https://raw.githubusercontent.com/${REPO}/main/install.sh | bash"
    fi
    return 0
}

# roda um comando com privilegios (sudo quando nao for root); sem re-exec
sudo_run() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ---------- 1. requisitos ----------
[ "$(uname -m)" = "x86_64" ] || die "suporte apenas a arquitetura x86_64 por enquanto."

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    die "rode como root ou instale sudo."
fi

command -v curl >/dev/null 2>&1 || die "curl nao encontrado. Instale-o (pacman -S curl / apt install curl / apk add curl)."

check_update || true

# ---------- 2. detectar init ----------
INIT="none"
if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif [ -f /etc/openrc ] || command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
fi

# ---------- 3. baixar binarios ----------
log "baixando ${TARBALL} (v${VERSION})..."
curl -fsSL "${BASE_URL}/${TARBALL}" -o "${TMP}/${TARBALL}" || die "falha no download de ${BASE_URL}/${TARBALL}"
tar -xzf "${TMP}/${TARBALL}" -C "$TMP" || die "falha ao extrair o tarball (arquivo corrompido?)."

BIN_DIR="${PREFIX}/bin"
sudo_run mkdir -p "$BIN_DIR"
sudo_run install -m 0755 "$TMP/xemonitor"      "$BIN_DIR/xemonitor"
sudo_run install -m 0755 "$TMP/xemonitor-bridge" "$BIN_DIR/xemonitor-bridge"
GUI_INSTALLED=0
if [ -f "$TMP/xemonitor-gui" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor-gui" "$BIN_DIR/xemonitor-gui"
    GUI_INSTALLED=1
fi
log "binarios instalados em ${BIN_DIR}/ (xemonitor, xemonitor-bridge${GUI_INSTALLED:+, xemonitor-gui})"
GUI_SUMMARY=""
[ "$GUI_INSTALLED" = "1" ] && GUI_SUMMARY="  ${C_BLUE}GUI:${C_NC}     ${BIN_DIR}/xemonitor-gui (bandeja; inicia no login)"

# desinstalador vem no release; o instalador grava no sistema p/ uso local
if [ -f "$TMP/xemonitor-uninstall" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor-uninstall" "$BIN_DIR/xemonitor-uninstall"
    log "desinstalador instalado em ${BIN_DIR}/xemonitor-uninstall"
else
    warn "release antigo sem xemonitor-uninstall; baixe-o manualmente do repositorio."
fi

sudo_run mkdir -p "${PREFIX}/share/xemonitor"
printf '%s\n' "$VERSION" | sudo_run tee "${PREFIX}/share/xemonitor/VERSION" > /dev/null

# ---------- 4. regras udev (CH340 + uinput) ----------
UDEV_CH340='SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"'
UDEV_UINPUT='KERNEL=="uinput", GROUP="input", MODE="0660"'
if [ -d /etc/udev/rules.d ]; then
    printf '%s\n' "$UDEV_CH340" | sudo_run tee /etc/udev/rules.d/99-ch340.rules > /dev/null
    log "regra udev do CH340 instalada (99-ch340.rules)."
    printf '%s\n' "$UDEV_UINPUT" | sudo_run tee /etc/udev/rules.d/99-xemonitor-uinput.rules > /dev/null
    log "regra udev do uinput instalada (99-xemonitor-uinput.rules)."
    # garante o modulo uinput no boot (injetor nativo)
    printf '%s\n' 'uinput' | sudo_run tee /etc/modules-load.d/xemonitor-uinput.conf > /dev/null
    sudo_run modprobe uinput 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        sudo_run udevadm control --reload-rules || true
        sudo_run udevadm trigger || true
    fi
else
    warn "diretorio /etc/udev/rules.d nao encontrado; pule as regras udev."
fi

# ---------- 4b. icone do app (hicolor) ----------
# PNG 512x512 (release) ou SVG fallback (Tabler barcode) no hicolor/apps.
ICON_DIR="${PREFIX}/share/icons/hicolor/scalable/apps"
sudo_run mkdir -p "$ICON_DIR"
if [ -f "$TMP/xemonitor.png" ]; then
    # icone novo (cores vivas, fundo transparente) em hicolor 512x512
    sudo_run mkdir -p "${PREFIX}/share/icons/hicolor/512x512/apps"
    sudo_run install -m 0644 "$TMP/xemonitor.png" "${PREFIX}/share/icons/hicolor/512x512/apps/xemonitor.png"
    log "icone instalado em ${PREFIX}/share/icons/hicolor/512x512/apps/xemonitor.png"
else
    cat > "$TMP/xemonitor.svg" <<'SVGEOF'
<!-- XeMonitor app icon (Tabler barcode, MIT) -->
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M4 7v-1a2 2 0 0 1 2 -2h2" />
  <path d="M4 17v1a2 2 0 0 0 2 2h2" />
  <path d="M16 4h2a2 2 0 0 1 2 2v1" />
  <path d="M16 20h2a2 2 0 0 0 2 -2v-1" />
  <path d="M5 11h1v2h-1l0 -2" />
  <path d="M10 11l0 2" />
  <path d="M14 11h1v2h-1l0 -2" />
  <path d="M19 11l0 2" />
</svg>
SVGEOF
    sudo_run install -m 0644 "$TMP/xemonitor.svg" "${ICON_DIR}/xemonitor.svg"
    log "icone instalado em ${ICON_DIR}/xemonitor.svg"
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    sudo_run gtk-update-icon-cache -f "${PREFIX}/share/icons/hicolor" >/dev/null 2>&1 || true
fi

# ---------- 4c. desktop entry + autostart + pasta central de config ----------
if [ "$GUI_INSTALLED" = "1" ]; then
    # .desktop do app (menu/taskbar + icone da janela no Wayland)
    cat > "$TMP/xemonitor.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=XeMonitor
Comment=Scanner Honeywell 1900 como teclado virtual
Exec=${BIN_DIR}/xemonitor-gui
Icon=xemonitor
Terminal=false
Categories=Utility;
EOF
    sudo_run install -d "${PREFIX}/share/applications"
    sudo_run install -m 0644 "$TMP/xemonitor.desktop" "${PREFIX}/share/applications/xemonitor.desktop"
    log "desktop entry instalado (${PREFIX}/share/applications/xemonitor.desktop)."

    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
        USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        [ -n "$USER_HOME" ] || USER_HOME="$HOME"

        # autostart no login: GUI + cliente (o bridge ja e servico de sistema)
        AUTOSTART_DIR="$USER_HOME/.config/autostart"
        sudo_run mkdir -p "$AUTOSTART_DIR"
        sudo_run install -m 0644 "$TMP/xemonitor.desktop" "$AUTOSTART_DIR/xemonitor.desktop"
        sudo_run chown -R "$REAL_USER" "$USER_HOME/.config/autostart" 2>/dev/null || true
        log "autostart instalado ($AUTOSTART_DIR/xemonitor.desktop) — GUI inicia no login."

        # pasta central de config/log do usuario + config padrao (auto_start)
        CFG_DIR_USER="$USER_HOME/.config/xemonitor"
        sudo_run mkdir -p "$CFG_DIR_USER"
        if [ ! -f "$CFG_DIR_USER/xemonitor-gui.conf" ]; then
            cat > "$TMP/xemonitor-gui.conf" <<EOF
tcp_host=127.0.0.1
tcp_port=9000
server_mode=systemd-system
bridge_path=${BIN_DIR}/xemonitor-bridge
client_path=${BIN_DIR}/xemonitor
log_path=${CFG_DIR_USER}/xemonitor.log
auto_start=true
tray_enabled=true
EOF
            sudo_run install -m 0644 "$TMP/xemonitor-gui.conf" "$CFG_DIR_USER/xemonitor-gui.conf"
        fi
        sudo_run chown -R "$REAL_USER" "$CFG_DIR_USER" 2>/dev/null || true
        log "config central em ${CFG_DIR_USER}/ (xemonitor-gui.conf, log e pids)."
    fi

    # unit systemd de usuario (alternativa ao autostart; NAO habilitada por
    # padrao para nao iniciar o GUI duas vezes no login)
    if [ "$INIT" = "systemd" ]; then
        cat > "$TMP/xemonitor-gui.service" <<EOF
[Unit]
Description=XeMonitor GUI (bandeja)
After=graphical-session.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/xemonitor-gui --no-replace
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
        sudo_run install -d /etc/systemd/user
        sudo_run install -m 0644 "$TMP/xemonitor-gui.service" /etc/systemd/user/xemonitor-gui.service
        sudo_run systemctl daemon-reload >/dev/null 2>&1 || true
        log "unit systemd de usuario disponivel (/etc/systemd/user/xemonitor-gui.service)."
        log "para usar no lugar do autostart: systemctl --user enable xemonitor-gui.service"
    fi
fi

# ---------- 4d. dependencias de runtime do GUI (Debian/Ubuntu) ----------
# xemonitor-gui linka libdbus-1.so.3 e libsystemd.so.0; em instalacoes
# minimas libdbus-1-3 pode faltar. Best-effort: instala via apt quando possivel.
if [ "$GUI_INSTALLED" = "1" ] && command -v apt-get >/dev/null 2>&1; then
    log "instalando dependencias de runtime do GUI (libdbus-1-3 libsystemd0)..."
    sudo_run apt-get install -y --no-install-recommends libdbus-1-3 libsystemd0 >/dev/null 2>&1 ||
        warn "nao foi possivel instalar via apt (manual: apt-get install libdbus-1-3 libsystemd0)."
fi

# ---------- 5. grupos de acesso serial ----------
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
    # uucp/dialout: acesso serial; input: acesso ao /dev/uinput (injetor nativo)
    # cria o grupo 'input' se faltar (Debian/Ubuntu minimal sem udev nao o tem)
    sudo_run getent group input >/dev/null 2>&1 || sudo_run groupadd input 2>/dev/null || true
    sudo_run usermod -aG uucp,dialout,input "$REAL_USER" || true
    log "usuario '${REAL_USER}' adicionado aos grupos uucp, dialout e input."
    warn "efetivo apenas apos novo login (ou use 'sg uucp -c ...')."
fi

# ---------- 6. servico do bridge ----------
if [ "$SERVICE" = "1" ]; then
    if [ "$INIT" = "systemd" ]; then
        # Usa a unit versionada do release quando presente (fallback: gera inline)
        if [ -f "$TMP/systemd/xemonitor-bridge.service" ]; then
            SVC_UNIT="$TMP/systemd/xemonitor-bridge.service"
        else
            SVC_UNIT="$TMP/xemonitor-bridge.service"
            cat > "$SVC_UNIT" <<EOF
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
        fi
        sudo_run install -m 0644 "$SVC_UNIT" /etc/systemd/system/xemonitor-bridge.service
        sudo_run systemctl daemon-reload
        sudo_run systemctl enable xemonitor-bridge >/dev/null 2>&1 || true
        sudo_run systemctl restart xemonitor-bridge 2>/dev/null || sudo_run systemctl start xemonitor-bridge || true
        log "servico systemd 'xemonitor-bridge' instalado e iniciado."
    elif [ "$INIT" = "openrc" ]; then
        # Usa o init script versionado do release quando presente (fallback: inline)
        if [ -f "$TMP/openrc/xemonitor-bridge" ]; then
            INIT_SCRIPT="$TMP/openrc/xemonitor-bridge"
            # Substitui o caminho do binario pelo prefixo escolhido (padrao /usr/local)
            sed -i "s|command=\"/usr/local/bin/xemonitor-bridge\"|command=\"${BIN_DIR}/xemonitor-bridge\"|" "$INIT_SCRIPT"
        else
            INIT_SCRIPT="$TMP/xemonitor-bridge.init"
            cat > "$INIT_SCRIPT" <<EOF
#!/sbin/openrc-run
description="XeMonitor serial-to-TCP bridge (Honeywell 1900 / CH340)"
command="${BIN_DIR}/xemonitor-bridge"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
        fi
        sudo_run install -m 0755 "$INIT_SCRIPT" /etc/init.d/xemonitor-bridge
        sudo_run rc-update add xemonitor-bridge default 2>/dev/null || true
        sudo_run rc-service xemonitor-bridge start || true
        log "servico OpenRC 'xemonitor-bridge' instalado e iniciado."
    else
        warn "init nao identificado; servico nao instalado. Rode o bridge manualmente: ${BIN_DIR}/xemonitor-bridge"
    fi
fi

# ---------- 7. dependencia de injecao (cliente) ----------
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    command -v ydotool >/dev/null 2>&1 || warn "ydotool nao encontrado (fallback Wayland). Instale: pacman -S ydotool / apt install ydotool / apk add ydotool."
else
    command -v xdotool >/dev/null 2>&1 || warn "xdotool nao encontrado (fallback X11). Instale: pacman -S xdotool / apt install xdotool / apk add xdotool."
fi

# ---------- 8. resumo ----------
if [ "$SERVICE" = "1" ] && [ "$INIT" != "none" ]; then
    SERVICE_MSG="O servico do bridge ja esta ativo (${INIT}). Escaneie um codigo:"
else
    SERVICE_MSG="Servico nao instalado (init=${INIT}). Inicie o bridge manualmente:"
fi
cat <<EOF

${C_CIANO}============================================================${C_NC}
  ${C_CIANO}XeMonitor instalado!${C_NC}
  Versao: ${VERSION} (veja ${PREFIX}/share/xemonitor/VERSION)
  Instalador: ${INSTALL_VERSION}
  Init:   ${INIT}
${C_CIANO}------------------------------------------------------------${C_NC}
  ${C_BLUE}Bridge:${C_NC}  ${BIN_DIR}/xemonitor-bridge   (serial -> TCP :9000)
  ${C_BLUE}Cliente:${C_NC} ${BIN_DIR}/xemonitor
${GUI_SUMMARY}

  Config central (Linux): ~/.config/xemonitor/
    xemonitor-gui.conf | xemonitor-YYYY-MM-DD.log | pids
  Status/diagnostico:  ./status_xemonitor.sh
  Desinstalar:         ${BIN_DIR}/xemonitor-uninstall  (--purge remove config+logs)

  ${SERVICE_MSG}
    echo 'exemplo' | ${BIN_DIR}/xemonitor --stdin
  ou conecte via TCP (ex.: com o scanner no /dev/ttyUSB0):
    ${BIN_DIR}/xemonitor --tcp 127.0.0.1:9000

  Para reconfigurar o scanner: ver AGENTS.md / TODO.md
${C_CIANO}============================================================${C_NC}
EOF
