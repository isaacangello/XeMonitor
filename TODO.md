# TODO — XeMonitor

Plano de trabalho da sessão atual. Atualizado conforme o progresso.

---

## v0.8.0 — Install Linux robusto (2026-08-29)

> Sessão: usuário reportou que `install.sh` "completa" mas não funciona
> em CachyOS (KDE Wayland). Análise de todo o histórico + patches Faixas
> 1+2+3 (autodetect device, askpass, detecção sessão/libc, banner logout,
> status real, --client-only/--bridge-only, driver/kernel check, DTR/RTS
> confirm, diagnose no tarball).

### Pendente (validação final)
- [ ] Commit + tag `v0.8.0` + `gh release`
- [ ] Validar WSL2 (Alpine/OpenRC) — TODO pós-release
- [ ] Validar Docker (`--device /dev/ttyUSB0`) — TODO pós-release

### FEITO nesta sessão (real install CachyOS, EXIT=0 e validação TUDO OK)
- [x] Fix: `local` no top-level (linha 690 + 550/807/832/930) abortavam com `set -euo pipefail`
- [x] Fix: ydotool unit — Arch/CachyOS usa `ydotool.service` (não `.socket`); install agora detecta a unit certa e valida na sessão/status
- [x] Fix: grupos — Arch não tem grupo `dialout` (só `uucp`); install adiciona só grupos existentes e `check_groups` ignora grupo inexistente (elimina aviso falso)
- [x] Fix: validação da porta 9000 com retry (restart do bridge pode demorar)
- [x] Fix: `check_update` comparava versão errada (avisava "1.3.0 mais nova" quando local=1.4.0); agora `ver_newer` (semver)
- [x] Real install (`bash install.sh` no CachyOS) roda limpo: EXIT=0, TUDO OK, status block com 5 OKs
- [x] Bridge: `sleepNs(200ms)` após `TIOCMBIS` em `configureSerial` — sem delay o driver `ch341-uart` não aplicava DTR/RTS a tempo; scan cru `7898773920105\r\n` (15 bytes) agora injetado de ponta a ponta no Kate
- [x] Scan físico validado (CachyOS): `7898773920105` → bridge → TCP → injeção no Kate

### Já implementado (v0.8.0)
- [x] install.sh 1.4.0: autodetect device, detecção sessão, install injetor
- [x] install.sh 1.4.0: banner logout, status real, --client-only/--bridge-only
- [x] install.sh 1.4.0: pre-check driver, reinstall=restart
- [x] bridge.zig: autoDetectSerial, --device, --print-device, DTR/RTS confirm
- [x] gui.zig: askpass (kssh/zenity/yad/xterm), detecção system vs user unit
- [x] units: source /etc/xemonitor/device
- [x] diagnose_xemonitor.sh: seção Driver & kernel
- [x] release.yml: tarball inclui diagnose
- [x] versionamento: build.zig.zon 0.7.2→0.8.0, xemonitor.rc, xemonitor.iss

---

## OBSOLETO (versões já released/integradas)

### v0.7.2 — Erros silenciados do bridge agora propagam (2026-08-17)

> Logs reais do usuário mostraram o problema: bridge inicializou às 18:44,
> morreu às 18:45 (`EndOfStream`), e o cliente ficou **12h em loop
> `TCP connect failed`** sem que a tarefa `XeMonitor-Bridge` religasse o
> serviço. `bridge-task.log` inexistente confirmou: a tarefa não subiu o
> serviço, e o instalador mentiu "Bridge iniciado". v0.7.2 faz todos esses
> erros silenciados virarem `_FATAL`.

### v0.7.1 — OBSOLETO
### v0.7.0 — OBSOLETO
### v0.6.1 — OBSOLETO
### v0.6.0 — OBSOLETO
### v0.5.1 — OBSOLETO

> Versões já integradas no CHANGELOG/main branch. Mantidas no CHANGELOG para histórico.

---

## Roadmap (visão geral)
1. ✅ **Windows**: `xemonitor`/`xemonitor-gui` injeta via `SendInput` (validado; fake-scan ponta a ponta; **scan físico validado** em 2026-08-15 após fix DTR/RTS no bridge)
2. ✅ **Linux**: `xemonitor` injeta via uinput/ydotool (validado no CachyOS)
3. ✅ **Migração WSL Arch→Alpine/OpenRC/musl** (item 2 acima — validado)
4. ✅ **GUI Windows + instalador Inno Setup** (item 3 acima — GUI principal; CI/CD Windows builda setup.exe)
5. ⏳ **v0.8.0 release** (validação CachyOS + tag + release) — implementação completa; falta E2E + commit/tag
6. ⏳ **WSL2 + Docker** — TODOs pós-v0.8.0 (autodetect via by-id; WSL precisa usbipd attach; Docker precisa `--device` manual)

(End of file - total 161 lines)