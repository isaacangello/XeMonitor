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

O driver CH340 no Windows está corrompido (erro 31 / AccessDenied), então o acesso à serial é feito via **bridge TCP no WSL2** (distro padrão **Alpine**/OpenRC; Arch/systemd mantido como fallback):

```
Scanner USB-Serial (CH340) → WSL2 (Alpine) lê /dev/ttyUSB0 → bridge TCP :9000
        → xemonitor-gui.exe (app principal: janela + bandeja)
            → xemonitor.exe --tcp 127.0.0.1:9000 → SendInput (Win32 nativo) → Enter
```

O `xemonitor-gui.exe` é o **app principal no Windows**: lê
`%APPDATA%\xemonitor\xemonitor-gui.conf` (`server_mode=wsl`, `auto_start=true`) e
inicia o bridge (via `bridge_ctl.bat`) + o cliente automaticamente.

### Linux

O bridge pode rodar localmente e o `xemonitor` injeta via **teclado virtual nativo `/dev/uinput`** (padrão, sem ferramentas extras), com fallback para `ydotool` (Wayland) ou `xdotool` (X11) quando indisponível (`--inject uinput|ydotool|xdotool`).

## Características

- **Leitura serial** (`--port`, `-p`, porta direta) em `115200 8N1` sem handshake, com auto-detecção de scanners Honeywell/Xenon.
- **Modo TCP** (`--tcp HOST:PORT`) para ler de uma rede (ex.: bridge no WSL2) — reconecta a cada 2s.
- **Modo stdin** (`--stdin`) para pipe de outras fontes.
- **Injeção de teclado**:
  - Windows: `SendInput` nativo (Win32) com `KEYEVENTF_UNICODE` — sem PowerShell/clipboard.
  - Linux: teclado virtual nativo `/dev/uinput` (padrão) — sem precisar de ydotool/xdotool;
    fallback automático para `ydotool` (Wayland) / `xdotool` (X11), override com `--inject`.
- Envia `Enter` (`VK_RETURN`) logo após o texto injetado.
- Reconexão automática em caso de desconexão (serial ou TCP).
- **Pasta central de config/log**: `~/.config/xemonitor` (Linux) / `%APPDATA%\xemonitor`
  (Windows) — **logs datados** `xemonitor-YYYY-MM-DD.log` (um arquivo novo por dia,
  verificado a cada escrita), pids e `xemonitor-gui.conf` moram todos lá
  (override `XEMONITOR_CONFIG_DIR`; fallback para o diretório atual).
- **GUI** (`xemonitor-gui`, DVUI+SDL3): janela + bandeja + controle do
  bridge/cliente. **App principal no Windows** (modo `wsl` via `bridge_ctl.bat`);
  no Linux com ícone da janela (X11 via `SDL_SetWindowIcon`; Wayland via
  `.desktop`) e bandeja (opt-in `--tray`, padrão desligado). Config
  `xemonitor-gui.conf` na pasta central, `auto_start` no login.

## Instalação

### Linux

Instalador oficial (baixa o binário da última GitHub Release e configura tudo — regras udev do CH340 e do uinput, grupos `uucp/dialout/input`, deps de runtime do GUI via apt no Debian/Ubuntu e o serviço do bridge em systemd ou OpenRC):

```bash
curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash
```

- Instala `xemonitor`, `xemonitor-bridge` e `xemonitor-gui` em `/usr/local/bin`.
- Cria as regras udev `99-ch340.rules` (`MODE="0666"`) e `99-xemonitor-uinput.rules`
  (`GROUP="input"`, `MODE="0660"`), além de `/etc/modules-load.d/xemonitor-uinput.conf`
  para o injetor nativo `/dev/uinput` funcionar direto.
- Adiciona o usuário aos grupos `uucp`, `dialout` e `input`.
- Instala e inicia o serviço `xemonitor-bridge` (systemd ou OpenRC) — já inicia com o sistema.
- Instala o `.desktop` do app, o autostart XDG (GUI inicia no login) e um
  `~/.config/xemonitor/xemonitor-gui.conf` padrão (`auto_start=true`).
- Também instala a unit systemd de usuário opcional
  (`/etc/systemd/user/xemonitor-gui.service`) para quem preferir ao autostart:
  `systemctl --user enable xemonitor-gui.service`.
