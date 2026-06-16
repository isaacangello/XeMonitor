#!/bin/bash
# Setup WSL2 for XeMonitor bridge — run once: bash setup_wsl.sh

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

echo "[setup] Done! /dev/ttyUSB0 is now accessible."
ls -la /dev/ttyUSB0
