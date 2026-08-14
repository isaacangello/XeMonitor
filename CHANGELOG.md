# Changelog

## [0.3.1] — 2026-08-14

### Changed
- **Desinstalador no sistema** — o `uninstall.sh` agora vem **dentro do release**
  (`xemonitor-uninstall`) e o `install.sh` (1.2.2) o grava em
  `/usr/local/bin/xemonitor-uninstall`. Não precisa mais baixar o uninstaller
  pelo CDN (o problema do `curl | bash --purge` some). O instalado descobre o
  prefixo sozinho (mesmo com `--prefix` customizado) e se remove junto na
  desinstalação.
- `install.sh` 1.2.2: instala o desinstalador (desde 1.2.1 também cria o grupo
  `input` quando ele não existe — Debian/Ubuntu minimal sem udev).

## [0.3.0] — 2026-08-14

### Added
- **Log rotativo por data** — o cliente grava `xemonitor-YYYY-MM-DD.log` na pasta
  central (ex.: `xemonitor-2026-08-14.log`); a cada escrita o `logPrint` verifica
  se o arquivo do dia existe e, se o dia mudou, abre um novo (evita um log de
  vários dias). Vale para Windows e Linux. O GUI lê o datado de hoje no
  `backfillLog` (fallback para o legado `xemonitor.log`).
- **Desinstalador Linux** — novo `uninstall.sh` na raiz: remove binários, serviços
  (systemd/OpenRC), regras udev (CH340 + uinput), `/etc/modules-load.d`,
  `.desktop`/autostart e ícone hicolor, mas **mantém** `~/.config/xemonitor`
  (config + logs). `./uninstall.sh --purge` remove também config, logs e pids.
- **Compatibilidade Ubuntu/Debian** — CI passa a compilar em `ubuntu-22.04`
  (glibc 2.35): o `xemonitor-gui` lançado roda em Ubuntu 22.04+, Debian 12+ e
  derivados (antes exigia glibc 2.39/24.04). `install.sh` 1.2.0 instala as deps
  de runtime do GUI via apt (`libdbus-1-3 libsystemd0`), adiciona o usuário ao
  grupo `input` e instala regra udev/modulo para `/dev/uinput` (injetor nativo).
- `install.sh` agora avisa `apt install ydotool` no fallback Wayland.

### Changed
- `status_xemonitor.sh` e `diagnose_xemonitor.sh` passam a ler o log datado de
  hoje (fallback p/ `xemonitor.log`).
- `build.zig.zon` → `.version = "0.3.0"`.

## [0.2.0] — 2026-08-14

### Added
- **Injetor Linux nativo** — novo `src/uinput.zig` cria teclado virtual em
  `/dev/uinput` (sem dependência de ydotool/xdotool; agora o **padrão** no Linux),
  com fallback automático para `ydotool` (Wayland) / `xdotool` (X11) e flag
  `--inject <uinput|ydotool|xdotool>`.
- **Config central** — novo `src/paths.zig` resolve/cria o diretório da aplicação:
  Linux `~/.config/xemonitor` (ou `$XDG_CONFIG_HOME`), Windows `%APPDATA%\xemonitor`
  (fallback `%LOCALAPPDATA%`), override `XEMONITOR_CONFIG_DIR` p/ testes; fallback
  cwd. `xemonitor.log`, pids (`xemonitor.pid`, `xemonitor-gui.pid`,
  `xemonitor_tray.pid`) e `xemonitor-gui.conf` passam a morar nesse diretório.
- **Ícone da janela** — `setWindowIcon()` no GUI (SDL3 `SDL_CreateSurface` +
  `SDL_SetWindowIcon`, desenho das barras do barcode); no Wayland o ícone vem do
  `.desktop` (`assets/xemonitor.desktop` → `Icon=xemonitor`). `src/icon.zig`
  (barcode 24x24) com o ícone procedural da bandeja.
- **Autostart do GUI** — `install.sh` instala autostart XDG
  (`~/.config/autostart/xemonitor.desktop`) + unit systemd de usuário opcional
  (`systemd/xemonitor-gui.service`, `/etc/systemd/user/`, não habilitada por padrão).
  O servidor (bridge) já inicia com o sistema via systemd/OpenRC.
- **GUI no release** — `release.yml` passa a compilar `xemonitor-gui`
  (`x86_64-linux-gnu`, SDL3 de fonte + dbus-1 do sistema) e incluí-lo no tarball.
- `status_xemonitor.sh`/`status_bridge.bat` reportam a pasta central (config/log/pids)
  e as últimas linhas do log.
- `install.sh` 1.1.0: instala `xemonitor-gui`, `.desktop`, autostart, cria
  `~/.config/xemonitor` com `xemonitor-gui.conf` padrão (auto_start), resumo novo.
