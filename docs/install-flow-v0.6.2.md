# Fluxo de Instalação do Zero — XeMonitor v0.6.2

## Pré-requisitos (Inno Setup)
1. Usuário executa `XeMonitor-0.6.2-setup.exe`
2. Inno Setup copia tudo para `C:\Program Files\XeMonitor\`:
   - Binários: `xemonitor-gui.exe`, `xemonitor.exe`
   - Bridge Linux: `bridge` (musl estático)
   - Scripts: `setup_wsl.sh`, `setup_usb.bat`, `bridge_ctl.bat`, `wsl_timeout.ps1`, etc.
   - OpenRC init: `openrc\xemonitor-bridge`
   - Systemd unit: `systemd\xemonitor-bridge.service`
3. Wizard termina → dispara `install_windows.bat /silent`

## install_windows.bat (elevado, /silent)

### [1/7] WSL2
- Roda `wsl --status` via `wsl_timeout.ps1` (30s timeout)
- Se WSL não existe → `wsl --install --no-distribution` → pede reboot
- Se existe → `wsl --update` → OK

### [2/7] usbipd-win
- Verifica `where usbipd` ou `C:\Program Files\usbipd-win\usbipd.exe`
- Se ausente → instala via `winget install usbipd`

### [3/7] Alpine (distro WSL)
- Testa `wsl -d Alpine echo ok` via `wsl_timeout.ps1` (60s)
- Se Alpine não existe:
  1. Baixa `alpine-minirootfs-*.tar.gz` de `dl-cdn.alpinelinux.org` (até 300s)
  2. `wsl --unregister Alpine` (se registro quebrado)
  3. `wsl --import Alpine C:\wsl\Alpine <tarball> --version 2`
  4. Verifica novamente `wsl -d Alpine echo ok`
- `wsl --set-default Alpine`
- **Resultado**: Alpine minirootfs puro, sem pacotes instalados

### [4/7] WSL Setup (bridge + módulos)

**4a - setup_wsl.sh** (a chave do problema):
- Converte path: `C:\Program Files\XeMonitor\setup_wsl.sh` → `/mnt/c/Program Files/XeMonitor/setup_wsl.sh`
- Chama `wsl_timeout.ps1` task `setup_wsl` com 120s timeout
- Dentro do Alpine, o script faz:
  1. Detecta distro (`/etc/alpine-release`)
  2. `apk add --no-cache eudev kmod openrc`
  3. Cria regra udev: `/etc/udev/rules.d/99-ch340.rules`
  4. Habilita udev no OpenRC: `rc-update add udev default`
  5. Cria `/run/openrc/softlevel`
  6. Cria/atualiza `/etc/wsl.conf` com `[boot] command = /sbin/modprobe usbip-core && /sbin/modprobe vhci-hcd && /sbin/modprobe ch341`
  7. `modprobe ch341` (runtime)

**4b - copy_bridge**: Copia binário `bridge` → `/usr/local/bin/xemonitor-bridge`

**4c - copy_openrc**: Copia init script → `/etc/init.d/xemonitor-bridge`
- Se falha (rc≠0): instala `openrc` via apk + retry

**4d - svc_enable**: `rc-update add xemonitor-bridge default` + `rc-service xemonitor-bridge start`

### [5/7] Binários Windows
- Copia `xemonitor-gui.exe` + `xemonitor.exe` para `C:\Program Files\XeMonitor\`

### [5b] Config GUI
- Cria `%APPDATA%\xemonitor\xemonitor-gui.conf` com `server_mode=wsl`, `auto_start=true`, `tray_enabled=true`

### [6/7] Tarefas Agendadas
- Roda `scripts/install_autostart.bat /silent`
- Cria 3 tarefas:
  - `XeMonitor-USB-Attach` (ONLOGON, HIGHEST) → `setup_usb.bat /silent`
  - `XeMonitor-Bridge` (ONLOGON, delay 30s) → `start_bridge.cmd`
  - `XeMonitor-App` (ONLOGON, delay 45s, LIMITED) → `xemonitor-gui.exe`

### [7/7] Início

**7a**: `rc-service xemonitor-bridge start` (bridge sobe TCP 9000)

**7b**: `setup_usb.bat /silent`:
1. Verifica distro Alpine
2. Verifica usbipd
3. `usbipd unbind -g <old-guid>` (limpa binding antigo)
4. `usbipd bind --hardware-id 1a86:7523` (compartilha CH340)
5. Espera WSL pronto (loop 30s: `wsl -d Alpine echo ok`)
6. `usbipd attach -w Alpine --hardware-id 1a86:7523` (attaches ao WSL)
7. `apk add --no-cache kmod` + `modprobe ch341`
8. Poll `/dev/ttyUSB0` (loop 15s: `test -c /dev/ttyUSB0`)

**7c**: `tty_check` via `wsl_timeout.ps1` → `wsl -d Alpine sh -c "test -c /dev/ttyUSB0"` (30s)
- **Se OK**: "Scanner USB-Serial detectado"
- **Se falha**: "Scanner USB-Serial NAO detectado" ← AQUI ESTÁ O ERRO

---

## Possíveis causas de falha no "USB-Serial não detectado"

1. **`setup_wsl.sh` falha (rc=127)** — path com espaços não protegido no `sh -c` do `wsl_timeout.ps1` → sem kmod/openrc → módulos não carregam → `/dev/ttyUSB0` não aparece
2. **Fallback manual carrega módulos mas CH340 ainda não está attached** quando `tty_check` roda (timing)
3. **usbipd attach falha silenciosamente** — device não compartilhado corretamente
4. **Alpine fresh import não tem `/lib/modules/`** para os módulos do WSL2 kernel
5. **copy_openrc falha** — `/etc/init.d/` não existe no Alpine minirootfs fresh (openrc não instalado ainda)

## Fix aplicado no v0.6.2 (wsl_timeout.ps1)

Antes (quebrado):
```powershell
"setup_wsl" { $argLine = "-d $distro -u root -- sh -c `"$src`"" }
```
Path com espaços é splitado pelo shell → `sh -c /mnt/c/Program` → rc=127.

Depois (corrigido):
```powershell
"setup_wsl" { $argLine = "-d $distro -u root -- sh -c `"'$src'`"" }
```
Single quotes internos protegem o path dos espaços no shell.

## Fallback adicionado no install_windows.bat (v0.6.2)

Se `setup_wsl.sh` falhar (rc≠0), o instalador tenta manualmente:
1. `apk add --no-cache eudev kmod openrc`
2. `modprobe usbip-core`, `modprobe vhci-hcd`, `modprobe ch341`
3. Cria `/etc/wsl.conf` com boot command
4. Cria regra udev

Se `copy_openrc` falhar:
1. `apk add --no-cache openrc`
2. `mkdir -p /etc/init.d`
3. Retry do copy_openrc

Se `setup_usb.bat` step 4/4 rodar:
1. `apk add --no-cache kmod` (garante modprobe disponível)
2. `modprobe ch341`
