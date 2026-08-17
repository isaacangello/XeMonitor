# Changelog

## [Unreleased]

## [0.6.1] — 2026-08-16

### Fixed
- **Tarefa `XeMonitor-App` abria console visível** — o TR da tarefa apontava
  para `start_xemonitor.cmd` (wrapper `cmd.exe`) que criava uma janela de
  console. Agora aponta direto para `xemonitor-gui.exe` (subsystem=windows),
  sem console. Aplicado em `install_autostart.bat` e no fallback do
  `install_windows.bat`.

## [0.6.0] — 2026-08-16

### Added
- **Modo Reparo no instalador** — detecta instalação existente e oferece
  `[R]eparo / [C]ancelar` (ou auto-reparo com `/silent`). Reparo: kill
  GUI/cliente → recopia binários/scripts → `setup_wsl.sh` → recria tarefas →
  `setup_usb.bat` (attach + modprobe ch341 + poll 15s) → bridge → GUI via
  tarefa `XeMonitor-App` `/RL LIMITED`. Backup + reset de `xemonitor-gui.conf`.
- **Módulo `ch341` automatizado** — `setup_wsl.sh` adiciona `modprobe ch341`
  ao `[boot] command` do `wsl.conf` e verifica `lsmod` ao final. `setup_usb.bat`
  garante o módulo carregado *após* o attach com poll de `/dev/ttyUSB0` (15s)
  e log em `%APPDATA%\xemonitor\setup-usb-task.log`. `bridge_ctl.bat` ganha
  nova ação `ch341` (modprobe + test). `gui.zig` repairWorker executa
  `bridge_ctl ch341` antes do poll.
- **`diagnose_windows.bat --check/--fix`** camada `check_ch341` — verifica se o
  driver ch341 está carregado e `/dev/ttyUSB0` existe; `--fix` garante o módulo
  antes do poll.
- **Lockfile single-instance** no instalador — `xemonitor-install.lock` em
  `%TEMP%` evita que duas instâncias rodem em paralelo.
- **PID no log** do instalador — `%INSTALL_PID%` em cada linha de log para
  correlacionar com processos.
- **`diagnose_windows.bat` empacotado** no setup.exe (`{app}\diagnose_windows.bat`).

### Fixed
- **Instalador elevava o GUI** — `[Run]` passo 2 rodava `xemonitor-gui.exe`
  direto (herdando admin do setup) → GUI congelava (UIPI) e SendInput não
  injetava. Agora usa `schtasks /Run /TN XeMonitor-App` (tarefa `/RL LIMITED`).
- **Tarefa `XeMonitor-USB-Attach` pendurada** — `setup_usb.bat` sem `/silent`
  fazia `pause` no final, mantendo a tarefa "Running" indefinidamente. Agora
  a tarefa roda `setup_usb.bat /silent`.
- **Attach falhava silenciosamente no logon** — Alpine pode não estar pronto
  quando a tarefa `XeMonitor-USB-Attach` roda (~logon). `setup_usb.bat` agora
  faz poll de `wsl -d Alpine echo ok` (até 30s) antes do `usbipd attach`.
- **`%DISTRO%` vazio** — se o passo 3 do instalador falhasse, `%DISTRO%` ficava
  vazio e todos os `wsl -d` subsequentes retornavam rc=-1 silenciosamente.
  Validação explícita de `%DISTRO%` antes do passo 4; aborta com mensagem.

### Changed
- **Versão 0.6.0** (`assets/xemonitor.rc`, `packaging/windows/xemonitor.iss`,
  `build.zig.zon`).

## [0.5.1] — 2026-08-16

### Added
- **Botão "Reparar" na GUI (modo wsl/Windows)** — em um clique: para o bridge,
  reattacha o CH340 via tarefa agendada `XeMonitor-USB-Attach` (elevada, sem
  popup UAC), espera o `/dev/ttyUSB0` voltar (~15s), reinicia o bridge, mata o
  cliente órfão e relança o `xemonitor.exe` conectando na porta 9000.
