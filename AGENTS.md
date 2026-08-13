# AGENTS.md — Contexto para o assistente (XeMonitor)

## Projeto
**XeMonitor** — aplicação Zig que lê códigos de barras de um scanner Honeywell 1900 (Granit) via **CH340 (USB-SERIAL)** e injeta o texto como teclado no Windows via **`SendInput` nativo (Win32)**.

> Importante: o alvo é o scanner **USB-SERIAL**. Scanners USB-HID já funcionam como teclado nativo no Gerenciador de Dispositivos e **não** fazem parte do fluxo.

- Scanner: Honeywell 1900 · adaptador CH340 USB-Serial · porta atual `COM4` (pode mudar)
- Serial: `115200 8N1`, sem handshake
- Driver CH340 no Windows **quebrado** (erro 31 / AccessDenied) → o fluxo ativo usa **TCP bridge via WSL2**:
  - **WSL2** lê `/dev/ttyUSB0` e serve via TCP na porta **9000** (`zig-out/bin/bridge`) — hoje **Arch/systemd**; planejado migrar p/ **Alpine/OpenRC** (menos recursos)
  - **Windows** conecta com `xemonitor.exe --tcp 127.0.0.1:9000` e injeta via `SendInput` (Win32, nativo, sem PowerShell/clipboard)

## Injeção de teclado (Linux)
- No Linux o bridge pode rodar local (ex.: CachyOS) e o `xemonitor` injeta via **ydotool** (Wayland) ou **xdotool** (X11), tornando o app um "teclado virtual" usável em qualquer programa.
- Linux (CachyOS) validado de ponta a ponta: bridge sob **systemd** (unit de usuário, ver abaixo) → TCP 9000 → `xemonitor --tcp` → ydotool → editor focado.
- Binário do bridge é **musl estático** (Zig linka musl p/ Linux por padrão): roda em glibc (Arch/CachyOS) **e** musl (Alpine) sem recompilação — provado via `readelf` (sem dynamic interpreter).

## Injeção de teclado (Windows)
- Padrão: `.windows_sendinput` — `SendInput` com `KEYEVENTF_UNICODE` (texto) e `VK_RETURN` (Enter), em um único batch.
- Estruturas ABI em `src/main.zig` (struct `w`): `INPUT` tem **40 bytes no x64** (o union interno usa MOUSEINPUT de 32 bytes) — `cbSize` incorreto faz `SendInput` retornar 0. Diagnóstico via `GetLastError()` em `w.last_sendinput_error`.
- UIPI: `SendInput` de Médio→Médio funciona; retorna 0 (bloqueado) se o alvo for de integridade maior. xemonitor e editor devem rodar **não elevados**.
- Fallback legado `.windows_powershell` (SendKeys + clipboard) ainda existe no enum, mas não é selecionado.

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
openrc/xemonitor-bridge           → (planejado) init script OpenRC p/ Alpine/WSL
install.sh                        → instalador Linux (curl | bash): release + udev + grupos + serviço
.github/workflows/release.yml     → CI/CD: tags v* → build musl ReleaseSafe → GitHub Release
TODO.md               → plano/checklist da sessão atual
.checkpoint.md        → diário de sessão (contexto + pendências)
CHANGELOG.md          → changelog
```

## Roadmap (visão geral)
1. **xemonitor como teclado nos dois SO** — Windows: `SendInput` (validado); Linux: ydotool/xdotool (validado no CachyOS).
2. **Migrar bridge WSL de Arch/systemd → Alpine/OpenRC** (menos recursos) — ver seção no `TODO.md`; testar OpenRC no WSL real.
3. **Instalador Windows** (SÓ quando for ao Windows): wizard next-next-finish.
4. **Instalador Linux**: `curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash` (feito; aguardando commit + tag `v0.1.0`).

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

:: Bridge manual no CachyOS (unit systemd de usuário)
systemctl --user start xemonitor-bridge
systemctl --user status xemonitor-bridge
journalctl --user -u xemonitor-bridge -f

:: Docker (tarefa agendada 'init Docker WSL' cuida no boot/logon)
wsl -d Arch -u root systemctl status docker
```

## Ambiente
- Zig **0.15.2** em `C:\zig-x86_64-windows-0.15.2\` (Windows); **0.16.0** no WSL; CachyOS (dev/teste Linux)
- libserialport em `C:\msys64\ucrt64\`
- WSL2 distro **Arch** (nome: `Arch`), systemd rodando, Docker ativo — **planejado migrar p/ Alpine/OpenRC**
- **CachyOS** (Linux host de dev/teste): Wayland + ydotool (`/run/user/1000/.ydotool_socket`), bridge via **unit systemd de usuário** `~/.config/systemd/user/xemonitor-bridge.service` com `ExecStart=/usr/bin/sg uucp -c '...bridge'` (wrapper dispensa re-login; sessão antiga não herdou grupo `uucp`)
- usbipd em `C:\Program Files\usbipd-win\usbipd.exe` (nem sempre no PATH)
- `gh` (GitHub CLI) em `C:\Program Files\GitHub CLI\gh.exe`
- Git remote: `git@github.com:isaacangello/XeMonitor.git` (SSH)

## Convenções / avisos
- **Não rodar o CLion elevado para testes de injeção**: processo admin não injeta teclas (UIPI) em janelas não-elevadas.
- Bridge executa de `/usr/local/bin/xemonitor-bridge` (cópia feita pelo install script); ao recompilar, rodar install script com `--reinstall` ou re-rodar o install.
- Preferir `logPrint()` (stderr + `xemonitor.log`) em vez de `std.debug.print`.
- Logs das 3 vias (stdin/TCP/serial): `[scan] '...'` (conteúdo lido), `[info] injected '...'` e `[info] enter sent` (sucesso do SendInput). Eco cru de byte foi removido — não reintroduzir.
- Ícone de bandeja é **opt-in** (`--tray`); padrão desligado. O ícone usa PowerShell oculto — se o processo for morto com `taskkill /f`, vira órfão (limpar cache `TrayNotify` + reiniciar explorer).
- O modo TCP do bridge deve aceitar múltiplas conexões (xemonitor reconecta a cada 2s).
- Validar injeção sem elevado: tarefa agendada com `/rl LIMITED` + wrapper `.cmd` que redireciona stdout/stderr para arquivo; ler o log com a ferramenta read (a saída do terminal corrompe bytes).
- Ver `TODO.md` (plano atual) e `.checkpoint.md` (contexto histórico/pendências).
