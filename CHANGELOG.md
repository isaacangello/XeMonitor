# Changelog

## [Unreleased]

## [0.8.0] — 2026-08-29

### Added (install.sh 1.4.0)

- **Autodetect de device USB-serial no bridge** — `src/bridge.zig` agora tem
  `autoDetectSerial()` que tenta, em ordem: `/dev/serial/by-id/*` (udev
  symlinks; mais estavel entre reboots) → `/dev/ttyUSB*` → `/dev/ttyACM*` →
  `/dev/ttyUSB0` (fallback). Override via `--device <path>`. O install grava
  o resultado em `/etc/xemonitor/device`; as units systemd/OpenRC fazem
  `source` desse arquivo e passam `--device "$DEVICE"` para o bridge.
- **`--print-device` flag no bridge** — detecta e imprime o path, depois
  sai. Usado pelo install.sh para descobrir o device antes de instalar.
- **DTR/RTS confirmados via `TIOCMGET`** — após `ioctl(TIOCMBIS)`, o bridge
  chama `TIOCM_GET` e loga se as modem lines ficaram realmente setadas.
  Quando o driver é `cdc_acm` (sem suporte), o log avisa e sugere
  `sudo modprobe ch341` (driver nativo que suporta DTR/RTS).
- **Detecção de sessão gráfica + install do injetor** — install detecta
  `XDG_SESSION_TYPE` e:
  - **Wayland**: instala `ydotool` via `pacman`/`apt`/`dnf`/`apk` e ativa
    `ydotool.socket` (systemd de usuário).
  - **X11**: instala `xdotool` (idem).
  - **tty/sem GUI**: pula GUI/desktop entry/autostart e loga que o cliente
    CLI continua funcional. Validação real vai para `xemonitor-diagnose`.
- **Detecção de libc (glibc vs musl)** — em Alpine/musl, install pula o
  GUI e avisa (binário glibc é incompatível com musl). Bridge+CLI continuam.
- **Pre-check de driver kernel** — install.sh consulta `udevadm info`/
  `/sys/class/tty/.../driver` para detectar o driver ativo do device.
  Se for `cdc_acm`, tenta `modprobe ch341` automaticamente. Status aparece
  no resumo final.
- **Banner destacado de logout/login** — quando `id -Gn` difere dos grupos
  no `/etc/group` (mudanças não-efetivas), install exibe um banner
  amarelo no momento de `usermod -aG` E no resumo final. Resolve o
  problema clássico "instalei, mas o GUI não injeta" (uinput negado).
- **Status real no resumo final** — bloco com cores mostrando serviço,
  porta 9000, device, driver, injetor (ydotool.socket/xdotool), grupos.
  Falhas em qualquer item aparecem com cor vermelha + instrução de fix.
- **Flag `--client-only`** — instala só cliente+GUI (sem bridge/service/
  udev de CH340). Para thin clients conectando a um bridge remoto.
- **Flag `--bridge-only`** — instala só bridge+service+udev CH340
  (sem GUI/cliente). Para servidores headless.
- **Reinstall = restart do service** — rodar install.sh duas vezes
  detecta o service existente e chama `systemctl restart` (em vez de
  `enable`+`start`, que podem falhar se já rodando). Binário é atualizado.
- **`xemonitor-diagnose` no tarball** — `diagnose_xemonitor.sh` agora
  vai no release e é instalado como `/usr/local/bin/xemonitor-diagnose`.
  Nova seção "Driver & kernel" cobre driver ativo, módulo ch341
  carregado, modinfo e dmesg.

### Added (GUI 0.8.0)

- **Askpass (sem polkit)** — `runPrivileged` em `src/gui.zig` agora
  detecta o askpass disponível na ordem `ksshaskpass` (KDE) → `zenity`
  → `yad` → `gnome-passwd` → terminal (`konsole`/`xterm`/`gnome-terminal`/
  `alacritty`/`foot`) → instrução manual. Quando o GUI precisa
  `systemctl start` (modo `systemd-system`), o askpass gráfico pede a
  senha; o terminal fallback spawna um `konsole`/`xterm` pedindo senha
  nativa do sudo. Resolve a dependência implícita de `polkit`/`pkexec`
  que quebrava em distros sem agente polkit.
- **Detecção automática de server_mode (systemd-system vs user)** — no
  init do GUI, em Linux, detecta qual unit está realmente rodando e
  reconcilia com o `server_mode` do conf. Resolve a inconsistência
  documentada (CachyOS user unit vs Arch system unit; install
  rescrevendo o conf do run_xemonitor.sh).

### Changed

