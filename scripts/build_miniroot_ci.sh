#!/bin/bash
# ============================================================
# build_miniroot_ci.sh - Variante do build_miniroot.sh para
# ambiente CI Linux (sem WSL). Usa Docker (Alpine container)
# para gerar o miniroot pre-configurado com o bridge.
#
# Uso:
#   bash scripts/build_miniroot_ci.sh \
#     --bridge-version 0.8.0 --bridge-build 001 \
#     --bridge zig-out/bin/bridge \
#     --init   openrc/xemonitor-bridge \
#     --out-dir packaging/windows/miniroots
#
# Requisitos: docker (rootless OK), alpine:3.24 ou similar
# ============================================================
set -e

BRIDGE_VERSION=""
BRIDGE_BUILD=""
BRIDGE_SRC=""
INIT_SRC=""
OUT_DIR="packaging/windows/miniroots"
ALPINE_IMAGE="alpine:3.24"

while [ $# -gt 0 ]; do
    case "$1" in
        --bridge-version) BRIDGE_VERSION="$2"; shift 2 ;;
        --bridge-build)   BRIDGE_BUILD="$2";   shift 2 ;;
        --bridge)         BRIDGE_SRC="$2";     shift 2 ;;
        --init)           INIT_SRC="$2";       shift 2 ;;
        --out-dir)        OUT_DIR="$2";        shift 2 ;;
        --alpine-image)   ALPINE_IMAGE="$2";   shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "[miniroot-ci] argumento desconhecido: $1" >&2; exit 1 ;;
    esac
done

[ -n "$BRIDGE_VERSION" ] || { echo "[miniroot-ci] --bridge-version obrigatorio" >&2; exit 1; }
[ -n "$BRIDGE_BUILD"   ] || { echo "[miniroot-ci] --bridge-build obrigatorio"   >&2; exit 1; }
[ -n "$BRIDGE_SRC"     ] || { echo "[miniroot-ci] --bridge obrigatorio"          >&2; exit 1; }
[ -n "$INIT_SRC"       ] || { echo "[miniroot-ci] --init obrigatorio"            >&2; exit 1; }
[ -f "$BRIDGE_SRC"   ] || { echo "[miniroot-ci] bridge nao encontrado: $BRIDGE_SRC" >&2; exit 1; }
[ -f "$INIT_SRC"     ] || { echo "[miniroot-ci] init nao encontrado: $INIT_SRC"     >&2; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "[miniroot-ci] docker nao encontrado" >&2; exit 1; }

TARBALL_NAME="alpine-bridge-${BRIDGE_VERSION}.${BRIDGE_BUILD}-x86_64.tar.gz"
TARBALL_PATH="${OUT_DIR}/${TARBALL_NAME}"
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "[miniroot-ci] === build $TARBALL_NAME ==="

# Container efemero Alpine
CONTAINER="xem-miniroot-${BRIDGE_VERSION}-${BRIDGE_BUILD}"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

echo "[miniroot-ci] subindo $ALPINE_IMAGE..."
docker run --name "$CONTAINER" --rm -d "$ALPINE_IMAGE" sleep infinity >/dev/null
trap "docker rm -f $CONTAINER >/dev/null 2>&1 || true; rm -rf $WORK_DIR" EXIT

echo "[miniroot-ci] apk update + deps..."
docker exec "$CONTAINER" sh -c "apk update && apk add --no-cache openrc kmod eudev"

# Diretorio temporario no container para o bridge e init
docker exec "$CONTAINER" mkdir -p /tmp/xem

# Copia arquivos do host para o container
docker cp "$BRIDGE_SRC" "$CONTAINER:/tmp/xem/bridge"
docker cp "$INIT_SRC" "$CONTAINER:/tmp/xem/xemonitor-bridge"

# Configura o Alpine dentro do container
docker exec "$CONTAINER" sh -c '
set -e
mkdir -p /run/openrc
touch /run/openrc/softlevel
mkdir -p /etc/udev/rules.d
echo "SUBSYSTEM==\"tty\", ATTRS{idVendor}==\"1a86\", ATTRS{idProduct}==\"7523\", MODE==\"0666\"" > /etc/udev/rules.d/99-ch340.rules
printf "[boot]\ncommand = /sbin/modprobe usbip-core && /sbin/modprobe vhci-hcd && /sbin/modprobe ch341\n" > /etc/wsl.conf
mkdir -p /usr/local/bin
cp /tmp/xem/bridge /usr/local/bin/xemonitor-bridge
chmod 755 /usr/local/bin/xemonitor-bridge
sed -e "s/\r$//" /tmp/xem/xemonitor-bridge > /etc/init.d/xemonitor-bridge
chmod 755 /etc/init.d/xemonitor-bridge
rc-update add xemonitor-bridge default
modprobe usb-core 2>/dev/null || true
modprobe ch341 2>/dev/null || true
modprobe usbserial 2>/dev/null || true
rc-service xemonitor-bridge start
sleep 3
if netstat -tln 2>/dev/null | grep -q ":9000"; then
    echo "OK: bridge na porta 9000"
else
    echo "AVISO: porta 9000 nao ouvindo (sem device)"
fi
rc-service xemonitor-bridge stop
'

# Exporta o filesystem do container como tarball
echo "[miniroot-ci] exportando $TARBALL_PATH..."
mkdir -p "$OUT_DIR"
docker export "$CONTAINER" > "$TARBALL_PATH"
docker rm -f "$CONTAINER" >/dev/null 2>&1

SIZE=$(stat -c '%s' "$TARBALL_PATH" 2>/dev/null || stat -f '%z' "$TARBALL_PATH" 2>/dev/null)
SIZE_MB=$(echo "scale=1; $SIZE / 1048576" | bc 2>/dev/null || echo "?")
echo "[miniroot-ci] OK: $TARBALL_NAME gerado (${SIZE_MB} MB)"

# Rolling 10
echo "[miniroot-ci] aplicando rolling 10..."
COUNT=0
for f in $(ls -1t "$OUT_DIR"/alpine-bridge-*.tar.gz 2>/dev/null | grep -v "alpine-bridge-current"); do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -gt 10 ]; then
        echo "[miniroot-ci] removendo (rolling 10): $(basename "$f")"
        rm -f "$f"
    fi
done

echo "[miniroot-ci] === $TARBALL_NAME concluido ==="
