#!/usr/bin/env bash
# XeMonitor — diagnóstico / auto-recuperação no Linux host.
#
# Uso:
#   ./diagnose_xemonitor.sh                # --check (padrão)
#   ./diagnose_xemonitor.sh --check
#   ./diagnose_xemonitor.sh --fix          # mata instâncias velhas e reinicia o bridge
#   ./diagnose_xemonitor.sh --test-serial  # teste live da serial (para o bridge temporariamente)
#   ./diagnose_xemonitor.sh --help
#
# Cada camada é verificada e reportada com PASS/FAIL + correção sugerida.
# Exit code: 0 = tudo OK; 1 = algum problema encontrado.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$REPO_DIR/zig-out/bin"
SERIAL="/dev/ttyUSB0"
PORT=9000
CFG_DIR="${XEMONITOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/xemonitor}"
# Log rotativo por data (xemonitor-YYYY-MM-DD.log); fallback p/ legado.
LOG="$CFG_DIR/xemonitor-$(date +%Y-%m-%d).log"
[ -f "$LOG" ] || LOG="$CFG_DIR/xemonitor.log"
MODE="check"
FAIL=0

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

# report <nivel> <msg>   — nível: OK | OFF | AVISO | ERRO | INFO
report() {
    local nivel="$1"
    shift
    case "$nivel" in
        OK)    printf '[OK]    %s\n' "$*" ;;
        OFF)   printf '[OFF]   %s\n' "$*"; FAIL=1 ;;
        AVISO) printf '[AVISO] %s\n' "$*" ;;
        ERRO)  printf '[ERRO]  %s\n' "$*"; FAIL=1 ;;
        INFO)  printf '[INFO]  %s\n' "$*" ;;
    esac
}

check_device() {
    echo "--- /dev/ttyUSB0 (CH340) ---"
    if [ ! -e "$SERIAL" ]; then
        report ERRO "$SERIAL não existe. Conecte o scanner (CH340) e confira: lsusb | grep -i ch340"
        return
    fi
    if [ -c "$SERIAL" ]; then
        report OK "$SERIAL é device char, presente."
    else
        report ERRO "$SERIAL não é device char (estranho)."
        return
    fi
    if [ -w "$SERIAL" ]; then
        report OK "gravável pelo usuário (permissões ok)."
    else
        report AVISO "sem permissão de escrita (veja grupos abaixo / regra udev 99-ch340.rules)."
    fi
    ls -la "$SERIAL"
    echo
}

check_groups() {
    echo "--- grupos de acesso serial ---"
    if id -nG | tr ' ' '\n' | grep -qE "uucp|dialout"; then
        report OK "usuário em uucp/dialout."
    else
        report AVISO "usuário não está em uucp/dialout (relogin ou 'sg uucp -c ...')."
    fi
    echo
}

check_bridge() {
    echo "--- serviço systemd 'xemonitor-bridge' (sistema) ---"
    if ! systemctl cat xemonitor-bridge >/dev/null 2>&1; then
        report ERRO "unit não existe. Instale via install.sh (systemd system) ou ./run_xemonitor.sh."
        echo
        return
    fi
    if systemctl is-active --quiet xemonitor-bridge; then
        report OK "unit active."
    else
        report ERRO "unit não está active (status: $(systemctl is-active xemonitor-bridge))."
        report INFO "Correção: pkexec systemctl restart xemonitor-bridge"
        echo
        return
    fi
    local pid
    pid="$(systemctl show -p MainPID --value xemonitor-bridge)"
    if [ "$pid" = "0" ] || [ ! -d "/proc/$pid" ]; then
        report ERRO "MainPID=$pid inválido."
        return
    fi
    report OK "MainPID=$pid."
    if grep -q "$BIN/bridge" /proc/"$pid"/cmdline 2>/dev/null || grep -q "xemonitor-bridge" /proc/"$pid"/cmdline 2>/dev/null; then
        report OK "processo é o bridge."
    else
        report AVISO "PID $pid não é o bridge (cmdline: $(tr '\0' ' ' < /proc/"$pid"/cmdline 2>/dev/null))."
    fi
    echo
}