- `docs/windows-installer.md` — instruções do instalador Windows (wizard
  next-next-finish, Inno Setup recomendado) e de como era feito antes (scripts .bat).
- `diagnose_xemonitor.sh` — diagnóstico/auto-recuperação do host Linux
  (`--check`, `--fix`, `--test-serial`), alinhado à pasta central e ao bridge systemd.

### Changed
- **Layout do GUI** — a lista de scans/logs agora fica em uma nova linha abaixo do
  cabeçalho "Histórico (últimos scans)" (botões Copiar/Exportar não ocupam mais a
  coluna esquerda; box horizontal fechado corretamente).
- `run_xemonitor.sh` grava a config e o log na pasta central (`$CFG_DIR`).
- `build.zig.zon` → `.version = "0.2.0"`.

## Antes de v0.2.0 — histórico (work pré-0.2.0)

### Added
- Native Win32 serial API (`--winapi` flag) with DTR/RTS fallback
- TCP mode (`--tcp <HOST:PORT>`) for reading from network (e.g. WSL2 bridge)
- Stdin mode (`--stdin`) for reading from standard input
- `logPrint()` function with file logging (`xemonitor.log`) and thread-safe mutex
- Single-instance mutex on Windows to prevent duplicate processes
- CH340 serial adapter detection in auto-scan scoring
- Bridge unit tests for `SharedState` and `parseHttpPath` in `src/bridge.zig`
- `zig build test-bridge` step (Linux-only)
- `AGENTS.md` — agent context file
- `TODO.md` — session plan/checklist
- `systemd/xemonitor-bridge.service` — systemd unit for the bridge in WSL2
- `scripts/install_bridge_service.sh` — installs/enables the bridge systemd unit (supports `--reinstall`)
- `scripts/install_autostart.bat` — creates scheduled tasks (USB attach, bridge, xemonitor)
- `scripts/uninstall_autostart.bat` — removes the scheduled tasks
- `status_bridge.bat` — bridge service + xemonitor status
- `.github/workflows/release.yml` — GitHub Actions workflow: tags `v*` → build musl estático (x86_64-linux, ReleaseSafe) → tarball `xemonitor-linux-x86_64.tar.gz` + sha256 → publica Release
- `install.sh` — instalador Linux (`curl -LsSf | bash`): baixa a última Release, instala `xemonitor`/`xemonitor-bridge` em `/usr/local/bin`, regra udev CH340, grupos `uucp,dialout`, serviço systemd ou OpenRC; flags `--prefix`/`--no-service` e overrides `XEMONITOR_VERSION`/`XEMONITOR_BASE_URL`
- Versionamento SemVer **v0.<recurso>.<correção>** — primeira tag: v0.1.0
- README bilíngue: `README.md` (inglês, padrão GitHub) + `README.pt-BR.md` (português), com link de navegação mútuo na linha do título; conteúdo atualizado (features atuais, instalação via `install.sh`/Releases, versionamento, troubleshooting)

### Fixed
- `install.sh`: eliminado o re-exec `exec sudo -E bash "$0"` (quebrado quando invocado via pipe com caminho absoluto do bash — `$0=/usr/bin/bash` → "cannot execute binary file"). Agora usa `sudo` por comando, funcionando em qualquer invocação (`curl | bash`, `bash install.sh`, `./install.sh`, root direto)

### Changed
- Replaced all `std.debug.print` calls with `logPrint()` for unified logging
- Refactored main loop to support serial/TCP/stdin modes cleanly
- Updated usage/help text with new flags
- Fixed `build.zig.zon` serial dependency URL to a pinned commit
- Bridge raw TCP mode now accepts multiple/recurring connections (shared-state reader thread + per-client writer threads), matching the HTTP mode pattern
- `run_bridge.bat` now starts the bridge via systemd (`systemctl start xemonitor-bridge`) instead of a detached window
- `stop_bridge.bat` stops the systemd service + kills xemonitor
- `setup_usb.bat` — fallback path for usbipd when not in PATH
- Git remote switched to SSH (`git@github.com:isaacangello/XeMonitor.git`)
- Windows scheduled task `init Docker WSL` now runs at Boot + Logon and starts Docker via systemd

### Removed
- `ORIENTACAO.md` (obsolete; content merged into README/AGENTS)

### Added (new files, histórico)
- `.gitignore` — ignore build output and cache
- `.checkpoint.md` — development session context
- `setup_wsl.sh` — WSL2 udev rule for CH340 + wsl.conf kernel modules
- `test_com4.ps1` — PowerShell COM4 connectivity test
- `src/bridge.py` — Python bridge alternative (stdlib-only)
- `setup_usb.bat` — automated USB setup via usbipd (admin auto-elevation)