- Requer `sudo` (ou rodar como root).

**Distros suportadas**: o GUI do release (`xemonitor-gui`) é compilado no Ubuntu 22.04
(glibc 2.35) e roda em **Ubuntu 22.04+ / Debian 12+** e derivados; os binários musl
`xemonitor` e `xemonitor-bridge` rodam em qualquer distro. O instalador detecta apt
no Debian/Ubuntu e instala as deps de runtime do GUI (`libdbus-1-3`, `libsystemd0`).

**Desinstalar** (mantém a config e os logs) — o `install.sh` instala um comando
no sistema (sem precisar baixar pelo CDN):

```bash
xemonitor-uninstall           # remove binarios, servicos, regras udev, desktop/autostart e icone
xemonitor-uninstall --purge   # remove tambem ~/.config/xemonitor (config, logs e pids)
```

(Alternativa de desenvolvedor/repo: `./uninstall.sh`.)

Alternativa local (desenvolvedor): `zig build gui` + `zig-out/bin/xemonitor-gui` (ver `run_xemonitor.sh`).

### Windows

1. Compile: `zig build` (gera `zig-out\bin\xemonitor.exe` e `xemonitor-gui.exe`).
2. Prepare o WSL2 (**Alpine**/OpenRC padrão; Arch/systemd fallback) com o bridge:
   `setup_usb.bat` (attach CH340 via usbipd) + `scripts/install_bridge_service.sh`
   (detecta init e instala o serviço).
3. Rode `run_bridge.bat` (USB attach → serviço do bridge → `xemonitor-gui.exe`),
   ou apenas `xemonitor-gui.exe` com a config `server_mode=wsl` + `auto_start=true`.

**Instalador Windows (wizard next-next-finish)**: `packaging/windows/xemonitor.iss`
(Inno Setup) + `packaging/windows/install_windows.bat` instalam tudo (WSL2, usbipd,
Alpine, bridge, binários em `%ProgramFiles%\XeMonitor`, config do GUI, tarefas
agendadas) e iniciam o fluxo. Guia em [docs/windows-installer.md](docs/windows-installer.md).

## Compilar

```bash
zig build              # exe (Windows) / binário Linux + bridge
zig build bridge       # bridge Linux (WSL2)
zig build test         # testes do app
zig build test-bridge  # testes do bridge (Linux-only)
```

