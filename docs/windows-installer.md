# Instalador Windows — instruções (wizard next-next-finish)

> Status: **implementado no v0.5.1** (`packaging/windows/`). O instalador real
> (rodar o `XeMonitor-0.5.1-setup.exe` num PC com o fluxo limpo) é validado de
> ponta a ponta nesta versão: UAC real, progresso visível do WSL, GUI em janela
> (sem terminal) e feedback do scanner USB-Serial.

## Objetivo

Empacotar `xemonitor-gui.exe` (+ `xemonitor.exe`, bridge e scripts de apoio)
num instalador que o usuário roda e conclui em três cliques, sem
console/PowerShell manual. Ao terminar, deve deixar o fluxo pronto para
escanear:

1. `xemonitor-gui.exe` (app principal, janela + bandeja — **subsystem GUI**, sem
   terminal) e `xemonitor.exe` instalados em `C:\Program Files\XeMonitor\`.
2. WSL2 + usbipd + distro **Alpine** (padrão; Arch fallback) com o serviço do
   bridge instalado e iniciado (`/usr/local/bin/xemonitor-bridge`).
3. Config do GUI em `%APPDATA%\xemonitor\xemonitor-gui.conf`
   (`server_mode=wsl`, `auto_start=true`, `tray_enabled=true`, `lang=pt_br`).
4. Tarefas agendadas de logon (espelho de `scripts/install_autostart.bat`):
   - `XeMonitor-USB-Attach` (logon, `/rl HIGHEST`) — `usbipd attach` do CH340;
   - `XeMonitor-Bridge` (logon, +30s) — `bridge_ctl.bat enable`;
   - `XeMonitor-App` (logon, +45s, `/rl LIMITED`) — `start_xemonitor.cmd`
     (roda o `xemonitor-gui.exe`; não elevado p/ UIPI).
5. Atalho no menu Iniciar (`XeMonitor`) e desktop (opcional).
6. **Scanner USB-Serial conectado** — o instalador roda o `setup_usb.bat`
   (bind/attach do CH340 via usbipd) e avisa claramente se o Honeywell 1900
   USB-SERIAL não for detectado (`/dev/ttyUSB0` no WSL).

## Arquivos do pacote (`packaging/windows/`)

- **`xemonitor.iss`** (Inno Setup): `AppVersion=0.5.1`,
  `MyAppExeName=xemonitor-gui.exe`. `[Files]` instala os binários Windows
  (`xemonitor-gui.exe`, `xemonitor.exe`), o bridge Linux (`zig-out/bin/bridge`),
  `setup_wsl.sh`, `openrc/xemonitor-bridge`, `systemd/xemonitor-bridge.service`,
  os scripts (`bridge_ctl.bat`, `install_bridge_service.sh`,
  `install_autostart.bat`, `uninstall_autostart.bat`) e os helpers
  (`install_windows.bat`, `start_bridge.cmd`, `start_xemonitor.cmd`).
  `[Run]`: roda `install_windows.bat` (**elevado + visível**, com `/silent` para
  suprimir os `pause`) e depois inicia o GUI com `runascurrentuser nowait`
  (integridade **Média**, evita bloqueio UIPI do SendInput).
  `[UninstallRun]`: `uninstall_autostart.bat`.
- **`install_windows.bat`**: instalador completo (auto-eleva via UAC):
  1. WSL2 (`wsl --status` / `--update`; instala com `--no-distribution` se faltar);
  2. usbipd-win (via `winget install usbipd`, fallback `C:\Program Files\usbipd-win\`);
  3. distro WSL (detecta Alpine → Arch; instala Alpine com
     `wsl --install -d Alpine --no-launch` se faltar);
  4. bridge: `setup_wsl.sh` + copia o binário para `/usr/local/bin/xemonitor-bridge`
     + copia o **init script** `openrc/xemonitor-bridge` (e a unit systemd) para o
     WSL + instala o serviço (OpenRC no Alpine / systemd no Arch);
  5. binários Windows para `%ProgramFiles%\XeMonitor`;
  5b. `xemonitor-gui.conf` em `%APPDATA%\xemonitor`;
  6. tarefas agendadas (`install_autostart.bat` ou fallback schtasks);
  7. inicia o bridge + roda `setup_usb.bat` (attach CH340) + verifica e avisa
     se o scanner USB-Serial está conectado. O GUI **não** é lançado daqui
     (evita elevação) — o `[Run]` do Inno faz isso depois, sem elevar.
- **`start_xemonitor.cmd` / `start_bridge.cmd`**: wrappers das tarefas
  agendadas; redirecionam stdout/stderr para `%APPDATA%\xemonitor\*.task.log`
  (a saída da sessão de tarefa corrompe bytes UTF-8).

## Compilação (no Windows)

```cmd
rem 1. precisa do Zig 0.16 e do Inno Setup instalado
zig build                 rem (Debug; xemonitor.exe + bridge Linux)
zig build gui -Doptimize=ReleaseSafe   rem precisa do patch sdl3 (ver abaixo)
powershell -ExecutionPolicy Bypass -File scripts\patch_sdl3_release.ps1
zig build gui -Doptimize=ReleaseSafe
iscc packaging\windows\xemonitor.iss
```

> **Bug translate-c (Zig 0.16, issue #327):** `zig build gui -Doptimize=ReleaseSafe`
> no Windows falha com "unused local constant" no `sdl3-c.zig` gerado
> (`extern_local_wcscat_s`/`extern_local_wcscpy_s`). Rodar
> `scripts/patch_sdl3_release.ps1` (idempotente) aplica o workaround no cache
> antes do build ReleaseSafe do GUI.

Gera `dist\XeMonitor-0.5.1-setup.exe`.

## Checklist para validar o instalador real

1. Compilar o `.iss` (Inno Setup) num PC com o Inno instalado.
2. Rodar o wizard **Next → Next → Finish** (pede admin para Program Files/tarefas).
3. Observar o **console visível** com o progresso `[1/7]..[7c]` (WSL/usbipd/Alpine
   + attach USB + verificação do scanner).
4. Confirmar: binários em `%ProgramFiles%\XeMonitor`, config em `%APPDATA%\xemonitor`,
   tarefas criadas, bridge ativo no WSL, GUI aberto **em janela** (sem terminal)
   e cliente conectado.
5. Confirmar o feedback do scanner: `[OK] Scanner USB-Serial detectado` ou o
   aviso `[IMPORTANTE] Scanner USB-Serial NAO detectado` com instruções.
6. Escanear um código no Bloco de Notas (com o fluxo serial funcionando).

## Lembretes importantes

- **UIPI**: xemonitor/gui e o editor-alvo devem rodar **não elevados**. O
  instalador pede admin, mas a tarefa `XeMonitor-App` usa `/rl LIMITED`, o
  `install_windows.bat` **não** lança o GUI (evita processo elevado) e o
  `[Run]` do GUI usa `runascurrentuser` — não elevar a injeção.
- **Pasta de config**: o app usa `%APPDATA%\xemonitor` (ver `src/paths.zig`); o
  instalador grava o `xemonitor-gui.conf` e os wrappers criam a pasta se faltar.
- Bridge continua no WSL (Alpine/OpenRC padrão; Arch/systemd fallback); o
  instalador **não** roda o bridge no Windows — apenas o serviço no WSL.
- O driver CH340 no Windows permanece quebrado (erro 31); por isso todo o
  fluxo usa o bridge TCP no WSL (não há acesso serial direto no Windows).
- **DTR/RTS**: o Honeywell 1900 em modo serial só transmite com DTR+RTS ativos.
  O bridge aciona ambos (`ioctl(TIOCMBIS)` em `src/bridge.zig`); se o scan não
  chegar, verifique se o binário instalado em `/usr/local/bin/xemonitor-bridge`
  é o atualizado (recompilar com `zig build` e reinstalar).
- **Scanner USB-Serial**: o Honeywell 1900 deve estar conectado via adaptador
  CH340 (USB-SERIAL) para o fluxo funcionar. O GUI (modo `wsl`) avisa na barra
  de status quando o `/dev/ttyUSB0` não está presente e o `bridge_ctl.bat dev`
  testa a presença do dispositivo.