- **`diagnose_windows.bat`** — diagnóstico/auto-recuperação no Windows, espelho
  do `diagnose_xemonitor.sh`: `--check` (WSL/CH340/bridge/porta/cliente/GUI/
  tarefas/UIPI/log), `--fix` (reattach USB + restart bridge + relança GUI) e
  `--test-serial` (leitura live do `/dev/ttyUSB0` por 8s, sem pendurar).
- **`VERSIONINFO` 0.5.1** nos binários Windows (`xemonitor.exe` e
  `xemonitor-gui.exe`) — `assets/xemonitor.rc` compartilhado.

### Fixed
- **Hang do GUI no modo wsl** — o main loop spawnava `wsl.exe` sincronamente a
  cada 1s (status) e 5s (check do device), congelando a janela. O status agora
  usa `portIsOpen(127.0.0.1:9000)` (sem spawn) e o check do device roda em
  thread; ações de bridge (`start/stop/restart`) também foram movidas para
  thread no Windows.
- **`. foi inesperado` no cmd** — parênteses dentro de strings em blocos
  `if (...)` multi-linha quebravam o parse do cmd nos `.bat` (aplicado também
  no novo `diagnose_windows.bat`).

### Changed
- **`xemonitor-gui.exe` agora é app de janela (subsystem GUI)** no Windows —
  sem terminal de console. O cliente `xemonitor.exe` continua console (CLI) e
  é spawnado com `create_no_window` (SDK `std.process.run`).
- **Instalador Windows reescrito para feedback real** — o `[Run]` do Inno roda
  `install_windows.bat` **elevado e visível** (`/silent` suprime os `pause`),
  mostrando o progresso `[1/7]..[7c]`; o GUI é lançado em seguida pelo
  `[Run]` com `runascurrentuser` (integridade **Média** — evita o bloqueio
  UIPI do `SendInput` ao injetar em apps não-elevados).
- **Feedback do scanner USB-Serial** — o instalador verifica `/dev/ttyUSB0`
  no WSL e avisa claramente quando o Honeywell 1900 USB-SERIAL (CH340) não
  está conectado; a GUI (modo `wsl`) também avisa na barra de status e o
  `bridge_ctl.bat` ganhou a ação `dev` para testar a presença do dispositivo.

### Fixed
- **Bridge no Alpine recém-instalado** — o `install_windows.bat` agora copia
  o init script `openrc/xemonitor-bridge` (e a unit systemd) para o WSL antes
  de `rc-update add`/`systemctl enable`; antes só rodava o `rc-update`, que
  falhava silenciosamente (`|| true`) numa distro nova.
- **`wsl --install` do Alpine** — corrigido para `wsl --install -d Alpine
  --no-launch` (a sintaxe `--name` usada antes não é válida).
- **Setup USB na instalação** — `install_windows.bat` agora executa
  `setup_usb.bat` ao final (attach do CH340 ao WSL), em vez de só criar a
  tarefa agendada.
