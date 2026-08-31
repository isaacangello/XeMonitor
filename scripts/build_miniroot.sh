#!/bin/sh
# ============================================================
# build_miniroot.sh - Orquestra a geracao de um miniroot Alpine
# pre-configurado com o bridge para a versao/compilacao atual.
#
# Requisitos: Alpine 3.24+ ja roda 'sh' como POSIX. Nao requer bash.
# O script usa 'wsl' (assume que esta sendo rodado dentro do $WSL_EXE ou
# em um Linux com $WSL_EXE instalado - WSL2 e o ambiente alvo primario).
#
# Fluxo:
#   1) Importa alpine-minirootfs em distro temporaria
#      (XeMonitor-Miniroot-<bridge_version>-<bridge_build>)
#   2) Roda build_golden_alpine.sh DENTRO da distro (apk deps,
#      udev, wsl.conf, init, bridge)
#   3) Valida: rc-service xemonitor-bridge start + porta 9000
#   4) Exporta como tarball em
#      packaging/windows/miniroots/alpine-bridge-<version>.<build>-x86_64.tar.gz
#   5) Aplica rolling 10: apaga os mais antigos alem de 10
#   6) Limpa distro temporaria + VHD residual
#
# Uso (a partir da raiz do repo, em WSL/Linux):
#   bash scripts/build_miniroot.sh \
#     --bridge-version 0.8.0 --bridge-build 003 \
#     --bridge /mnt/c/XeMonitor/XeMonitor/zig-out/bin/bridge \
#     --init   /mnt/c/XeMonitor/XeMonitor/openrc/xemonitor-bridge \
#     --minirootfs /mnt/c/XeMonitor/alpine-minirootfs.tar.gz
#
# Parametros obrigatorios: --bridge-version, --bridge-build,
#                         --bridge, --init
# Opcional: --minirootfs (default /mnt/c/XeMonitor/alpine-minirootfs.tar.gz)
#           --out-dir (default packaging/windows/miniroots relativo ao CWD)
#           --keep (nao apaga a distro temporaria apos exportar; debug)
# ============================================================
set -e

BRIDGE_VERSION=""
BRIDGE_BUILD=""
BRIDGE_SRC=""
INIT_SRC=""
MINIROOTFS="/mnt/c/XeMonitor/alpine-minirootfs.tar.gz"
OUT_DIR="packaging/windows/miniroots"
KEEP=0

# Auto-detecta o binario wsl.exe. Dentro do proprio $WSL_EXE (Alpine):
#   /mnt/c/WINDOWS/system32/wsl.exe
# Em Linux nativo com $WSL_EXE instalado:
#   /usr/bin/wsl
# Em qualquer caso o usuario pode forcar via env WSL_EXE.
if [ -z "$WSL_EXE" ]; then
    # Tentar varios paths comuns (Windows e WSL nativo)
    for p in \
        /mnt/c/Windows/System32/wsl.exe \
        /mnt/c/Windows/system32/wsl.exe \
        /mnt/c/WINDOWS/system32/wsl.exe \
        /usr/bin/wsl \
        /usr/local/bin/wsl
    do
        if [ -x "$p" ]; then
            WSL_EXE="$p"
            break
        fi
    done
    if [ -z "$WSL_EXE" ]; then
        if command -v wsl >/dev/null 2>&1; then
            WSL_EXE=$(command -v wsl)
        else
            echo "[miniroot] ERRO: wsl.exe nao encontrado. Defina WSL_EXE=/path/to/wsl" >&2
            exit 1
        fi
    fi
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --bridge-version) BRIDGE_VERSION="$2"; shift 2 ;;
        --bridge-build)   BRIDGE_BUILD="$2";   shift 2 ;;
        --bridge)         BRIDGE_SRC="$2";     shift 2 ;;
        --init)           INIT_SRC="$2";       shift 2 ;;
        --minirootfs)     MINIROOTFS="$2";     shift 2 ;;
        --out-dir)        OUT_DIR="$2";        shift 2 ;;
        --keep)           KEEP=1;              shift   ;;
        -h|--help)
            sed -n '2,32p' "$0"
            exit 0
            ;;
        *)
            echo "[miniroot] argumento desconhecido: $1" >&2
            exit 1
            ;;
    esac
done

