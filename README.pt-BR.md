# XeMonitor &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; [🇺🇸 English](README.md)

> **Leitor de código de barras → teclado virtual.** Transforma qualquer leitor de código de barras USB-Serial (ex.: Honeywell Granit 1900) em um teclado (keyboard wedge) no Windows e Linux.

Aplicação em **Zig** que lê códigos de barras de um scanner (ex.: Honeywell 1900 / Granit) e injeta o conteúdo recebido como teclado no sistema operacional — virando um "teclado virtual" utilizável em qualquer programa.

*Palavras-chave: software leitor de código de barras, Honeywell 1900, Honeywell Granit, leitor USB serial, CH340, adaptador USB serial, keyboard wedge, escanear para teclado.*

## Hardware suportado

Funciona com qualquer dispositivo que emita texto por **porta serial/COM** (padrão `115200 8N1`, configurável) com fim de linha `\r`/`\n`:

- **Honeywell Granit 1900 / 1980 / 1990** (via adaptador USB-Serial CH340) — o hardware de referência
- **Honeywell Xenon 1900 / 1902 / 1950**, modelos seriais **Voyager / Orbit / Solaris**
- Qualquer **leitor de código de barras USB-Serial** com adaptador CH340, CP210x ou FTDI
- **Leitores RFID / crachá, leitores OBD** e outros dispositivos seriais que emitem linhas de texto

Se o seu leitor aparecer como **porta serial/COM** (não como teclado USB-HID), o XeMonitor consegue ler. Leitores USB-HID já funcionam como teclado nativo e não precisam de software.

## Fluxo de funcionamento

### Windows (fluxo ativo — driver CH340 quebrado)

O driver CH340 no Windows está corrompido (erro 31 / AccessDenied), então o acesso à serial é feito via **bridge TCP no WSL2**:

```
Scanner USB-Serial (CH340) → WSL2 lê /dev/ttyUSB0 → bridge TCP :9000
        → xemonitor.exe --tcp 127.0.0.1:9000 → SendInput (Win32 nativo) → Enter
```

### Linux

O bridge pode rodar localmente e o `xemonitor` injeta via **ydotool** (Wayland) ou **xdotool** (X11).

## Características

- **Leitura serial** (`--port`, `-p`, porta direta) em `115200 8N1` sem handshake, com auto-detecção de scanners Honeywell/Xenon.
- **Modo TCP** (`--tcp HOST:PORT`) para ler de uma rede (ex.: bridge no WSL2) — reconecta a cada 2s.
- **Modo stdin** (`--stdin`) para pipe de outras fontes.
- **Injeção de teclado**:
  - Windows: `SendInput` nativo (Win32) com `KEYEVENTF_UNICODE` — sem PowerShell/clipboard.
  - Linux Wayland: `ydotool`.
  - Linux X11: `xdotool`.
- Envia `Enter` (`VK_RETURN`) logo após o texto injetado.
- Reconexão automática em caso de desconexão (serial ou TCP).
- Logs em `xemonitor.log` (`[scan] '...'`, `[info] injected '...'`, `[info] enter sent`).
- Ícone de bandeja **opt-in** (`--tray`), desligado por padrão.

## Instalação

### Linux

Instalador oficial (baixa o binário da última GitHub Release e configura tudo — regra udev do CH340, grupos `uucp/dialout` e serviço do bridge em systemd ou OpenRC):

```bash
curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash
```

- Instala `xemonitor` e `xemonitor-bridge` em `/usr/local/bin`.
- Cria a regra udev `99-ch340.rules` (`MODE="0666"`).
- Adiciona o usuário aos grupos `uucp` e `dialout`.
- Instala e inicia o serviço `xemonitor-bridge` (systemd ou OpenRC).
- Requer `sudo` (ou rodar como root).

Alternativa local (desenvolvedor): `zig build bridge` + `zig-out/bin/xemonitor`.

### Windows

1. Clone o repositório e compile: `zig build` (gera `zig-out\bin\xemonitor.exe`).
2. Prepare o WSL2 (Arch) com o bridge: ver `scripts/install_bridge_service.sh` e `setup_usb.bat`.
3. Rode `run_bridge.bat` (USB attach via usbipd → serviço systemd do bridge → `xemonitor.exe --tcp` + Bloco de Notas).

> Instalador Windows (wizard next-next-finish) está no roadmap.

## Compilar

```bash
zig build              # exe (Windows) / binário Linux + bridge
zig build bridge       # bridge Linux (WSL2)
zig build test         # testes do app
zig build test-bridge  # testes do bridge (Linux-only)
```

