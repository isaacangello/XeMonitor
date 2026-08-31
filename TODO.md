# TODO — XeMonitor

Plano de trabalho da sessão atual. Atualizado conforme o progresso.

---

## v0.8.0 — Sessão 2: Miniroot versionado por `bridge` (2026-08-30)

> Continuação da v0.8.0 focada no instalador Windows. Substitui a golden
> image estática (que copiava o bridge para o VHD) por **miniroots
> versionados por `bridge_version.bridge_build`**, gerados automaticamente
> em cada `zig build bridge` e validados antes de irem pro instalador.

### Plano de execução (6 etapas)
1. [x] **Etapa 0 — Versionamento do `bridge`**
   - `build.zig.zon` ganha `.bridge_version = "0.8.0"` (semver, independente
     da versão do app).
   - `build.zig` resolve `BRIDGE_BUILD` (contador) com fallback
     arquivo `zig-out/.bridge_build` → env `XM_BRIDGE_BUILD` → `001`.
     Auto-bump a cada `zig build bridge`.
   - `src/bridge.zig` recebe `BRIDGE_VERSION`/`BRIDGE_BUILD`/`BRIDGE_ARCH`
     via `addOptions` (não `addCMacro` — Zig 0.16 mudou a API).
   - Flags: `--version` ("Xe. 0.8.0 bridge 003"), `--print-version`
     ("0.8.0.003"), `--print-arch` ("x86_64-linux-musl"), `--version-json`.
   - Step `build-bridge-miniroot` registrada (em Linux: chama script;
     em Windows: skip + aviso).
   - **Validado**: `zig build bridge` → 4x sucessivos produzem bridge
     0.8.0.001 → 0.8.0.004 com auto-bump do contador. Flags funcionam
     em WSL Alpine. `zig build`/`test`/`gui` todos verdes.

2. [x] **Etapa 1 — Geração automática de miniroot**
   - `scripts/build_miniroot.sh` (POSIX sh, **não** bash) orquestra o
     ciclo completo: importa minirootfs, roda `build_golden_alpine.sh`
     (reutilizado), valida `rc-service start + porta 9000`, exporta
     com nome versionado, aplica rolling 10.
   - Auto-detecta `wsl.exe` em múltiplos paths (resolve PATH case-mismatch
     no DrvFS: `/mnt/c/Windows/System32/wsl.exe` vs `/mnt/c/WINDOWS/...`).
   - `wsl --import`/`--export` chamados de dentro do WSL precisam de
     path Windows com **forward slashes** (`C:/wsl/...`), não backslashes
     nem paths WSL (`/mnt/c/...`).
   - VHD temporário em `C:\wsl\XeMonitor-Miniroot-<ver>-<build>`, limpo
     no fim via `trap cleanup EXIT`. Não usa `wsl --shutdown` (derruba
     todas as distros).
   - `packaging/windows/miniroots/` (rolling 10) + `.gitkeep`.
   - **Validado**: tarball `alpine-bridge-0.8.0.004-x86_64.tar.gz` (28.4 MB)
     gerado, importado como `Alpine-Test`, confirmado `/usr/local/bin/
     xemonitor-bridge` executável, init script OpenRC sem CRLF,
     `bridge --version` → `Xe. 0.8.0 bridge 010`.

