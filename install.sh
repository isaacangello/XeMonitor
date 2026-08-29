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
# v1.4.2: corrige a URL de download por tag especifica (era
#          releases/{TAG}/download -> 404; agora releases/download/{TAG}).
# v1.4.1: resolve versao real da release quando VERSION=latest (API do GitHub)
#          e grava o tag real (ex.: v0.8.0) em /usr/local/share/xemonitor/VERSION
#          (antes gravava o literal 'latest'); ver_newer tolera prefixo 'v'.
# v1.4.0: autodetect de device (/dev/serial/by-id -> ttyUSB* -> ttyACM*),
# deteccao de sessao grafica, install do injetor (ydotool/xdotool), check de
# driver kernel, banner destacado de logout, --client-only/--bridge-only,
# reinstall = restart, status real no resumo.
#
# Opcoes:
#   --prefix <dir>       prefixo de instalacao (padrao: /usr/local)
#   --no-service         nao instala/inicia o servico (so binarios + udev)
#   --check-only         valida requisitos sem instalar (exit 0 se OK, 1 se faltar)
#   --dry-run            simula instalacao mostrando passos sem executar sudo
#   --validate           roda validacao pos-install (padrao: ON)
#   --no-validate        desliga validacao pos-install
#   --client-only        instala so o cliente (sem bridge/service/udev CH340)
#   --bridge-only        instala so o bridge (sem GUI/cliente/desktop entry)
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
INSTALL_VERSION="1.4.2"
TARBALL="xemonitor-linux-x86_64.tar.gz"
VERSION="${XEMONITOR_VERSION:-latest}"
PREFIX="/usr/local"
SERVICE=1
CHECK_ONLY=0
DRY_RUN=0
VALIDATE=1
QUIET=0
VERBOSE=0
CLIENT_ONLY=0
BRIDGE_ONLY=0
REAL_USER="${SUDO_USER:-${USER:-}}"
MISSING_GROUPS=""
YDOTOOL_UNIT=""
YDOTOOL_SESSION="wayland"

usage() {
    cat <<'HELP'
XeMonitor - instalador Linux (v1.4.2)

Uso:
  curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash

Instala o bridge (servidor serial->TCP) e o xemonitor (cliente teclado virtual)
em /usr/local/bin, configura as regras udev (CH340 + uinput), adiciona o usuario
aos grupos de acesso serial/uinput (uucp/dialout/input) e instala o servico do
bridge (systemd ou OpenRC).

O desinstalador tambem e instalado: /usr/local/bin/xemonitor-uninstall
  (use 'xemonitor-uninstall --purge' para remover config + logs).

Opcoes:
  --prefix <dir>       prefixo de instalacao (padrao: /usr/local)
  --no-service         nao instala/inicia o servico (so binarios + udev)
  --check-only         valida requisitos sem instalar (exit 0 se OK, 1 se faltar)
  --dry-run            simula instalacao mostrando passos sem executar sudo
  --validate           roda validacao pos-install (padrao: ON)
  --no-validate        desliga validacao pos-install
  --client-only        instala so o cliente (sem bridge/service/udev CH340)
  --bridge-only        instala so o bridge (sem GUI/cliente/desktop entry)
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
        --client-only) CLIENT_ONLY=1; shift ;;
        --bridge-only) BRIDGE_ONLY=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --version|-V) printf 'XeMonitor installer %s\n' "$INSTALL_VERSION"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) shift ;;
    esac
done

if [ "$CLIENT_ONLY" = "1" ] && [ "$BRIDGE_ONLY" = "1" ]; then
    printf "${C_RED}[erro]${C_NC} --client-only e --bridge-only sao mutuamente exclusivos.\n" 2>/dev/null || true
    printf '[erro] --client-only e --bridge-only sao mutuamente exclusivos.\n' >&2
    exit 1
fi

# ---------- Cores embutidas (ANSI) ----------
if [ -t 1 ] && [ "$QUIET" -eq 0 ]; then
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[31m"
    C_BLUE="\033[34m"
    C_CIANO="\033[36m"
    C_BOLD="\033[1m"
    C_NC="\033[0m"
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_CIANO=""; C_BOLD=""; C_NC=""
fi

log()  { if [ "$QUIET" -eq 0 ]; then printf "${C_GREEN}[install]${C_NC} %s\n" "$*"; fi; }
warn() { printf "${C_YELLOW}[aviso]${C_NC} %s\n" "$*"; }
die()  { printf "${C_RED}[erro]${C_NC} %s\n" "$*" >&2; exit 1; }
debug() { if [ "$VERBOSE" -eq 1 ]; then printf "${C_BLUE}[debug]${C_NC} %s\n" "$*"; fi; }

# Newline real (para concatenacao em strings via +=)
NL=$'\n'
attention() {
    printf '\n'
    printf "${C_BOLD}${C_YELLOW}============================================================${C_NC}\n"
    printf "${C_BOLD}${C_YELLOW}  ATENCAO${C_NC}\n"
    printf "${C_BOLD}${C_YELLOW}============================================================${C_NC}\n"
    while [ "$#" -gt 0 ]; do
        printf "${C_YELLOW}  * %s${C_NC}\n" "$1"
        shift
    done
    printf "${C_BOLD}${C_YELLOW}============================================================${C_NC}\n"
    printf '\n'
}

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
    elif [ -n "${SUDO_ASKPASS:-}" ] && [ -x "$SUDO_ASKPASS" ]; then
        sudo -A "$@"
    else
        sudo "$@"
    fi
}

