# KNOWN_ISSUES — problemas já diagnosticados (NÃO re-resolver)

Este arquivo cataloga problemas encontrados e **já resolvidos/diagnosticados**
no XeMonitor. O objetivo é evitar que agentes/desenvolvedores novos percam
tempo re-descobrindo a causa raiz ou "corrijam" uma correção que já é
necessária. Se um sintoma reaparecer, consulte primeiro esta lista.

> Antes de mexer em qualquer um destes pontos, **leia a issue completa**.
> Muitos "fixes" são requisitos de hardware/driver, não bugs a remover.

---

## 1. Serial — DTR/RTS obrigatório (Honeywell 1900)
- **Sintoma**: o bridge lê **zero bytes** do scanner em `/dev/ttyUSB0`, mesmo
  com o scanner bipando/acendendo (lê o código).
- **Causa raiz**: o Honeywell 1900 em modo serial **só transmite com
  DTR+RTS ativos**. Sem eles, a serial fica muda.
- **Fix (não remover)**: `src/bridge.zig` `configureSerial` faz
  `ioctl(TIOCMBIS)` com `TIOCM_DTR | TIOCM_RTS` **após** o `tcsetattr`.
- **Refs**: AGENTS.md (DTR/RTS obrigatórios), checkpoint 2026-08-15/08-29.

## 2. Serial — delay entre acionar DTR/RTS e leitura
- **Sintoma**: mesmo com DTR/RTS ativos, o scan não saía (bridge mudo).
- **Causa raiz**: o driver `ch341-uart` não aplicava as modem lines a tempo
  (`TIOCMGET` mostrava `0x20`, sem DTR/RTS).
- **Fix (não remover)**: `sleepNs(200ms)` entre o `TIOCMBIS` e o `TIOCMGET`
  em `configureSerial`. Teste definitivo: `sleep(1s)` em python lia o scan
  limpo a 115200; o fix de 200ms no bridge confirmou o mesmo resultado.

## 3. WSL Alpine — udev NÃO roda, `/dev/serial/by-id/` nunca existe
- **Sintoma**: instalador gravava um caminho **by-id fixo** em
  `/etc/xemonitor/device`; o bridge tentava abrir device inexistente →
  zero bytes.
- **Causa raiz**: o daemon udev **não roda no WSL2**. O symlink
  `/dev/serial/by-id/...` é criado pelo udev userspace, que está inativo.
  Quem cria o `/dev/ttyUSB0` é o kernel `vhci` (usbipd).
- **Fix**: `install_windows.bat` resolve o device **real dentro do Alpine**
  (by-id se existir, senão `/dev/ttyUSB0`). Regra udev em
  `packaging/windows/udev/60-persistent-serial.rules`.

## 4. Driver CH340 no Windows — erro 31 / AccessDenied (NÃO RESOLVIDO)
- **Sintoma**: `SetCommState` erro 31, libserialport AccessDenied, PuTTY erro 5.
- **Status**: **contornado** pelo TCP bridge WSL2 (o Windows não toca na serial).
  O driver CH340 do Windows continua corrompido.
- Se um dia voltar ao acesso direto, é preciso reinstalar/diagnosticar o driver.

## 5. Serial — "lê 1 byte lixo por scan" (PENDENTE de teste de baud)
- **Sintoma**: o bridge recebe **1 byte lixo por scan** (hex `ED/EC/E2/CD/89`)
  com device `/dev/ttyUSB0`.
- **Status**: baud 115200 confirmado pelo usuário na controladora do scanner;
  DTR/RTS ativos (dtrtest → `TIOCMGET=0x26`). Teste de baud 9600 vs 115200
  **adiado** (decisão do usuário: após o plano de versionamento). Ver
  `tools/dtrtest.zig`.

## 6. Windows — SendInput `INPUT` = 40 bytes no x64
- **Sintoma**: `SendInput` retorna 0.
- **Causa raiz**: o union interno usa `MOUSEINPUT` (32 bytes), então `INPUT`
  no x64 tem **40 bytes**. `cbSize` incorreto faz `SendInput` falhar.
- **Fix**: `cbSize` correto (40) em `src/main.zig` (struct `w`).
- **Diagnóstico**: `GetLastError()` em `w.last_sendinput_error`.

## 7. Windows — UIPI: SendInput Médio→Elevado é bloqueado
- **Sintoma**: `SendInput` retorna 0 se o alvo é de integridade maior.
- **Regra**: xemonitor e o editor alvo devem rodar em integridade **Média**
  (não elevados). Validar injeção sem elevar: tarefa `/rl LIMITED` + wrapper
  `.cmd` que redireciona stdout/stderr para arquivo.

