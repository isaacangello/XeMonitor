#!/bin/sh
# Setup WSL2 for XeMonitor bridge — run once: sh setup_wsl.sh
# Configura udev, modulos do kernel (usbip) e wsl.conf.
# Detecta a distro: Alpine (OpenRC) vs Arch/CachyOS (systemd).
#
# Alpine  (padrao, menor footprint): apk add eudev kmod openrc; rc-update add udev
# Arch    (fallback): systemd ja ativo; udev embutido
set -e

# ---- Detecta distro ----
if [ -f /etc/alpine-release ]; then
    DISTRO="alpine"
elif command -v pacman >/dev/null 2>&1; then
    DISTRO="arch"
else
    DISTRO="generic"
fi
echo "[setup] Distro detectada: $DISTRO"

# ---- Instala dependencias (Alpine) ----
if [ "$DISTRO" = "alpine" ]; then
    echo "[setup] Instalando eudev, kmod e openrc (Alpine)..."
    apk add --no-cache eudev kmod openrc 2>/dev/null || {
        echo "[setup] AVISO: falha ao instalar pacotes (sem rede?). Seguindo mesmo assim."
    }
fi

# ---- Regra udev do CH340 (0666 p/ leitura sem grupo extra) ----
echo "[setup] Creating udev rule for CH340..."
if [ -d /etc/udev/rules.d ]; then
    tee /etc/udev/rules.d/99-ch340.rules > /dev/null <<'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"
EOF
else
    mkdir -p /etc/udev/rules.d
    tee /etc/udev/rules.d/99-ch340.rules > /dev/null <<'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666"
EOF
fi

echo "[setup] Reloading udev rules..."
if command -v udevadm >/dev/null 2>&1; then
    # No WSL o daemon udev pode nao estar rodando; timeout evita travar.
    timeout 10 udevadm control --reload-rules 2>/dev/null || true
    timeout 10 udevadm trigger 2>/dev/null || true
fi

# ---- Habilita udev no boot (Alpine/OpenRC) ----
if [ "$DISTRO" = "alpine" ] && command -v rc-update >/dev/null 2>&1; then
    echo "[setup] Habilitando udev no runlevel default (OpenRC)..."
    rc-update add udev default 2>/dev/null || true
    rc-update add udev-trigger default 2>/dev/null || true
fi

echo "[setup] Setting permissions on /dev/ttyUSB0..."
chmod 666 /dev/ttyUSB0 2>/dev/null || true

# ---- OpenRC em WSL/container: sem isso o rc-service recusa operar ----
# (no WSL o OpenRC nao e o init real; softlevel sinaliza "boot aberto").
if [ "$DISTRO" = "alpine" ]; then
    mkdir -p /run/openrc
    touch /run/openrc/softlevel
    echo "[setup] OpenRC softlevel criado (modo WSL/container)."
fi

# ---- Configura wsl.conf para carregar modulos usbip no boot ----
# [boot] command roda como root no boot do WSL, antes de qualquer sessao.
# NAO usa systemd=true: no Alpine o init e OpenRC (systemd=false/missing e ok).
WSL_CONF="/etc/wsl.conf"
BOOT_CMD='/sbin/modprobe usbip-core && /sbin/modprobe vhci-hcd'

if [ -f "$WSL_CONF" ] && grep -q "usbip-core\|vhci-hcd" "$WSL_CONF" 2>/dev/null; then
    echo "[setup] wsl.conf ja configurado para usbip."
else
    echo "[setup] Configurando wsl.conf para carregar modulos usbip..."
    # Garante a secao [boot] com command
    if [ -f "$WSL_CONF" ] && grep -q "^\[boot\]" "$WSL_CONF" 2>/dev/null; then
        if ! grep -q "^command" "$WSL_CONF" 2>/dev/null; then
            sed -i '/^\[boot\]/a command = /sbin/modprobe usbip-core \&\& /sbin/modprobe vhci-hcd' "$WSL_CONF"
        else
            # Ja tem command, faz append dos modulos (evita duplicar)
            sed -i 's/^command = \(.*\)/command = \1 \&\& \/sbin\/modprobe usbip-core \&\& \/sbin\/modprobe vhci-hcd/' "$WSL_CONF"
        fi
    else
        # Cria wsl.conf com [boot] + command. Alpine: sem systemd=true
        if [ "$DISTRO" = "alpine" ]; then
            printf '[boot]\ncommand = %s\n' "$BOOT_CMD" | tee "$WSL_CONF" > /dev/null
        else
            printf '[boot]\nsystemd=true\ncommand = %s\n' "$BOOT_CMD" | tee "$WSL_CONF" > /dev/null
        fi
    fi
    echo "[setup] wsl.conf atualizado:"
    cat "$WSL_CONF"
fi

# ---- Passwordless sudo para modprobe (opcional, facilita reload manual) ----
# Alpine usa doas; Arch usa sudo. Mantem compatibilidade com ambos.
if [ -d /etc/sudoers.d ] && command -v sudo >/dev/null 2>&1; then
    SUDOERS_FILE="/etc/sudoers.d/modprobe-usbip"
    if [ ! -f "$SUDOERS_FILE" ]; then
        echo "[setup] Configurando passwordless sudo para modprobe..."
        CURRENT_USER="${SUDO_USER:-$(id -un 2>/dev/null || echo user)}"
        echo "$CURRENT_USER ALL=(ALL) NOPASSWD: /sbin/modprobe" > "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
    fi
elif command -v doas >/dev/null 2>&1; then
    # Alpine: allowgroup wheel p/ doas (best-effort)
    if [ ! -f /etc/doas.d/doas.conf ]; then
        echo "[setup] Configurando doas (permit wheel)..."
        mkdir -p /etc/doas.d
        echo "permit persist :wheel" > /etc/doas.d/doas.conf
        chmod 440 /etc/doas.d/doas.conf
    fi
fi

echo "[setup] Done! /dev/ttyUSB0 deve aparecer apos attach via setup_usb.bat"
echo "[setup] Recomendado: reinicie o WSL com 'wsl --shutdown' (no Windows)"
ls -la /dev/ttyUSB0 2>/dev/null || echo "[setup] (aguarde o attach via usbipd para ver /dev/ttyUSB0)"