- **`run_xemonitor.sh`** agora autodetecta device (via `bridge
  --print-device` + fallback) e grava em `/etc/xemonitor/device`. Coerente
  com o caminho `install.sh`.
- **Systemd unit** agora faz `source /etc/xemonitor/device` para pegar o
  `DEVICE=...` (em vez de hardcoded `--device /dev/ttyUSB0`).
- **OpenRC init** idem: `start_pre()` faz source do device file.
- **`install.sh 1.3.0 → 1.4.0`** (separado do binário `0.7.2 → 0.8.0`).

### Fixed (v0.8.0 em CachyOS — real install, EXIT=0 / validação TUDO OK)

- **`local` no top-level removido** — em 5 pontos (grupos, injetor,
  validação porta 9000, validação/status ydotool) um `local` fora de função
  abortava o script com `set -euo pipefail` ("local: somente pode ser usado
  em uma função"). Trocado por variáveis globais sem `local`.
- **ydotool unit por distro** — Arch/CachyOS/Manjaro usam `ydotool.service`
  (não `.socket`, inexistente). install detecta a unit real
  (`ytool.socket` → `ytool.service`) antes de `enable --now`, e a validação/
  status acha qualquer uma das duas. No CachyOS ativou `ydotool.service`
  corretamente.
- **Grupos inexistentes no usermod/check_groups** — Arch/CachyOS usam
  `uucp` sem `dialout`; install agora adiciona só os grupos que existem e o
  `check_groups` ignora grupo inexistente (elimina o aviso falso
  "FALTAM dialout" e o erro `usermod: grupo 'dialout' não existe`).
- **Validação da porta 9000 com retry** — o `restart` do bridge pode
  demorar a escutar; a validação esperava até 10s antes de marcar erro
  (corrige falso negativo "porta não está escutando").
- **Comparação de versão do instalador** — `check_update` avisava
  "existe uma versao mais nova (1.3.0)" quando a local era 1.4.0. Novo
  comparador `ver_newer()` (semver) só avisa quando a remota é de fato
  maior.
- **Bridge: delay entre `TIOCMBIS` e leitura serial** — `src/bridge.zig`
  (`configureSerial`) aciona DTR+RTS via `ioctl(TIOCMBIS)` mas, sem um
  intervalo entre o set e o uso, o driver `ch341-uart` não aplicava as
  modem lines a tempo (o `TIOCMGET` confirmava `status=0x20` sem DTR/RTS,
  e o scanner ficava mudo mesmo com DTR/RTS fisicamente ativos). Adicionado
  `sleepNs(200 * std.time.ns_per_ms)` entre o `TIOCMBIS` e o início da
  leitura. Validado em CachyOS: scan cru em 115200 com DTR+RTS confirmados
  (`7898773920105\r\n`) injetado de ponta a ponta no Kate.

### Notes

- **Plataforma-alvo primaria**: CachyOS (KDE Wayland). Validado: ydotool
  em `[extra]`, ksshaskpass nativo, ch341 no kernel padrão. WSL2 e Docker
  ficam como TODOs (documentados no `.checkpoint.md`).
- **Backward-compat**: o autodetect é backward-compatible (sem flag
  `--device` = comportamento antigo + log). Quem tinha `/dev/ttyUSB0`
  fixo continua funcionando.
- **Backward-compat do GUI conf**: campo `server_mode` aceita os 4 valores
  antigos (`subprocess`/`systemd-user`/`systemd-system`/`wsl`); a
  detecção só ajusta quando há mismatch entre conf e unit real.

## [0.7.2] — 2026-08-17

### Fixed
- **Instalador: erros silenciados do bridge agora propagam** — `copy_bridge`,
  `copy_openrc` e `svc_enable` no `install_windows.bat` viram `_FATAL` em vez
  de `AVISO` (antes, a Fase 3 "concluía" sem bridge ou init script e a
  Fase 4 mentia "Bridge iniciado"). Diagnostico comprovado pelos logs reais
  do usuário: `bridge-task.log` nunca existiu, cliente ficou 12h em loop
  `TCP connect failed: error.Unexpected`, bridge nunca subiu.
- **`svc_enable` (`wsl_timeout.ps1`) propaga erro real** — removido o
  `2>/dev/null || true` silenciador; se `rc-service` não existe (Fase 2
  falhou默默) ou `rc-service start` falha, retorna erro 201.
- **`bridge_ctl.bat :rc_start` valida porta 9000 ouvindo** — após
  `rc-service start`, roda `ss -tln | grep :9000` para confirmar que o
  daemon realmente subiu (não só que o OpenRC reportou `started`).
- **`install_windows.bat :runwsl` checa `XEMONITOR_SRC` vazio** — evita
  `cp "" /usr/local/bin/...` silencioso quando `to_wsl_path` falha.

### Added
- **CI/CD Windows Build** — `build-windows` job no `release.yml`: `windows-latest` runner, Zig 0.16.0, Inno Setup via Chocolatey, `ISCC.exe` compila `XeMonitor-*-setup.exe`
- **`release` job** — agrega `linux-binaries` + `windows-installer` → GitHub Release único
- **install.sh v1.3.0** — SHA256 verification, ANSI colors embutidos, `--check-only/--dry-run/--validate/--quiet/--verbose`, `$HOME/.local/share` para dados grandes
- **`wsl_timeout.ps1` tarefa `svc_status`** — verifica `rc-service status`
  + `ss -tln | grep :9000` após `svc_enable`; usado pelo `install_windows.bat`
  pós-Fase 4 passo 1 para confirmar que o bridge está realmente ouvindo.
- **`.gitattributes`** — `* text=auto` + binários explícitos (`*.png`,
  `*.ico`, `*.exe`, etc.). Normaliza line endings para LF no repo;
  resolve diferenças CRLF (partição Windows) vs LF (clone Linux).

### Changed
- **Auto-elevação: `fltmc` no lugar de `net session`** — `net session`
  falha quando `LanmanServer` está parado mesmo em admin. `fltmc`
  (Filter Manager) é confiável em qualquer estado de serviços Windows.
- **Lockfile mata processo ativo** — antes, lockfile presente abortava
  o instalador ("Outra instancia parece estar em execucao"). Agora
  mata o processo PID dono do lock (se ativo) e segue; limpa locks
  órfãos automaticamente.
- **Padrão `:die` centralizado** — substitui `del lockfile; pause; exit /b 1`
  espalhado por 5+ pontos. `if !_FATAL!==1 goto :die` é goto-safe (nunca
  dentro de blocos `( )`), garante cleanup consistente.
- **Inno Setup `PrepareToInstall` robusto** — trata aspas no path do
  desinstalador, extrai só o `.exe` (remove params extras), fallback
  HKCU depois de HKLM.

## [0.7.1] — 2026-08-17

### Changed
- **Instalador: desinstalacao automatica** — `UninstallExistingInstall=yes` no
  Inno Setup. Qualquer versao existente (mesma, mais velha ou mais nova) e
  desinstalada automaticamente antes de instalar. Suporta upgrade, downgrade
  e restore.
- **Alpine sempre fresh** — `install_windows.bat` remove Alpine existente
  e reimporta do minirootfs. Garante estado limpo em qualquer reinstalacao.
- **Processos mortos antes da desinstalacao** — `taskkill` no `[UninstallRun]`
  antes do `uninstall_autostart.bat` para evitar arquivos locked.
- **GUI inicia apos instalacao** — removido `skipifsilent` do `[Run]` step 2;
  a tarefa `XeMonitor-App` e disparada mesmo em modo silencioso.

## [0.7.0] — 2026-08-17

### Changed
- **Instalador reestruturado em 4 fases** — elimina fragilidade do `sh -c
  "complex_cmd"` via `wsl_timeout.ps1`. Scripts `.sh` são gerados via `echo`
  no `.bat`, copiados para Alpine, e executados de lá. Cada fase é
  independente e pode ser re-executada.
  - Fase 1: Dependências Windows + Alpine (WSL2, winget, wget, usbipd, download+import)
  - Fase 2: Dependências Alpine (openrc, kmod, eudev — verificado ANTES de usar)
  - Fase 3: Cópia de arquivos + config Alpine (bridge, init script, udev, wsl.conf, modulos)
  - Fase 4: Configuração final (servico, binarios, tarefas, USB, scanner)
- **`wsl_timeout.ps1` simplificado** — novas tasks genéricas `copy_file` e
  `run_script` substituem `setup_wsl`, `copy_bridge`, `copy_openrc`,
  `copy_systemd`. Download do Alpine removido do PS1 (fica no .bat).
- **wget com progresso** para download do Alpine (`JernejSimoncic.Wget` via
  winget; fallback: `Invoke-WebRequest`). winget adicionado como requisito.
- **Logs consolidados em `%APPDATA%\xemonitor\logs\`** — install.log,
  wsl.out.txt, wsl.err.txt, setup-usb.log, bridge-task.log, app-task.log.
- **`setup_usb.bat` simplificado** — remove `apk add kmod` (garantido na Fase 2).

### Removed
- **`setup_wsl.sh` removido do pacote Inno Setup** — scripts agora são gerados
  via echo no install_windows.bat. Arquivo mantido no repo para Linux/manual.

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