## 8. `.bat` — parênteses em strings dentro de blocos + UTF-8 multibyte
- **Sintoma**: `cmd : . foi inesperado neste momento.`
- **Causa raiz** (duas):
  - `(`/`)` dentro de mensagens em blocos `if (...) ( ... )` corrompem o parse.
  - em-dash UTF-8 (`—`, bytes 0xE2 0x80 0x94) corrompe o parse porque o cmd
    lê .bat em codepage OEM (não UTF-8).
- **Fix/regra**: **todos os `.bat` devem ser 100% ASCII**, sem parênteses
  dentro de strings em blocos. (Verificado com scan por bytes > 127.)
- **Atenção**: parênteses no `:log` NÃO são a causa da anomalia de log
  intercalado (ver issue 16).

## 9. Build — AccessDenied ao recompilar (arquivo travado)
- **Sintoma**: `zig build` falha: `unable to update file ... AccessDenied`
  em `zig-out\bin\xemonitor.exe`.
- **Causa**: o `xemonitor.exe` anterior ainda está rodando (trava o arquivo).
- **Fix**: `taskkill /F /IM xemonitor.exe` antes de recompilar (e
  `xemonitor-gui.exe`).

## 10. Inno Setup — `#include` de texto puro NÃO define macro
- **Sintoma**: `#include "VERSION"` (arquivo com só `0.8.1`) falha com
  "Expression expected" ou "Text is not inside a section".
- **Causa**: o ISPP cola o conteúdo inline; texto puro não vira macro.
- **Fix**: passar a versão via `ISCC /DMyAppVersion=<ver>` (lida do `VERSION`).
  `xemonitor.iss` usa `#ifndef MyAppVersion` com default `0.0.0`.

## 11. Versionamento — drift entre arquivos (CORRIGIDO via VERSION file)
- **Problema**: bridge/exe/gui/iss/bat/CI versionavam separadamente
  (fonte diferente em cada). Esquecia-se de bumpar todos.
- **Fix (v0.8.1)**: `VERSION` na raiz é a **fonte única**. Bumpar =
  editar `VERSION` + `assets/xemonitor.rc` (metadados PE). Ver
  `docs/bridge-versioning.md`. Nunca bumpar binários/iss/bat direto.

## 12. Zig 0.16 — `std.process.argsAlloc` não existe
- **Sintoma**: `tools/scantest.zig` não compila.
- **Nota**: API removida/não-existente no Zig 0.16. Não é bug a corrigir;
  usar outra abordagem para ler argv (ex.: `std.process.Init.args`).

## 13. `.bat` — CRLF obrigatório
- **Sintoma**: `.bat` com LF-só executa **em silêncio** (nada acontece).
- **Fix**: garantir CRLF ao gravar `.bat` (o git converte LF→CRLF ao
  check-out com `core.autocrlf`; cuidado ao escrever via ferramentas que
  gravam LF).

## 14. `.bat` — `goto :main` para pular subrotinas
- **Sintoma**: subrotinas definidas rodam por queda e o `exit /b` encerra
  cedo o script.
- **Fix**: usar `goto :main` no topo para pular as subrotinas (que ficam
  no fim do arquivo).

## 15. GUI Windows — hang com `spawn síncrono` de wsl.exe no main loop
- **Sintoma**: o GUI congela.
- **Causa**: `runBridgeCtl("status")` a cada 1s e `runBridgeCtl("dev")` a
  cada 5s no main loop, ambos com spawn síncrono de wsl.exe/processos.
- **Fix**: status via `portIsOpen("127.0.0.1", tcp_port)` (sem spawn); check
  `dev` migrado para thread (`devCheckWorker`). Nunca spawn síncrono de
  wsl.exe/processos longos no main loop.

## 16. Instalador — log intercalado (processos cmd concorrentes)
- **Sintoma**: `%TEMP%\xemonitor-install.log` com passadas intercaladas e
  "fora de ordem" (2-3 passadas escrevendo no mesmo log).
- **Causa**: execução concorrente de processos cmd no mesmo `.bat`/log.
  Não é o padrão de parênteses do `:log` (teste isolado passou limpo).
- **Status**: não reproduzido de forma controlada. Blindar com lockfile
  single-instance + validar `%DISTRO%` não-vazio no passo 4.

## 17. Linux — `pkill/pgrep -f` casa com o shell invocador
- **Sintoma**: `pkill -f XeMonitor` mata o próprio shell (o pattern aparece
  no cmdline do shell que invoca).
