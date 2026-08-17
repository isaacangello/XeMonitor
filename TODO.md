# TODO — XeMonitor

Plano de trabalho da sessão atual. Atualizado conforme o progresso.

---

## v0.6.0 — Instalação robusta: módulo ch341 + modo Reparo (2026-08-16)

> Scan físico com a versão instalada **validado** (injeção ponta a ponta). Esta rodada
> automatiza as intervenções que fizeram o sistema funcionar e blinda o instalador.
> Release v0.6.0 só após revalidar a instalação (decisão do usuário).

### Intervenções que fizeram funcionar (a automatizar)
1. `resolveBridgeCtl` fallbacks `../scripts` + `../../scripts` (dev) — já feito (`src/gui.zig:386`)
2. **GUI não-elevado** via tarefa `XeMonitor-App` `/RL LIMITED` (elevado = freeze + UIPI bloqueia SendInput)
3. Reattach CH340 manual: `usbipd attach --wsl=Alpine -b 4-5` (a tarefa `XeMonitor-USB-Attach` falhou silenciosamente)
4. **`modprobe ch341`** — módulo NÃO auto-carrega no Alpine; sem ele `/dev/ttyUSB0` não aparece
5. `bridge_ctl restart` após o attach

### Plano
- [ ] **setup_wsl.sh**: boot cmd do wsl.conf → `modprobe usbip-core && modprobe vhci-hcd && modprobe ch341`; `lsmod | grep ch341` ao final
- [ ] **setup_usb.bat**: pós-attach → verificar/`modprobe ch341` → poll `/dev/ttyUSB0` (15s) → log em `%APPDATA%\xemonitor\setup-usb-task.log` → exit code ≠0 em falha
- [ ] **bridge_ctl.bat**: ação `ch341` = `modprobe ch341 && test -c /dev/ttyUSB0`
- [ ] **install_windows.bat**: detectar instalação existente → `[R]eparo/[N]ova/cancelar` (`/silent`=auto-reparo); reparo idempotente (kill+recopy+setup_wsl+tasks+usb+bridge+GUI via tarefa); backup+reset do `xemonitor-gui.conf`; lockfile single-instance; validar `%DISTRO%` no passo 4; PID no log
- [ ] **xemonitor.iss**: `[Run]` do GUI → `schtasks /Run /TN XeMonitor-App` (nunca exe direto do instalador elevado)
- [ ] **gui.zig repairWorker**: passo `bridge_ctl ch341` antes do poll
- [ ] **diagnose_windows.bat**: `check_ch341` no `--check` e `--fix`
- [ ] Investigar falha silenciosa da tarefa `XeMonitor-USB-Attach` (log + exit code + retry)
- [ ] Bump v0.6.0 (`.rc`/`.iss`/`build.zig.zon`) + rebuild ReleaseSafe + ISCC + validação
- [ ] Docs (.checkpoint.md, AGENTS.md, CHANGELOG.md) + commit + tag `v0.6.0` + `gh release`

---

## v0.7.1 — Uninstall automatico + Alpine fresh (2026-08-17)

> Inno Setup desinstala qualquer versao existente antes de instalar. Alpine
> sempre reimportado fresh. Corrige o problema do instalador fechar ao
> detectar instalacao existente.

### Feito
- [x] **xemonitor.iss**: `UninstallExistingInstall=yes` — desinstalacao automatica
- [x] **xemonitor.iss**: `taskkill` no `[UninstallRun]` antes do `uninstall_autostart.bat`
- [x] **xemonitor.iss**: removido `skipifsilent` do `[Run]` step 2 (GUI inicia apos install)
- [x] **install_windows.bat**: Alpine sempre fresh (remove + reimport em vez de reutilizar)
- [x] **Bump 0.7.1**: xemonitor.rc, build.zig.zon, xemonitor.iss, install_windows.bat
- [x] **CHANGELOG.md**: entrada v0.7.1

### Pendente
- [ ] Build + test + ISCC + validacao
- [ ] Commit + tag `v0.7.1` + `gh release`

---

## v0.7.0 — Reformulação do Instalador Windows (2026-08-17)

> Instalador reestruturado em 4 fases claras. Elimina fragilidade do `sh -c`
> com paths complexos. Scripts gerados via echo no .bat, copiados e executados
> dentro do Alpine. Dependências verificadas ANTES de serem usadas.

### Feito
- [x] **wsl_timeout.ps1**: novas tasks `copy_file` e `run_script`; removidas `setup_wsl`, `copy_bridge`, `copy_openrc`, `copy_systemd`; download do Alpine removido (fica no bat)
- [x] **install_windows.bat**: reescrito em 4 fases (Windows deps → Alpine deps → Alpine config → Final); gera scripts via echo; logs em `%APPDATA%\xemonitor\logs\`
- [x] **setup_usb.bat**: removido `apk add kmod` (Fase 2 garante); logs em `logs\`
- [x] **start_bridge.cmd / start_xemonitor.cmd**: logs movidos para `logs\`
- [x] **xemonitor.iss**: `setup_wsl.sh` removido dos `[Files]`
- [x] **Bump 0.7.0**: xemonitor.rc, build.zig.zon, xemonitor.iss
- [x] **CHANGELOG.md**: entrada v0.7.0

### Pendente
- [ ] Build + test + ISCC + validação do zero (remover Alpine, instalar do 0.7.0)
- [ ] Commit + tag `v0.7.0` + `gh release`
- [ ] Atualizar docs/install-flow-v0.7.2.md para v0.7.0

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
- [x] **2026-08-16 (2ª sessão v0.5.1)**: fix hang do GUI (spawn síncrono de `wsl.exe` no main loop → `portIsOpen` + threads), botão **Reparar** (USB via tarefa `XeMonitor-USB-Attach` + restart bridge + relança cliente), `diagnose_windows.bat` (--check/--fix/--test-serial/--help), VERSIONINFO 0.5.1 nos exes
  - `src/gui.zig`: `watchdogTick` spawna `devCheckWorker` (thread; `runBridgeCtlOk`), `wslAction` assíncrono no Windows, `startRepair`/`repairWorker`, `spawnClient` retorna addr, botão Reparar (gray + guard, dvui sem `.enabled`), `drainAsyncMsg` no main loop; `zig build`/`build test`/`build gui` OK
  - `src/i18n.zig`: chaves `btn_repair` + `msg_repair_*` (us/pt_br)
  - `assets/xemonitor.rc`: bloco `VERSIONINFO` 0.5.1 (xemonitor.exe e xemonitor-gui.exe)
  - `diagnose_windows.bat` criado: corrigidos CRLF, `goto :main`, e **parênteses em strings dentro de blocos `if (...)`** (causa do ". foi inesperado"; `:report` agora usa `if`s de linha única); `--check`/`--help`/`--test-serial` validados; `timeout 1 dd` no test-serial (não pendura sem scan)
  - setup ReleaseSafe recompilado: `dist\XeMonitor-0.5.1-setup.exe` **SHA256=`0E7149C9EA2A70D72C581EB952FDDC9284498FC6AAB339F1BC1E6860C3449587`**
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