Requisito: **Zig 0.16.0** (Windows: `C:\zig\zig-x86_64-windows-0.16.0\`; WSL/CachyOS: 0.16.0). Dependência Zig: `serial` (ZigEmbeddedGroup), pinada via `build.zig.zon`.

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
xemonitor --inject <uinput|ydotool|xdotool>  (injetor de teclado no Linux; padrão uinput)
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
- Tags `v*` disparam o workflow `.github/workflows/release.yml`, que builda os binários **musl estático** (x86_64-linux, ReleaseSafe) + **`xemonitor-gui`** (x86_64-linux-gnu, SDL3 de fonte + dbus do sistema) e publica `xemonitor-linux-x86_64.tar.gz` na GitHub Release.
- O binário musl estático roda tanto em sistemas glibc (Arch/CachyOS/Debian) quanto musl (Alpine) — um único artefato para host Linux e WSL Alpine.
- Releases: https://github.com/isaacangello/XeMonitor/releases

## Estrutura do projeto

```
src/main.zig          → app principal (serial/TCP/stdin + injeção de teclado)
src/bridge.zig        → bridge Linux/WSL2 (TCP raw :9000 e HTTP :8080)
src/gui.zig           → GUI (SDL3 + dvui): janela + config + controle bridge/cliente (Windows: app principal)
src/tray.zig          → bandeja (SNI/D-Bus no Linux; nativa Win32 no Windows)
src/icon.zig          → ícone procedural da bandeja (barcode 24x24)
src/i18n.zig          → i18n (us/pt_br) + t(comptime key) + formatInto
src/uinput.zig        → injetor Linux nativo /dev/uinput
src/paths.zig         → resolução do diretório central de config (Linux ~/.config, Windows %APPDATA%)
src/bridge.py         → bridge Python legado (stdlib-only)
src/index.html        → página embutida do modo HTTP do bridge
assets/xemonitor.desktop → desktop entry (ícone da janela/menu, Wayland)
build.zig             → build script (exe + bridge + gui + testes)
install.sh            → instalador Linux (curl | bash)
uninstall.sh          → fonte do desinstalador Linux; empacotado no release como
                        /usr/local/bin/xemonitor-uninstall (--purge remove config+logs)
diagnose_xemonitor.sh → diagnóstico/auto-recuperação do host Linux (--check, --fix, --test-serial)
.github/workflows/release.yml → CI/CD: tags v* → build musl + gui (ubuntu-22.04) → GitHub Release
run_xemonitor.sh      → (Linux) bridge systemd + GUI com bandeja (auto_start)
stop_xemonitor.sh     → (Linux) mata GUI + cliente + para o bridge
status_xemonitor.sh   → (Linux) status serviço/GUI/cliente/serial + pasta de config
run_bridge.bat        → USB attach + bridge (Alpine/Arch) + xemonitor + Bloco de Notas
stop_bridge.bat       → encerra bridge + xemonitor
status_bridge.bat     → status do serviço bridge + xemonitor
setup_usb.bat         → attach CH340 ao WSL via usbipd (auto-eleva)
setup_wsl.sh          → setup udev + módulos usbip + wsl.conf (detecta Alpine/Arch)
scripts/bridge_ctl.bat → controla o serviço do bridge no WSL (Alpine/OpenRC + Arch/systemd)
scripts/install_bridge_service.sh → instala o serviço do bridge (detecta init: systemd/OpenRC)
scripts/install_autostart.bat     → tarefas agendadas (USB/bridge/GUI)
scripts/uninstall_autostart.bat   → remove tarefas agendadas
systemd/xemonitor-bridge.service  → unit systemd do bridge (sistema)
systemd/xemonitor-gui.service     → unit systemd de usuário opcional do GUI
openrc/xemonitor-bridge            → init script OpenRC do bridge (padrão no Alpine WSL)
packaging/windows/                → instalador Windows: xemonitor.iss + install_windows.bat + start_*.cmd
docs/windows-installer.md → guia do instalador Windows (wizard next-next-finish)
TODO.md / AGENTS.md / CHANGELOG.md → plano / contexto / changelog
```

## Logs esperados

Ao escanear, o log **datado** mostra (Linux `~/.config/xemonitor/xemonitor-YYYY-MM-DD.log`,
Windows `%APPDATA%\xemonitor\xemonitor-YYYY-MM-DD.log`; um arquivo novo é criado na
virada do dia — verificado a cada escrita):

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
- O injetor padrão usa `/dev/uinput` — confira se o device existe e se seu usuário está no
  grupo `input` (regra `MODE="0660"` ou `usermod -aG input $USER`, depois relogin).
- Se o uinput falhar, há fallback automático para `ydotool` (Wayland) / `xdotool` (X11);
  force um deles com `--inject <uinput|ydotool|xdotool>`.
- Wayland: confirme o socket `/run/user/.../.ydotool_socket` quando usar ydotool.
- O texto é digitado onde está o foco — o log `injected` não garante foco no editor.

### Bridge não abre `/dev/ttyUSB0`
Grupo novo (`uucp`) vale após novo login — use `sg uucp -c '...'` na sessão atual, ou deixe o serviço systemd rodar (root abre a serial). A regra udev `MODE="0666"` também libera para qualquer usuário.

## Roadmap

- [x] Teclado virtual no Windows (`SendInput`, validado com **scan físico real** no v0.5.0) e Linux (`uinput`/`ydotool`/`xdotool`, validado).
- [x] Instalador Linux + workflow de Release (v0.1.0; tags v0.1.0–v0.5.0 publicadas).
- [x] Instalador Windows (wizard next-next-finish) — `packaging/windows/` (Inno Setup + install_windows.bat); validado de ponta a ponta no v0.5.1 (UAC real, GUI em janela, feedback do scanner USB-Serial).
- [x] Migrar bridge do WSL de Arch/systemd → **Alpine/OpenRC** (v0.5.0; binário musl estático roda em ambos).
- [x] Scan físico no Windows revalidado (v0.5.0, 2026-08-15) — causa raiz: bridge não acionava DTR/RTS; corrigido (`src/bridge.zig`).
