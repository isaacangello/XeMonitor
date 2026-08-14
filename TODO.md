# TODO — XeMonitor

Plano de trabalho da sessão atual. Atualizado conforme o progresso.

## Organização v0.2.0 (sessão atual)
> Alvo: pasta central de config/log, GUI com layout/ícone melhores, autostart e
> instruções do instalador Windows.

### Código
- [x] **Layout do GUI**: lista de scans/logs em nova linha abaixo de "Histórico (últimos scans)" (box horizontal do cabeçalho fechado com bloco `{}`; botões Copiar/Exportar não roubam mais a coluna esquerda)
- [x] **`src/paths.zig`** (novo): `openConfigDir` + `joinPath` — resolve/cria Linux `~/.config/xemonitor` (ou `$XDG_CONFIG_HOME`), Windows `%APPDATA%\xemonitor` (fallback `%LOCALAPPDATA%`), override `XEMONITOR_CONFIG_DIR`, fallback cwd
- [x] **`src/main.zig`**: `xemonitor.log`, `xemonitor.pid`, `xemonitor_tray.pid` → pasta central (via `paths`)
- [x] **`src/gui.zig`**: `xemonitor-gui.conf`, `xemonitor-gui.pid`, `log_path` padrão → pasta central; `setWindowIcon()` (SDL3, barras do barcode; X11 via `SDL_SetWindowIcon`, Wayland via `.desktop`)

### Scripts / instalação
- [x] `run_xemonitor.sh`: `CFG_DIR="${XEMONITOR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/xemonitor}"`; cria pasta; config + log no `$CFG_DIR`
- [x] `status_xemonitor.sh`: reporta pasta central + arquivos (tamanhos) + tail do log
- [x] `status_bridge.bat`: reporta `%APPDATA%\xemonitor` + tail do log
- [x] `install.sh` → **1.1.0**: instala `xemonitor-gui`, `.desktop` (share/applications), autostart XDG, `~/.config/xemonitor` + config padrão, unit systemd de usuário opcional; resumo atualizado
- [x] `.github/workflows/release.yml`: `zig build gui -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe` (apt `libsdl3-dev libdbus-1-dev`) + `xemonitor-gui` no tarball

### Autostart (Q2 — "os dois")
- [x] Autostart XDG no login: `~/.config/autostart/xemonitor.desktop` (via install.sh)
- [x] Unit systemd de usuário opcional: `systemd/xemonitor-gui.service` → `/etc/systemd/user/` (não habilitada por padrão p/ não duplicar com autostart)

### Instalador Windows (instruções)
- [x] `docs/windows-installer.md`: wizard next-next-finish (Inno Setup recomendado) + como foi feito antes (scripts .bat/`install_autostart.bat` + tarefas agendadas `/rl LIMITED`)

### Docs
- [x] `CHANGELOG.md` (seção Unreleased v0.2.0), `README.md`, `README.pt-BR.md`, `AGENTS.md`, este `TODO.md`
- [x] `assets/xemonitor.desktop` (Entry Type=Application, `Icon=xemonitor`)

### Verificação
- [x] Rebuild `zig build` + `zig build gui` + `zig build test` — verdes (exit 0) após todos os edits
- [x] `XEMONITOR_CONFIG_DIR=/tmp/cfgtest`: cliente (`--stdin`) criou `/tmp/cfgtest/xemonitor/xemonitor.log` + `xemonitor.pid`, com `[scan]`/`[info] injected`/`enter sent`
- [x] GUI com config pré-escrita no cfg dir: abriu/renderizou (dvui 720x520), ícone OK, watchdog rodou (`computeBridgeStatus`), pid criado/removido no cleanup; saveConfig na saída limpa
- [x] `status_xemonitor.sh` com a estrutura nova (reporta `~/.config/xemonitor`, serviço, GUI, cliente, serial, grupos); `bash -n` nos `.sh` OK
- [x] `run_xemonitor.sh`: `bash -n` OK (execução interativa fica p/ o usuário — inicia bridge root + GUI em foreground)
- [x] Observação: no smoke test o `stopBridge` do deinit do GUI (modo `systemd-system`, `pkexec systemctl stop`) parou o bridge — comportamento pré-existente (fora do escopo v0.2.0)


## Infra / Git (concluído)
- [x] Tarefa agendada `init Docker WSL` ajustada (Boot + Logon) para iniciar WSL/Arch e garantir Docker via systemd
- [x] Docker ativo no WSL (v29.4.3, `systemctl enable docker`)
- [x] Excluir `ORIENTACAO.md` (obsoleto, conteúdo fundido no README/AGENTS)
- [x] Instalar `gh` (GitHub CLI 2.97.0) e autenticar como `isaacangello`
- [x] Chave SSH `ed25519` gerada com `isaacangello@inf.ufpel.edu.br` e adicionada ao GitHub
- [x] Remote `origin` trocado para SSH `git@github.com:isaacangello/XeMonitor.git`
- [x] `user.name`/`user.email` configurados no repositório

