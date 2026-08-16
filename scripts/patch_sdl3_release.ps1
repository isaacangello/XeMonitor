# ============================================================
# patch_sdl3_release.ps1 — workaround do bug translate-c no Zig 0.16.
# https://codeberg.org/ziglang/translate-c/issues/327
#
# `zig build gui -Doptimize=ReleaseSafe` no Windows falha com
# "unused local constant" em `extern_local_wcscat_s`/`extern_local_wcscpy_s`
# (headers MinGW fortify do SDL3, arquivo sdl3-c.zig gerado). Este script
# insere os marcadores `_ = &extern_local_...` no arquivo gerado dentro do
# .zig-cache, deixando o build ReleaseSafe compilavel.
#
# Uso (na raiz do repo):
#   powershell -ExecutionPolicy Bypass -File scripts\patch_sdl3_release.ps1
#
# Idempotente: nao duplica os marcadores em execucoes subsequentes.
# ============================================================
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$cache = Join-Path $root '.zig-cache'
if (-not (Test-Path $cache)) {
    Write-Host "  [patch] .zig-cache nao encontrado; nada a fazer."
    exit 0
}

$file = Get-ChildItem -Path $cache -Recurse -Filter 'sdl3-c.zig' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $file) {
    Write-Host "  [patch] sdl3-c.zig nao encontrado no cache. Rode 'zig build gui' (Debug) primeiro."
    exit 0
}

$content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
$orig = $content

foreach ($name in @('wcscat_s', 'wcscpy_s')) {
    $structMarker = "const extern_local_$name = struct"
    $useMarker = "&extern_local_$name;"
    if ($content.Contains($structMarker) -and -not $content.Contains($useMarker)) {
        # Insere o marcador apos o "};" de fechamento do struct.
        $pattern = '(const extern_local_' + $name + ' = struct \{[^}]*\};)'
        $content = $content -replace $pattern, ('$1' + "`r`n        _ = &extern_local_$name;")
        Write-Host "  [patch] marcador inserido para $name"
    }
}

if ($content -eq $orig) {
    Write-Host "  [patch] marcadores ja presentes (ou sem structs) em $($file.FullName)"
    exit 0
}

Set-Content -LiteralPath $file.FullName -Value $content -Encoding UTF8 -NoNewline
Write-Host "  [patch] sdl3-c.zig patcheado: $($file.FullName)"
exit 0
