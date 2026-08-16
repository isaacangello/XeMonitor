# TODO — XeMonitor

Plano de trabalho da sessão atual. Atualizado conforme o progresso.

---

## Pendentes para a próxima sessão no Windows

### 1. (Concluído) Validação no Windows (scan físico + UIPI)
- [x] Scan físico → **VALIDADO (2026-08-15)**: o scanner bipava/luzia mas a captura crua em `/dev/ttyUSB0` não recebia bytes. Causa raiz: **bridge não acionava DTR/RTS** — o Honeywell 1900 em modo serial só transmite com DTR/RTS ativas. Corrigido em `src/bridge.zig` (`ioctl(TIOCMBIS)` com `TIOCM_DTR|TIOCM_RTS` após `tcsetattr`); bridge reinstalado em `/usr/local/bin/xemonitor-bridge` no Alpine. Scan físico validado de ponta a ponta: `7898405966679`/`7898567704461` → bridge → TCP 9000 → cliente → `SendInput` → Bloco de Notas.
  - CH340 attachado ao WSL (COM6, busid 4-1, usbipd Shared); `/dev/ttyUSB0` no Alpine (mknod manual, udevd via `/sbin/udevd --daemon`)
  - Fake-scan validado de ponta a ponta (bridge Alpine → xemonitor-gui → cliente → SendInput): `TEST10` + `enter sent`
- [x] UIPI: xemonitor e editor em integridade **Média** (não elevado) — validado em sessões anteriores

### 2. (Concluído) Migração WSL: Arch/systemd → Alpine/OpenRC
- ✅ Alpine 3.24.1 instalado via rootfs (`wsl --import Alpine C:\wsl\Alpine`)
- ✅ `setup_wsl.sh` adaptado (udevadm com timeout + softlevel OpenRC; wsl.conf sem systemd)
- ✅ `openrc/xemonitor-bridge` (sem `need net`); `install_bridge_service.sh` cria softlevel
- ✅ `bridge_ctl.bat` detecta Alpine/OpenRC primeiro, Arch/systemd fallback
- ✅ Fake-scan ponta a ponta no Alpine validado; porta 9000 OK

### 3. (Concluído) GUI Windows + instalador
- ✅ `zig build gui` compila para Windows (fixes portabilidade em gui.zig/tray.zig)
- ✅ GUI como app principal: modo `wsl` usa `bridge_ctl.bat`; cliente resolve `xemonitor.exe` ao lado do exe
- ✅ `xemonitor.iss` / `install_windows.bat` / `start_xemonitor.cmd` / `install_autostart.bat` → GUI
- ✅ Validado no Windows: janela + auto_start + cliente + injeção SendInput (TEST10)

### 4. (Em andamento) v0.5.1: docs + tag/release
- [x] Atualizar docs (AGENTS.md, README, README.pt-BR, CHANGELOG, .checkpoint.md, TODO.md, docs/windows-installer.md)
- [x] `build.zig.zon` → 0.5.1
- [x] Fix bridge DTR/RTS + scan físico validado de ponta a ponta (bloqueio de release removido)
- [x] v0.5.1 fixes: GUI subsystem (sem terminal), feedback USB-Serial (instalador + GUI + `bridge_ctl dev`), init script OpenRC no instalador, `wsl --install -d Alpine`, `setup_usb.bat` no instalador, `[Run]` elevado+visível `/silent`, `[Run]` GUI `runascurrentuser`, `scripts/patch_sdl3_release.ps1`
- [x] **Fix `. foi inesperado` no cmd** (2026-08-16): remover parênteses dentro de strings em blocos `if (...)` multi-linha (`install_windows.bat`, `setup_usb.bat`, `run_bridge.bat`, `bridge_ctl.bat`) + remover em-dash UTF-8 (byte 0xE2 0x80 0x94) de `.bat` (cmd parseia em codepage OEM)
- [x] Instalador E2E validado (EXIT=0): passos 1-7c OK; Alpine baixado do site/importado/default; bridge → `/usr/local/bin/xemonitor-bridge`; init OpenRC registrado (`rc-update add ... default`); serviço **started** escutando 9000; TCP 9000 conectado; tarefas agendadas criadas; `setup_usb.bat /silent` EXIT=0
- [x] setup.exe recompilado com os `.bat` corrigidos: `dist\XeMonitor-0.5.1-setup.exe` SHA256=`4CAB3BE841CCA37DC730AD5626D65457F986A0986399978410E3531D53A6FAC6` (ISCC em `C:\Users\isaac\AppData\Local\Programs\Inno Setup 6\ISCC.exe`)
- [ ] Investigar log anômalo da instalação real do usuário (3 passadas intercaladas no `xemonitor-install.log`; 1ª com `%DISTRO%` vazio/rc=-1 → console mostrou "falhou ao copiar o bridge", mas bridge foi copiado na 2ª passada). Teste isolado do `:log` com parênteses passou limpo → causa provável: processos cmd concorrentes no mesmo .bat/log (não reproduzido). Blindar `install_windows.bat`: single-instance lockfile, validar `%DISTRO%` no passo 4, log com PID
- [x] Fix `zig build test` quebrado: PNG estava em `src\Barcode Scanner.png` mas o `build.zig` referenciou `b.path("Barcode Scanner.png")` (raiz) → `file_hash FileNotFound`. Corrigido nas 2 linhas; build test volta a passar
- [x] `dist/` adicionado ao `.gitignore` (setup.exe é artefato de build; release via `gh release upload`)
- [ ] Decidir migração do `xemonitor-gui.conf` antigo (passo 5b preserva `server_mode=subprocess auto_start=false`; instalador só grava `wsl+auto_start=true` quando o conf não existe)
- [ ] Revalidar `setup.exe` com UAC real (duplo clique) após investigação
- [ ] Commit + tag `v0.5.1` + `gh release create` + upload do `setup.exe` (após validação do usuário com UAC real)