## Documentação
- [x] Criar `TODO.md` (este arquivo)
- [x] Criar `AGENTS.md`
- [x] Atualizar `.checkpoint.md` com o estado real
- [x] Atualizar `CHANGELOG.md`

## Bridge
- [x] Corrigir modo TCP do `src/bridge.zig` para aceitar múltiplas conexões (thread leitora serial → `SharedState`, loop `accept`, thread escritora por cliente)
- [x] Adicionar testes (`readSince`/`currentSeq`) e corrigir teste pré-existente
- [x] `zig build test-bridge` compilando + 13 testes passando (executados no WSL)

## Automação do bridge (systemd no WSL)
- [x] Criar `systemd/xemonitor-bridge.service` (ExecStartPre aguarda `/dev/ttyUSB0`, Restart=always)
- [x] Criar `scripts/install_bridge_service.sh` (copia binário para `/usr/local/bin/xemonitor-bridge`, instala/habilita, `--reinstall`)
- [x] Serviço instalado e habilitado no WSL (`systemctl is-enabled` = enabled)
- [x] Validado: TCP multi-conexão + reconexão após desconexão (2 clients simultâneos)
- [x] Atualizar `run_bridge.bat` para usar `wsl systemctl start xemonitor-bridge`
- [x] Atualizar `stop_bridge.bat` (stop serviço + taskkill)
- [x] Criar `status_bridge.bat`
- [x] Robustecer `setup_usb.bat` com fallback do caminho do usbipd

## Autostart no Windows
- [x] Criar `scripts/install_autostart.bat` (3 tarefas: USB attach, bridge, xemonitor) — **instaladas**
- [x] Criar `scripts/uninstall_autostart.bat`

## Instalador Linux + Release (versionamento)
- [x] Criar `.github/workflows/release.yml` (tags `v*` → build musl estático ReleaseSafe x86_64-linux + tarball `xemonitor-linux-x86_64.tar.gz` + publicação da Release)
- [x] Criar `install.sh` (baixa tarball da última Release; `sudo` para udev CH340 + grupos `uucp,dialout` + serviço; detecta systemd/OpenRC; `--prefix`/`--no-service`; override `XEMONITOR_VERSION`/`XEMONITOR_BASE_URL` p/ teste)
- [x] Testar `install.sh` no container Alpine (root): download, instalação em `/usr/local/bin`, regra udev, VERSION, binários executáveis
- [x] Builds ReleaseSafe musl validados localmente (xemonitor 4.4MB, bridge 4.3MB)
- [x] Versionamento definido: **v0.<recurso>.<correção>** (recurso → +meio, correção → +último) — primeira tag: **v0.1.0**
- [ ] Commit + tag `v0.1.0` + push + `gh release create` (aguardando OK do usuário)
- [ ] `git push -u origin main`

## Validação no Windows (quando voltar ao Windows)
1. [ ] `taskkill /F /IM xemonitor.exe` (matar antes de recompilar)
2. [ ] Rebuild: `C:\zig-x86_64-windows-0.15.2\zig.exe build`
3. [ ] `run_bridge.bat` (usbipd attach CH340 → systemd bridge → `xemonitor.exe --tcp 127.0.0.1:9000`)
4. [ ] Scan físico → log deve mostrar `[scan] '<código completo>'` (não `'TSSA00'`), `[info] injected '...'` e `[info] enter sent`
5. [ ] UIPI: xemonitor e editor em integridade Média (não elevado)

## Validação no CachyOS (concluída)
- [x] Fix TCP no `src/main.zig`: `rbuf [0]u8` no arm `.tcp` (o `netRead` anexa o buffer interno do reader como 2º iovec; reader novo por byte descartava o byte extra → `'TSSA00'`)
- [x] End-to-end com scanner real: bridge → TCP 9000 → `xemonitor --tcp` (ydotool) → Kate
- [x] Scan físico `7898121840147` → `[scan] '7898121840147'` completo, `[info] injected '...'`, `[info] enter sent`; texto chegou no editor
- [x] **Bridge sob systemd (Linux)**: unit de usuário `~/.config/systemd/user/xemonitor-bridge.service` (`ExecStart=/usr/bin/sg uucp -c '...bridge'`; wrapper dispensa re-login) → `systemctl --user enable --now` → `active`, serial aberto, porta 9000, scan OK
- [x] Nota: para abrir `/dev/ttyUSB0` sem re-login, usar `sg uucp -c '...'` (grupo `uucp` adicionado mas sessão antiga não o herdou)

