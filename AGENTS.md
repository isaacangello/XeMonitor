# AGENTS.md — Contexto para o assistente (XeMonitor)

## Projeto
**XeMonitor** — aplicação Zig que lê códigos de barras de um scanner Honeywell 1900 (Granit) via CH340 (USB-Serial) e injeta o texto como teclado no Windows.

- Scanner: Honeywell 1900 · adaptador CH340 USB-Serial · porta atual `COM4` (pode mudar)
- Serial: `115200 8N1`, sem handshake
- Driver CH340 no Windows **quebrado** (erro 31 / AccessDenied) → o fluxo ativo usa **TCP bridge via WSL2**:
  - **WSL2** (Arch, systemd rodando) lê `/dev/ttyUSB0` e serve via TCP na porta **9000** (`zig-out/bin/bridge`)
  - **Windows** conecta com `xemonitor.exe --tcp 127.0.0.1:9000` e injeta via PowerShell `SendKeys`

## Estrutura
```
src/main.zig          → app principal (serial/TCP/stdin + injeção de teclado)
src/bridge.zig        → bridge Linux/WSL2 (TCP raw porta 9000 e HTTP -s porta 8080)
src/bridge.py         → bridge Python legado (stdlib-only, alternativa)
src/index.html        → página embutida do modo HTTP do bridge
build.zig             → build script (exe + bridge + testes)
build.zig.zon         → dependências (Zig 0.15.2, serial)
run_bridge.bat        → inicia bridge (systemd) + xemonitor + Bloco de Notas
stop_bridge.bat       → encerra bridge + xemonitor
status_bridge.bat     → status do serviço bridge + xemonitor
setup_usb.bat         → attach CH340 ao WSL via usbipd (auto-eleva)
setup_wsl.sh          → setup udev + modulos usbip + wsl.conf
scripts/install_bridge_service.sh → instala systemd unit do bridge
scripts/install_autostart.bat     → cria tarefas agendadas (USB/bridge/xemonitor)
scripts/uninstall_autostart.bat   → remove as tarefas agendadas
systemd/xemonitor-bridge.service  → unit systemd do bridge
TODO.md               → plano/checklist da sessão atual
.checkpoint.md        → diário de sessão (contexto + pendências)
CHANGELOG.md          → changelog
```

## Comandos
```cmd
:: Compilar tudo (exe Windows + bridge Linux) e rodar testes
zig build
zig build test

:: Bridge (compila o binário Linux para WSL2)
zig build bridge
zig build test-bridge       :: testes do bridge (Linux-only; roda no WSL)

:: Rodar o app via TCP bridge
run_bridge.bat              :: USB attach (se preciso) + systemd bridge + xemonitor
stop_bridge.bat             :: encerrar tudo
status_bridge.bat           :: status

:: Rodar direto (sem bridge)
zig-out\bin\xemonitor.exe --tcp 127.0.0.1:9000
zig-out\bin\xemonitor.exe --port COM4 --winapi
zig-out\bin\xemonitor.exe --stdin

:: Bridge manual no WSL
wsl -d Arch -u root systemctl start xemonitor-bridge
wsl -d Arch -u root systemctl status xemonitor-bridge

:: Docker (tarefa agendada 'init Docker WSL' cuida no boot/logon)
wsl -d Arch -u root systemctl status docker
```

## Ambiente
- Zig **0.15.2** em `C:\zig-x86_64-windows-0.15.2\` (Windows); **0.16.0** no WSL
- libserialport em `C:\msys64\ucrt64\`
- WSL2 distro **Arch** (nome: `Arch`), systemd rodando, Docker ativo
- usbipd em `C:\Program Files\usbipd-win\usbipd.exe` (nem sempre no PATH)
- `gh` (GitHub CLI) em `C:\Program Files\GitHub CLI\gh.exe`
- Git remote: `git@github.com:isaacangello/XeMonitor.git` (SSH)

## Convenções / avisos
- **Não rodar o CLion elevado para testes de injeção**: processo admin não injeta teclas (UIPI) em janelas não-elevadas.
- Bridge executa de `/usr/local/bin/xemonitor-bridge` (cópia feita pelo install script); ao recompilar, rodar install script com `--reinstall` ou re-rodar o install.
- Preferir `logPrint()` (stderr + `xemonitor.log`) em vez de `std.debug.print`.
- O modo TCP do bridge deve aceitar múltiplas conexões (xemonitor reconecta a cada 2s).
- Ver `TODO.md` (plano atual) e `.checkpoint.md` (contexto histórico/pendências).