---

## Histórico — já concluído (tags pushed)

## Histórico — já concluído (tags pushed)

### v0.4.0 (2026-08-15) — i18n + quit dialog + header compacto + histórico scroll + tema runtime
- Fix deadlock `ManagedProc.stop()` (SIGTERM→SIGKILL por pid antes do mutex)
- Diálogo de confirmação de encerramento (botão "Encerrar" + bandeja "Sair")
- `src/i18n.zig`: tabelas `us`/`pt_br`, `t(comptime key)`, `formatInto({s}/{d})`
- Config `lang` + seletor dropdown no painel
- Header compacto: idioma + "Encerrar" no topo ao lado de "XeMonitor"
- Histórico: `scrollArea` vertical auto + stick-to-bottom
- Tema claro/escuro runtime via `SDL_EVENT_SYSTEM_THEME_CHANGED`
- Janela 880x660 (geometria persistida antiga removida)

### v0.3.1 (2026-08-14) — Desinstalador no sistema
- `uninstall.sh` empacotado no release como `xemonitor-uninstall` em `/usr/local/bin`
- `install.sh` 1.2.2 instala o desinstalador; auto-descobre prefixo; `--purge` remove config+logs

### v0.3.0 (2026-08-14) — Log rotativo + uninstaller + Ubuntu/Debian compat
- Log datado `xemonitor-YYYY-MM-DD.log` (reabre na virada do dia)
- `uninstall.sh` na raiz (mantém config; `--purge` remove tudo)
- CI em `ubuntu-22.04` (glibc 2.35); `install.sh` instala `libdbus-1-3 libsystemd0`, grupo `input`, udev uinput

### v0.2.0 (2026-08-14) — Pasta central + GUI melhor + autostart
- `src/paths.zig`: `~/.config/xemonitor` / `%APPDATA%\xemonitor` (override `XEMONITOR_CONFIG_DIR`)
- `src/uinput.zig`: injetor nativo `/dev/uinput` (padrão Linux; fallback ydotool/xdotool)
- GUI: layout histórico, ícone janela (`setWindowIcon`), ícone bandeja barcode branco
- Autostart XDG + unit systemd usuário opcional
- `install.sh` 1.1.0 instala `xemonitor-gui`, `.desktop`, autostart
- `release.yml` builda `xemonitor-gui` + inclui no tarball

### v0.1.0 — Base: bridge multi-conexão, systemd WSL, autostart Windows, release workflow
- Bridge TCP multi-conexão + testes (13 passing)
- `systemd/xemonitor-bridge.service` + `install_bridge_service.sh` (WSL)
- `run_bridge.bat` / `stop_bridge.bat` / `status_bridge.bat`
- `scripts/install_autostart.bat` (3 tarefas agendadas `/rl LIMITED`) — instaladas
- `.github/workflows/release.yml`: tags `v*` → musl ReleaseSafe + tarball
- `install.sh`: curl|bash → release + udev + grupos + serviço (systemd/OpenRC)

---

## Roadmap (visão geral)
1. ✅ **Windows**: `xemonitor`/`xemonitor-gui` injeta via `SendInput` (validado; fake-scan ponta a ponta; **scan físico validado** em 2026-08-15 após fix DTR/RTS no bridge)
2. ✅ **Linux**: `xemonitor` injeta via uinput/ydotool (validado no CachyOS)
3. ✅ **Migração WSL Arch→Alpine/OpenRC** (item 2 acima — validado)
4. ✅ **GUI Windows + instalador** (item 3 acima — GUI principal; instalador real validado na v0.5.1)
5. ⏳ **v0.5.1 release** (item 4 acima)