# ---- Validacoes ----
[ -n "$BRIDGE_VERSION" ] || { echo "[miniroot] --bridge-version obrigatorio" >&2; exit 1; }
[ -n "$BRIDGE_BUILD"   ] || { echo "[miniroot] --bridge-build obrigatorio"   >&2; exit 1; }
[ -n "$BRIDGE_SRC"     ] || { echo "[miniroot] --bridge obrigatorio"          >&2; exit 1; }
[ -n "$INIT_SRC"       ] || { echo "[miniroot] --init obrigatorio"            >&2; exit 1; }
[ -f "$BRIDGE_SRC"   ] || { echo "[miniroot] bridge nao encontrado: $BRIDGE_SRC" >&2; exit 1; }
[ -f "$INIT_SRC"     ] || { echo "[miniroot] init nao encontrado: $INIT_SRC"     >&2; exit 1; }
[ -f "$MINIROOTFS"   ] || { echo "[miniroot] minirootfs nao encontrado: $MINIROOTFS" >&2; exit 1; }
# wsl --import aceita path WSL (/mnt/c/...) para o tarball de entrada.
# Apenas o VHD de saida precisa ser convertido para formato Windows
# (com forward slashes, que wsl.exe aceita e nao colide com escape do shell).

DISTRO="XeMonitor-Miniroot-${BRIDGE_VERSION}-${BRIDGE_BUILD}"
TARBALL_NAME="alpine-bridge-${BRIDGE_VERSION}.${BRIDGE_BUILD}-x86_64.tar.gz"
TARBALL_PATH="${OUT_DIR}/${TARBALL_NAME}"
VHD_DIR="C:\\wsl\\${DISTRO}"

mkdir -p "$OUT_DIR"

echo "[miniroot] === build ${TARBALL_NAME} ==="
echo "[miniroot] bridge-version=$BRIDGE_VERSION bridge-build=$BRIDGE_BUILD"
echo "[miniroot] bridge=$BRIDGE_SRC"
echo "[miniroot] init=$INIT_SRC"
echo "[miniroot] minirootfs=$MINIROOTFS"
echo "[miniroot] out=$OUT_DIR"

# ---- 1) Limpar distro temporaria residual ----
if $WSL_EXE -l -q 2>/dev/null | grep -q "^${DISTRO}\$"; then
    echo "[miniroot] removendo distro temporaria residual $DISTRO"
    $WSL_EXE --terminate "$DISTRO" >/dev/null 2>&1 || true
    $WSL_EXE --unregister "$DISTRO" >/dev/null 2>&1 || true
    sleep 1
fi

cleanup() {
    if [ "$KEEP" = "1" ]; then
        echo "[miniroot] (--keep) distro temporaria $DISTRO mantida para debug"
        return
    fi
    # Nao usar 'wsl --shutdown' (derruba TODAS as distros e impede o --export
    # futuro). Apenas unregister a distro alvo.
    $WSL_EXE --terminate "$DISTRO" >/dev/null 2>&1 || true
    sleep 1
    $WSL_EXE --unregister "$DISTRO" >/dev/null 2>&1 || true
    rm -rf "/mnt/c/wsl/${DISTRO}" 2>/dev/null || true
    echo "[miniroot] distro temporaria $DISTRO removida"
}
trap cleanup EXIT

# ---- 2) Importar minirootfs ----
echo "[miniroot] importando minirootfs como $DISTRO"
# Quando o wsl.exe eh invocado de dentro do WSL (Alpine) via
# /mnt/c/.../wsl.exe, ele NAO aceita paths WSL (/mnt/c/...) como
# argumentos. Ambos os paths (VHD de saida e tarball de entrada)
# precisam estar no formato Windows com forward slashes: C:/wsl/foo.
# /mnt/c/wsl/foo  ->  C:/wsl/foo
TEMP_VHD_WIN=$(printf '%s' "/mnt/c/wsl/${DISTRO}" | sed 's|^/mnt/c/|C:/|')
# Tambem converter o minirootfs se ele vier como path WSL.
TARBALL_WIN=$(printf '%s' "$MINIROOTFS" | sed 's|^/mnt/c/|C:/|')
echo "[miniroot] vhd path: $TEMP_VHD_WIN"
echo "[miniroot] tarball path: $TARBALL_WIN"
# Garantir que C:\wsl existe
if [ ! -d /mnt/c/wsl ]; then
    /mnt/c/Windows/System32/cmd.exe /c "if not exist C:\\wsl mkdir C:\\wsl" >/dev/null 2>&1 || true
fi
$WSL_EXE --import "$DISTRO" "$TEMP_VHD_WIN" "$TARBALL_WIN" --version 2
if [ $? -ne 0 ]; then
    echo "[miniroot] ERRO: $WSL_EXE --import falhou" >&2
    exit 1
fi

