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
#   --prefix <dir>       prefixo de instalacao (padrao: /usr/local)
#   --no-service         nao instala/inicia o servico (so binarios + udev)
#   --check-only         valida requisitos sem instalar (exit 0 se OK, 1 se faltar)
#   --dry-run            simula instalacao mostrando passos sem executar sudo
#   --validate           roda validacao pos-install (padrao: ON)
#   --no-validate        desliga validacao pos-install
#   --quiet              output minimo (so erros/avisos)
#   --verbose            output debug (comandos executados)
#   --version|-V         mostra a versao do instalador e sai
#   --help               mostra esta ajuda
#
# Variaveis uteis (para testes/avancado):
#   XEMONITOR_VERSION       tag do release (padrao: latest)
#   XEMONITOR_BASE_URL      URL base de download (padrao: github releases)
#   XEMONITOR_CURL_TIMEOUT  timeout do curl em segundos (padrao: 30)
#   XEMONITOR_CURL_RETRY    numero de tentativas do curl (padrao: 3)
#   XEMONITOR_CURL_RETRY_DELAY  delay entre tentativas em segundos (padrao: 2)

set -euo pipefail

REPO="isaacangello/XeMonitor"
INSTALL_VERSION="1.3.0"
TARBALL="xemonitor-linux-x86_64.tar.gz"
VERSION="${XEMONITOR_VERSION:-latest}"
PREFIX="/usr/local"
SERVICE=1
CHECK_ONLY=0
DRY_RUN=0
VALIDATE=1
QUIET=0
VERBOSE=0
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
  --prefix <dir>       prefixo de instalacao (padrao: /usr/local)
  --no-service         nao instala/inicia o servico (so binarios + udev)
  --check-only         valida requisitos sem instalar (exit 0 se OK, 1 se faltar)
  --dry-run            simula instalacao mostrando passos sem executar sudo
  --validate           roda validacao pos-install (padrao: ON)
  --no-validate        desliga validacao pos-install
  --quiet              output minimo (so erros/avisos)
  --verbose            output debug (comandos executados)
  --version|-V         mostra a versao do instalador e sai
  --help               mostra esta ajuda

Variaveis uteis (para testes/avancado):
  XEMONITOR_VERSION            tag do release (padrao: latest)
  XEMONITOR_BASE_URL           URL base de download (padrao: github releases)
  XEMONITOR_CURL_TIMEOUT       timeout do curl em segundos (padrao: 30)
  XEMONITOR_CURL_RETRY         numero de tentativas do curl (padrao: 3)
  XEMONITOR_CURL_RETRY_DELAY   delay entre tentativas em segundos (padrao: 2)
HELP
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:-/usr/local}"; shift 2 ;;
        --no-service) SERVICE=0; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --validate) VALIDATE=1; shift ;;
        --no-validate) VALIDATE=0; shift ;;
        --quiet) QUIET=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --version|-V) printf 'XeMonitor installer %s\n' "$INSTALL_VERSION"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) shift ;;
    esac
done

# ---------- Cores embutidas (ANSI) ----------
if [ -t 1 ] && [ "$QUIET" -eq 0 ]; then
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[31m"
    C_BLUE="\033[34m"
    C_CIANO="\033[36m"
    C_NC="\033[0m"
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_CIANO=""; C_NC=""
fi

log()  { [ "$QUIET" -eq 0 ] && printf "${C_GREEN}[install]${C_NC} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[aviso]${C_NC} %s\n" "$*"; }
die()  { printf "${C_RED}[erro]${C_NC} %s\n" "$*" >&2; exit 1; }
debug() { [ "$VERBOSE" -eq 1 ] && printf "${C_BLUE}[debug]${C_NC} %s\n" "$*"; }

# ---------- curl com retry/timeout configuravel ----------
CURL_TIMEOUT="${XEMONITOR_CURL_TIMEOUT:-30}"
CURL_RETRY="${XEMONITOR_CURL_RETRY:-3}"
CURL_RETRY_DELAY="${XEMONITOR_CURL_RETRY_DELAY:-2}"

curl_fetch() {
    local url="$1" output="$2"
    debug "curl_fetch: $url -> $output (timeout=${CURL_TIMEOUT}s retry=${CURL_RETRY} delay=${CURL_RETRY_DELAY}s)"
    curl -fsSL --max-time "$CURL_TIMEOUT" --retry "$CURL_RETRY" --retry-delay "$CURL_RETRY_DELAY" "$url" -o "$output"
}

# ---------- sudo wrapper ----------
sudo_run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] sudo $*"
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ---------- check_update (opcional, nao bloqueante) ----------
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

