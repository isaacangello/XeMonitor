#!/usr/bin/env bash
# XeMonitor — Ponto de entrada estável no Linux (default: systemd-user, zero sudo)
# Uso: ./run_xemonitor.sh [--replace] [--system] [--user-bridge] [--fake-scan MS] [--no-enable]
#
# --replace       : Reset total (para instâncias antigas via systemd/pkill, reescreve config)
# --system        : Usa unit de SISTEMA (root, sobrevive ao logout). Exige senha sudo.
#                   Default: unit de USUÁRIO (sg uucp, sem sudo — usuário precisa estar em uucp).
# --user-bridge   : Bridge roda como child do script (sem systemd, modo dev)
# --fake-scan MS  : Gera scans fake a cada MS ms (só com --user-bridge)
# --no-enable     : Pula 'systemctl enable' (unit não persiste no boot)

set -euo pipefail

# ==========================================
# Configurações
# ==========================================
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
CFG_DIR="${XEMONITOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/xemonitor}"
CONF="$CFG_DIR/xemonitor-gui.conf"
PORT=9000

REPLACE=1          # Sempre ativo (estilo kwin --replace)
SYSTEM_MODE=0      # --system  (unit de sistema/root)  [default: user]
USER_BRIDGE=0      # --user-bridge
FAKE_SCAN=         # --fake-scan MS
AUTO_ENABLE=1      # --no-enable desliga

# Parse args - usando while para suportar shift corretamente
while [ $# -gt 0 ]; do
    case "$1" in
        --replace)       REPLACE=1 ;;
        --system)        SYSTEM_MODE=1 ;;
        --user-bridge)   USER_BRIDGE=1 ;;
        --fake-scan)     FAKE_SCAN="${2:-400}"; shift ;;
        --no-enable)     AUTO_ENABLE=0 ;;
        --help|-h)
            cat <<EOF
Uso: $0 [--replace] [--system] [--user-bridge] [--fake-scan MS] [--no-enable]

Opções:
  --replace       Reset total: para instâncias antigas, reescreve config,
                  reinicia o bridge (padrão, sempre ativo).
  --system        Usa o bridge como unit de SISTEMA (root). Sobrevive ao
                  logout, mas exige senha sudo. DEFAULT é unit de usuário
                  (sem sudo; requer pertencer ao grupo 'uucp'/'dialout').
  --user-bridge   Bridge roda como child do script (sem systemd, modo dev).
                  Requer --fake-scan para gerar dados de teste.
  --fake-scan MS  Gera scans fake 'TEST<n>' a cada MS milissegundos
                  (só funciona com --user-bridge).
  --no-enable     Não faz 'systemctl enable' (unit não persiste no boot).
  --help, -h      Mostra esta ajuda.
EOF
            exit 0
            ;;
        *) echo "[ERRO] Opção desconhecida: $1"; exit 1 ;;
    esac
    shift
done

# ==========================================
# Helpers
# ==========================================
detect_ch340_device() {
    for d in /dev/serial/by-id/usb-1a86*; do [ -e "$d" ] && echo "$d" && return 0; done
    for tty in /dev/ttyUSB*; do
        [ -e "$tty" ] && udevadm info -a -n "$tty" 2>/dev/null | grep -q "1a86" && echo "$tty" && return 0
    done
    [ -e /dev/ttyUSB0 ] && echo "/dev/ttyUSB0" && return 0
    return 1
}

test_dtr_rts() {
    python3 -c "
import os, fcntl, struct, time
TIOCM_DTR=0x002; TIOCM_RTS=0x004
TIOCM_BIS=0x5416  # TIOCMBIS (set bits). ATENCAO: 0x5417 e TIOCMBIC (clear).
TIOCM_GET=0x5415
fd=os.open('$1', os.O_RDWR|os.O_NOCTTY)
try:
    fcntl.ioctl(fd, TIOCM_BIS, struct.pack('I', TIOCM_DTR|TIOCM_RTS))
    time.sleep(0.2)
    s=struct.unpack('I', fcntl.ioctl(fd, TIOCM_GET, struct.pack('I',0)))[0]
    ok=(s & (TIOCM_DTR|TIOCM_RTS)) == (TIOCM_DTR|TIOCM_RTS)
    os.close(fd); exit(0 if ok else 1)
except OSError: exit(1)
" 2>/dev/null
}