# ---- 3) Configurar (reusa build_golden_alpine.sh) ----
CFG_SH="$(cd "$(dirname "$0")" && pwd)/build_golden_alpine.sh"
[ -f "$CFG_SH" ] || { echo "[miniroot] build_golden_alpine.sh nao encontrado em $CFG_SH" >&2; exit 1; }
# Converter path do $WSL_EXE (cross-distro) -- build_golden_alpine.sh espera /mnt/c/...
BRIDGE_WSL=$(echo "$BRIDGE_SRC" | sed 's|\\|/|g' | sed 's|^C:|/mnt/c|')
INIT_WSL=$(echo "$INIT_SRC" | sed 's|\\|/|g' | sed 's|^C:|/mnt/c|')
echo "[miniroot] executando build_golden_alpine.sh dentro da distro..."
$WSL_EXE -d "$DISTRO" -u root -- sh "$CFG_SH" "$BRIDGE_WSL" "$INIT_WSL"
if [ $? -ne 0 ]; then
    echo "[miniroot] ERRO: build_golden_alpine.sh falhou" >&2
    exit 1
fi

# ---- 4) Validar (rc-service start + porta 9000) ----
echo "[miniroot] validando bridge (rc-service start + porta 9000)..."
PORT_OK=$($WSL_EXE -d "$DISTRO" -u root -- sh -c "
    mkdir -p /run/openrc
    touch /run/openrc/softlevel
    rc-service xemonitor-bridge start
    sleep 3
    (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ':9000' && echo PORT-OK || echo PORT-FAIL
")
if [ "$PORT_OK" != "PORT-OK" ]; then
    echo "[miniroot] AVISO: porta 9000 nao confirmada (device pode estar ausente, normal em geracao sem scanner)" >&2
    # Nao abortar: a validacao completa exige scanner USB; o build em CI/dev
    # provavelmente nao tera o device. Confiar no rc-service start.
    RC_STATUS=$($WSL_EXE -d "$DISTRO" -u root -- rc-service xemonitor-bridge status 2>&1 || true)
    echo "[miniroot] rc-service status: $RC_STATUS"
fi

# Parar o servico para exportar consistente
$WSL_EXE -d "$DISTRO" -u root -- rc-service xemonitor-bridge stop >/dev/null 2>&1 || true

# ---- 5) Exportar ----
echo "[miniroot] exportando -> $TARBALL_PATH"
# wsl --export tambem precisa de path Windows quando invocado de dentro do WSL.
# O TARBALL_PATH eh relativo ao CWD do shell (que eh o repo root /mnt/c/XeMonitor/XeMonitor),
# entao pre-fixar com C:/XeMonitor/XeMonitor/ se for relativo.
case "$TARBALL_PATH" in
    /mnt/c/*) TARBALL_WIN_OUT=$(printf '%s' "$TARBALL_PATH" | sed 's|^/mnt/c/|C:/|') ;;
    /*)       TARBALL_WIN_OUT="C:/XeMonitor/XeMonitor/${TARBALL_PATH#/}" ;;
    *)        TARBALL_WIN_OUT="C:/XeMonitor/XeMonitor/$TARBALL_PATH" ;;
esac
echo "[miniroot] export path: $TARBALL_WIN_OUT"
# Parar o servico para um export consistente (sem wsl --shutdown,
# que derruba a distro temporaria e faz o --export falhar).
$WSL_EXE -d "$DISTRO" -u root -- rc-service xemonitor-bridge stop >/dev/null 2>&1 || true
$WSL_EXE --export "$DISTRO" "$TARBALL_WIN_OUT"
EXPORT_RC=$?
if [ "$EXPORT_RC" -ne 0 ]; then
    echo "[miniroot] ERRO: $WSL_EXE --export falhou (rc=$EXPORT_RC)" >&2
    exit 1
fi
if [ $? -ne 0 ]; then
    echo "[miniroot] ERRO: $WSL_EXE --export falhou" >&2
    exit 1
fi
SIZE=$(stat -c '%s' "$TARBALL_PATH" 2>/dev/null || stat -f '%z' "$TARBALL_PATH" 2>/dev/null)
SIZE_MB=$(echo "scale=1; $SIZE / 1048576" | bc 2>/dev/null || echo "?")
echo "[miniroot] OK: ${TARBALL_NAME} gerado (${SIZE_MB} MB)"

# ---- 6) Rolling 10 (apaga os mais antigos alem de 10) ----
# Lista os tarballs por mtime desc, mantem os 10 primeiros, apaga o resto.
echo "[miniroot] aplicando rolling 10 em $OUT_DIR..."
COUNT=0
for f in $(ls -1t "$OUT_DIR"/alpine-bridge-*.tar.gz 2>/dev/null); do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -gt 10 ]; then
        echo "[miniroot] removendo (rolling 10): $(basename "$f")"
        rm -f "$f"
    fi
done

echo "[miniroot] === build ${TARBALL_NAME} concluido ==="