check_port() {
    echo "--- porta TCP $PORT ---"
    if ! ss -tln 2>/dev/null | grep -q ":$PORT"; then
        report ERRO "porta $PORT não está escutando."
        report INFO "Correção: systemctl --user restart xemonitor-bridge"
        echo
        return
    fi
    report OK "porta $PORT escutando."
    local pid bridge_pid
    pid="$(ss -tlnp 2>/dev/null | grep ":$PORT" | sed -E 's/.*pid=([0-9]+).*/\1/' | head -1)"
    bridge_pid="$(systemctl show -p MainPID --value xemonitor-bridge 2>/dev/null)"
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -d "/proc/$pid" ]; then
        if grep -q "$BIN/bridge" "/proc/$pid/cmdline" 2>/dev/null || grep -q "xemonitor-bridge" "/proc/$pid/cmdline" 2>/dev/null; then
            report OK "dono da porta é o nosso bridge (PID $pid)."
        else
            report ERRO "porta $PORT ocupada por outro processo (PID $pid)."
            report INFO "Correção: sudo kill $pid  (se for um xemonitor-bridge antigo/root)"
        fi
    elif [ -n "$bridge_pid" ] && [ "$bridge_pid" != "0" ]; then
        report OK "porta ativa; dono não exibido pelo ss (wrapper 'sg uucp'), bridge MainPID=$bridge_pid."
    else
        report ERRO "porta $PORT escutando, mas sem bridge ativo e dono não identificado."
        report INFO "Identifique: sudo ss -tlnp | grep :$PORT"
    fi
    echo
}

check_client() {
    echo "--- cliente (xemonitor --tcp) ---"
    local pids n
    pids="$(pgrep -x xemonitor 2>/dev/null)"
    n="$(printf '%s\n' "$pids" | grep -c . 2>/dev/null || echo 0)"
    if [ -z "$pids" ]; then
        report OFF "cliente não está rodando. Correção: ./run_xemonitor.sh"
        echo
        return
    fi
    if [ "$n" -gt 1 ]; then
        report AVISO "$n instâncias de xemonitor rodando (esperado 1): $pids"
        report INFO "Correção: pkill -x xemonitor  e reinicie via GUI/run_xemonitor.sh"
    else
        report OK "1 instância rodando (PID $pids)."
    fi
    if ss -tn 2>/dev/null | grep ESTAB | grep -q ":${PORT}"; then
        report OK "há conexão ESTAB em :$PORT."
    else
        report AVISO "cliente rodando, mas sem conexão ESTAB em :$PORT (reconecta a cada 2s)."
    fi
    echo
}

check_gui() {
    echo "--- xemonitor-gui ---"
    local n
    n="$(pgrep -x xemonitor-gui 2>/dev/null | wc -l)"
    if [ "$n" -eq 0 ]; then
        report OFF "xemonitor-gui não está rodando."
    elif [ "$n" -eq 1 ]; then
        report OK "1 instância rodando."
    else
        report AVISO "$n instâncias de xemonitor-gui (esperado 1)."
        report INFO "Correção: pkill -x xemonitor-gui  e reinicie."
    fi
    echo
}

check_injector() {
    echo "--- injetor de teclado (uinput / ydotool) ---"
    if [ -e /dev/uinput ]; then
        report OK "/dev/uinput presente (injetor nativo)."
    else
        report AVISO "/dev/uinput ausente — injetor nativo indisponível (fallback ydotool/xdotool)."
    fi
    if command -v ydotool >/dev/null 2>&1; then
        report OK "ydotool instalado (fallback Wayland)."
        if systemctl is-active --quiet ydotool 2>/dev/null || systemctl --user is-active --quiet ydotool 2>/dev/null; then
            report OK "serviço ydotool active."
        else
            report AVISO "serviço ydotool não active. Correção: systemctl --user enable --now ydotool"
        fi
        if ss -x 2>/dev/null | grep -q ydotool_socket; then
            report OK "socket .ydotool_socket escutando."
        else
            report AVISO "socket .ydotool_socket não encontrado (daemon pode estar com outro caminho)."
        fi
    else
        report AVISO "ydotool não instalado (fallback Wayland ausente)."
    fi
    if command -v xdotool >/dev/null 2>&1; then
        report OK "xdotool instalado (fallback X11)."
    else
        report AVISO "xdotool não instalado (fallback X11 ausente)."
    fi
    echo
}