# ---------- Validacao de requisitos ----------
check_requirements() {
    local missing=0

    [ "$(uname -m)" = "x86_64" ] || { warn "arquitetura $(uname -m) nao suportada (apenas x86_64)"; missing=1; }

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        warn "sudo nao encontrado e nao e root"; missing=1
    fi

    command -v curl >/dev/null 2>&1 || { warn "curl nao encontrado"; missing=1; }
    command -v tar >/dev/null 2>&1 || { warn "tar nao encontrado"; missing=1; }
    command -v sha256sum >/dev/null 2>&1 || { warn "sha256sum nao encontrado"; missing=1; }

    if [ "$missing" -eq 1 ]; then
        return 1
    fi
    return 0
}

# ---------- 1. Requisitos basicos ----------
log "verificando requisitos..."
check_requirements || die "requisitos basicos nao atendidos."
check_update || true

# ---------- 2. Detectar init ----------
INIT="none"
if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif [ -f /etc/openrc ] || command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
fi
log "init detectado: ${INIT}"

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "check-only: OK (requisitos atendidos, init=${INIT})"
    exit 0
fi

# ---------- 3. Baixar binarios + SHA256 ----------
BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/${VERSION}/download}"
[ "$VERSION" = "latest" ] && BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/latest/download}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "baixando ${TARBALL} (v${VERSION})..."
curl_fetch "${BASE_URL}/${TARBALL}" "${TMP}/${TARBALL}" || die "falha no download de ${BASE_URL}/${TARBALL}"

log "baixando ${TARBALL}.sha256..."
if curl_fetch "${BASE_URL}/${TARBALL}.sha256" "${TMP}/${TARBALL}.sha256" 2>/dev/null; then
    log "verificando SHA256..."
    (cd "$TMP" && sha256sum -c "${TARBALL}.sha256") || die "SHA256 nao confere! Arquivo corrompido ou adulterado."
    log "SHA256 OK."
else
    warn "arquivo .sha256 nao encontrado no release; pulando verificacao de integridade."
fi

log "extraindo..."
tar -xzf "${TMP}/${TARBALL}" -C "$TMP" || die "falha ao extrair o tarball (arquivo corrompido?)."

