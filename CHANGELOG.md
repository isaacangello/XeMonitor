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

### Changed
- Replaced all `std.debug.print` calls with `logPrint()` for unified logging
- Refactored main loop to support serial/TCP/stdin modes cleanly
- Updated usage/help text with new flags
- Fixed `build.zig.zon` serial dependency URL to a pinned commit

### Added (new files)
- `.gitignore` — ignore build output and cache
- `.checkpoint.md` — development session context
- `.ai/` — AI tooling configuration
- `ORIENTACAO.md` — user guide (Portuguese)
- `run_xemonitor.bat` — compile & run script
- `run_bridge.bat` — bridge startup script (WSL2 + xemonitor)
- `stop_bridge.bat` — stop all bridge processes
- `setup_wsl.sh` — WSL2 udev rule for CH340
- `test_com4.ps1` — PowerShell COM4 connectivity test
- `src/bridge.py` — Python bridge alternative (stdlib-only)
- `setup_usb.bat` — automated USB setup via usbipd (admin auto-elevation)

### Changed
- `setup_wsl.sh` — now also configures wsl.conf for kernel modules (usbip-core, vhci-hcd) and passwordless sudo for modprobe
- `run_bridge.bat` — checks USB availability, offers to run setup_usb.bat automatically, compiles bridge if needed
