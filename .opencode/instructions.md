# Instruções de sessão (opencode) — XeMonitor

Contexto operacional resumido do projeto (ver `AGENTS.md` para detalhes).

## Fluxo ativo
1. Scanner Honeywell 1900 (USB-SERIAL via CH340) no WSL2 (Arch, systemd) → `/dev/ttyUSB0`
2. Bridge Zig (`zig-out/bin/bridge`) serve TCP raw na porta **9000** no WSL2
3. `xemonitor.exe --tcp 127.0.0.1:9000` (Windows) lê o scan e injeta como teclado via **`SendInput`** (Win32 nativo)

Não usar PowerShell/clipboard para injeção (fallback `.windows_powershell` é legado).

## UIPI (regra de ouro)
- xemonitor e o editor alvo (ex.: Notepad++/Bloco de Notas) devem rodar em integridade **Média**.
- `SendInput` Médio→Médio funciona; Médio→Elevado retorna 0 (bloqueado).
- Para validar injeção sem elevar: `schtasks` com `/rl LIMITED` + wrapper `.cmd` que redireciona stdout/stderr para arquivo; ler o resultado com a ferramenta read (o terminal corrompe bytes UTF-8 soltos).

## Build / teste
```cmd
taskkill /F /IM xemonitor.exe 2>nul
C:\zig-x86_64-windows-0.15.2\zig.exe build
C:\zig-x86_64-windows-0.15.2\zig.exe build test
```
- Matar xemonitor **antes** de recompilar.
- "info: libserialport configured" no stderr é normal (não é erro).
- Zig 0.15.2 (Windows) / 0.16.0 (WSL). Não usar `catch |err| {...} else` (0.15 não compila).

## Logs (xemonitor.log, append — não truncar com processo aberto)
- `[scan] '...'` — conteúdo lido
- `[info] injected '...'` / `[info] enter sent` — sucesso do SendInput
- `[error] SendInput ... failed (GetLastError=0x...)` — falha (ver `w.last_sendinput_error`)

## Avisos
- Ícone de bandeja é opt-in (`--tray`); não criar órfãos de PowerShell ao matar com `taskkill /f`.
- Bridge executa de `/usr/local/bin/xemonitor-bridge`; ao recompilar, rodar `scripts/install_bridge_service.sh` (ou `--reinstall`).
- WSL: usar `wsl -u root systemctl ...` para o serviço do bridge (isaac não gerencia systemd).
- Linux é um alvo possível, mas a validação atual é Windows.

## Ver também
- `TODO.md` — plano atual
- `.checkpoint.md` — histórico/pendências da sessão
- `CHANGELOG.md` — changelog
