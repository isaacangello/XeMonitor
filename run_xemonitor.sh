#!/usr/bin/env bash
# XeMonitor — inicia bridge + GUI (bandeja) no Linux host.
# Espelho do run_bridge.bat para o fluxo Linux (systemd de sistema, root).
# Por padrão faz REPLACE (estilo 'kwin --replace'): encerra instâncias antigas
# de xemonitor-gui/xemonitor e reinicia o bridge para garantir estado limpo.
#
# Uso: ./run_xemonitor.sh [--no-replace]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$REPO_DIR/zig-out/bin"
CFG_DIR="${XEMONITOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/xemonitor}"
CONF="$CFG_DIR/xemonitor-gui.conf"
PORT=9000
REPLACE=1

for arg in "$@"; do
    case "$arg" in
        --no-replace) REPLACE=0 ;;
        --help|-h) echo "Uso: $0 [--no-replace]"; exit 0 ;;
    esac
done

echo "========================================"
echo " Iniciando XeMonitor (Linux host)"
echo "========================================"
echo

# 0. Scanner presente?
if [ ! -c /dev/ttyUSB0 ]; then
    echo "[AVISO] /dev/ttyUSB0 nao encontrado. Conecte o scanner (CH340) e rode novamente."
    echo "        O bridge (start-pre) espera o dispositivo por ate 60s."
    echo
fi

# 0b. Porta 9000 livre? (bridge antigo costuma ficar preso aí)
if ss -tln 2>/dev/null | grep -q ":$PORT"; then
    if systemctl is-active --quiet xemonitor-bridge 2>/dev/null || pgrep -x xemonitor-bridge >/dev/null 2>&1; then
        echo "[OK] Porta $PORT ja em uso pelo nosso bridge (servico systemd xemonitor-bridge)."
    else
        echo "[ERRO] A porta $PORT esta em uso por outro processo."
        pid="$(ss -tlnp 2>/dev/null | grep ":$PORT" | sed -E 's/.*pid=([0-9]+).*/\1/' | head -1)"
        if [ -n "$pid" ]; then
            echo "       Processo: $(ps -o comm=,args= -p "$pid" 2>/dev/null)"
            echo "       Libere com: sudo kill $pid  (se for um xemonitor-bridge antigo)"
        else
            echo "       Identifique o processo: sudo ss -tlnp | grep :$PORT"
        fi
        echo "       Depois rode novamente: $0"
        exit 1
    fi
fi

# 1. Binarios compilados? (guia nao entra no 'zig build' padrao)
need=""
for b in bridge xemonitor xemonitor-gui; do
    [ -x "$BIN/$b" ] || need="$need $b"
done
if [ -n "$need" ]; then
    echo "[INFO] Compilando:$need ..."
    ( cd "$REPO_DIR" && zig build gui && zig build bridge && zig build )
    echo
fi

# 1b. REPLACE: encerra instancias antigas (evita duplicatas de GUI/cliente)
if [ "$REPLACE" = "1" ]; then
    echo "[INFO] --replace: encerrando instancias antigas de xemonitor-gui/xemonitor..."
    pkill -TERM -x xemonitor-gui 2>/dev/null || true
    pkill -TERM -x xemonitor 2>/dev/null || true
    sleep 1
    pkill -KILL -x xemonitor-gui 2>/dev/null || true
    pkill -KILL -x xemonitor 2>/dev/null || true
    echo
fi

# 2. Pasta central de config/log (Linux: ~/.config/xemonitor; log e pids moram aqui)
mkdir -p "$CFG_DIR"

# 2b. Ícone do app na pasta de ícones do sistema (hicolor, usuário)
ICON_DST="$HOME/.local/share/icons/hicolor/scalable/apps/xemonitor.svg"
if [ -f "$REPO_DIR/assets/tabler-icons/barcode.svg" ] && { [ ! -f "$ICON_DST" ] || ! cmp -s "$REPO_DIR/assets/tabler-icons/barcode.svg" "$ICON_DST"; }; then
    echo "[INFO] Instalando ícone: $ICON_DST"
    mkdir -p "$(dirname "$ICON_DST")"
    cp "$REPO_DIR/assets/tabler-icons/barcode.svg" "$ICON_DST"
    gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi

# 3. Unit systemd de SISTEMA (root) do bridge — garante acesso ao /dev/ttyUSB0
#    (instala via scripts/install_bridge_service.sh, que copia o binario e a unit)
if [ ! -f /etc/systemd/system/xemonitor-bridge.service ]; then
    echo "[INFO] Servico de sistema do bridge nao instalado. Instalando (pede senha)..."
    if command -v pkexec >/dev/null 2>&1; then
        pkexec bash "$REPO_DIR/scripts/install_bridge_service.sh"
    else
        echo "[ERRO] Instale com: sudo bash $REPO_DIR/scripts/install_bridge_service.sh"
        exit 1
    fi
fi
if [ ! -f /etc/systemd/system/xemonitor-bridge.service ]; then
    echo "[ERRO] Servico de sistema nao ficou instalado."
    exit 1
fi

# 4. Config do GUI: systemd-system + auto_start (inicia tudo) + bandeja
#    (log_path é só a base: o cliente escreve xemonitor-YYYY-MM-DD.log no dir)
cat > "$CONF" <<EOF
tcp_host=127.0.0.1
tcp_port=$PORT
server_mode=systemd-system
bridge_path=$BIN/bridge
client_path=$BIN/xemonitor
log_path=$CFG_DIR/xemonitor.log
auto_start=true
tray_enabled=true
EOF

# 5. Inicia o bridge via systemd de SISTEMA (root). Se ja estiver ativo,
#    usa o que esta rodando (evita prompt pkexec desnecessario). Reinicia
#    (pkexec) somente quando o binario foi recompilado e o servico esta parado.
if systemctl is-active --quiet xemonitor-bridge; then
    echo "[OK] Bridge ja esta ativo (servico systemd xemonitor-bridge)."
else
    if command -v pkexec >/dev/null 2>&1; then
        pkexec systemctl start xemonitor-bridge
    else
        echo "[INFO] Iniciando bridge como root (pede senha)..."
        sudo systemctl start xemonitor-bridge
    fi
fi
echo -n "[INFO] aguardando porta $PORT..."
for i in $(seq 1 30); do
    if ss -tln 2>/dev/null | grep -q ":$PORT"; then
        echo " ok"
        break
    fi
    [ "$i" = 30 ] && echo " FALHOU (bridge nao subiu a porta $PORT em 30s)." && exit 1
    sleep 1
done
sleep 1
if systemctl is-active --quiet xemonitor-bridge; then
    echo "[OK] Bridge rodando (systemd system, root)."
else
    echo "[AVISO] Bridge pode estar aguardando /dev/ttyUSB0."
fi

# 5b. Probe TCP: confirma que o servidor aceita conexao (antes de abrir o GUI)
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "
import socket
try:
    s = socket.create_connection(('127.0.0.1', $PORT), timeout=2)
    s.close()
    print('ok')
except OSError as e:
    print('fail')
" | grep -q ok; then
        echo "[OK] Bridge aceita conexoes TCP na porta $PORT."
    else
        echo "[AVISO] Nao foi possivel conectar na porta $PORT (cliente tentara reconectar)."
    fi
else
    echo "[INFO] python3 ausente; pulando probe TCP."
fi

# 6. Abre o GUI (icone na bandeja; fechar a janela esconde p/ bandeja)
cd "$REPO_DIR"
echo "[OK] Abrindo xemonitor-gui. 'Sair' no menu da bandeja encerra."
echo
exec "$BIN/xemonitor-gui"
