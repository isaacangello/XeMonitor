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
#define MyAppVersion "0.8.0"
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
; Detecta versao existente via [Code] PrepareToInstall e desinstala
; automaticamente (upgrade, downgrade e restore).

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
; Init OpenRC + unit systemd
Source: "..\..\openrc\xemonitor-bridge"; DestDir: "{app}\openrc"; Flags: ignoreversion
Source: "..\..\systemd\xemonitor-bridge.service"; DestDir: "{app}\systemd"; Flags: ignoreversion
; Scripts
Source: "..\..\scripts\bridge_ctl.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\wsl_timeout.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\install_bridge_service.sh"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\install_autostart.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\..\scripts\uninstall_autostart.bat"; DestDir: "{app}\scripts"; Flags: ignoreversion
; Diagnostico Windows (--check / --fix / --test-serial)
Source: "..\..\diagnose_windows.bat"; DestDir: "{app}"; Flags: ignoreversion
; Instalador/helpers do pacote
Source: "install_windows.bat"; DestDir: "{app}\packaging\windows"; Flags: ignoreversion
Source: "start_bridge.cmd"; DestDir: "{app}\packaging\windows"; Flags: ignoreversion
Source: "start_xemonitor.cmd"; DestDir: "{app}\packaging\windows"; Flags: ignoreversion
; Golden image Alpine (pre-configurada e testada): openrc/kmod/eudev + udev
; rule CH340 + wsl.conf + init script + bridge. Importada pelo instalador.
; Permite instalacao offline (sem depender de download do Alpine).
Source: "..\..\packaging\windows\golden\xemonitor-alpine-3.24.1-x86_64.tar.gz"; DestDir: "{app}\packaging\windows\golden"; Flags: ignoreversion

[Icons]
Name: "{group}\XeMonitor"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall XeMonitor"; Filename: "{uninstallexe}"
Name: "{autodesktop}\XeMonitor"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Run]
; Passo 1: instalador completo (WSL2/usbipd/Alpine + bridge + tarefas + USB)
; Rodado ELEVADO (herda o admin do setup) e VISIVEL para o usuario ver o
; progresso [1/7]..[7c]. /silent suprime os pauses do .bat. Instalacao ja
; existente + /silent = auto-reparo (ve o proprio install_windows.bat).
Filename: "{app}\packaging\windows\install_windows.bat"; WorkingDir: "{app}"; Parameters: "/silent"; StatusMsg: "Configurando WSL, bridge, USB e tarefas..."
; Passo 2: lanca o GUI principal (janela + bandeja). NUNCA roda o exe direto
; daqui: [Run] herda a elevacao do setup e um xemonitor elevado congela (UIPI
; bloqueia o SendInput). A tarefa XeMonitor-App foi criada pelo passo 1 com
; /RL LIMITED; basta dispara-la. schtasks /Run nao eleva (o nivel da tarefa
; governa), entao o GUI roda em integridade Media, correta p/ injecao.
Filename: "{cmd}"; Parameters: "/c schtasks /Run /TN ""XeMonitor-App"""; Flags: nowait; StatusMsg: "Iniciando XeMonitor..."

[UninstallRun]
; Matar processos xemonitor antes de remover tarefas (arquivos podem estar locked).
; herda o admin do uninstaller; skipifdoesntexist evita erro se processos nao existem.
Filename: "{cmd}"; Parameters: "/c taskkill /F /IM xemonitor-gui.exe >nul 2>&1 & taskkill /F /IM xemonitor.exe >nul 2>&1"; Flags: skipifdoesntexist
; Remove tarefas agendadas. /silent suprime o pause.
Filename: "{app}\scripts\uninstall_autostart.bat"; Parameters: "/silent"; StatusMsg: "Removendo tarefas agendadas..."
; Remove a distro WSL 'Alpine' (registro + VHD) deixada pela instalacao, para
; nao interferir numa futura instalacao. skipifdoesntexist evita erro se nao existe.
Filename: "{cmd}"; Parameters: "/c wsl --terminate Alpine >nul 2>&1 & wsl --unregister Alpine >nul 2>&1"; Flags: skipifdoesntexist; StatusMsg: "Removendo distro WSL Alpine..."

[UninstallDelete]
; Fresh total: remove a pasta de config do app (conf + logs + pids) e a install dir.
Type: filesandordirs; Name: "{userappdata}\xemonitor"
Type: filesandordirs; Name: "{commonappdata}\XeMonitor"

[Code]
// Detecta instalacao existente via registro e desinstala automaticamente.
// Funciona para upgrade (mesma versao), downgrade (versao mais nova) e restore.
const
  APP_ID = '{D4B7C7E6-5E1A-4B9A-9A11-7F4E0B6D2C88}';

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  RawPath: String;
  UninstallKey: String;
begin
  Result := '';
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + APP_ID + '_is1';
  RawPath := '';

  // Buscar caminho do desinstalador antigo no registro (HKLM ou HKCU)
  if not RegQueryStringValue(HKLM, UninstallKey, 'UninstallString', RawPath) then
    RegQueryStringValue(HKCU, UninstallKey, 'UninstallString', RawPath);

  if RawPath <> '' then
  begin
    // Remover aspas ao redor
    if Copy(RawPath, 1, 1) = '"' then
      RawPath := Copy(RawPath, 2, Length(RawPath) - 2);
    // Extrair somente o caminho do .exe (remover parametros extras)
    if Pos('.exe', LowerCase(RawPath)) > 0 then
      RawPath := Copy(RawPath, 1, Pos('.exe', LowerCase(RawPath)) + 3);

    if FileExists(RawPath) then
      Exec(RawPath, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
