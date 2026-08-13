# XeMonitor &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; [🇧🇷 Português](README.pt-BR.md)

> **Barcode scanner → virtual keyboard.** Turns any USB-Serial barcode scanner (e.g. Honeywell Granit 1900) into a USB keyboard wedge on Windows and Linux.

A **Zig** application that reads barcodes from a scanner (e.g. Honeywell 1900 / Granit) and injects the received content as keyboard input into the operating system — effectively turning it into a "virtual keyboard" usable in any program.

*Keywords: barcode scanner software, Honeywell 1900, Honeywell Granit, USB serial barcode scanner, CH340, USB to serial adapter, keyboard wedge, scan to keyboard, code barre.*

## Supported hardware

Works with any device that outputs text over a **serial/COM port** (default `115200 8N1`, configurable) terminated by `\r`/`\n`:

- **Honeywell Granit 1900 / 1980 / 1990** (via CH340 USB-Serial adapter) — the reference hardware
- **Honeywell Xenon 1900 / 1902 / 1950**, **Voyager / Orbit / Solaris** serial models
- Any **USB-Serial barcode scanner** using a CH340, CP210x or FTDI adapter
- **RFID / badge readers, OBD readers** and other serial devices that emit text lines

If your scanner enumerates as a **serial/COM port** (not a USB-HID keyboard), XeMonitor can read it. USB-HID scanners already act as a native keyboard and need no software.

## How it works

### Windows (active flow — broken CH340 driver)

The CH340 driver on Windows is corrupted (error 31 / AccessDenied), so serial access is done through a **TCP bridge in WSL2**:

```
Scanner USB-Serial (CH340) → WSL2 reads /dev/ttyUSB0 → bridge TCP :9000
        → xemonitor.exe --tcp 127.0.0.1:9000 → SendInput (native Win32) → Enter
```

### Linux

The bridge can run locally and `xemonitor` injects via **ydotool** (Wayland) or **xdotool** (X11).

## Features

- **Serial reading** (`--port`, `-p`, bare port) at `115200 8N1` with no handshake, with auto-detection of Honeywell/Xenon scanners.
- **TCP mode** (`--tcp HOST:PORT`) to read from the network (e.g. WSL2 bridge) — reconnects every 2s.
- **stdin mode** (`--stdin`) for piping from other sources.
- **Keyboard injection**:
  - Windows: native `SendInput` (Win32) with `KEYEVENTF_UNICODE` — no PowerShell/clipboard.
  - Linux Wayland: `ydotool`.
  - Linux X11: `xdotool`.
- Sends `Enter` (`VK_RETURN`) right after the injected text.
- Automatic reconnection on disconnect (serial or TCP).
- Logs to `xemonitor.log` (`[scan] '...'`, `[info] injected '...'`, `[info] enter sent`).
- System tray icon is **opt-in** (`--tray`), off by default.

## Installation

### Linux

Official installer (downloads the binary from the latest GitHub Release and configures everything — CH340 udev rule, `uucp/dialout` groups, and the bridge service on systemd or OpenRC):

```bash
curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash
```

- Installs `xemonitor` and `xemonitor-bridge` into `/usr/local/bin`.
- Creates the `99-ch340.rules` udev rule (`MODE="0666"`).
- Adds the user to the `uucp` and `dialout` groups.
- Installs and starts the `xemonitor-bridge` service (systemd or OpenRC).
- Requires `sudo` (or running as root).

Local alternative (developer): `zig build bridge` + `zig-out/bin/xemonitor`.

### Windows

1. Clone the repo and build: `zig build` (produces `zig-out\bin\xemonitor.exe`).
2. Set up WSL2 (Arch) with the bridge: see `scripts/install_bridge_service.sh` and `setup_usb.bat`.
3. Run `run_bridge.bat` (USB attach via usbipd → systemd bridge service → `xemonitor.exe --tcp` + Notepad).

> Windows installer (next-next-finish wizard) is on the roadmap.

## Build

```bash
zig build              # exe (Windows) / Linux binary + bridge
zig build bridge       # Linux bridge (WSL2)
zig build test         # app tests
zig build test-bridge  # bridge tests (Linux-only)
```

