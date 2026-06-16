#!/bin/bash
# Setup WSL2 for XeMonitor bridge — run once: bash setup_wsl.sh
# Configura udev, modulos do kernel (usbip), e wsl.conf

set -e

echo "[setup] Creating udev rule for CH340..."
sudo tee /etc/udev/rules.d/99-ch340.rules > /dev/null <<'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"
EOF

echo "[setup] Reloading udev rules..."
sudo udevadm control --reload-rules
sudo udevadm trigger

echo "[setup] Setting permissions on /dev/ttyUSB0..."
sudo chmod 666 /dev/ttyUSB0 2>/dev/null || true

# ---- Configura wsl.conf para carregar modulos usbip no boot ----
WSL_CONF="/etc/wsl.conf"
if [ -f "$WSL_CONF" ] && grep -q "usbip-core\|vhci-hcd" "$WSL_CONF" 2>/dev/null; then
    echo "[setup] wsl.conf ja configurado para usbip."
else
    echo "[setup] Configurando wsl.conf para carregar modulos usbip..."
    # Garante que a secao [boot] existe com command
    if [ -f "$WSL_CONF" ] && grep -q "^\[boot\]" "$WSL_CONF" 2>/dev/null; then
        # Ja tem [boot], adiciona command se nao existir
        if ! grep -q "^command" "$WSL_CONF" 2>/dev/null; then
            sudo sed -i '/^\[boot\]/a command = \/sbin\/modprobe usbip-core \&\& \/sbin\/modprobe vhci-hcd' "$WSL_CONF"
        else
            # Ja tem command, faz append dos modulos
            sudo sed -i 's/^command = \(.*\)/command = \1 \&\& \/sbin\/modprobe usbip-core \&\& \/sbin\/modprobe vhci-hcd/' "$WSL_CONF"
        fi
    else
        # Cria wsl.conf com [boot] + command
        printf '[boot]\nsystemd=true\ncommand = /sbin/modprobe usbip-core \&\& /sbin/modprobe vhci-hcd\n' | sudo tee "$WSL_CONF" > /dev/null
    fi
    echo "[setup] wsl.conf atualizado:"
    cat "$WSL_CONF"
fi

# ---- Passwordless sudo para modprobe (opcional, facilita reload manual) ----
SUDOERS_FILE="/etc/sudoers.d/modprobe-usbip"
if [ ! -f "$SUDOERS_FILE" ]; then
    echo "[setup] Configurando passwordless sudo para modprobe..."
    echo "$USER ALL=(ALL) NOPASSWD: /sbin/modprobe" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
fi

echo "[setup] Done! /dev/ttyUSB0 deve aparecer apos attach via setup_usb.bat"
echo "[setup] Recomendado: reinicie o WSL com 'wsl --shutdown' (no Windows)"
ls -la /dev/ttyUSB0 2>/dev/null || echo "[setup] (aguarde o attach via usbipd para ver /dev/ttyUSB0)"
