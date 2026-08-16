; ============================================================
; xemonitor.iss — instalador Windows do XeMonitor (Inno Setup)
; Wizard Next -> Next -> Finish. Instala tudo e inicia o fluxo:
;   - xemonitor.exe (Windows, injetor SendInput)
;   - bridge (Linux musl p/ WSL)
;   - setup_wsl.sh + openrc init script
;   - scripts (bridge_ctl, install_bridge_service, autostart)
;   - roda install_windows.bat ao final ([Run]) que cuida de
;     WSL2/usbipd/Alpine + tarefas + inicio automatico.
;
; Compilacao (na raiz do repo):
;   iscc packaging\windows\xemonitor.iss
; ============================================================
#define MyAppName "XeMonitor"
#define MyAppVersion "0.5.1"
#define MyAppPublisher "XeMonitor"
#define MyAppExeName "xemonitor-gui.exe"

[Setup]
AppId={{D4B7C7E6-5E1A-4B9A-9A11-7F4E0B6D2C88}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\XeMonitor
DefaultGroupName=XeMonitor
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=XeMonitor-{#MyAppVersion}-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#MyAppName} {#MyAppVersion}
; UIPI: o instalador pede admin (tarefas + Program Files), mas o
; [Run] que inicia o xemonitor nao roda elevado (tarefa /RL LIMITED).

[Languages]
Name: "ptbr"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Files]
; Binarios Windows (GUI principal + cliente injetor)
Source: "..\..\zig-out\bin\xemonitor-gui.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\zig-out\bin\xemonitor.exe"; DestDir: "{app}"; Flags: ignoreversion
; Setup USB CH340 (usbipd bind/attach) — usado pela tarefa XeMonitor-USB-Attach
Source: "..\..\setup_usb.bat"; DestDir: "{app}"; Flags: ignoreversion
; Bridge Linux (musl estatico) — compilado com `zig build bridge -Doptimize=ReleaseSafe`
Source: "..\..\zig-out\bin\bridge"; DestDir: "{app}"; Flags: ignoreversion
; Setup WSL (udev/usbip/wsl.conf) + init OpenRC + unit systemd
Source: "..\..\setup_wsl.sh"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\openrc\xemonitor-bridge"; DestDir: "{app}\openrc"; Flags: ignoreversion
Source: "..\..\systemd\xemonitor-bridge.service"; DestDir: "{app}\systemd"; Flags: ignoreversion
; Scripts
Source: "..\..\scripts\bridge_ctl.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\wsl_timeout.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\install_bridge_service.sh"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\install_autostart.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\uninstall_autostart.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion
; Instalador/helpers do pacote
Source: "install_windows.bat"; DestDir: "{app}\packaging\windows"; Flags: ignoreversion
Source: "start_bridge.cmd"; DestDir: "{app}\packaging\windows"; Flags: ignoreversion
Source: "start_xemonitor.cmd"; DestDir: "{app}\packaging\windows"; Flags: ignoreversion

[Icons]
Name: "{group}\XeMonitor"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall XeMonitor"; Filename: "{uninstallexe}"
Name: "{autodesktop}\XeMonitor"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Run]
; Passo 1: instalador completo (WSL2/usbipd/Alpine + bridge + tarefas + USB)
; Rodado ELEVADO (herda o admin do setup) e VISIVEL para o usuario ver o
; progresso [1/7]..[7c]. /silent suprime os pauses do .bat.
Filename: "{app}\packaging\windows\install_windows.bat"; WorkingDir: "{app}"; Parameters: "/silent"; StatusMsg: "Configurando WSL, bridge, USB e tarefas..."
; Passo 2: lanca o GUI principal (janela + bandeja; nao elevado para evitar
; bloqueio UIPI no SendInput — o setup pediu admin, [Run] herda elevacao)
Filename: "{app}\{#MyAppExeName}"; Flags: nowait skipifsilent runascurrentuser; Description: "Iniciar XeMonitor agora"

[UninstallRun]
; Desinstalador visivel e em primeiro plano (nao runhidden/runascurrentuser):
; herda o admin do uninstaller, mostra o progresso e /silent suprime o pause.
Filename: "{app}\scripts\uninstall_autostart.bat"; Parameters: "/silent"; StatusMsg: "Removendo tarefas agendadas..."
