#!/usr/bin/env bash
# XeMonitor — status no Linux host (espelho do status_bridge.bat).
# Uso: ./status_xemonitor.sh
echo "========================================"
echo " Status do XeMonitor (Linux host)"
echo "========================================"
echo

CFG_DIR="${XEMONITOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/xemonitor}"

echo "--- Pasta central de config/log ---"
echo "    $CFG_DIR"
if [ -d "$CFG_DIR" ]; then
    for f in xemonitor-gui.conf xemonitor-gui.pid xemonitor.pid xemonitor.log; do
        if [ -f "$CFG_DIR/$f" ]; then
            printf "    [OK] %-20s %8s bytes\n" "$f" "$(stat -c %s "$CFG_DIR/$f" 2>/dev/null || echo '?')"
        fi
    done
    echo "    --- ultimas linhas do log (xemonitor.log) ---"
    tail -n 5 "$CFG_DIR/xemonitor.log" 2>/dev/null || echo "    (log ainda nao criado)"
else
    echo "    [AVISO] pasta de config ainda nao existe (roda ./run_xemonitor.sh)."
fi
echo

echo "--- Servico systemd (sistema/root) 'xemonitor-bridge' ---"
systemctl status xemonitor-bridge --no-pager 2>&1 | grep -E "Loaded|Active|Main PID|CGroup" || true
echo

echo "--- xemonitor-gui ---"
if pgrep -x xemonitor-gui >/dev/null 2>&1; then
    echo "[OK] xemonitor-gui rodando."
else
    echo "[OFF] xemonitor-gui nao esta rodando."
fi
echo

echo "--- cliente (xemonitor --tcp) ---"
if pgrep -x xemonitor >/dev/null 2>&1; then
    echo "[OK] cliente conectando."
else
    echo "[OFF] cliente nao esta rodando."
fi
echo

echo "--- /dev/ttyUSB0 ---"
ls -la /dev/ttyUSB0 2>&1
echo

echo "--- grupos de acesso serial ---"
if id -nG | tr ' ' '\n' | grep -qE "uucp|dialout"; then
    echo "[OK] grupo uucp/dialout presente."
else
    echo "[AVISO] usuario nao esta em uucp/dialout (relogin ou 'sg uucp')."
fi
