# Instruções para Testar o Instalador na VM Windows (dockur/windows)

## 1. Subir a VM

```bash
cd /home/isaacca/hd/Codigos/XeMonitor/xemonitor
docker compose -f docker-compose.xm-test.yml up -d
```

Aguarde o download do Windows 10 LTSC (~4.6 GB) e o primeiro boot (~30-40 min).

## 2. Acessar a VM

Abra no navegador: **http://127.0.0.1:8006/**

- Login: `xemonitor`
- Senha: `xemonitor`

## 3. Habilitar WSL2 na VM

No PowerShell (Admin) dentro da VM:

```powershell
# Verificar status
wsl --status

# Se não habilitado, rodar:
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
Restart-Computer -Force
```

Após reboot:

```powershell
wsl --set-default-version 2
wsl --update
wsl --status
wsl --list --online
```

## 4. Testar o Instalador

### Opção A: Usar tarball já baixado (recomendado, evita download)

```powershell
Copy-Item "Z:\alpine-minirootfs-3.24.1-x86_64.tar.gz" "$env:TEMP\alpine-minirootfs.tar.gz"
Test-Path "$env:TEMP\alpine-minirootfs.tar.gz"
cd Z:\packaging\windows
.\install_windows.bat
```

### Opção B: Deixar o script baixar automaticamente

```powershell
cd Z:\packaging\windows
.\install_windows.bat
```

O script agora:
1. Instala winget (App Installer) se faltar
2. Instala wget (via winget/choco/scoop) se faltar
3. Busca versão latest do Alpine (3.24.1) do YAML oficial
4. Baixa o minirootfs ou usa o que já está em `%TEMP%\alpine-minirootfs.tar.gz`
5. Importa Alpine via `wsl --import`
6. Instala dependências (openrc, kmod, eudev)
7. Configura udev + wsl.conf + modprobe ch341
8. Inicia bridge e valida porta 9000
9. Copia binários Windows
10. Cria tarefas agendadas

## 5. Validar Fixes F1-F6

Observe no log se erros propagam como `_FATAL` em vez de `AVISO`:

- `copy_bridge` / `copy_openrc` falha → `_FATAL`
- `svc_enable` sem exit code → agora checa `WSL_RC`
- `svc_status` valida porta 9000 após `svc_enable`
- `bridge_ctl.bat :rc_start` valida `ss -tln | grep :9000`
- `schtasks /Create` checa exit code

## 6. Fake Scan Test (se bridge subir)

```powershell
wsl -d Alpine -- /usr/local/bin/xemonitor-bridge --fake-scan
```

Abra o Bloco de Notas, dê foco, o scan deve injetar texto.

## Arquivos Úteis

- `Z:\WSL_ENABLE_COMMANDS.txt` — comandos WSL prontos para copiar/colar
- `Z:\alpine-minirootfs-3.24.1-x86_64.tar.gz` — tarball Alpine 3.24.1
- Logs em `%APPDATA%\xemonitor\logs\install.log`

## Parar a VM

```bash
docker compose -f docker-compose.xm-test.yml down
```

## Limpar tudo (se quiser recomeçar do zero)

```bash
docker compose -f docker-compose.xm-test.yml down -v
rm -rf /home/isaacca/xm-win
```