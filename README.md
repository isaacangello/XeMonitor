# XeMonitor

Aplicação em Zig para ler dados de um dispositivo serial (ex.: scanner, Leitor de codigo de barras) e injetar o conteúdo recebido como entrada de teclado no sistema operacional.

## Visão geral

O executável:

1. Seleciona a porta serial automaticamente (detecta scanners Honeywell/Xenon) ou via CLI/ambiente.
2. Configura a serial em `115200 8N1` sem handshake (configurável via `XEMONITOR_BAUD`).
3. Lê bytes continuamente até encontrar fim de linha (`\r` ou `\n`).
4. Normaliza payloads que chegam com separador intercalado `'3'` (ex.: `132333` -> `1233`).
5. Injeta o texto no sistema e em seguida envia `Enter`.
6. Reconecta automaticamente em caso de desconexão da porta serial.

## Stack e dependências

- Zig `0.15.2` (mínimo, conforme `build.zig.zon`)
- Dependência Zig:
  - `serial` (ZigEmbeddedGroup)
- Ferramenta de injeção de teclado por ambiente:
  - Windows: `powershell` + `System.Windows.Forms.SendKeys`
  - Linux Wayland: `ydotool`
  - Linux X11: `xdotool`
- Ícone de bandeja (opcional):
  - Linux: `yad`
  - Windows: `powershell` (já presente por padrão)

## Estrutura do projeto

- `src/main.zig`: lógica principal (serial + parsing + injeção de teclado)
- `src/root.zig`: módulo base e testes simples
- `build.zig`: configuração de build/test/run
- `build.zig.zon`: metadados do pacote e dependências

## Compilar

```bash
zig build
```

## Executar

```bash
zig build run
```

Ou após compilar:

```bash
./zig-out/bin/xemonitor [--port <PORT>]
```

Exemplos:

```bash
./zig-out/bin/xemonitor --port COM4
./zig-out/bin/xemonitor COM4
```

O programa escolhe a porta nesta ordem:

1. Argumento de linha de comando (`--port` ou direto)
2. Variável de ambiente `XEMONITOR_PORT`
3. Detecção automática (procura scanners Honeywell/Xenon)
4. Padrão: `COM1` (Windows) ou `/dev/ttyUSB0` (Linux)

O baud rate pode ser configurado via variável de ambiente `XEMONITOR_BAUD` (padrão: `115200`).

O programa escolhe o injetor automaticamente:

- Windows -> PowerShell SendKeys
- Linux com `XDG_SESSION_TYPE=wayland` -> `ydotool`
- Linux (outros casos) -> `xdotool`

Tray icon durante execução:

- Linux: se `yad` estiver instalado, cria ícone na bandeja.
- Windows: cria ícone na bandeja usando `System.Windows.Forms.NotifyIcon` via PowerShell.
- Outros sistemas: não cria ícone (apenas warning no log).

## Testes

```bash
zig build test
```

## Configuração

A porta serial e baud rate podem ser definidos de três formas:

- **Argumento CLI**: `xemonitor --port COM4` ou `xemonitor COM4`
- **Variável de ambiente**: `XEMONITOR_PORT=COM4` e `XEMONITOR_BAUD=9600`
- **Auto-detecção**: o programa procura dispositivos Honeywell/Xenon conectados

Valores padrão (quando não detectado):

- Porta serial: `COM1` (Windows) ou `/dev/ttyUSB0` (Linux)
- Baud rate: `115200`
- Configuração serial: 8N1, sem handshake

## Logs esperados

Ao iniciar, você verá algo como:

- `serial port 'COM4' selected (source=cli).`
- `serial baud rate=115200`
- `platform=..., keyboard injector=...`

Durante leitura, cada byte recebido é impresso no console.

Se a porta não for encontrada, o programa tenta reconectar a cada 2 segundos.

## Troubleshooting

### Erro de compilação: `no module named 'serial'`

O módulo `serial` precisa estar importado no `build.zig` dentro do `root_module` do executável. O projeto já está ajustado para isso.

### Porta serial não encontrada

Mensagem típica:

- `[warn] serial port '...' (source=...) not found. retrying selection every 2s...`

O programa tentará reconectar automaticamente. Se necessário, especifique a porta:

```bash
./zig-out/bin/xemonitor --port COM3
# ou
export XEMONITOR_PORT=COM3
```

### Sem injeção de teclado no Linux

- Wayland: confirme se `ydotool` está instalado e funcional.
- X11: confirme `xdotool`.
- Verifique permissões do usuário para acesso à serial (`/dev/ttyUSB0`).

### Sem ícone de bandeja no Linux

- Instale `yad` (ex.: Debian/Ubuntu: `sudo apt install yad`).
- O app continua funcionando sem o ícone; ele apenas emite um warning no log.

### Sem ícone de bandeja no Windows

- Verifique se `powershell` está disponível no PATH.
- O app continua funcionando sem o ícone; ele apenas emite um warning no log.
