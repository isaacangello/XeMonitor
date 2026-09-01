# ============================================================
# prepare_miniroot_for_iss.ps1 - Pre-step do Inno Setup: copia o
# miniroot mais recente (alpine-bridge-*.tar.gz) em
# packaging\windows\miniroots\ para um nome fixo
# 'alpine-bridge-current.tar.gz'. O xemonitor.iss referencia esse
# nome fixo (Inno Setup 6 nao suporta wildcard em Source).
#
# Uso:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_miniroot_for_iss.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_miniroot_for_iss.ps1 -MinirootDir C:\path
# ============================================================
param(
    [string]$Root = (Get-Location).Path,
    [string]$MinirootDir = ""
)

$ErrorActionPreference = "Stop"

if ($MinirootDir -eq "") {
    $MinirootDir = Join-Path $Root "packaging\windows\miniroots"
}

if (-not (Test-Path -LiteralPath $MinirootDir)) {
    Write-Error "[miniroot-prep] pasta nao encontrada: $MinirootDir"
}

$latest = Get-ChildItem -LiteralPath $MinirootDir -Filter "alpine-bridge-*.tar.gz" -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -ne "alpine-bridge-current.tar.gz" } |
          Sort-Object LastWriteTime -Descending |
          Select-Object -First 1

if ($null -eq $latest) {
    Write-Error "[miniroot-prep] nenhum miniroot em $MinirootDir (rode 'zig build build-bridge-miniroot' em WSL)."
}

$dest = Join-Path $MinirootDir "alpine-bridge-current.tar.gz"
Copy-Item -LiteralPath $latest.FullName -Destination $dest -Force
Write-Host "[miniroot-prep] OK: $($latest.Name) -> alpine-bridge-current.tar.gz ($([math]::Round($latest.Length/1MB,1)) MB)"