- **Fix**: usar `pkill -x` / `pgrep -x` (nome exato de processo) nos scripts
  `run_xemonitor.sh`/`stop_xemonitor.sh`/`status_xemonitor.sh`.

## 18. Linux — `wl-copy` bifurca processo de fundo (trava o shell tool)
- **Sintoma**: comandos seguintes ficam enfileirados / o shell trava ~120s
  esperando EOF (o `wl-copy` herda o pipe).
- **Fix**: evitar `wl-paste` em pipe composto; usar
  `timeout 5 wl-paste > arquivo` e `pgrep -x`/kill por PID.

## 19. Zig 0.16 — `child.stdin` double-close (panic BADF no copy)
- **Sintoma**: panic `recoverableOsBugDetected` (BADF) ao usar wl-copy.
- **Causa**: Zig 0.16 fecha stdio não-nulo no `wait`; fechar `child.stdin`
  e chamar `wait` = double-close.
- **Fix**: fechar `child.stdin` e setar `child.stdin = null` antes do `wait`.
- Nota: `std.process.run` hardcoda `.stdin=.ignore`; para o wl-copy (lê
  stdin) é obrigatório `std.process.spawn` com `.stdin=.pipe`.

## 20. Build — PNG path no build.zig
- **Sintoma**: `zig build test` quebra (`file_hash FileNotFound`).
- **Causa**: `build.zig` referenciando `Barcode Scanner.png` na raiz, mas o
  arquivo vive em `src\Barcode Scanner.png`.
- **Fix**: usar `src/Barcode Scanner.png` nas 2 linhas (test-png e gui).

## 21. GUI Linux — quote/escaping de heredoc via `sh -c` no Windows
- **Sintoma**: ao copiar conteúdo multi-linha (regra udev) via
  `wsl ... sh -c '...'`, o escaping quebra.
- **Fix**: `packaging/windows/udev/60-persistent-serial.rules` é um **arquivo
  separado** copiado via DrvFS (evita o heredoc/`sh -c`). Não embutir regras
  udev em strings do `.bat`.

## 22. wsl_timeout.ps1 — quoting e LF do argumento sh
- **Problemas resolvidos**: LF normalization do argLine; **quoting externo
  single-quote** em `sh -c '...'` (resolve conflito de aspas com o
  CommandLineToArgvW via ProcessStartInfo); fallback manual se
  `rc-service start` falhar; validação porta 9000 com `ss` **ou** `netstat`
  (Alpine só tem netstat); `mkdir -p /run /run/openrc /run/lock` antes do
  `rc-service`.

## 23. CachyOS — conflito de porta 9000 (unit systemd de sistema legado)
- **Sintoma**: um unit systemd **de sistema** legado respawnava e tomava a
  porta 9000 do unit de usuário (bridge antigo como root, `Restart=always`).
- **Fix**: `systemctl disable --now xemonitor-bridge` (unit de sistema).
  Agora só existe o unit de usuário. Refs: AGENTS.md.

## 24. Tray (Windows) — órfão de PowerShell ao matar com `taskkill /f`
- **Sintoma**: o ícone de bandeja usa PowerShell oculto; matar o processo
  com `taskkill /f` deixa o PS órfão.
- **Fix**: bandeja é **opt-in** (`--tray`, padrão desligado); limpar cache
  `TrayNotify` + reiniciar explorer se órfão.

## 25. musl estático — bridge roda em glibc e musl sem recompilar
- **Nota (não é bug)**: `zig build bridge` linka musl por padrão → o binário
  roda em Arch/CachyOS (glibc) **e** Alpine (musl). Confirmado via `readelf`
  (sem dynamic interpreter).

---

## Anti-regras rápidas (resumo executivo)

- **NÃO remover** o `ioctl(TIOCMBIS)` DTR/RTS nem o `sleepNs(200ms)` do
  `src/bridge.zig`.
- **NÃO** usar `/dev/serial/by-id/` como device fixo no WSL Alpine.
- **NÃO** bumpar versão editando mais de 2 arquivos (VERSION + rc).
- **NÃO** usar `#include` de texto puro no ISPP; usar `-DMyAppVersion`.
- **NÃO** colocar parênteses em strings dentro de `if (...)` nem em-dash
  UTF-8 em `.bat`. `.bat` = ASCII puro + CRLF.
- **NÃO** rodar xemonitor/editor elevados (UIPI bloqueia o SendInput).
- **NÃO** recompilar com xemonitor rodando (AccessDenied).
- **NÃO** spawn síncrono de wsl.exe/processos longos no main loop do GUI.
- **NÃO** `pkill -f` em scripts Linux (casa com o shell); usar `-x`.
