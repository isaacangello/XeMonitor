# Versionamento (fonte única: arquivo VERSION)

Desde v0.8.1, a versão do XeMonitor tem **uma única fonte de verdade**: o
arquivo `VERSION` na raiz do repo (uma linha, ex. `0.8.1`). Todos os
binários e o instalador derivam a versão dele. Bumpar = editar `VERSION`
(e, no Windows, `assets/xemonitor.rc` para os metadados do PE).

## Fluxo da versão

```
VERSION (raiz)  ──►  build.zig (resolveVersion) → addOptions {version}
                        ├── bridge  (build_options.version)
                        ├── xemonitor.exe (build_options.version; --version)
                        └── xemonitor-gui (build_options.version; título da janela)
                  ──►  .github/workflows/release.yml
                        ├── build-linux: --bridge-version "$(cat VERSION)"
                        └── build-windows: ISCC "/DMyAppVersion=$(cat VERSION)"
                  ──►  xemonitor.iss (MyAppVersion via -DMyAppVersion)
                        └── [Run] repassa a versão ao install_windows.bat
```

### Únicos 2 arquivos manuais por bump

1. `VERSION` — a fonte em si.
2. `assets/xemonitor.rc` — `FILEVERSION`/`PRODUCTVERSION`/`FileVersion`/
   `ProductVersion` (metadados do executável Windows; o Inno pode ler do PE,
   mas mantemos explícito).

Tudo o mais é derivado automaticamente: `build.zig.zon` (`.version` e
`.bridge_version` devem estar em sincronia com `VERSION` — o CI valida),
nomes de artefato, mensagens do instalador, `--version` dos binários,
título da janela.

### `#include` não é usado no ISPP

O preprocessor do Inno Setup (`#include`) cola o conteúdo de texto puro
inline, o que **não** vira uma macro — incluí-lo diretamente causa
"Expression expected". Por isso o `xemonitor.iss` recebe a versão via
`ISCC /DMyAppVersion=<ver>`, e o `#ifndef MyAppVersion` define `0.0.0`
como default para uso manual acidental.

## Saídas

- `xemonitor --version` → `xemonitor 0.8.1`
- `bridge --version` → human; `bridge --print-version` → `0.8.0.001`
  (machine); `bridge --version-json` → JSON com `version`/`bridge_build`/`arch`.
- `xemonitor-gui` → título da janela `XeMonitor 0.8.1`.
- Instalador → `dist/XeMonitor-0.8.1-setup.exe`.

## Bridge build (contador)

Independente do `VERSION`, o `bridge` tem um contador de build
(`BRIDGE_BUILD`, 3+ dígitos) que **auto-incrementa** a cada
`zig build bridge`, persistido em `zig-out/.bridge_build` (gitignored).
Fonte no `build.zig` (`resolveBridgeBuild`). Fallback: env `XM_BRIDGE_BUILD`
(CI), depois `001`.

## Geração do miniroot

`scripts/build_miniroot.sh` gera `alpine-bridge-<version>.<build>-x86_64.tar.gz`
em `packaging/windows/miniroots/`. Com o `VERSION` como fonte, o
`--bridge-version` passado no CI vira `$(cat VERSION)`, e o contador
`<build>` vem do CI/`XM_BRIDGE_BUILD`.

## Bump (passo a passo)

1. Editar `VERSION` (ex.: `0.8.1` → `0.8.2`).
2. Editar `assets/xemonitor.rc` (4 valores: FILEVERSION, PRODUCTVERSION,
   FileVersion string, ProductVersion string) para `0,8,2,0` / `0.8.2`.
3. Manter `build.zig.zon`: `.version` e `.bridge_version` em `0.8.2`.
4. Recompilar Windows: `zig-out\bin\xemonitor.exe` / `xemonitor-gui.exe`.
5. `packaging\windows\build_installer.bat` → lê `VERSION` e chama
   `ISCC /DMyAppVersion=0.8.2`, gerando `dist/XeMonitor-0.8.2-setup.exe`.
6. Commit + push.

## Convenções / avisos

- **Nunca** bumpar versão editando os binários/iss/bat direto: estes são
  derivados do `VERSION`.
- `build.zig.zon` `.version`/`.bridge_version` devem estar em sincronia com
  `VERSION`; o CI (check opcional) valida a igualdade.
- Ao recompilar o Windows, mate `xemonitor.exe`/`xemonitor-gui.exe` antes
  (o arquivo fica locked e o `zig build` falha com AccessDenied).
