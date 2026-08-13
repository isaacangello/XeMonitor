# Changelog

## [Unreleased]

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