# Roda um comando como outro usuario via sudo, respeitando SUDO_ASKPASS (-A).
sudo_user_run() {
    local user="$1"; shift
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] sudo -u ${user} $*"
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        su -s /bin/sh "$user" -c "$*"
    elif [ -n "${SUDO_ASKPASS:-}" ] && [ -x "$SUDO_ASKPASS" ]; then
        sudo -A -u "$user" "$@"
    else
        sudo -u "$user" "$@"
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
    if [ "$remote_ver" != "$INSTALL_VERSION" ] && ver_newer "$remote_ver" "$INSTALL_VERSION"; then
        warn "existe uma versao mais nova do instalador (${remote_ver}); a sua e ${INSTALL_VERSION}."
        warn "atualize com: curl -LsSf https://raw.githubusercontent.com/${REPO}/main/install.sh | bash"
    fi
    return 0
}

# ---------- Comparador de versoes (semver: X.Y.Z) ----------
# Retorna 0 se v1 > v2. Tolera sufixo 'v' (ex.: v0.8.0) e nao-numericos -> 0.
ver_newer() {
    local a b i ai bi
    a="${1#v}"; b="${2#v}"
    IFS='.' read -r -a a <<<"$a"
    IFS='.' read -r -a b <<<"$b"
    for i in 0 1 2; do
        ai="${a[$i]:-0}"; bi="${b[$i]:-0}"
        case "$ai" in *[!0-9]*) ai=0;; esac
        case "$bi" in *[!0-9]*) bi=0;; esac
        [ "$ai" -gt "$bi" ] 2>/dev/null && return 0
        [ "$ai" -lt "$bi" ] 2>/dev/null && return 1
    done
    return 1
}

# ---------- Resolver versao real da release quando VERSION=latest ----------
# Consulta a API do GitHub para obter o tag_name (ex.: v0.8.0) da ultima
# release. Se a API falhar (sem rede, rate-limit), mantem 'latest' como
# fallback e continua usando /releases/latest/download.
resolve_version() {
    [ "$VERSION" != "latest" ] && return 0
    local json tag
    json="$(curl -fsSL --max-time "$CURL_TIMEOUT" "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
    tag="$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$tag" ]; then
        VERSION="$tag"
        log "release mais recente detectada: ${VERSION}"
    else
        warn "nao foi possivel detectar a versao da ultima release; usando 'latest'."
    fi
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

# ---------- Detectar libc (glibc vs musl) ----------
detect_libc() {
    if [ -f /etc/alpine-release ]; then
        echo "musl"
    elif ldd --version 2>&1 | head -1 | grep -qi musl; then
        echo "musl"
    else
        echo "glibc"
    fi
}

# ---------- Detectar gerenciador de pacotes ----------
detect_pkg_mgr() {
    if command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "none"
    fi
}

# ---------- Detectar sessao grafica ----------
detect_session() {
    local s="${XDG_SESSION_TYPE:-}"
    if [ -z "$s" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        s="x11"
    fi
    [ -z "$s" ] && s="tty"
    echo "$s"
}

# ---------- Detectar grupos efetivos do usuario real ----------
# Retorna a lista de grupos faltando (em $MISSING_GROUPS).
check_groups() {
    MISSING_GROUPS=""
    if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ] || ! id "$REAL_USER" >/dev/null 2>&1; then
        return 0
    fi
    local eff g
    eff="$(id -Gn "$REAL_USER" 2>/dev/null || true)"
    # Arch/CachyOS usam 'uucp' (sem dialout); Debian/Ubuntu usam dialout (sem uucp).
    # Verifica a presenca do grupo (existencia + obrigatoriedade por distro).
    for g in uucp dialout input; do
        # Se o grupo nao existe no sistema, nao pode ser exigido.
        getent group "$g" >/dev/null 2>&1 || continue
        case " $eff " in
            *" $g "*) ;;
            *) MISSING_GROUPS="$MISSING_GROUPS $g" ;;
        esac
    done
    return 0
}

