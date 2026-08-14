# Instalador Windows — instruções (wizard next-next-finish)

> Status: **planejado** (roadmap item 3). Este documento registra o que fazer
> quando estivermos no Windows para criar o instalador com wizard
> **Next → Next → Finish** (estilo dos instaladores clássicos do Windows).

## Objetivo

Empacotar `xemonitor.exe` (+ bridge e scripts de apoio) num instalador que o
usuário roda e conclui em três cliques, sem console/PowerShell manual. Ao
terminar, deve deixar o fluxo pronto para escanear:

1. `xemonitor.exe` instalado (ex.: `C:\Program Files\XeMonitor\`).
2. Tarefas agendadas de **boot/logon** (espelho de `scripts/install_autostart.bat`):
   - `init Docker WSL` (boot + logon) — inicia o Docker no WSL;
   - `attach CH340` (logon) — `usbipd attach` do scanner ao WSL;
   - `start bridge` (logon) — `systemctl start xemonitor-bridge` no WSL;
   - `start xemonitor` (logon) — roda `xemonitor.exe --tcp 127.0.0.1:9000`
     como processo invisível.
3. Ícone de atalho no menu Iniciar (`XeMonitor`) e/ou bandeja (opt-in `--tray`).

## Como foi feito antes (padrão do projeto)

O projeto **não usa** um instalador MSI/WiX. O padrão até aqui é **script**:

- **Linux**: `install.sh` (curl | bash) — instala binários, udev, grupos,
  serviço, autostart (v0.2.0+).
- **Windows**: `scripts/install_autostart.bat` — cria as tarefas agendadas
  com `schtasks` (sem UI de wizard). Os `.bat` (`run_bridge.bat`,
  `stop_bridge.bat`, `status_bridge.bat`) fazem o resto do dia a dia.

Portanto há **duas opções** para o "instalador Windows":

### Opção A — avançar o script .bat (recomendada, menor esforço)

Converter `install_autostart.bat` num `install_windows.bat` que:
- copia `xemonitor.exe` para `%ProgramFiles%\XeMonitor\`;
- cria as tarefas agendadas (boot + logon);
- cria atalho no Menu Iniciar (via PowerShell, `WScript.Shell`).

O "wizard" nesse caso é a própria janela do Windows (contas de usuário /
UAC + confirmações do `schtasks`). Próximo passo real de wizard é a Opção B.

### Opção B — instalador com wizard Next→Next→Finish

Ferramentas adequadas (custo x resultado):

| Ferramenta | Esforço | Observação |
|---|---|---|
| **Inno Setup** (`.iss`) | Baixo | Compila com `ISCC.exe`; cria installer.exe com wizard next-next-finish; suporte a `[Run]`/`[Tasks]`; é o mais usado p/ este estilo |
| **NSIS** (`.nsi`) | Baixo | Wizard padrão; mais verboso que Inno; mesmo papel |
| **WiX / MSI** | Alto | Silencioso/empacotado p/ enterprise; exige `.wxs` + WiX toolset; sem wizard visual rico por padrão |
| **Tarefas agendadas** (atual) | Zero | Não é wizard — é o "como foi feito" |

> Recomendação: **Inno Setup** — instalador .exe único, wizard
> next-next-finish, permissões automáticas, e permite rodar
> `install_autostart.bat`/PowerShell ao final via `[Run]`.

## Esqueleto Inno Setup (p/ quando formos ao Windows)

`packaging/windows/xemonitor.iss` (a criar):

```iss
[Setup]
AppName=XeMonitor
AppVersion=0.2.0
DefaultDirName={autopf}\XeMonitor
DefaultGroupName=XeMonitor
OutputDir=dist
OutputBaseFilename=XeMonitor-0.2.0-setup
PrivilegesRequired=admin        ; cria tarefas agendadas + Program Files

[Files]
Source: "zig-out\bin\xemonitor.exe"; DestDir: "{app}"
Source: "scripts\install_autostart.bat"; DestDir: "{app}\scripts"

[Icons]
Name: "{group}\XeMonitor"; Filename: "{app}\xemonitor.exe"

[Run]
Filename: "{app}\scripts\install_autostart.bat"; Flags: runhidden
; opcional: Filename: "{app}\xemonitor.exe"; Parameters: "--tray"; Flags: nowait
```

Compilação (no Windows):
```cmd
rem precisa do Inno Setup instalado (iscc.exe no PATH)
iscc packaging\windows\xemonitor.iss
```

### Passos para implementar (checklist — ao chegar no Windows)

1. Criar `packaging/windows/xemonitor.iss` com o esqueleto acima (ajustar versão).
2. Confirmar que `xemonitor.exe` compila no Windows 0.15.2: `C:\zig-x86_64-windows-0.15.2\zig.exe build`.
3. Testar o instalador numa VM/usuário limpo: rodar o wizard
   **Next → Next → Finish** e escanear um código no Bloco de Notas.
4. Subir o `.iss` para o repo; rodar `install_autostart.bat` **já coberto** pelo
   `[Run]` do instalador.
5. (Opcional) incluir o `setup_usb.bat` como atalho no grupo XeMonitor.

## Lembretes importantes

- **UIPI**: xemonitor e o editor-alvo devem rodar **não elevados**. O instalador
  pode pedir admin (para criar tarefas/instalar em Program Files), mas o
  **`[Run]` que lança o xemonitor não deve rodar elevado** — ou use a tarefa
  agendada com `/rl LIMITED` (padrão atual) para evitar o bloqueio do SendInput.
- **Tarefas agendadas**: manter o padrão `/rl LIMITED` + wrappers `.cmd` que
  redirecionam stdout/stderr para arquivo (a saída do terminal corrompe bytes
  UTF-8).
- **Pasta de config**: em v0.2.0+ o log/pid ficam em `%APPDATA%\xemonitor`
  (ver `src/paths.zig`); o instalador não precisa criá-la — o app cria na
  primeira execução.
- Bridge continua no WSL (Arch/Alpine); o instalador Windows **não** instala o
  bridge — apenas as tarefas que iniciam o serviço no WSL.