## GUI Linux (dvui) — correções de sessão
- [x] **Toggle da bandeja não funcionava**: o loop principal bloqueava para sempre em `SDL_WaitEvent(null)` quando ocioso (`win.waitTime(end_micros)` retorna `maxInt(u32)` com `end_micros == null` → `waitEventTimeout(maxInt)` → `SDL_WaitEvent(null)`). Fix: `waitEventTimeout(@min(wait_event_micros, 250_000))` (poll de 250ms) em `gui.zig`. Validado via D-Bus `Activate` → `hidden=true/false=true` (3 alternâncias).
- [x] **Texto sobreposto no campo host:porta**: `dvui.textEntry()` deixa o widget como pai corrente (só restaurado no `deinit()`) → o `labelNoFmt("  :  ")` e o `te_port` eram criados **dentro do textLayout interno do `te_host`** (confirmado: parent=`TextEntryWidget.zig:213`, rect `x=-6,y=-6`). Fix: `te.deinit()` imediato (padrão dos exemplos do dvui — textEntry deve ser último filho), restaura o pai para a row. Agora `tPort rect={x=215,y=0,w=82,h=38}` ao lado do host (`{x=0,w=182}`), sem sobreposição, sem erro de `parentReset`.
- [x] `zig build gui` + `zig build test` passando (exit 0)

## GUI Linux — ícone da bandeja + export (sessão atual)
- [x] **Ícone barcode branco** em `src/icon.zig` (24x24 procedural; barras eram pretas → invisíveis no painel KDE; agora 255,255,255)
- [x] **`IconName` "system-run" → "xemonitor"** em `src/tray.zig` (GetAll + Get) — KDE resolvia do tema e ignorava o pixmap
- [x] **Botões de export** no `renderHistoryPanel`: **"Copiar"** (wl-copy via `.stdin=.pipe`; escopo = últimos 200 em memória, código por linha, sem prefixo) e **"Exportar arquivo"** (zenity `--file-selection --save`)
- [x] Fix double-close no `copyToClipboard` (`child.stdin = null` antes do `wait` — panic BADF no Zig 0.16)
- [x] Validado: clipboard (wl-paste), arquivo texto, SNI registrado, barcode branco visível após expandir itens ocultos do KDE; código temporário de teste removido
- [x] `zig build gui` + `zig build test` passando (exit 0)

## Migração WSL: Arch/systemd → Alpine/OpenRC (quando voltar ao Windows)
> Bridge é **musl estático** (provado via `readelf`: sem dynamic interpreter) → roda em Alpine sem recompilar. O trabalho é de **init + scripts**, não de código.
- [ ] Criar `openrc/xemonitor-bridge` (init script OpenRC; dispensa `ExecStartPre` — bridge já re-tenta serial a cada 2s)
- [ ] Adaptar `scripts/install_bridge_service.sh` → OpenRC (`rc-update add default` + `rc-service start`)
- [ ] `iniciar.bat` / `run_bridge.bat` / `stop_bridge.bat` / `status_bridge.bat`: `systemctl` → `rc-service` (`is-active`→`status`)
- [ ] `scripts/install_autostart.bat`: `wsl -d Arch` → distro Alpine + `rc-service start`
- [ ] `setup_usb.bat`: `usbipd attach -w Arch` → nome da distro Alpine
- [ ] `setup_wsl.sh`: remover `systemd=true` do wsl.conf; `apk add eudev kmod openrc`; `rc-update add udev` (regra udev MODE=0666 continua, dispensa grupo `uucp`)
- [ ] Instalar distro Alpine no WSL + testar OpenRC real + revalidar scan (item 3 da Validação no Windows)

## Roadmap (teclado nas duas plataformas)
1. [x] **Windows**: `xemonitor.exe` injeta via `SendInput` (validado; faltar revalidar após fix TCP — ver "Validação no Windows")
2. [x] **Linux**: `xemonitor` injeta via ydotool (Wayland) — validado no CachyOS (systemd) e WSL pode rodar local
3. [ ] **Instalador Windows** (next-next-finish) — só quando for ao Windows
4. [x] **Instalador Linux**: `curl -LsSf https://raw.githubusercontent.com/isaacangello/XeMonitor/main/install.sh | bash` (baixa Release, udev, grupos, serviço systemd/OpenRC) — pendente o commit+tag v0.1.0

## Pendências históricas (bridge)
- [x] Testar leitura real escaneando um código de barras (Honeywell 1900) — **feito no CachyOS** (código `7898121840147`)
