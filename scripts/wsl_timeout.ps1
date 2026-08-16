# wsl_timeout.ps1 — roda wsl.exe com timeout (kill) e captura stdout/stderr.
# Usado pelo install_windows.bat (e outros .bat) para nao travar/morrer em
# silencio quando wsl.exe trava em contexto elevado (microsoft/WSL#4144/#9032).
#
# Uso (via install_windows.bat):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\wsl_timeout.ps1 `
#       -Timeout <segundos> -Task <nome_tarefa>
# Env (opcionais, conforme a tarefa): XEMONITOR_DISTRO, XEMONITOR_SRC
#
# Tarefas:
#   status        wsl --status
#   distro_ok     wsl -d <distro> echo ok
#   install_alpine Baixa o minirootfs do SITE da Alpine e importa no WSL
#                 (o Alpine NAO esta na lista padrao de wsl --install):
#                 https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/
#   set_default   wsl --set-default <distro>
#   setup_wsl     wsl -d <distro> -u root -- sh -c "<src>"
#   copy_bridge   wsl -d <distro> -u root -- sh -c "cp '<src>' /usr/local/bin/xemonitor-bridge && chmod 755 ..."
#   copy_openrc   idem, para /etc/init.d/xemonitor-bridge
#   copy_systemd  idem, para /etc/systemd/system/xemonitor-bridge.service
#   svc_enable    rc-update add + rc-service start (OpenRC) | systemctl (systemd)
#   tty_check     wsl -d <distro> sh -c "test -c /dev/ttyUSB0"
#
# Exit codes: rc do wsl (0 = ok), 200 = TIMEOUT, 201 = erro de processo/tarefa.
# Stdout/stderr do wsl sao gravados em %TEMP%\xemonitor-wsl.{out,err}.txt.

param([int]$Timeout = 30, [string]$Task = "")

$distro = $env:XEMONITOR_DISTRO
$src    = $env:XEMONITOR_SRC
$out    = Join-Path $env:TEMP "xemonitor-wsl.out.txt"
$err    = Join-Path $env:TEMP "xemonitor-wsl.err.txt"
Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue

switch ($Task) {
    "status"        { $argLine = "--status" }
    "update"        { $argLine = "--update" }
    "install_wsl"   { $argLine = "--install --no-distribution" }
    "distro_ok"     { $argLine = "-d $distro echo ok" }
    "install_alpine" {
        # Alpine NAO esta na lista padrao do wsl --install. Baixa o minirootfs
        # do site oficial e importa. Resolve a versao mais recente via
        # latest-releases.yaml (fallback: versao conhecida).
        $base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64"
        $file = "alpine-minirootfs-3.24.1-x86_64.tar.gz"
        try {
            $yaml = (Invoke-WebRequest -UseBasicParsing -Uri "$base/latest-releases.yaml" -TimeoutSec 30).Content
            if ($yaml -match 'flavor: alpine-minirootfs[\s\S]*?file: (alpine-minirootfs-[\d.]+-x86_64\.tar\.gz)') {
                $file = $Matches[1]
            }
        } catch {
            Write-Output "aviso: nao resolveu latest-releases.yaml; usando $file"
        }
        $tgz = Join-Path $env:TEMP "alpine-minirootfs.tar.gz"
        Remove-Item -LiteralPath $tgz -ErrorAction SilentlyContinue
        Write-Output "baixando $base/$file"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$file" -OutFile $tgz -TimeoutSec 240
        } catch {
            Write-Output "falha no download: $($_.Exception.Message)"
            exit 201
        }
        if (-not (Test-Path -LiteralPath $tgz) -or (Get-Item -LiteralPath $tgz).Length -lt 1000000) {
            Write-Output "download incompleto"
            exit 201
        }
        # Se ja existe um registro Alpine quebrado (o bat so chega aqui quando
        # wsl -d Alpine nao responde), remove antes de importar.
        $list = (& wsl -l -q 2>$null | Out-String)
        if ($list -match "Alpine") {
            & wsl --unregister Alpine 2>$null | Out-Null
        }
        $argLine = "--import Alpine C:\wsl\Alpine `"$tgz`" --version 2"
    }
    "set_default"   { $argLine = "--set-default $distro" }
    "setup_wsl"     { $argLine = "-d $distro -u root -- sh -c `"$src`"" }
    "copy_bridge"   { $argLine = "-d $distro -u root -- sh -c `"cp '$src' /usr/local/bin/xemonitor-bridge && chmod 755 /usr/local/bin/xemonitor-bridge`"" }
    "copy_openrc"   { $argLine = "-d $distro -u root -- sh -c `"cp '$src' /etc/init.d/xemonitor-bridge && chmod 755 /etc/init.d/xemonitor-bridge`"" }
    "copy_systemd"  { $argLine = "-d $distro -u root -- sh -c `"cp '$src' /etc/systemd/system/xemonitor-bridge.service && chmod 644 /etc/systemd/system/xemonitor-bridge.service`"" }
    "svc_enable"    {
        $script = @'
if command -v rc-service >/dev/null 2>&1; then
  mkdir -p /run/openrc 2>/dev/null
  touch /run/openrc/softlevel 2>/dev/null
  rc-update add xemonitor-bridge default 2>/dev/null || true
  rc-service xemonitor-bridge start 2>/dev/null || true
else
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable xemonitor-bridge 2>/dev/null || true
  systemctl restart xemonitor-bridge 2>/dev/null || true
fi
'@
        $argLine = "-d $distro -u root -- sh -c `"$script`""
    }
    "svc_start"     {
        $script = @'
if command -v rc-service >/dev/null 2>&1; then
  mkdir -p /run/openrc 2>/dev/null
  touch /run/openrc/softlevel 2>/dev/null
  rc-service xemonitor-bridge start 2>/dev/null || true
else
  systemctl start xemonitor-bridge 2>/dev/null || true
fi
'@
        $argLine = "-d $distro -u root -- sh -c `"$script`""
    }
    "tty_check"     { $argLine = "-d $distro sh -c `"test -c /dev/ttyUSB0`"" }
    default {
        Write-Output "Tarefa desconhecida: $Task"
        exit 201
    }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "wsl.exe"
$psi.Arguments = $argLine
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
try {
    if (-not $p.Start()) {
        Write-Output "Falha ao iniciar wsl.exe"
        exit 201
    }
} catch {
    Write-Output "ERRO ao iniciar wsl.exe: $($_.Exception.Message)"
    exit 201
}

# Leitura assincrona: evita deadlock se o wsl exceder o pipe (64KB) enquanto
# ainda roda (WaitForExit bloquearia, mataríamos como "TIMEOUT").
$stdoutTask = $p.StandardOutput.ReadToEndAsync()
$stderrTask = $p.StandardError.ReadToEndAsync()

if (-not $p.WaitForExit($Timeout * 1000)) {
    try { $p.Kill() } catch {}
    Write-Output "TIMEOUT apos ${Timeout}s"
    exit 200
}
$p.WaitForExit()
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
if ($stdout) { $stdout | Out-File -FilePath $out -Encoding utf8 }
if ($stderr) { $stderr | Out-File -FilePath $err -Encoding utf8 }
exit $p.ExitCode
