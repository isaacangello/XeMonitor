# wsl_timeout.ps1 — roda wsl.exe com timeout (kill) e captura stdout/stderr.
# Usado pelo install_windows.bat (e outros .bat) para nao travar/morrer em
# silencio quando wsl.exe trava em contexto elevado (microsoft/WSL#4144/#9032).
#
# Uso (via install_windows.bat):
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\wsl_timeout.ps1 `
#       -Timeout <segundos> -Task <nome_tarefa>
# Env (opcionais, conforme a tarefa): XEMONITOR_DISTRO, XEMONITOR_SRC, XEMONITOR_DEST
#
# Tarefas (v0.7.0 — 4 fases):
#   status        wsl --status
#   update        wsl --update
#   install_wsl   wsl --install --no-distribution
#   distro_ok     wsl -d <distro> echo ok
#   import_alpine wsl --import Alpine (tarball ja baixado; download fica no bat)
#   set_default   wsl --set-default <distro>
#   copy_file     wsl -d <distro> -u root -- cp "<src>" "<dest>"
#   run_script    wsl -d <distro> -u root -- sh "<src>"
#   svc_enable    rc-update add + rc-service start (OpenRC) | systemctl (systemd)
#   svc_start     rc-service start | systemctl start
#   tty_check     wsl -d <distro> sh -c "test -c /dev/ttyUSB0"
#
# Exit codes: rc do wsl (0 = ok), 200 = TIMEOUT, 201 = erro de processo/tarefa.
# Stdout/stderr do wsl sao gravados em %APPDATA%\xemonitor\logs\wsl.{out,err}.txt.

param([int]$Timeout = 30, [string]$Task = "")

$distro = $env:XEMONITOR_DISTRO
$src    = $env:XEMONITOR_SRC
$logDir = Join-Path $env:APPDATA "xemonitor\logs"
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$out = Join-Path $logDir "wsl.out.txt"
$err = Join-Path $logDir "wsl.err.txt"
Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue

switch ($Task) {
    "status"        { $argLine = "--status" }
    "update"        { $argLine = "--update" }
    "install_wsl"   { $argLine = "--install --no-distribution" }
    "distro_ok"     { $argLine = "-d $distro echo ok" }
    "stop_alpine"   {
        # Derruba a instancia Alpine (Running pode travar o --unregister).
        $argLine = "--terminate Alpine"
    }
    "import_alpine" {
        $tgz = $env:XEMONITOR_TARBALL
        if (-not $tgz -or -not (Test-Path -LiteralPath $tgz)) {
            Write-Output "tarball nao encontrado: $tgz"
            exit 201
        }
        # Se ja existe um registro Alpine, derruba e remove antes de importar.
        # Relatorio preciso (nao silenciar): um unregister falho deixaria a
        # distro registrada e o --import abaixo quebraria com ERROR_ALREADY_EXISTS.
        $list = (& wsl -l -q 2>$null | Out-String)
        if ($list -match "Alpine") {
            & wsl --terminate Alpine 2>$null | Out-Null
            & wsl --unregister Alpine 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
            $after = (& wsl -l -q 2>$null | Out-String)
            if ($after -match "Alpine") {
                Write-Output "import_alpine: distro Alpine ainda registrada apos unregister"
                exit 201
            }
        }
        # Remover VHD residual, se sobrou
        if (Test-Path -LiteralPath "C:\wsl\Alpine") {
            Remove-Item -LiteralPath "C:\wsl\Alpine" -Recurse -Force -ErrorAction SilentlyContinue
        }
        $argLine = "--import Alpine C:\wsl\Alpine `"$tgz`" --version 2"
    }
    "set_default"   { $argLine = "--set-default $distro" }
    "copy_file"     {
        $dest = $env:XEMONITOR_DEST
        $argLine = "-d $distro -u root -- cp `"$src`" `"$dest`""
    }
    "run_script"    { $argLine = "-d $distro -u root -- sh `"$src`"" }
    "svc_enable"    {
        # Propaga erro: se rc-service nao existe (openrc nao instalado) ou
        # rc-service start falha, retorna erro 201. Nao silencia mais com
        # `2>/dev/null || true` — diagnosticar falha real e crucial para o
        # instalador. Validacao final: porta 9000 deve estar ouvindo.
        $script = @'
set -e
if command -v rc-service >/dev/null 2>&1; then
  # Em WSL, OpenRC nao tem init real, entao /run e /run/openrc podem
  # nao existir entre runs. Criar AMBOS antes de qualquer coisa:
  # /run/lock eh o local padrao dos lock files de servico.
  mkdir -p /run /run/openrc /run/lock
  touch /run/openrc/softlevel
  rc-update add xemonitor-bridge default || true
  # Tentar rc-service primeiro; se falhar com lock error, cair no fallback
  # manual (executa o binario em background). O miniroot pre-configurado ja
  # garante que /usr/local/bin/xemonitor-bridge existe e /etc/init.d/xemonitor-bridge
  # tem o init script.
  if ! rc-service xemonitor-bridge start 2>&1; then
    echo "AVISO: rc-service start falhou (lock OpenRC em WSL). Fallback manual."
    # Garantir que nenhum zombie esta rodando
    pkill -9 -f xemonitor-bridge 2>/dev/null || true
    sleep 1
    # Iniciar manualmente em background, gravando pid
    nohup /usr/local/bin/xemonitor-bridge --device "${DEVICE:-/dev/ttyUSB0}" >/var/log/xemonitor-bridge.log 2>&1 &
    BRIDGE_PID=$!
    echo "$BRIDGE_PID" > /run/xemonitor-bridge.pid
    sleep 1
  fi
  # Validar porta 9000 ouvindo (bridge binario pode ter crashado)
  # Usar 'ss' (iproute2) ou 'netstat' (busybox) - o miniroot Alpine nao
  # tem ss por default, so o netstat do busybox.
  sleep 1
  PORT_OK=0
  ss -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  if [ "$PORT_OK" = "0" ]; then
    netstat -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  fi
  if [ "$PORT_OK" = "0" ]; then
    echo "ERRO: bridge nao esta ouvindo na porta 9000 apos start"
    rc-service xemonitor-bridge status 2>&1 || true
    pgrep -fa xemonitor-bridge 2>&1 || echo "bridge nao encontrado no ps"
    exit 1
  fi
  echo "OK: bridge iniciado e porta 9000 ouvindo"
  exit 0
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable xemonitor-bridge || true
  systemctl restart xemonitor-bridge || {
    echo "ERRO: systemctl restart xemonitor-bridge falhou"
    systemctl status xemonitor-bridge --no-pager 2>&1 || true
    exit 1
  }
  sleep 1
  PORT_OK=0
  ss -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  if [ "$PORT_OK" = "0" ]; then
    netstat -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  fi
  if [ "$PORT_OK" = "0" ]; then
    echo "ERRO: bridge nao esta ouvindo na porta 9000 apos restart"
    systemctl status xemonitor-bridge --no-pager 2>&1 || true
    exit 1
  fi
  echo "OK: bridge iniciado e porta 9000 ouvindo"
  exit 0
fi
echo "ERRO: nem OpenRC nem systemd disponiveis - Fase 2 falhou?"
exit 1
'@
        $argLine = "-d $distro -u root -- sh -c '" + $script + "'"
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
        $argLine = "-d $distro -u root -- sh -c '" + $script + "'"
    }
    "svc_status"    {
        # Verifica status real do bridge: rc-service status + porta 9000 ouvindo.
        # usado pelo install_windows.bat pós-svc_enable para confirmar que o
        # daemon realmente subiu (diagnostico do bug 'rc-service start == OK
        # mas daemon morre logo em seguida').
        $script = @'
if command -v rc-service >/dev/null 2>&1; then
  rc-service xemonitor-bridge status || {
    echo "ERRO: rc-service status != started"
    exit 1
  }
  if ! pgrep -f xemonitor-bridge >/dev/null 2>&1; then
    echo "ERRO: rc-service status OK mas processo nao encontrado no ps"
    exit 1
  fi
  # Validar porta 9000 (ss ou netstat do busybox)
  PORT_OK=0
  ss -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  if [ "$PORT_OK" = "0" ]; then
    netstat -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  fi
  if [ "$PORT_OK" = "0" ]; then
    echo "ERRO: processo vivo mas porta 9000 nao ouvindo"
    exit 1
  fi
  echo "OK: rc-service=started processo=ativo porta=9000"
  exit 0
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet xemonitor-bridge || {
    echo "ERRO: systemctl is-active != active"
    exit 1
  }
  PORT_OK=0
  ss -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  if [ "$PORT_OK" = "0" ]; then
    netstat -tln 2>/dev/null | grep -q ':9000' && PORT_OK=1
  fi
  if [ "$PORT_OK" = "0" ]; then
    echo "ERRO: active mas porta 9000 nao ouvindo"
    exit 1
  fi
  echo "OK: systemctl=active porta=9000"
  exit 0
fi
echo "ERRO: nem OpenRC nem systemd disponiveis"
exit 1
'@
        $argLine = "-d $distro -u root -- sh -c '" + $script + "'"
    }
    "tty_check"     { $argLine = "-d $distro sh -c `"test -c /dev/ttyUSB0`"" }
    default {
        Write-Output "Tarefa desconhecida: $Task"
        exit 201
    }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "wsl.exe"
# Normalizar line endings para LF (Windows PowerShell here-strings vem com
# CRLF; o sh POSIX dentro do WSL pode interpretar o \r como parte de uma
# opcao do 'set', gerando 'illegal option -').
$argLine = $argLine -replace "`r`n", "`n"
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
