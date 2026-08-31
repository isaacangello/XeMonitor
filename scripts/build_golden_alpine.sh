#!/bin/sh
# ============================================================
# build_golden_alpine.sh - Configura um Alpine minirootfs como
# "golden image" do XeMonitor (rodar DENTRO da distro alvo).
#
# Prepara: openrc/kmod/eudev + udev rule CH340 + /etc/wsl.conf
#          + init script do bridge + bridge binario + rc-update.
# Apos rodar, o host exporta a distro via: wsl --export <d> -
#
# Uso (dentro da distro):
#   sh /mnt/.../build_golden_alpine.sh /mnt/.../bridge /mnt/.../init
#     $1 = caminho do binario 'bridge' (musl estatico)
#     $2 = caminho do init script openrc/xemonitor-bridge
# ============================================================
set -e

BRIDGE_SRC="${1:-/mnt/c/XeMonitor/XeMonitor/zig-out/bin/bridge}"
INIT_SRC="${2:-/mnt/c/XeMonitor/XeMonitor/openrc/xemonitor-bridge}"

echo '[golden] apk update + deps (openrc kmod eudev)...'
apk update
apk add --no-cache openrc kmod eudev

echo '[golden] /run/openrc/softlevel...'
mkdir -p /run/openrc
touch /run/openrc/softlevel

echo '[golden] udev rule CH340...'
mkdir -p /etc/udev/rules.d
echo 'SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE=="0666"' > /etc/udev/rules.d/99-ch340.rules

echo '[golden] /etc/wsl.conf (modulos usbip/vhci/ch341 no boot)...'
printf '[boot]\ncommand = /sbin/modprobe usbip-core && /sbin/modprobe vhci-hcd && /sbin/modprobe ch341\n' > /etc/wsl.conf

echo '[golden] bridge binario...'
mkdir -p /usr/local/bin
cp "$BRIDGE_SRC" /usr/local/bin/xemonitor-bridge
chmod 755 /usr/local/bin/xemonitor-bridge

echo '[golden] init script openrc (forcar LF - CRLF quebra o shebang)...'
# Arquivos .bat/.md podem vir com CRLF; um shebang com \r final faz o kernel
# falhar 'No such file or directory' ao executar o init. Normalizar para LF.
sed -e 's/\r$//' "$INIT_SRC" > /etc/init.d/xemonitor-bridge
chmod 755 /etc/init.d/xemonitor-bridge

echo '[golden] habilitando servico...'
rc-update add xemonitor-bridge default

echo '[golden] modulos (best-effort)...'
modprobe usbip-core 2>/dev/null || true
modprobe vhci-hcd 2>/dev/null || true
modprobe ch341 2>/dev/null || true
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

echo '[golden] OK: configuracao concluida.'