# ---------- 4. Instalar binarios ----------
BIN_DIR="${PREFIX}/bin"
log "instalando binarios em ${BIN_DIR}/..."
sudo_run mkdir -p "$BIN_DIR"
sudo_run install -m 0755 "$TMP/xemonitor"      "$BIN_DIR/xemonitor"
sudo_run install -m 0755 "$TMP/xemonitor-bridge" "$BIN_DIR/xemonitor-bridge"
GUI_INSTALLED=0
if [ -f "$TMP/xemonitor-gui" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor-gui" "$BIN_DIR/xemonitor-gui"
    GUI_INSTALLED=1
fi
log "binarios instalados: xemonitor, xemonitor-bridge${GUI_INSTALLED:+, xemonitor-gui}"

# Desinstalador
if [ -f "$TMP/xemonitor-uninstall" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor-uninstall" "$BIN_DIR/xemonitor-uninstall"
    log "desinstalador instalado em ${BIN_DIR}/xemonitor-uninstall"
else
    warn "release antigo sem xemonitor-uninstall; baixe-o manualmente do repositorio."
fi

sudo_run mkdir -p "${PREFIX}/share/xemonitor"
printf '%s\n' "$VERSION" | sudo_run tee "${PREFIX}/share/xemonitor/VERSION" > /dev/null

# ---------- 5. Regras udev ----------
UDEV_CH340='SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"'
UDEV_UINPUT='KERNEL=="uinput", GROUP="input", MODE="0660"'
if [ -d /etc/udev/rules.d ]; then
    log "instalando regras udev..."
    printf '%s\n' "$UDEV_CH340" | sudo_run tee /etc/udev/rules.d/99-ch340.rules > /dev/null
    log "regra udev do CH340 instalada (99-ch340.rules)."
    printf '%s\n' "$UDEV_UINPUT" | sudo_run tee /etc/udev/rules.d/99-xemonitor-uinput.rules > /dev/null
    log "regra udev do uinput instalada (99-xemonitor-uinput.rules)."
    printf '%s\n' 'uinput' | sudo_run tee /etc/modules-load.d/xemonitor-uinput.conf > /dev/null
    sudo_run modprobe uinput 2>/dev/null || true
    if command -v udevadm >/dev/null 2>&1; then
        sudo_run udevadm control --reload-rules || true
        sudo_run udevadm trigger || true
    fi
else
    warn "diretorio /etc/udev/rules.d nao encontrado; pulando regras udev."
fi

# ---------- 6. Icone hicolor ----------
ICON_DIR="${PREFIX}/share/icons/hicolor/scalable/apps"
sudo_run mkdir -p "$ICON_DIR"
if [ -f "$TMP/xemonitor.png" ]; then
    sudo_run mkdir -p "${PREFIX}/share/icons/hicolor/512x512/apps"
    sudo_run install -m 0644 "$TMP/xemonitor.png" "${PREFIX}/share/icons/hicolor/512x512/apps/xemonitor.png"
    log "icone PNG instalado (512x512)."
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
    log "icone SVG instalado (fallback Tabler)."
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    sudo_run gtk-update-icon-cache -f "${PREFIX}/share/icons/hicolor" >/dev/null 2>&1 || true
fi

# ---------- 7. Desktop entry + autostart + config central ----------
if [ "$GUI_INSTALLED" = "1" ]; then
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
    log "desktop entry instalado."

    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
        USER_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        [ -n "$USER_HOME" ] || USER_HOME="$HOME"

        # Autostart
        AUTOSTART_DIR="$USER_HOME/.config/autostart"
        sudo_run mkdir -p "$AUTOSTART_DIR"
        sudo_run install -m 0644 "$TMP/xemonitor.desktop" "$AUTOSTART_DIR/xemonitor.desktop"
        sudo_run chown -R "$REAL_USER" "$USER_HOME/.config/autostart" 2>/dev/null || true
        log "autostart instalado ($AUTOSTART_DIR/xemonitor.desktop)."

        # Config central
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
        log "config central em ${CFG_DIR_USER}/."
    fi

    # systemd user unit (opcional, nao habilitada por padrao)
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

# ---------- 8. Dependencias runtime GUI (Debian/Ubuntu) ----------
if [ "$GUI_INSTALLED" = "1" ] && command -v apt-get >/dev/null 2>&1; then
    log "instalando dependencias de runtime do GUI (libdbus-1-3 libsystemd0)..."
    sudo_run apt-get update >/dev/null 2>&1 || true
    sudo_run apt-get install -y --no-install-recommends libdbus-1-3 libsystemd0 >/dev/null 2>&1 ||
        warn "nao foi possivel instalar via apt (manual: apt-get install libdbus-1-3 libsystemd0)."
fi

# ---------- 9. Grupos de acesso serial ----------
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
    sudo_run getent group input >/dev/null 2>&1 || sudo_run groupadd input 2>/dev/null || true
    sudo_run usermod -aG uucp,dialout,input "$REAL_USER" || true
    log "usuario '${REAL_USER}' adicionado aos grupos uucp, dialout e input."
    warn "efetivo apenas apos novo login (ou use 'sg uucp -c ...')."
fi

# ---------- 10. Servico do bridge ----------
if [ "$SERVICE" = "1" ]; then
    if [ "$INIT" = "systemd" ]; then
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
        log "instalando servico systemd..."
        sudo_run install -m 0644 "$SVC_UNIT" /etc/systemd/system/xemonitor-bridge.service
        sudo_run systemctl daemon-reload
        sudo_run systemctl enable xemonitor-bridge >/dev/null 2>&1 || true
        sudo_run systemctl restart xemonitor-bridge 2>/dev/null || sudo_run systemctl start xemonitor-bridge || true
        log "servico systemd 'xemonitor-bridge' instalado e iniciado."
    elif [ "$INIT" = "openrc" ]; then
        if [ -f "$TMP/openrc/xemonitor-bridge" ]; then
            INIT_SCRIPT="$TMP/openrc/xemonitor-bridge"
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
        log "instalando servico OpenRC..."
        sudo_run install -m 0755 "$INIT_SCRIPT" /etc/init.d/xemonitor-bridge
        sudo_run rc-update add xemonitor-bridge default 2>/dev/null || true
        sudo_run rc-service xemonitor-bridge start || true
        log "servico OpenRC 'xemonitor-bridge' instalado e iniciado."
    else
        warn "init nao identificado; servico nao instalado. Rode o bridge manualmente: ${BIN_DIR}/xemonitor-bridge"
    fi
fi

# ---------- 11. Validacao pos-install ----------
if [ "$VALIDATE" -eq 1 ] && [ "$SERVICE" -eq 1 ] && [ "$INIT" != "none" ]; then
    log "validando instalacao..."
    VALIDATION_FAILED=0

    # 11a. Servico ativo
    if [ "$INIT" = "systemd" ]; then
        if ! systemctl is-active --quiet xemonitor-bridge; then
            warn "servico systemd 'xemonitor-bridge' nao esta ativo."
            VALIDATION_FAILED=1
        else
            log "servico systemd ativo."
        fi
    elif [ "$INIT" = "openrc" ]; then
        if ! rc-service xemonitor-bridge status 2>/dev/null | grep -q "started"; then
            warn "servico OpenRC 'xemonitor-bridge' nao esta rodando."
            VALIDATION_FAILED=1
        else
            log "servico OpenRC ativo."
        fi
    fi

    # 11b. Porta 9000 escutando
    if command -v ss >/dev/null 2>&1; then
        if ! ss -tln 2>/dev/null | grep -q ':9000'; then
            warn "porta 9000 nao esta escutando (bridge pode nao ter subido completamente)."
            VALIDATION_FAILED=1
        else
            log "porta 9000 OK."
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if ! netstat -tln 2>/dev/null | grep -q ':9000'; then
            warn "porta 9000 nao esta escutando."
            VALIDATION_FAILED=1
        else
            log "porta 9000 OK."
        fi
    else
        warn "ss/netstat nao disponiveis; pulando check de porta."
    fi

    # 11c. Teste de injeção fake (stdin)
    if command -v timeout >/dev/null 2>&1; then
        log "testando injeção via stdin (fake scan)..."
        CFG_DIR_USER="${XEMONITOR_CONFIG_DIR:-$USER_HOME/.config/xemonitor}"
        LOG_FILE="${CFG_DIR_USER}/xemonitor-$(date +%Y-%m-%d).log"
        [ -f "$LOG_FILE" ] || LOG_FILE="${CFG_DIR_USER}/xemonitor.log"

        # Roda xemonitor --stdin em background, manda fake scan, espera log
        echo "VALIDATE123" | timeout 5 "${BIN_DIR}/xemonitor" --stdin >/dev/null 2>&1 || true
        sleep 1
        if [ -f "$LOG_FILE" ] && grep -q "injected 'VALIDATE123'" "$LOG_FILE" 2>/dev/null; then
            log "teste de injeção OK."
        else
            warn "teste de injeção falhou (verifique log: $LOG_FILE)."
            VALIDATION_FAILED=1
        fi
    else
        warn "timeout nao disponivel; pulando teste de injeção."
    fi

    if [ "$VALIDATION_FAILED" -eq 1 ]; then
        warn "validacao pos-install detectou problemas (veja avisos acima)."
        warn "use 'xemonitor-uninstall --purge' para remover tudo e tentar novamente."
    else
        log "validacao pos-install: TUDO OK."
    fi
fi

# ---------- 12. Dependencia de injecao (cliente) ----------
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    command -v ydotool >/dev/null 2>&1 || warn "ydotool nao encontrado (fallback Wayland). Instale: pacman -S ydotool / apt install ydotool / apk add ydotool."
else
    command -v xdotool >/dev/null 2>&1 || warn "xdotool nao encontrado (fallback X11). Instale: pacman -S xdotool / apt install xdotool / apk add xdotool."
fi

# ---------- 13. Resumo ----------
if [ "$SERVICE" = "1" ] && [ "$INIT" != "none" ]; then
    SERVICE_MSG="O servico do bridge ja esta ativo (${INIT}). Escaneie um codigo:"
else
    SERVICE_MSG="Servico nao instalado (init=${INIT}). Inicie o bridge manualmente:"
fi

GUI_SUMMARY=""
[ "$GUI_INSTALLED" = "1" ] && GUI_SUMMARY="  ${C_BLUE}GUI:${C_NC}     ${BIN_DIR}/xemonitor-gui (bandeja; inicia no login)"

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