Requisito: **Zig 0.16.0** (Windows: 0.15.2 em `C:\zig-x86_64-windows-0.15.2\`; WSL/CachyOS: 0.16.0). Dependência Zig: `serial` (ZigEmbeddedGroup), pinada via `build.zig.zon`.

## Uso

```
xemonitor [--port <PORT>]
xemonitor [-p <PORT>]
xemonitor <PORT>
xemonitor --winapi      (API serial nativa Win32 no Windows)
xemonitor --tcp <HOST:PORT>  (lê de TCP em vez de serial)
xemonitor --stdin           (lê de stdin)
xemonitor --tray            (ícone de bandeja; desligado por padrão)
xemonitor --kill            (encerra uma instância em execução)
```

Exemplos:

```bash
./zig-out/bin/xemonitor --port COM4
./zig-out/bin/xemonitor --winapi
./zig-out/bin/xemonitor --tcp 127.0.0.1:9000
wsl python3 src/bridge.py | xemonitor --stdin
```

### Bridge

```
bridge                  servidor TCP raw (porta padrão 9000)
bridge -s <url>         servidor HTTP (ex.: http://0.0.0.0:8080)
bridge -h               ajuda
```

O modo TCP aceita múltiplas conexões (o `xemonitor` reconecta a cada 2s).

### Seleção de porta (ordem)

1. Argumento CLI (`--port`/direto).
2. Variável de ambiente `XEMONITOR_PORT`.
3. Detecção automática (scanners Honeywell/Xenon).
4. Padrão: `COM1` (Windows) ou `/dev/ttyUSB0` (Linux).

Baud rate configurável via `XEMONITOR_BAUD` (padrão: `115200`), serial `8N1` sem handshake.

## Release / versionamento

- **Versionamento**: SemVer `v0.<recurso>.<correção>` — recurso novo aumenta o número do meio (`v0.1.0 → v0.2.0`); correção aumenta o último (`v0.2.0 → v0.2.1`).
- Tags `v*` disparam o workflow `.github/workflows/release.yml`, que builda os binários **musl estático** (x86_64-linux, ReleaseSafe) e publica `xemonitor-linux-x86_64.tar.gz` na GitHub Release.
- O binário musl estático roda tanto em sistemas glibc (Arch/CachyOS/Debian) quanto musl (Alpine) — um único artefato para host Linux e WSL Alpine.
- Releases: https://github.com/isaacangello/XeMonitor/releases

## Estrutura do projeto

```
src/main.zig          → app principal (serial/TCP/stdin + injeção de teclado)
src/bridge.zig        → bridge Linux/WSL2 (TCP raw :9000 e HTTP :8080)
src/bridge.py         → bridge Python legado (stdlib-only)
src/index.html        → página embutida do modo HTTP do bridge
build.zig             → build script (exe + bridge + testes)
install.sh            → instalador Linux (curl | bash)
.github/workflows/release.yml → CI/CD: tags v* → build musl → GitHub Release
run_bridge.bat        → USB attach + bridge (systemd) + xemonitor + Bloco de Notas
stop_bridge.bat       → encerra bridge + xemonitor
status_bridge.bat     → status do serviço bridge + xemonitor
setup_usb.bat         → attach CH340 ao WSL via usbipd (auto-eleva)
setup_wsl.sh          → setup udev + módulos usbip + wsl.conf
scripts/install_bridge_service.sh → instala unit systemd do bridge
scripts/install_autostart.bat     → tarefas agendadas (USB/bridge/xemonitor)
scripts/uninstall_autostart.bat   → remove tarefas agendadas
systemd/xemonitor-bridge.service  → unit systemd do bridge
TODO.md / AGENTS.md / CHANGELOG.md → plano / contexto / changelog
```

## Logs esperados

Ao escanear, o log (`xemonitor.log`) mostra:

- `[scan] '7898121840147'` — conteúdo lido (completo, sem bytes soltos).
- `[info] injected '...'` — sucesso do `SendInput`.
- `[info] enter sent` — `Enter` enviado.

## Troubleshooting

### Porta serial não encontrada
O programa tenta reconectar a cada 2s. Especifique a porta: `xemonitor --port COM3` ou `export XEMONITOR_PORT=COM3`.

### Driver CH340 quebrado no Windows (erro 31 / AccessDenied)
Use o fluxo via bridge TCP no WSL2 (`run_bridge.bat`). Diagnóstico do driver: reinstalar/diagnosticar o CH340.

### UIPI bloqueando injeção no Windows
`SendInput` funciona Médio→Médio; retorna 0 se o alvo for de integridade maior. Rode o `xemonitor` e o editor alvo **não elevados**.

### Sem injeção no Linux
- Wayland: confirme `ydotool` (e o socket `/run/user/.../.ydotool_socket`).
- X11: confirme `xdotool`.
- O texto é digitado onde está o foco — o log `injected` não garante foco no editor.

### Bridge não abre `/dev/ttyUSB0`
Grupo novo (`uucp`) vale após novo login — use `sg uucp -c '...'` na sessão atual, ou deixe o serviço systemd rodar (root abre a serial). A regra udev `MODE="0666"` também libera para qualquer usuário.

## Roadmap

- [x] Teclado virtual no Windows (`SendInput`, validado) e Linux (`ydotool`/`xdotool`, validado).
- [x] Instalador Linux + workflow de Release (v0.1.0).
- [ ] Instalador Windows (wizard next-next-finish).
- [ ] Migrar bridge do WSL de Arch/systemd → Alpine/OpenRC (binário musl estático já roda em Alpine).
