# ============================================================
# make_install_staging.ps1 - Monta um staging dir que reproduz
# a estrutura de C:\Program Files\XeMonitor\ apos o Inno Setup.
#
# O staging eh usado por scripts\run_install_test.bat para validar
# o install_windows.bat SEM precisar rodar o Inno (que tem wizard
# interativo, deteccao de versao antiga via registro, etc.).
#
# Estrutura produzida (zig-out\staging\XeMonitor\):
#   xemonitor-gui.exe
#   xemonitor.exe
#   bridge
#   setup_usb.bat
#   diagnose_windows.bat
#   openrc\xemonitor-bridge
#   systemd\xemonitor-bridge.service
#   scripts\bridge_ctl.bat
#   scripts\wsl_timeout.ps1
#   scripts\install_bridge_service.sh
#   scripts\install_autostart.bat
#   scripts\uninstall_autostart.bat
#   packaging\windows\install_windows.bat
#   packaging\windows\start_bridge.cmd
#   packaging\windows\start_xemonitor.cmd
#   packaging\windows\miniroots\alpine-bridge-*.tar.gz
#
# Uso:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_install_staging.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_install_staging.ps1 -Root C:\outro\repo -StagingDir C:\outra\staging
# ============================================================
param(
    [string]$Root       = (Get-Location).Path,
    [string]$StagingDir = ""
)

$ErrorActionPreference = "Stop"

if ($StagingDir -eq "") {
    $StagingDir = Join-Path $Root "zig-out\staging\XeMonitor"
}

Write-Host "[staging] Root       = $Root"
Write-Host "[staging] StagingDir = $StagingDir"

# ---- Validacoes ----
$required = @(
    "zig-out\bin\xemonitor-gui.exe",
    "zig-out\bin\xemonitor.exe",
    "zig-out\bin\bridge",
    "setup_usb.bat",
    "diagnose_windows.bat",
    "openrc\xemonitor-bridge",
    "systemd\xemonitor-bridge.service",
    "scripts\bridge_ctl.bat",
    "scripts\wsl_timeout.ps1",
    "scripts\install_bridge_service.sh",
    "scripts\install_autostart.bat",
    "scripts\uninstall_autostart.bat",
    "packaging\windows\install_windows.bat",
    "packaging\windows\start_bridge.cmd",
    "packaging\windows\start_xemonitor.cmd"
)
foreach ($rel in $required) {
    $abs = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $abs)) {
        Write-Error "[staging] FALTA: $rel (abs: $abs)"
    }
}

# ---- Limpa staging anterior ----
if (Test-Path -LiteralPath $StagingDir) {
    Write-Host "[staging] removendo staging anterior..."
    Remove-Item -LiteralPath $StagingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null

# ---- Copia arquivos (espelha layout do Inno [Files]) ----
$copyMap = @{
    "xemonitor-gui.exe"            = "zig-out\bin\xemonitor-gui.exe"
    "xemonitor.exe"                = "zig-out\bin\xemonitor.exe"
    "bridge"                       = "zig-out\bin\bridge"
    "setup_usb.bat"                = "setup_usb.bat"
    "diagnose_windows.bat"         = "diagnose_windows.bat"
    "openrc\xemonitor-bridge"      = "openrc\xemonitor-bridge"
    "systemd\xemonitor-bridge.service" = "systemd\xemonitor-bridge.service"
    "scripts\bridge_ctl.bat"       = "scripts\bridge_ctl.bat"
    "scripts\wsl_timeout.ps1"      = "scripts\wsl_timeout.ps1"
    "scripts\install_bridge_service.sh" = "scripts\install_bridge_service.sh"
    "scripts\install_autostart.bat"      = "scripts\install_autostart.bat"
    "scripts\uninstall_autostart.bat"    = "scripts\uninstall_autostart.bat"
    "packaging\windows\install_windows.bat" = "packaging\windows\install_windows.bat"
    "packaging\windows\start_bridge.cmd"    = "packaging\windows\start_bridge.cmd"
    "packaging\windows\start_xemonitor.cmd" = "packaging\windows\start_xemonitor.cmd"
}

foreach ($destRel in $copyMap.Keys) {
    $srcRel = $copyMap[$destRel]
    $src = Join-Path $Root $srcRel
    $dst = Join-Path $StagingDir $destRel
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host "[staging]   + $destRel"
}

# ---- Miniroot: copia o mais recente de packaging\windows\miniroots\ ----
$minirootDir = Join-Path $Root "packaging\windows\miniroots"
$minirootDstDir = Join-Path $StagingDir "packaging\windows\miniroots"
if (-not (Test-Path -LiteralPath $minirootDstDir)) {
    New-Item -ItemType Directory -Path $minirootDstDir -Force | Out-Null
}
$latest = Get-ChildItem -LiteralPath $minirootDir -Filter "alpine-bridge-*.tar.gz" -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending |
          Select-Object -First 1
if ($null -eq $latest) {
    Write-Warning "[staging] NENHUM miniroot em $minirootDir. Rode 'zig build build-bridge-miniroot' (em WSL) antes."
} else {
    Copy-Item -LiteralPath $latest.FullName -Destination (Join-Path $minirootDstDir $latest.Name) -Force
    Write-Host "[staging]   + packaging\windows\miniroots\$($latest.Name) ($([math]::Round($latest.Length/1MB,1)) MB)"
}

Write-Host "[staging] OK: staging pronto em $StagingDir"
Get-ChildItem -LiteralPath $StagingDir -Recurse -File | Measure-Object | ForEach-Object { Write-Host "[staging]   total $($_.Count) arquivos" }