- **translate-c no ReleaseSafe (Windows)** — `scripts/patch_sdl3_release.ps1`
  aplica o workaround do bug do translate-c (issue #327) no `sdl3-c.zig`
  gerado, permitindo `zig build gui -Doptimize=ReleaseSafe`.

## [0.5.0] — 2026-08-15

### Added
- **Migração WSL: Arch/systemd → Alpine/OpenRC** — distro WSL padrão passa a ser
  **Alpine** (menor footprint; fallback mantido para Arch). Novo init script
  `openrc/xemonitor-bridge` (sem `need net`; softlevel para WSL/container) e
  `scripts/install_bridge_service.sh` agora **detecta o init** (systemd vs
  OpenRC) e instala o serviço correto.
- **`scripts/bridge_ctl.bat`** — controla o serviço do bridge no WSL de forma
  transparente (detecta Alpine/OpenRC → `rc-service`, Arch/systemd →
  `systemctl`). Ações: `status | start | stop | restart | enable`; override de
  distro via `XEMONITOR_WSL_DISTRO`. Usado pelos scripts .bat, pelas tarefas
  agendadas e pelo GUI (modo `wsl`).
- **GUI como app principal no Windows** — o `xemonitor-gui.exe` passa a ser o
  executável inicial (janela + bandeja). No Windows:
  - modo `wsl` controla o bridge via `bridge_ctl.bat` (resolve o caminho junto
    ao exe: `<exe_dir>\scripts\bridge_ctl.bat` → `.\scripts\` → `.\`);
  - `startClient` resolve o `xemonitor.exe` como binário **irmão** do GUI
    (instalação/pasta de release);
  - a config `xemonitor-gui.conf` é gravada pelo instalador em
    `%APPDATA%\xemonitor` (`server_mode=wsl`, `auto_start=true`,
    `tray_enabled=true`, `lang=pt_br`).
- **Instalador Windows (`packaging/`)** — novo pacote em `packaging/windows`:
  - `xemonitor.iss` (Inno Setup, wizard next-next-finish): instala
    `xemonitor-gui.exe` + `xemonitor.exe` + bridge + scripts, roda
    `install_windows.bat` e inicia o GUI. `MyAppExeName=xemonitor-gui.exe`.
  - `install_windows.bat`: WSL2/usbipd/Alpine → setup_wsl.sh → bridge →
    binários em `%ProgramFiles%\XeMonitor` → config GUI → tarefas agendadas →
    início automático (bridge + GUI).
  - `start_xemonitor.cmd` / `start_bridge.cmd`: wrappers das tarefas agendadas
    (`/rl LIMITED` p/ UIPI média) com stdout/stderr em arquivo.
- **Autostart migrado para o GUI** — a tarefa `XeMonitor-App` roda
  `start_xemonitor.cmd` (que inicia o `xemonitor-gui.exe`, que lê a config e
  sobe bridge + cliente); `XeMonitor-Bridge` usa `bridge_ctl.bat enable`.
- **Portabilidade Windows no código** — `src/main.zig`, `src/gui.zig` e
  `src/tray.zig` compilam no Windows com Zig 0.16 sem `@cImport("time.h")`
  (datas/timestamps via `std.time.epoch`), `std.os.windows.GetCurrentProcessId`
  para PID, `child_pid` como `std.atomic.Value(u32)`, constantes Win32
  `GENERIC_READ/WRITE` etc. localmente, `BOOL.FALSE` explícito, e `szTip`
  com `std.mem.len`/`@min`.
- **Release empacota o fluxo novo** — `release.yml` inclui `openrc/`,
  `systemd/` e `scripts/install_bridge_service.sh` no tarball; `install.sh`
  usa o init script/unit versionados do release quando presentes (fallback
  inline mantido) e corrige o caminho do binário pelo prefixo escolhido.

### Changed
- `run_bridge.bat`, `status_bridge.bat`, `stop_bridge.bat` e `setup_usb.bat`
  detectam a distro WSL (Alpine primeiro, Arch fallback) e delegam ao
  `bridge_ctl.bat`.
- `setup_wsl.sh`: reescrito para `#!/bin/sh`, detecta Alpine/Arch, instala
  `eudev kmod openrc` no Alpine, usa `timeout` no `udevadm`, cria o softlevel
  OpenRC, configura `wsl.conf` **sem** `systemd=true` no Alpine, e suporta
  `doas` (Alpine) além de `sudo`.
- `README.md`/`README.pt-BR.md`: caminho do Zig no Windows atualizado para
  `C:\zig\zig-x86_64-windows-0.16.0\`.
- `build.zig.zon` → `.version = "0.5.0"`.

### Fixed
- **Portabilidade Windows (Zig 0.16)** — no Windows, `std.posix.pid_t` é um
  HANDLE (ponteiro); `child_pid` migrou para `u32` e o PID é extraído com
  `@intFromPtr`. `todayDate`/`timestampStr`/`todayDateStr` trocaram
  `localtime_r`/`localtime_s` por `std.time.epoch` (portátil).
- `tray.zig` (Windows): `@memcpy` de `szTip` com `[*:0]const u16` (sem `.len`)
  → `std.mem.len`; `POINT` duplicado em `MSG` apontava para tipo errado no
  Windows (usa o `POINT` já existente).
- **Bridge não acionava DTR/RTS** — o Honeywell 1900 em modo serial só
  transmite com as linhas DTR/RTS ativas; sem elas o `configureSerial` do
  bridge (termios raw) lia **zero bytes** (capturas cruas de 22s/45s/40s vazias
  no WSL). Corrigido em `src/bridge.zig` com `ioctl(TIOCMBIS)` após o
  `tcsetattr`, acionando `TIOCM_DTR | TIOCM_RTS`. Scan físico revalidado de
  ponta a ponta: `7898405966679`/`7898567704461` → `/dev/ttyUSB0` → bridge →
  TCP 9000 → `xemonitor` → `SendInput` → Bloco de Notas (título
  `* 7898567704461 - Bloco de notas`).

### Notes
- **Scan físico no Windows revalidado (2026-08-15)**: durante o diagnóstico, o
  scanner Honeywell 1900 via CH340 bipava/luzia mas a captura crua em
  `/dev/ttyUSB0` não recebia bytes (nem como HID). Causa raiz: **bridge não
  acionava DTR/RTS** (ver `Fixed`). Após a correção, o scan físico fluiu de
  ponta a ponta e injetou no Bloco de Notas (`7898567704461`). O dispositivo
  `c0f4:08f5` (teclado HID) era o teclado físico, não o scanner.

## [0.4.0] — 2026-08-15

### Added
- **i18n (inglês padrão + PT-BR)** — nova `src/i18n.zig` com as duas tabelas de
  strings (`us`/`pt_br`), seletor de idioma no painel do GUI e chave `lang` no
  config (padrão `us`). Todas as strings da interface (painéis, botões, status,
  mensagens `setMsg`, diálogo de encerramento, janela de log, exportação, bandeja)
  migraram para `i18n.t("chave")`. Chaves divergentes entre as tabelas falham em
  tempo de compilação; formatação runtime de `{s}`/`{d}` em `formatInto`.
- **Diálogo de confirmação de encerramento** — botão "Encerrar" e bandeja "Sair"
  agora pedem confirmação; "Cancelar"/fechar mantém o GUI rodando. Sem bandeja, o
  X continua encerrando direto.
- **Header compacto** — seletor de idioma + botão "Encerrar" movidos para o topo
  ao lado de "XeMonitor", liberando espaço vertical para o histórico.
- **Histórico com scroll + tempo real** — `scrollArea` vertical auto (barra só
  aparece quando a lista cresce); *stick-to-bottom*: quando chega scan novo e o
  usuário está no fim, a lista rola sozinha para mostrar o item (padrão
  `offsetFromMax <= 0` do dvui).
- **Tema claro/escuro em runtime** — detecção no init via `SDL_GetSystemTheme()`
  (portal `org.freedesktop.appearance/color-scheme`); reaplica automaticamente
  quando o sistema troca o tema (usa `SDL_EVENT_SYSTEM_THEME_CHANGED` via
  `backend.preferredColorScheme()` + `win.themeSet()` no loop principal).
- **Tamanho da janela fixo** — geometria persistida antiga removida; janela
  respeita `.size = 880x660` do `initWindow`.

### Fixed
- **Deadlock no `ManagedProc.stop()`** — a thread `waiter` segura o mutex durante
  o `wait` bloqueante do filho vivo, então o `stop()` que travava no `mutex.lock`
  nunca sinalizava o filho. Agora o `stop()` mata por pid primeiro
  (SIGTERM → SIGKILL fallback em 500ms) antes de adquirir o mutex; o encerramento
  do GUI para bridge/cliente nunca mais trava (guardado com `os != .windows`).
- **Panic `@memcpy` alias no status** — `computeBridgeStatus` grava direto em
  `status_buf` (modo subprocesso); `refreshStatus` agora pula o memcpy quando o
  ponteiro é o próprio buffer.
- **Layout do header** — header box (horizontal) agora fechado antes das seções
  seguintes (bloco explícito) para que subtitle, server, client e history
  permaneçam no root vbox vertical.

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