in_group_serial() {
    # True se o usuário efetivo pertence a um grupo que pode abrir a serial.
    id -nG | tr ' ' '\n' | grep -qE "^(uucp|dialout)$"
}

require_sudo() {
    # Se nao houver sudo sem senha, falha com instrucao clara.
    if ! sudo -n true 2>/dev/null; then
        echo "[ERRO] --system exige sudo (senha). Rode no terminal com 'sudo -v' primeiro"
        echo "       ou use o modo padrão (unit de usuário, sem sudo)."
        exit 1
    fi
}

# ==========================================
# 0. Detect Device + Teste DTR/RTS
# ==========================================
DETECTED_DEVICE="$(detect_ch340_device)" || DETECTED_DEVICE="/dev/ttyUSB0"
echo "[INFO] Device detectado: $DETECTED_DEVICE"

if ! test_dtr_rts "$DETECTED_DEVICE"; then
    echo "[AVISO] DTR/RTS NÃO suportado pelo kernel driver (ch341)."
    echo "         Scanner físico NÃO vai transmitir. Use --fake-scan para testar."
fi

if [ "$USER_BRIDGE" = "0" ] && [ "$SYSTEM_MODE" = "0" ] && ! in_group_serial; then
    echo "[ERRO] Você não está em uucp/dialout. Sem isso o bridge não abre a serial."
    echo "       Rode: sudo usermod -aG uucp \$USER  (e faça logout/login),"
    echo "       ou use '--system' (bridge como root)."
    exit 1
fi

# ==========================================
# 1. --replace: Reset Total (kwin --replace style)
# ==========================================
if [ "$REPLACE" = "1" ]; then
    echo "[INFO] --replace: parando instâncias antigas..."
    # Para ambas as units de forma best-effort (user unit nao precisa de sudo).
    systemctl --user stop xemonitor-bridge 2>/dev/null || true
    sudo systemctl stop xemonitor-bridge 2>/dev/null || true
    pkill -TERM -x xemonitor-gui xemonitor 2>/dev/null || true
    sleep 0.5
    pkill -KILL -x xemonitor-gui xemonitor 2>/dev/null || true
    rm -f /run/user/$UID/xemonitor*.pid /run/xemonitor*.pid 2>/dev/null || true
fi

# ==========================================
# 2. Modo do bridge: user (default) vs system (--system)
# ==========================================
if [ "$USER_BRIDGE" = "1" ]; then
    # Modo dev: bridge como child do script (sem systemd). Nada a instalar.
    : >/dev/null
elif [ "$SYSTEM_MODE" = "1" ]; then
    require_sudo

    # 2a. Device Config (sistema)
    sudo mkdir -p /etc/xemonitor
    printf 'DEVICE=%s\n' "$DETECTED_DEVICE" | sudo tee /etc/xemonitor/device >/dev/null

    # 2b. Systemd Unit de SISTEMA (--http + device explícito)
    sudo tee /etc/systemd/system/xemonitor-bridge.service >/dev/null <<UNIT
[Unit]
Description=XeMonitor serial-to-TCP bridge (Honeywell 1900 / CH340)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'set -a; source /etc/xemonitor/device 2>/dev/null; set +a; exec /usr/local/bin/xemonitor-bridge --http --device "\${DEVICE:-/dev/ttyUSB0}"'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload

    # Guarda de conflito: se o unit de usuário estiver ativo, para.
    if systemctl --user is-active --quiet xemonitor-bridge 2>/dev/null; then
        echo "[INFO] Unit de usuário ativo -> parando (modo --system)."
        systemctl --user stop xemonitor-bridge 2>/dev/null || true
    fi

    # 2c. Auto-enable (default on, --no-enable pula)
    if [ "$AUTO_ENABLE" = "1" ]; then
        sudo systemctl enable xemonitor-bridge >/dev/null 2>&1 || true
    fi

    # 2d. Sobe Bridge (system)
    echo "[INFO] Subindo bridge via systemd (system)..."
    sudo systemctl restart xemonitor-bridge

    SERVER_MODE="systemd-system"
else
    # MODO PADRÃO: unit de USUÁRIO (sg uucp, sem sudo)
    USER_UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$USER_UNIT_DIR"

    # Grava o device detectado DIRETO no unit (evita /etc/xemonitor, root-only).
    cat > "$USER_UNIT_DIR/xemonitor-bridge.service" <<UNIT