check_log() {
    echo "--- log (xemonitor-$(date +%Y-%m-%d).log, último scan) ---"
    if [ ! -f "$LOG" ]; then
        report AVISO "log não existe ainda ($LOG)."
        echo
        return
    fi
    local last
    last="$(grep -E "\[scan\]" "$LOG" 2>/dev/null | tail -1)"
    if [ -n "$last" ]; then
        report OK "último scan: $last"
        report INFO "log modificado em: $(stat -c '%y' "$LOG" | cut -d. -f1)"
    else
        report AVISO "nenhum [scan] registrado ainda."
    fi
    echo
}

do_fix() {
    echo "========================================"
    echo " Aplicando correções (--fix)"
    echo "========================================"
    echo
    pkill -TERM -x xemonitor-gui 2>/dev/null
    pkill -TERM -x xemonitor 2>/dev/null
    sleep 1
    pkill -KILL -x xemonitor-gui 2>/dev/null
    pkill -KILL -x xemonitor 2>/dev/null
    echo "[INFO] instâncias antigas de xemonitor-gui/xemonitor encerradas."
    echo
    echo "[INFO] reiniciando xemonitor-bridge..."
    pkexec systemctl restart xemonitor-bridge
    echo -n "[INFO] aguardando porta $PORT..."
    local i
    for i in $(seq 1 30); do
        if ss -tln 2>/dev/null | grep -q ":$PORT"; then
            echo " ok"
            break
        fi
        [ "$i" = 30 ] && { echo; report ERRO "porta $PORT não subiu após 30s."; }
        sleep 1
    done
    echo
    echo "[INFO] Diagnóstico pós-fix:"
    do_check
    echo
    echo "Para subir GUI + cliente: ./run_xemonitor.sh"
}

do_test_serial() {
    echo "========================================"
    echo " Teste live da serial (--test-serial)"
    echo "========================================"
    echo
    if [ ! -e "$SERIAL" ]; then
        report ERRO "$SERIAL não existe."
        exit 1
    fi
    echo "[INFO] parando o bridge temporariamente para liberar $SERIAL..."
    pkexec systemctl stop xemonitor-bridge
    echo "[INFO] lendo $SERIAL por 8s. DISPARE O SCANNER AGORA (ou digite no terminal)."
    echo "------------------------------------------------------------"
    output="$(timeout 8 cat "$SERIAL" 2>&1 || true)"
    echo "------------------------------------------------------------"
    pkexec systemctl start xemonitor-bridge
    if [ -n "$output" ]; then
        echo "[OK] bytes recebidos:"
        printf '%s\n' "$output" | sed 's/^/     /'
        report OK "hardware + serial OK (bytes chegaram)."
    else
        report ERRO "nenhum byte em 8s. Verifique: scanner ligado? gatilho dispara laser? CH340 recém-reconectado?"
        report INFO "Tente desconectar/reconectar o cabo USB do scanner (CH340) e repetir o teste."
    fi
}

do_check() {
    echo "========================================"
    echo " Diagnóstico do XeMonitor ($(date '+%F %T'))"
    echo "========================================"
    echo
    check_device
    check_groups
    check_bridge
    check_port
    check_client
    check_gui
    check_injector
    check_log
    if [ "$FAIL" -eq 0 ]; then
        echo "========================================"
        echo " TUDO OK. (Escaneie e confira o editor focado.)"
        echo "========================================"
    else
        echo "========================================"
        echo " PROBLEMAS/LAYERS FORA. Corrija ou rode: ./diagnose_xemonitor.sh --fix e depois ./run_xemonitor.sh"
        echo "========================================"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) MODE="check"; shift ;;
        --fix) MODE="fix"; shift ;;
        --test-serial) MODE="test-serial"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

case "$MODE" in
    check) do_check ;;
    fix) do_fix ;;
    test-serial) do_test_serial ;;
esac

exit "$FAIL"
