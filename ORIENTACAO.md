# XeMonitor — Guia de Uso

## O que é
Aplicativo em Zig que lê códigos de barras de um scanner Honeywell 1900 (via CH340 USB-Serial) e injeta o texto como teclado no Windows.

---

## Arquivos importantes

| Arquivo | Descrição |
|---------|-----------|
| `src/main.zig` | Código principal do programa |
| `build.zig` | Script de compilação |
| `run_xemonitor.bat` | Script pra compilar + executar (janela fica aberta) |
| `xemonitor.log` | Log de execução (gerado após rodar) |
| `zig-out/bin/xemonitor.exe` | Executável compilado |

---

## Como usar

### 1. Compilar e rodar
```
run_xemonitor.bat
```

### 2. Forçar porta específica
```
run_xemonitor.bat --port COM4
```
ou
```
set XEMONITOR_PORT=COM4
run_xemonitor.bat
```

### 3. Usar API nativa do Windows (se libserialport falhar)
```
run_xemonitor.bat --winapi
```

### 4. Mudar baud rate
```
set XEMONITOR_BAUD=9600
run_xemonitor.bat
```

---

## O que já foi feito / problemas resolvidos

### Log em arquivo
- Todo `std.debug.print` foi substituído por `logPrint`
- Grava no terminal E no arquivo `xemonitor.log`

### Auto-detect do CH340
- O programa agora reconhece CH340/CH341 (WCH) além de Honeywell/Xenon
- Score 8 para CH340: "ch34" (4) + "serial" (2) + "wch" (2)

### Configuração serial no WinAPI (`--winapi`)
- Usa `BuildCommDCBA` (API oficial do Windows) para montar o DCB
- Tenta com DTR/RTS ligados; se falhar, tenta com desligados
- Adicionado `PurgeComm` e `SetupComm` pra limpar/inicializar buffers
- `Sleep(100)` entre etapas pra dar tempo do CH340 responder

---

## Problema atual (não resolvido)
`SetCommState` retorna erro 31 (ERROR_GEN_FAILURE) no CH340 via WinAPI.
- Possível causa: driver CH340 desatualizado ou configuração de handshake
- Tentar sem `--winapi` (usa libserialport) pode resolver
- Se resolver, o `run_xemonitor.bat` padrão já usa libserialport

---

## Requisitos

- Zig 0.15.2 (`C:\zig-x86_64-windows-0.15.2\`)
- MSYS2 com libserialport (`C:\msys64\ucrt64\`)
- Driver CH340 instalado (www.wch.cn/download/CH341SER_EXE.html)
- Scanner Honeywell 1900 conectado via CH340

---

## Compilação manual
```
zig build
zig build run
```

## Limpar build
```
rm -rf zig-out .zig-cache
```
