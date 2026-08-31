# ============================================================
# make_golden.ps1 - Gera a "golden image" do Alpine (XeMonitor)
# no Windows, via WSL.
#
# Fluxo:
#   1. Importa o alpine-minirootfs numa distro temporaria (XeMonitor-Golden)
#   2. Copia build_golden_alpine.sh + bridge + init script para dentro
#   3. Executa a configuracao (apk deps + udev + wsl.conf + init + bridge)
#   4. Valida o bridge (rc-service start + porta 9000)
#   5. Exporta como xemonitor-alpine-<ver>-x86_64.tar.gz
#   6. Desregistra a distro temporaria
#
# Uso:
#   powershell -NoProfile -ExecutionPolicy Bypass -File make_golden.ps1
#       [-MiniRootfs C:\...\alpine-minirootfs-3.24.1-x86_64.tar.gz]
#       [-Distro XeMonitor-Golden]
#       [-OutDir ..\packaging\windows\golden]
# ============================================================
param(
    [string]$MiniRootfs = "C:\XeMonitor\XeMonitor\alpine-minirootfs-3.24.1-x86_64.tar.gz",
    [string]$Distro = "XeMonitor-Golden",
    [string]$Root = "C:\XeMonitor\XeMonitor",
    [string]$OutDir = "C:\XeMonitor\XeMonitor\packaging\windows\golden"
)

$ErrorActionPreference = "Stop"
$bridge = Join-Path $Root "zig-out\bin\bridge"
$init   = Join-Path $Root "openrc\xemonitor-bridge"
$cfgSh  = Join-Path $Root "scripts\build_golden_alpine.sh"
$ver    = "3.24.1"
$tarball= Join-Path $OutDir "xemonitor-alpine-$ver-x86_64.tar.gz"

if (-not (Test-Path -LiteralPath $MiniRootfs)) { Write-Error "minirootfs nao encontrado: $MiniRootfs" }
if (-not (Test-Path -LiteralPath $bridge))     { Write-Error "bridge nao encontrado: $bridge" }
if (-not (Test-Path -LiteralPath $init))       { Write-Error "init nao encontrado: $init" }
if (-not (Test-Path -LiteralPath $cfgSh))      { Write-Error "build_golden_alpine.sh nao encontrado: $cfgSh" }

function Log($m) { Write-Host "[golden] $m" }

# 1. Remover distro temporaria residual e importar fresh
$list = (& wsl -l -q 2>$null | Out-String)
if ($list -match $Distro) {
    Log "removendo distro temporaria residual $Distro"
    & wsl --unregister $Distro 2>$null | Out-Null
    Start-Sleep -Milliseconds 500
}
Log "importando $MiniRootfs como $Distro"
& wsl --import $Distro "C:\wsl\Golden" $MiniRootfs --version 2
if ($LASTEXITCODE -ne 0) { Write-Error "falha ao importar $Distro (rc=$LASTEXITCODE)" }

try {
    # 2. Copiar arquivos para dentro da distro (via /mnt/c)
    $cfgWsl  = "/mnt/c/XeMonitor/XeMonitor/scripts/build_golden_alpine.sh"
    $brWsl   = "/mnt/c/XeMonitor/XeMonitor/zig-out/bin/bridge"
    $iniWsl  = "/mnt/c/XeMonitor/XeMonitor/openrc/xemonitor-bridge"
    $vhdWsl  = "C:\wsl\Golden"
    Log "executando configuracao (apk + bridge + init)..."
    & wsl -d $Distro -u root -- sh "$cfgWsl" "$brWsl" "$iniWsl"
    if ($LASTEXITCODE -ne 0) { Write-Error "configuracao falhou (rc=$LASTEXITCODE)" }

    # 3. Validar o bridge embutido (servico + porta 9000)
    # Nota: criar /run/openrc/softlevel (igual ao svc_enable do instalador) -
    # sem ele, o openrc reclama 'did not boot' na 1a execucao do rc-service.
    Log "validando bridge (rc-service start + porta 9000)..."
    $portOk = & wsl -d $Distro -u root -- sh -c "mkdir -p /run/openrc; touch /run/openrc/softlevel; rc-service xemonitor-bridge start; sleep 3; (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ':9000' && echo PORT-OK || echo PORT-FAIL"
    if ($portOk -notmatch "PORT-OK") { Write-Warning "AVISO: porta 9000 nao confirmada na golden (device pode estar ausente, normal em geracao sem scanner)." }

    # 4. Exportar
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    Log "exportando imagem -> $tarball"
    wsl --shutdown
    Start-Sleep -Seconds 2
    & wsl --export $Distro "$tarball"
    if ($LASTEXITCODE -ne 0) { Write-Error "falha ao exportar (rc=$LASTEXITCODE)" }
    $sz = (Get-Item -LiteralPath $tarball).Length / 1MB
    Log "OK: golden image gerada ($([math]::Round($sz,1)) MB): $tarball"
}
finally {
    # 5. Limpeza da distro temporaria
    wsl --shutdown
    Start-Sleep -Seconds 2
    & wsl --unregister $Distro 2>$null | Out-Null
    Remove-Item -LiteralPath "C:\wsl\Golden" -Recurse -Force -ErrorAction SilentlyContinue
    Log "distro temporaria $Distro removida."
}
