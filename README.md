# XeMonitor

Aplicação em Zig para ler dados de um dispositivo serial (ex.: scanner, Leitor de codigo de barras) e injetar o conteúdo recebido como entrada de teclado no sistema operacional.

## Visão geral

O executável:

1. Abre uma porta serial fixa (`COM1` no Windows ou `/dev/ttyUSB0` no Linux).
2. Configura a serial em `115200 8N1` sem handshake.
3. Lê bytes continuamente até encontrar fim de linha (`\r` ou `\n`).
4. Normaliza payloads que chegam com separador intercalado `'3'` (ex.: `132333` -> `1233`).
5. Injeta o texto no sistema e em seguida envia `Enter`.

## Stack e dependências

- Zig `0.15.2` (mínimo, conforme `build.zig.zon`)
- Dependência Zig:
  - `serial` (ZigEmbeddedGroup)
- Ferramenta de injeção de teclado por ambiente:
  - Windows: `powershell` + `System.Windows.Forms.SendKeys`
  - Linux Wayland: `ydotool`
  - Linux X11: `xdotool`

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

O programa escolhe o injetor automaticamente:

- Windows -> PowerShell SendKeys
- Linux com `XDG_SESSION_TYPE=wayland` -> `ydotool`
- Linux (outros casos) -> `xdotool`

## Testes

```bash
zig build test
```

## Configuração atual no código

Atualmente os valores estão fixos em `src/main.zig`:

- Porta serial:
  - Windows: `"\\\\.\\COM1"`
  - Linux: `"/dev/ttyUSB0"`
- Serial config:
  - Baud rate: `115200`
  - Word size: `8`
  - Parity: `none`
  - Stop bits: `one`
  - Handshake: `none`

## Logs esperados

Ao iniciar, você verá algo como:

- `the serial port '...' selected .`
- `platform=..., keyboard injector=...`

Durante leitura, cada byte recebido é impresso no console.

## Troubleshooting

### Erro de compilação: `no module named 'serial'`

O módulo `serial` precisa estar importado no `build.zig` dentro do `root_module` do executável. O projeto já está ajustado para isso.

### Porta serial não encontrada

Mensagem típica:

- `Invalid config: the serial port '...' does not exist.`

Verifique se o dispositivo está conectado e ajuste a porta em `src/main.zig`.

### Sem injeção de teclado no Linux

- Wayland: confirme se `ydotool` está instalado e funcional.
- X11: confirme `xdotool`.
- Verifique permissões do usuário para acesso à serial (`/dev/ttyUSB0`).

## Próximas melhorias recomendadas

- Tornar porta serial e baud rate configuráveis por argumentos/variáveis de ambiente.
- Tratar reconexão automática da serial em caso de desconexão.
- Adicionar testes unitários para a função de normalização (`stripInterleavedSeparator`).
- Expor modo `dry-run` para debug sem injeção real de teclado.