Requirement: **Zig 0.16.0** (Windows: 0.15.2 at `C:\zig-x86_64-windows-0.15.2\`; WSL/CachyOS: 0.16.0). Zig dependency: `serial` (ZigEmbeddedGroup), pinned via `build.zig.zon`.

## Usage

```
xemonitor [--port <PORT>]
xemonitor [-p <PORT>]
xemonitor <PORT>
xemonitor --winapi      (use native Win32 serial API on Windows)
xemonitor --tcp <HOST:PORT>  (read from TCP instead of serial)
xemonitor --stdin           (read from stdin)
xemonitor --tray            (enable system tray icon; off by default)
xemonitor --kill            (terminate a running instance)
```

Examples:

```bash
./zig-out/bin/xemonitor --port COM4
./zig-out/bin/xemonitor --winapi
./zig-out/bin/xemonitor --tcp 127.0.0.1:9000
wsl python3 src/bridge.py | xemonitor --stdin
```

### Bridge

```
bridge                  raw TCP server (default port 9000)
bridge -s <url>         HTTP server (e.g. http://0.0.0.0:8080)
bridge -h               help
```

The TCP mode accepts multiple connections (the `xemonitor` client reconnects every 2s).

### Port selection (order)

1. CLI argument (`--port`/bare).
2. `XEMONITOR_PORT` environment variable.
3. Auto-detection (Honeywell/Xenon scanners).
4. Default: `COM1` (Windows) or `/dev/ttyUSB0` (Linux).

Baud rate configurable via `XEMONITOR_BAUD` (default: `115200`), serial `8N1` with no handshake.

## Release / versioning

- **Versioning**: SemVer `v0.<feature>.<fix>` — a new feature bumps the middle number (`v0.1.0 → v0.2.0`); a fix bumps the last (`v0.2.0 → v0.2.1`).
- Tags `v*` trigger the `.github/workflows/release.yml` workflow, which builds **static musl** binaries (x86_64-linux, ReleaseSafe) and publishes `xemonitor-linux-x86_64.tar.gz` to the GitHub Release.
- The static musl binary runs on both glibc (Arch/CachyOS/Debian) and musl (Alpine) systems — a single artifact for the Linux host and WSL Alpine.
- Releases: https://github.com/isaacangello/XeMonitor/releases

## Project structure

```
src/main.zig          → main app (serial/TCP/stdin + keyboard injection)
src/bridge.zig        → Linux/WSL2 bridge (raw TCP :9000 and HTTP :8080)
src/bridge.py         → legacy Python bridge (stdlib-only)
src/index.html        → embedded page for the bridge HTTP mode
build.zig             → build script (exe + bridge + tests)
install.sh            → Linux installer (curl | bash)
.github/workflows/release.yml → CI/CD: v* tags → musl build → GitHub Release
run_bridge.bat        → USB attach + bridge (systemd) + xemonitor + Notepad
stop_bridge.bat       → stops bridge + xemonitor
status_bridge.bat     → bridge service + xemonitor status
setup_usb.bat         → attach CH340 to WSL via usbipd (auto-elevates)
setup_wsl.sh          → udev + usbip modules + wsl.conf setup
scripts/install_bridge_service.sh → installs the bridge systemd unit
scripts/install_autostart.bat     → scheduled tasks (USB/bridge/xemonitor)
scripts/uninstall_autostart.bat   → removes scheduled tasks
systemd/xemonitor-bridge.service  → bridge systemd unit
TODO.md / AGENTS.md / CHANGELOG.md → plan / context / changelog
```

## Expected logs

On scan, the log (`xemonitor.log`) shows:

- `[scan] '7898121840147'` — content read (complete, no stray bytes).
- `[info] injected '...'` — `SendInput` success.
- `[info] enter sent` — `Enter` sent.

## Troubleshooting

### Serial port not found
The program retries every 2s. Specify the port: `xemonitor --port COM3` or `export XEMONITOR_PORT=COM3`.

### Broken CH340 driver on Windows (error 31 / AccessDenied)
Use the WSL2 TCP bridge flow (`run_bridge.bat`). Driver diagnosis: reinstall/diagnose the CH340.

### UIPI blocking injection on Windows
`SendInput` works Medium→Medium; it returns 0 if the target has higher integrity. Run `xemonitor` and the target editor **non-elevated**.

### No injection on Linux
- Wayland: make sure `ydotool` is installed (and the `/run/user/.../.ydotool_socket` socket).
- X11: make sure `xdotool` is installed.
- Text is typed where the focus is — the `injected` log does not guarantee editor focus.

### Bridge cannot open `/dev/ttyUSB0`
A newly added group (`uucp`) only takes effect after a new login — use `sg uucp -c '...'` in the current session, or let the systemd service run (root opens the serial). The `MODE="0666"` udev rule also grants access to any user.

## Roadmap

- [x] Virtual keyboard on Windows (`SendInput`, validated) and Linux (`ydotool`/`xdotool`, validated).
- [x] Linux installer + Release workflow (v0.1.0).
- [ ] Windows installer (next-next-finish wizard).
- [ ] Migrate the WSL bridge from Arch/systemd → Alpine/OpenRC (the static musl binary already runs on Alpine).