[Unit]
Description=XeMonitor serial-to-TCP bridge (Honeywell 1900 / CH340) [user]
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/sg uucp -c '/usr/local/bin/xemonitor-bridge --http --device "$DETECTED_DEVICE"'
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
UNIT

    # Guarda de conflito: se o unit de SISTEMA estiver ativo (root, Restart=always),
    # a 9000 fica presa. Tenta parar best-effort; se continuar ativa, erro claro.
    if systemctl is-active --quiet xemonitor-bridge 2>/dev/null; then
        echo "[INFO] Unit de sistema ativo (legado) -> tentando parar/desabilitar..."
        sudo systemctl stop xemonitor-bridge 2>/dev/null || true
        sudo systemctl disable xemonitor-bridge 2>/dev/null || true
        sleep 1
        if systemctl is-active --quiet xemonitor-bridge 2>/dev/null; then
            echo "[ERRO] Unit de sistema continua ativo segurando a porta $PORT."
            echo "       Rode: sudo systemctl disable --now xemonitor-bridge"
            exit 1
        fi
    fi

    systemctl --user daemon-reload

    if [ "$AUTO_ENABLE" = "1" ]; then
        systemctl --user enable xemonitor-bridge >/dev/null 2>&1 || true
    fi

    echo "[INFO] Subindo bridge via systemd (user)..."
    systemctl --user restart xemonitor-bridge

    SERVER_MODE="systemd-user"
fi

# ==========================================
# 3. Fake-scan (se pedido) — apenas modo user-bridge (child)
# ==========================================
if [ "$USER_BRIDGE" = "1" ]; then
    /usr/local/bin/xemonitor-bridge --http --device "$DETECTED_DEVICE" ${FAKE_SCAN:+--fake-scan $FAKE_SCAN} &
    BRIDGE_PID=$!
    echo "[INFO] Bridge user PID=$BRIDGE_PID (modo dev)"
    SERVER_MODE="subprocess"
elif [ -n "$FAKE_SCAN" ]; then
    echo "[AVISO] --fake-scan só funciona com --user-bridge. Ignorando."
fi

# ==========================================
# 4. Aguarda Bridge + Probe TCP + HTTP /health
# ==========================================
wait_for_bridge() {
    echo -n "[INFO] Aguardando porta $PORT..."
    for i in $(seq 1 30); do
        ss -tln 2>/dev/null | grep -q ":$PORT" && { echo " ok"; return 0; }
        [ "$i" = "30" ] && { echo " FALHOU"; return 1; }
        sleep 1
    done
}
wait_for_bridge || exit 1

# Probe TCP
if python3 -c "import socket; s=socket.create_connection(('127.0.0.1', $PORT), timeout=2); s.close()" 2>/dev/null; then
    echo "[OK] Bridge aceita conexões TCP na porta $PORT."
else
    echo "[AVISO] TCP probe falhou (cliente tentará reconectar)."
fi

# HTTP /health
if curl -sf http://127.0.0.1:9001/health >/dev/null; then
    echo "[OK] HTTP/SSE ativo na porta 9001."
else
    echo "[AVISO] HTTP/SSE não respondeu em 9001."
fi

# ==========================================
# 5. Config GUI (server_mode detectado, auto_start, tray)
# ==========================================
mkdir -p "$CFG_DIR"
cat > "$CONF" <<EOF
tcp_host=127.0.0.1
tcp_port=$PORT
server_mode=$SERVER_MODE
bridge_path=/usr/local/bin/xemonitor-bridge
client_path=/usr/local/bin/xemonitor
log_path=$CFG_DIR/xemonitor.log
auto_start=true
tray_enabled=true
EOF

# ==========================================
# 6. Cleanup Total (trap EXIT)
# ==========================================
cleanup() {
    echo "[INFO] Limpando..."
    [ -n "${BRIDGE_PID:-}" ] && kill "$BRIDGE_PID" 2>/dev/null || true
    pkill -TERM -x xemonitor-gui xemonitor 2>/dev/null || true
    sleep 0.5
    pkill -KILL -x xemonitor-gui xemonitor 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ==========================================
# 7. Exec GUI (foreground)
# ==========================================
echo "[OK] Abrindo xemonitor-gui (server_mode=$SERVER_MODE). 'Sair' no menu da bandeja encerra."
exec /usr/local/bin/xemonitor-gui