# ---------- 1. Requisitos basicos ----------
log "verificando requisitos..."
check_requirements || die "requisitos basicos nao atendidos."
check_update || true

# ---------- 2. Detectar init / libc / session / pkg mgr ----------
INIT="none"
if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif [ -f /etc/openrc ] || command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
fi
log "init detectado: ${INIT}"

LIBC="$(detect_libc)"
log "libc: ${LIBC}"

SESSION_TYPE="$(detect_session)"
log "sessao: ${SESSION_TYPE}"

PKG_MGR="$(detect_pkg_mgr)"
debug "pkg manager: ${PKG_MGR}"

# Validar compat: GUI requer glibc (release compila em glibc).
# Se --bridge-only, o device lib e o bridge sao musl, entao nao importa.
# Se --client-only, GUI e glibc, entao em musl o cliente CLI ainda funciona,
# mas o GUI e pulado.
GUI_AVAILABLE=0
if [ "$LIBC" = "glibc" ] && [ "$SESSION_TYPE" != "tty" ] && [ "$BRIDGE_ONLY" = "0" ]; then
    GUI_AVAILABLE=1
fi
log "GUI disponivel: ${GUI_AVAILABLE} (libc=${LIBC} sessao=${SESSION_TYPE})"

if [ "$CHECK_ONLY" = "1" ]; then
    log "check-only: OK (requisitos atendidos, init=${INIT}, libc=${LIBC}, sessao=${SESSION_TYPE}, gui=${GUI_AVAILABLE})"
    exit 0
fi