3. [ ] **Etapa 2 — Staging dir + fix do `install_windows.bat`** (em progresso)
   - `scripts/make_install_staging.ps1` (novo): monta `zig-out\staging\
     XeMonitor\` reproduzindo o layout do Inno. **Validado**.
   - `scripts/run_install_test.bat` (novo): wrapper que monta staging,
     faz `cd /d <staging>` (= WorkingDir do Inno), chama `install_windows
     .bat /silent` elevado, log em `%TEMP%`. **Validado** (log path).
   - Simplificou detecção `%APP_DIR%` no bat: agora é `set "APP_DIR=
     %CD%"` com validação de `packaging\windows\install_windows.bat`
     no CWD. Removido o fallback `..\..\build.zig` (bugado) e o
     `set "APP_DIR=%CD%"` dentro de bloco `( )` (delay expansion).
   - Parênteses em `echo` dentro de `if (...)` (linha 409): `(golden)`
     → `golden`. **Era a causa do `. foi inesperado`**.
   - Log escreve em `%TEMP_LOG%` (temp) e move para `LOGFILE` no fim —
     libera `rd /s /q %APPDATA%\xemonitor` na SANITIZACAO. **Validado**.
   - `run_install_test.bat` log em `%TEMP%\xemonitor-install-test-*.txt`
     (não em `%APPDATA%`) — mesma razão. **Validado**.
   - Fase 3 (cópia bridge para VHD) **removida** — miniroot já traz o
     bridge pre-baked.
   - Fase 1 [5] agora seleciona o tarball mais recente em
     `%APP_DIR%\packaging\windows\miniroots\alpine-bridge-*.tar.gz`.
   - Bug pré-existente corrigido: `set "DISTRO=Alpine"` movido para
     ANTES do `alpine_ok2` (era usado antes de ser definido).
   - **wsl_timeout.ps1**:
     - LF normalization do `argLine` (CRLF quebraria `set -e`).
     - **Quoting externo** de `sh -c '...'` (single quotes) ao invés de
       `sh -c "..."` (double). Aspas internas no script (paths com
       espaços) confundiam o parser do Windows que é chamado de
       `ProcessStartInfo.Arguments`.
     - Fallback manual se `rc-service start` falhar com lock error:
       executa `/usr/local/bin/xemonitor-bridge` direto em background
       e grava pid em `/run/xemonitor-bridge.pid`.
     - Validação de porta 9000 com `ss` OU `netstat` (Alpine miniroot
       só tem `netstat` do busybox).
     - `mkdir -p /run /run/openrc /run/lock` antes do `rc-service`
       (lock files precisam do dir).
   - **Validado parcial**: SANITIZACAO OK, Fase 1 OK, Fase 3 (no-op) OK,
     `svc_enable: OK`, bridge na 9000 confirmado. Última run travou em
     **svc_verify: rc=1** antes de eu corrigir o fallback netstat do
     `svc_status`. A corrigir na retomada.

4. [ ] **Etapa 3 — Inno Setup + release.yml** (pendente)
   - `xemonitor.iss` [Files]: substitui `xemonitor-alpine-3.24.1-*.tar.gz`
     por wildcard `alpine-bridge-<ver>.<build>-*.tar.gz` (precisa de
     `Check:` function Pascal Script).
   - `[UninstallRun]`/`[UninstallDelete]` ajustados.
   - `.gitignore` mantém `zig-out/` (cobre `.bridge_build` e `staging/`).
     Miniroots em `packaging/windows/miniroots/` **não** ignorados (rolling
     10 no repo).
   - `release.yml` ganha step `build-bridge-miniroot` no job `build-linux`
     (versão bash do `build_miniroot.sh` para CI sem WSL); job
     `build-windows` baixa o asset antes do ISCC.

5. [ ] **Etapa 4 — Build, ISCC, validação 2x** (pendente)
   - `zig build` + ISCC → setup.exe 0.8.0.
   - `scripts\run_install_test.bat` 2x seguidas (validar sanitização).

6. [ ] **Etapa 5 — Documentação local** (pendente)
   - `docs/bridge-versioning.md` (novo): tabela de bump (qual arquivo
     editar quando muda MAJOR/MINOR/PATCH/build).
   - `docs/installer-concepts.md` (atualizado): seção "miniroot estático
     por bridge" substitui "golden image".
   - `CHANGELOG.md` entrada v0.8.0 com a nova arquitetura.
   - `.checkpoint.md` entrada da sessão (decisões 1-12 + A-C + Plano
     executado + Resultado parcial).
   - `AGENTS.md` nota sobre staging dir, cache de miniroots, versionamento.
   - Sem commit/push até revisão do usuário.

### Decisões cravadas nesta sessão
- 1-12 + A-C do plano consolidado (ver `.checkpoint.md` desta sessão).
- Saída `--version` é single-line `Xe. 0.8.0 bridge 003` (palavra
  "bridge" substitui "build").
- Miniroot naming: `alpine-bridge-<version>.<bridge_build>-x86_64.tar.gz`.
- Auto-bump incondicional do `bridge_build` em todo `zig build bridge`.
- Sem B2 (bind mount). Bridge sempre dentro do miniroot.
- 1 miniroot por `bridge` (cada compilação do bridge gera um miniroot
  novo no `build_miniroot.sh`).
- Inno Setup referencia 1 miniroot empacotado (fonte autoritativa);
  sem cache no instalador.

### Bloqueios / pendências
- Staging dir em `zig-out\staging\XeMonitor\` ficou locked no fim da
  última run; precisa cleanup manual (provavelmente handle do explorer).
- A retomar: corrigir `svc_status` (fallback netstat — já fiz), re-rodar
  `run_install_test.bat` 2x, ISCC + commit em branch local.

---

## v0.8.0 — Sessão 1: Install Linux robusto (2026-08-29)

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