# ---------- 3. Detectar device USB-serial (para gravar em /etc/xemonitor/device) ----------
# A deteccao real acontece apos extrair o tarball (secao 4), usando o proprio
# binario `xemonitor-bridge --print-device`. Antes disso, tentamos o fallback
# estatico: varrer /dev/serial/by-id e /dev/ttyUSB* manualmente. Se nenhum
# for encontrado, o device fica como `/dev/ttyUSB0` (default do bridge) e o
# log avisa.
DETECTED_DEVICE=""
if [ "$CLIENT_ONLY" = "0" ]; then
    if ls /dev/serial/by-id/* >/dev/null 2>&1; then
        DETECTED_DEVICE="$(ls /dev/serial/by-id/* 2>/dev/null | head -1)"
    elif ls /dev/ttyUSB* >/dev/null 2>&1; then
        DETECTED_DEVICE="$(ls /dev/ttyUSB* 2>/dev/null | head -1)"
    elif ls /dev/ttyACM* >/dev/null 2>&1; then
        DETECTED_DEVICE="$(ls /dev/ttyACM* 2>/dev/null | head -1)"
    else
        DETECTED_DEVICE="/dev/ttyUSB0"
    fi
    log "device pre-detectado: ${DETECTED_DEVICE}"
fi

# ---------- 4. Baixar binarios + SHA256 ----------
# Descobre a versao real da release antes de montar a URL (resolve 'latest').
resolve_version
BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/download/${VERSION}}"
[ "$VERSION" = "latest" ] && BASE_URL="${XEMONITOR_BASE_URL:-https://github.com/${REPO}/releases/latest/download}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "baixando ${TARBALL} (${VERSION})..."
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

# Re-detectar device com o binário local (caso a pre-detect tenha falhado).
if [ -x "${TMP}/xemonitor-bridge" ]; then
    LOC_DETECTED="$("${TMP}/xemonitor-bridge" --print-device 2>/dev/null || true)"
    if [ -n "$LOC_DETECTED" ]; then
        if [ "$LOC_DETECTED" != "$DETECTED_DEVICE" ]; then
            log "device atualizado pela deteccao local: ${DETECTED_DEVICE} -> ${LOC_DETECTED}"
            DETECTED_DEVICE="$LOC_DETECTED"
        fi
    fi
fi

# ---------- 5. Detectar reinstalacao ----------
REINSTALL=0
if [ -f /etc/systemd/system/xemonitor-bridge.service ] || [ -f /etc/init.d/xemonitor-bridge ]; then
    REINSTALL=1
    log "instalacao anterior detectada (modo REINSTALL)."
fi

# ---------- 6. Instalar binarios ----------
BIN_DIR="${PREFIX}/bin"
log "instalando binarios em ${BIN_DIR}/..."
sudo_run mkdir -p "$BIN_DIR"

# Em --bridge-only, NAO instala cliente/GUI.
if [ "$BRIDGE_ONLY" = "0" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor"      "$BIN_DIR/xemonitor"
    GUI_INSTALLED=0
    if [ -f "$TMP/xemonitor-gui" ] && [ "$GUI_AVAILABLE" = "1" ]; then
        sudo_run install -m 0755 "$TMP/xemonitor-gui" "$BIN_DIR/xemonitor-gui"
        GUI_INSTALLED=1
    elif [ -f "$TMP/xemonitor-gui" ]; then
        warn "xemonitor-gui nao instalado (libc=${LIBC}, sessao=${SESSION_TYPE}, glibc+grafico requerido)."
    fi
else
    GUI_INSTALLED=0
    log "--bridge-only: cliente/GUI nao serao instalados."
fi

# Em --client-only, NAO instala o bridge.
if [ "$CLIENT_ONLY" = "0" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor-bridge" "$BIN_DIR/xemonitor-bridge"
else
    log "--client-only: bridge nao sera instalado."
fi

# Desinstalador (sempre)
if [ -f "$TMP/xemonitor-uninstall" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor-uninstall" "$BIN_DIR/xemonitor-uninstall"
    log "desinstalador instalado em ${BIN_DIR}/xemonitor-uninstall"
else
    warn "release antigo sem xemonitor-uninstall; baixe-o manualmente do repositorio."
fi

# Diagnostico (sempre que existir)
if [ -f "$TMP/xemonitor-diagnose" ]; then
    sudo_run install -m 0755 "$TMP/xemonitor-diagnose" "$BIN_DIR/xemonitor-diagnose"
    log "diagnostico instalado em ${BIN_DIR}/xemonitor-diagnose"
fi

sudo_run mkdir -p "${PREFIX}/share/xemonitor"
printf '%s\n' "$VERSION" | sudo_run tee "${PREFIX}/share/xemonitor/VERSION" > /dev/null

# ---------- 7. Gravar device detectado ----------
if [ "$CLIENT_ONLY" = "0" ]; then
    sudo_run mkdir -p /etc/xemonitor
    printf 'DEVICE=%s\n' "$DETECTED_DEVICE" | sudo_run tee /etc/xemonitor/device >/dev/null
    log "device gravado em /etc/xemonitor/device (DEVICE=${DETECTED_DEVICE})"
fi

# ---------- 8. Pre-check de driver kernel (Patch 3.6) ----------
if [ "$CLIENT_ONLY" = "0" ]; then
    DRIVER_NAME=""
    if [ -e "$DETECTED_DEVICE" ]; then
        DRIVER_NAME="$(udevadm info -n "$DETECTED_DEVICE" -q property 2>/dev/null | sed -n 's/^DRIVER=//p' | head -1)"
        if [ -z "$DRIVER_NAME" ] && [ -L "/sys/class/tty/$(basename "$DETECTED_DEVICE")/device/driver" ]; then
            DRIVER_NAME="$(basename "$(readlink "/sys/class/tty/$(basename "$DETECTED_DEVICE")/device/driver" 2>/dev/null)" 2>/dev/null)"
        fi
    fi
    if [ -n "$DRIVER_NAME" ]; then
        log "driver do device: ${DRIVER_NAME}"
        if [ "$DRIVER_NAME" = "cdc_acm" ]; then
            warn "driver 'cdc_acm' nao suporta ioctl de modem lines (TIOCMBIS)."
            warn "o Honeywell 1900 so transmite com DTR+RTS ativos. Tente: sudo modprobe ch341"
            if command -v modprobe >/dev/null 2>&1; then
                if [ "$DRY_RUN" = "0" ] && [ "$(id -u)" -eq 0 -o -n "$(command -v sudo)" ]; then
                    sudo_run modprobe ch341 2>/dev/null || true
                    NEW_DRIVER="$(udevadm info -n "$DETECTED_DEVICE" -q property 2>/dev/null | sed -n 's/^DRIVER=//p' | head -1)"
                    if [ "$NEW_DRIVER" = "ch341" ]; then
                        log "modprobe ch341: driver trocado para ch341 (DTR/RTS agora suportados)."
                    else
                        warn "modprobe ch341 nao trocou o driver (sistema sem ch341 instalado)."
                    fi
                fi
            fi
        elif [ "$DRIVER_NAME" = "ch341" ]; then
            log "driver ch341: DTR/RTS serao suportados."
        fi
    else
        debug "driver do device nao detectado (sem udev ou device inexistente)."
    fi
fi

# ---------- 9. Regras udev ----------
if [ -d /etc/udev/rules.d ]; then
    log "instalando regras udev..."
    if [ "$CLIENT_ONLY" = "0" ]; then
        UDEV_CH340='SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"'
        printf '%s\n' "$UDEV_CH340" | sudo_run tee /etc/udev/rules.d/99-ch340.rules > /dev/null
        log "regra udev do CH340 instalada (99-ch340.rules)."
    fi
    # uinput: sempre (cliente precisa para injecao via uinput).
    UDEV_UINPUT='KERNEL=="uinput", GROUP="input", MODE="0660"'
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

# ---------- 10. Icone hicolor ----------
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

# ---------- 11. Instalar injetor de teclado (Patch 1.1) ----------
install_injector() {
    case "$SESSION_TYPE" in
        tty)
            log "sessao tty detectada: instalacao de injetor pulada (sem GUI)."
            return 0
            ;;
        wayland)
            case "$PKG_MGR" in
                pacman) sudo_run pacman -S --noconfirm --needed ydotool >/dev/null 2>&1 \
                    && log "ydotool instalado (pacman)." \
                    || warn "pacman -S ydotool falhou; instale manualmente: sudo pacman -S ydotool" ;;
                apt) sudo_run apt-get install -y --no-install-recommends ydotool >/dev/null 2>&1 \
                    && log "ydotool instalado (apt)." \
                    || warn "apt install ydotool falhou; instale manualmente: sudo apt install ydotool" ;;
                dnf) sudo_run dnf install -y ydotool >/dev/null 2>&1 \
                    && log "ydotool instalado (dnf)." \
                    || warn "dnf install ydotool falhou; instale manualmente: sudo dnf install ydotool" ;;
                apk) sudo_run apk add ydotool >/dev/null 2>&1 \
                    && log "ydotool instalado (apk)." \
                    || warn "apk add ydotool falhou; instale manualmente: sudo apk add ydotool" ;;
                *) warn "gerenciador de pacotes desconhecido; instale ydotool manualmente." ;;
            esac
            # Habilita o injetor (systemd de usuario) para o usuario real.
            # O nome da unit varia por distro: ydotool.socket (Debian/Ubuntu/Fedora/Alpine)
            # ou ydotool.service (Arch/CachyOS/Manjaro).
            if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
                user_uid="$(id -u "$REAL_USER")"
                if [ "$DRY_RUN" = "1" ]; then
                    log "[dry-run] detectar unit ydotool + enable --now (como ${REAL_USER})"
                    YDOTOOL_UNIT="ydotool.socket"
                else
                    YDOTOOL_UNIT=""
                    for yunit in ydotool.socket ydotool.service; do
                        if sudo_user_run "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/${user_uid}" \
                                systemctl --user list-unit-files "$yunit" 2>/dev/null | grep -q "$yunit"; then
                            YDOTOOL_UNIT="$yunit"
                            break
                        fi
                    done
                    exists=0
                    # Caso a unit exista mas nao apareca em list-unit-files (ex.: template), checa o unit file.
                    if [ -n "$YDOTOOL_UNIT" ]; then
                        exists=1
                    elif sudo_user_run "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/${user_uid}" \
                            systemctl --user cat ydotool.service 2>/dev/null | grep -q Description; then
                        YDOTOOL_UNIT="ydotool.service"; exists=1
                    elif sudo_user_run "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/${user_uid}" \
                            systemctl --user cat ydotool.socket 2>/dev/null | grep -q Listen; then
                        YDOTOOL_UNIT="ydotool.socket"; exists=1
                    fi
                    if [ "$exists" -eq 1 ]; then
                        sudo_user_run "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/${user_uid}" \
                            systemctl --user enable --now "$YDOTOOL_UNIT" >/dev/null 2>&1 \
                            && log "${YDOTOOL_UNIT} (user) ativado para ${REAL_USER}." \
                            || warn "falha ao ativar ${YDOTOOL_UNIT} (user). Tente: systemctl --user enable --now ${YDOTOOL_UNIT}"
                    else
                        warn "nenhuma unit ydotool (.socket/.service) encontrada para o usuario."
                    fi
                fi
            fi
            ;;
        x11)
            case "$PKG_MGR" in
                pacman) sudo_run pacman -S --noconfirm --needed xdotool >/dev/null 2>&1 \
                    && log "xdotool instalado (pacman)." \
                    || warn "pacman -S xdotool falhou; instale manualmente." ;;
                apt) sudo_run apt-get install -y --no-install-recommends xdotool >/dev/null 2>&1 \
                    && log "xdotool instalado (apt)." \
                    || warn "apt install xdotool falhou; instale manualmente." ;;
                dnf) sudo_run dnf install -y xdotool >/dev/null 2>&1 \
                    && log "xdotool instalado (dnf)." \
                    || warn "dnf install xdotool falhou; instale manualmente." ;;
                apk) sudo_run apk add xdotool >/dev/null 2>&1 \
                    && log "xdotool instalado (apk)." \
                    || warn "apk add xdotool falhou; instale manualmente." ;;
                *) warn "gerenciador de pacotes desconhecido; instale xdotool manualmente." ;;
            esac
            ;;
    esac
}
if [ "$BRIDGE_ONLY" = "0" ]; then
    install_injector
fi

# ---------- 12. Desktop entry + autostart + config central ----------
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

# ---------- 13. Dependencias runtime GUI (Debian/Ubuntu) ----------
if [ "$GUI_INSTALLED" = "1" ] && command -v apt-get >/dev/null 2>&1; then
    log "instalando dependencias de runtime do GUI (libdbus-1-3 libsystemd0)..."
    sudo_run apt-get update >/dev/null 2>&1 || true
    sudo_run apt-get install -y --no-install-recommends libdbus-1-3 libsystemd0 >/dev/null 2>&1 ||
        warn "nao foi possivel instalar via apt (manual: apt-get install libdbus-1-3 libsystemd0)."
fi

# ---------- 14. Grupos de acesso serial ----------
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ] && id "$REAL_USER" >/dev/null 2>&1; then
    ADD_GROUPS=""
    for g in uucp dialout input; do
        getent group "$g" >/dev/null 2>&1 && ADD_GROUPS="${ADD_GROUPS:+$ADD_GROUPS,}$g"
    done
    [ -n "$ADD_GROUPS" ] && sudo_run usermod -aG "$ADD_GROUPS" "$REAL_USER" || true
    log "usuario '${REAL_USER}' adicionado aos grupos: ${ADD_GROUPS:-nenhum}."

    check_groups
    if [ -n "$MISSING_GROUPS" ]; then
        # Banner destacado: grupos ainda nao efetivos para o usuario atual.
        attention \
            "Os grupos ${MISSING_GROUPS} foram adicionados a ${REAL_USER}," \
            "mas a sessao atual ainda nao os herdou." \
            "Faca logout e login novamente (ou: newgrp ${MISSING_GROUPS%% *})" \
            "antes de usar o GUI, senao /dev/uinput (input) sera negado" \
            "e a injeccao de teclado nao funcionara."
    fi
fi

# ---------- 15. Servico do bridge ----------
if [ "$SERVICE" = "1" ] && [ "$CLIENT_ONLY" = "0" ]; then
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
ExecStart=/bin/bash -c 'set -a; source /etc/xemonitor/device 2>/dev/null; set +a; exec /usr/local/bin/xemonitor-bridge --device "\${DEVICE:-/dev/ttyUSB0}"'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        fi
        log "instalando servico systemd..."
        sudo_run install -m 0644 "$SVC_UNIT" /etc/systemd/system/xemonitor-bridge.service
        sudo_run systemctl daemon-reload
        if [ "$REINSTALL" = "1" ]; then
            sudo_run systemctl restart xemonitor-bridge 2>/dev/null || true
            log "servico systemd 'xemonitor-bridge' reiniciado."
        else
            sudo_run systemctl enable xemonitor-bridge >/dev/null 2>&1 || true
            sudo_run systemctl start xemonitor-bridge 2>/dev/null || true
            log "servico systemd 'xemonitor-bridge' instalado e iniciado."
        fi
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
command_args="--device \${DEVICE:-/dev/ttyUSB0}"

start_pre() {
    [ -f /etc/xemonitor/device ] && . /etc/xemonitor/device
    [ -n "\${DEVICE:-}" ] && command_args="--device \${DEVICE}"
    return 0
}

depend() {
    need net
}
EOF
        fi
        log "instalando servico OpenRC..."
        sudo_run install -m 0755 "$INIT_SCRIPT" /etc/init.d/xemonitor-bridge
        sudo_run rc-update add xemonitor-bridge default 2>/dev/null || true
        if [ "$REINSTALL" = "1" ]; then
            sudo_run rc-service xemonitor-bridge restart || true
            log "servico OpenRC 'xemonitor-bridge' reiniciado."
        else
            sudo_run rc-service xemonitor-bridge start || true
            log "servico OpenRC 'xemonitor-bridge' instalado e iniciado."
        fi
    else
        warn "init nao identificado; servico nao instalado. Rode o bridge manualmente: ${BIN_DIR}/xemonitor-bridge"
    fi
fi

# ---------- 16. Validacao pos-install (smoke, NAO injecao) ----------
if [ "$VALIDATE" = "1" ] && [ "$SERVICE" = "1" ] && [ "$INIT" != "none" ] && [ "$CLIENT_ONLY" = "0" ]; then
    log "validando instalacao..."
    VALIDATION_FAILED=0

    # 16a. Servico ativo
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

    # 16b. Porta 9000 escutando (com retry, pois o restart do bridge pode demorar)
    if command -v ss >/dev/null 2>&1; then
        n=0
        while [ "$n" -lt 10 ] && ! ss -tln 2>/dev/null | grep -q ':9000'; do
            sleep 1
            n=$((n+1))
        done
        if ss -tln 2>/dev/null | grep -q ':9000'; then
            log "porta 9000 OK."
        else
            warn "porta 9000 nao esta escutando (bridge pode nao ter subido completamente)."
            VALIDATION_FAILED=1
        fi
    fi

    # 16c. Device USB-serial visivel
    if [ -e "$DETECTED_DEVICE" ]; then
        log "device visivel: ${DETECTED_DEVICE}"
    else
        warn "device nao visivel: ${DETECTED_DEVICE} (CH340 conectado? udev recarregou?)"
        VALIDATION_FAILED=1
    fi

    # 16d. Injetor (se Wayland/X11 e GUI_INSTALLED)
    if [ "$GUI_INSTALLED" = "1" ]; then
        case "$SESSION_TYPE" in
            wayland)
                ydotool_ok=0
                if command -v systemctl >/dev/null 2>&1 && [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
                    for yunit in ydotool.service ydotool.socket; do
                        if sudo_user_run "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
                                systemctl --user is-active --quiet "$yunit" 2>/dev/null; then
                            ydotool_ok=1
                            YDOTOOL_UNIT="${YDOTOOL_UNIT:-$yunit}"
                            break
                        fi
                    done
                fi
                if [ "$ydotool_ok" = "1" ]; then
                    log "ydotool.injecor (${YDOTOOL_UNIT}) ativo."
                else
                    warn "nenhum ydotool injecor ativo (user ${REAL_USER}); injecao Wayland pode falhar."
                    VALIDATION_FAILED=1
                fi
                ;;
            x11)
                if ! command -v xdotool >/dev/null 2>&1; then
                    warn "xdotool nao instalado (injection via X11 pode falhar)."
                    VALIDATION_FAILED=1
                else
                    log "xdotool disponivel."
                fi
                ;;
        esac
    fi

    # 16e. Grupos efetivos
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        check_groups
        if [ -n "$MISSING_GROUPS" ]; then
            warn "grupos faltando para ${REAL_USER}:${MISSING_GROUPS} (logout/login necessario)."
            VALIDATION_FAILED=1
        else
            log "grupos de acesso serial efetivos."
        fi
    fi

    if [ "$VALIDATION_FAILED" = "1" ]; then
        warn "validacao pos-install detectou problemas (veja avisos acima)."
        warn "use 'xemonitor-diagnose' para diagnostico detalhado (instalado em ${BIN_DIR}/xemonitor-diagnose)."
    else
        log "validacao pos-install: TUDO OK."
    fi
fi

# ---------- 17. Resumo ----------
SERVICE_MSG=""
if [ "$SERVICE" = "1" ] && [ "$INIT" != "none" ] && [ "$CLIENT_ONLY" = "0" ]; then
    SERVICE_MSG="O servico do bridge ja esta ativo (${INIT}, device=${DETECTED_DEVICE}). Escaneie um codigo:"
elif [ "$CLIENT_ONLY" = "1" ]; then
    SERVICE_MSG="Modo --client-only: bridge NAO foi instalado. Conecte a um bridge remoto:"
else
    SERVICE_MSG="Servico nao instalado (init=${INIT}). Inicie o bridge manualmente:"
fi

GUI_SUMMARY=""
if [ "$GUI_INSTALLED" = "1" ]; then
    GUI_SUMMARY="  ${C_BLUE}GUI:${C_NC}     ${BIN_DIR}/xemonitor-gui (bandeja; inicia no login)"
fi

DIAG_SUMMARY="  ${C_BLUE}Diagnose:${C_NC} ${BIN_DIR}/xemonitor-diagnose  (--check, --fix, --test-serial)"

# 17a. Bloco de status real (Patch 3.1)
STATUS_BLOCK=""
if [ "$SERVICE" = "1" ] && [ "$INIT" != "none" ] && [ "$CLIENT_ONLY" = "0" ]; then
    STATUS_BLOCK+="  ${C_BOLD}Estado atual:${C_NC}${NL}"
    if [ "$INIT" = "systemd" ]; then
        STATE="$(systemctl is-active xemonitor-bridge 2>/dev/null || echo unknown)"
        if [ "$STATE" = "active" ]; then
            STATUS_BLOCK+="    ${C_GREEN}OK${C_NC}  servico systemd: active${NL}"
        else
            STATUS_BLOCK+="    ${C_RED}--${C_NC}  servico systemd: ${STATE}${NL}"
        fi
    fi
    if ss -tln 2>/dev/null | grep -q ':9000'; then
        STATUS_BLOCK+="    ${C_GREEN}OK${C_NC}  porta 9000: listening${NL}"
    else
        STATUS_BLOCK+="    ${C_RED}--${C_NC}  porta 9000: nao listening${NL}"
    fi
    if [ -e "$DETECTED_DEVICE" ]; then
        STATUS_BLOCK+="    ${C_GREEN}OK${C_NC}  device: ${DETECTED_DEVICE}${NL}"
    else
        STATUS_BLOCK+="    ${C_RED}--${C_NC}  device: ${DETECTED_DEVICE} (NAO encontrado)${NL}"
    fi
    if [ -n "$DRIVER_NAME" ]; then
        if [ "$DRIVER_NAME" = "ch341" ]; then
            STATUS_BLOCK+="    ${C_GREEN}OK${C_NC}  driver: ${DRIVER_NAME} (DTR/RTS suportados)${NL}"
        elif [ "$DRIVER_NAME" = "cdc_acm" ]; then
            STATUS_BLOCK+="    ${C_RED}--${C_NC}  driver: ${DRIVER_NAME} (NAO suporta DTR/RTS; modprobe ch341)${NL}"
        else
            STATUS_BLOCK+="    ${C_YELLOW}??${C_NC}  driver: ${DRIVER_NAME}${NL}"
        fi
    fi
    case "$SESSION_TYPE" in
        wayland)
            yup=0
            if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
                for yunit in ydotool.service ydotool.socket; do
                    if sudo_user_run "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" \
                            systemctl --user is-active --quiet "$yunit" 2>/dev/null; then
                        yup=1
                        YDOTOOL_UNIT="${YDOTOOL_UNIT:-$yunit}"
                        break
                    fi
                done
            fi
            if [ "$yup" = "1" ]; then
                STATUS_BLOCK+="    ${C_GREEN}OK${C_NC}  ydotool injecor (${YDOTOOL_UNIT}): ativo${NL}"
            else
                STATUS_BLOCK+="    ${C_RED}--${C_NC}  ydotool injecor: inativo (Wayland injection vai falhar)${NL}"
            fi
            ;;
        x11)
            if command -v xdotool >/dev/null 2>&1; then
                STATUS_BLOCK+="    ${C_GREEN}OK${C_NC}  xdotool: disponivel (X11 injection)${NL}"
            else
                STATUS_BLOCK+="    ${C_RED}--${C_NC}  xdotool: AUSENTE (X11 injection vai falhar)${NL}"
            fi
            ;;
    esac
    if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
        check_groups
        if [ -z "$MISSING_GROUPS" ]; then
            STATUS_BLOCK+="    ${C_GREEN}OK${C_NC}  grupos (uucp/dialout/input): efetivos${NL}"
        else
            STATUS_BLOCK+="    ${C_RED}--${C_NC}  grupos: FALTAM${MISSING_GROUPS} (logout/login necessario)${NL}"
        fi
    fi
fi

RESUMO=""
RESUMO+="${NL}${C_CIANO}============================================================${C_NC}${NL}"
RESUMO+="  ${C_CIANO}XeMonitor instalado!${C_NC}${NL}"
RESUMO+="  Versao: ${VERSION} (veja ${PREFIX}/share/xemonitor/VERSION)${NL}"
RESUMO+="  Instalador: ${INSTALL_VERSION}${NL}"
RESUMO+="  Init:   ${INIT} | libc: ${LIBC} | sessao: ${SESSION_TYPE}${NL}"
RESUMO+="${C_CIANO}------------------------------------------------------------${C_NC}${NL}"
RESUMO+="  ${C_BLUE}Bridge:${C_NC}  ${BIN_DIR}/xemonitor-bridge   (serial -> TCP :9000, device=${DETECTED_DEVICE})${NL}"
RESUMO+="  ${C_BLUE}Cliente:${C_NC} ${BIN_DIR}/xemonitor${NL}"
RESUMO+="${GUI_SUMMARY}${NL}"
RESUMO+="${DIAG_SUMMARY}${NL}"
RESUMO+="${STATUS_BLOCK}"
RESUMO+="  Config central (Linux): ~/.config/xemonitor/${NL}"
RESUMO+="    xemonitor-gui.conf | xemonitor-YYYY-MM-DD.log | pids${NL}"
RESUMO+="  Status/diagnostico:  xemonitor-diagnose --check${NL}"
RESUMO+="  Desinstalar:         ${BIN_DIR}/xemonitor-uninstall  (--purge remove config+logs)${NL}"
RESUMO+="${NL}"
RESUMO+="  ${SERVICE_MSG}${NL}"
RESUMO+="    echo 'exemplo' | ${BIN_DIR}/xemonitor --stdin${NL}"
RESUMO+="  ou conecte via TCP (ex.: com o scanner no /dev/ttyUSB0):${NL}"
RESUMO+="    ${BIN_DIR}/xemonitor --tcp 127.0.0.1:9000${NL}"
RESUMO+="${NL}"
RESUMO+="  Para reconfigurar o scanner: ver AGENTS.md / TODO.md${NL}"
RESUMO+="${C_CIANO}============================================================${C_NC}${NL}"
printf "%b" "$RESUMO"
