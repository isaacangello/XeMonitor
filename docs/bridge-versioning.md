# Bridge versioning

O binário `bridge` (musl estático, roda no Alpine WSL) tem versionamento
próprio e independente da versão do app Windows. Cada compilação gera um
**miniroot Alpine pré-configurado** que o instalador consome.

## Esquema

### Formato

`BRIDGE_VERSION` (semver) + `BRIDGE_BUILD` (contador, 3+ dígitos) =
`0.8.0.001` (machine-readable).

| Campo | Origem | Editado quando? | Onde? |
|---|---|---|---|
| `BRIDGE_VERSION` (semver) | `const` em `build.zig` | Bridge tem mudança observável pelo usuário | `build.zig` (linha `const BRIDGE_VERSION`) + `build.zig.zon` (`.bridge_version`) |
| `BRIDGE_BUILD` (contador) | `zig-out/.bridge_build` (auto) | Nunca (auto-bump em todo `zig build bridge`) | (auto) |
| App `VERSION` (semver) | `build.zig.zon` `.version` | App tem mudança (xemonitor.exe, xemonitor-gui.exe, instalador) | `build.zig.zon` + `xemonitor.rc` + `xemonitor.iss` |

### Saída textual

`bridge --version` (human) → `Xe. 0.8.0 bridge 001` (single-line, palavra
"bridge" substitui "build" no campo do contador).

`bridge --print-version` (machine) → `0.8.0.001`.

`bridge --version-json` → `{"version":"0.8.0","bridge_build":"001","arch":"x86_64-linux-musl"}`.

## Bump do `BRIDGE_VERSION`

Quando bumpar o `BRIDGE_VERSION` no `build.zig`:

1. Editar `const BRIDGE_VERSION: []const u8 = "0.8.0";` em `build.zig`.
2. Editar `.bridge_version = "0.8.0";` em `build.zig.zon` (manter em sincronia).
3. **Opcional**: bumpar `.version` do app em `build.zig.zon` (se for release do app).
4. **Opcional**: bumpar `FileVersion`/`ProductVersion` em `assets/xemonitor.rc`.
5. **Opcional**: bumpar `#define MyAppVersion` em `packaging/windows/xemonitor.iss`.
6. **Opcional**: resetar `zig-out/.bridge_build` se quiser (próximo build começa do `001`).
7. Próximo `zig build bridge` → incrementa `BRIDGE_BUILD` e injeta o valor novo.
8. Próximo `zig build build-bridge-miniroot` (em WSL) → gera
   `alpine-bridge-<version>.<bridge_build>-x86_64.tar.gz` no
   `packaging/windows/miniroots/`.

## Auto-bump do `BRIDGE_BUILD`

Toda chamada a `zig build bridge` (em qualquer host: Windows, Linux,
WSL) **incrementa o contador**. O arquivo de estado é `zig-out/.bridge_build`
(gitignored). Em clones fresh, o contador começa do `001` ou do valor
de `XM_BRIDGE_BUILD` (env var, usado por CI para determinismo).

Estratégia de fallback (na ordem):
1. `zig-out/.bridge_build` (persiste entre builds locais).
2. Env `XM_BRIDGE_BUILD` (override manual/CI).
3. `001` (bootstrap, gravado no arquivo).

Não é usado `git rev-list --count` (a API `Child.spawn` em Zig 0.16 é
instável para uso build-time síncrono; CI define `XM_BRIDGE_BUILD` para
ter valor determinístico).

## Geração de miniroot

`scripts/build_miniroot.sh` orquestra a geração:

```
zig-out/bin/bridge (versão X.Y.Z build NNN)
       +
alpine-minirootfs (3.24.1, 3.6 MB)
       +
openrc/kmod/eudev + udev rule CH340 + wsl.conf
       +
openrc/xemonitor-bridge (init script) + /etc/xemonitor/device override
       ↓
wsl --import distro temporária
       ↓
wsl -d distro -- sh build_golden_alpine.sh
       ↓
valida (rc-service start + porta 9000)
       ↓
wsl --export → alpine-bridge-X.Y.Z.NNN-x86_64.tar.gz
       ↓
rolling 10 (apaga os mais antigos)
```

Invocado pela step `zig build build-bridge-miniroot` (só funciona em
Linux/WSL; em Windows emite aviso e sai OK — o CI cuida).

## Cache e Release

- **Cache local** (rolling 10, em `packaging/windows/miniroots/`,
  **commitado** no repo): 10 tarballs mais recentes por mtime. Tamanho
  típico: 10 × ~30 MB = ~300 MB.
- **Asset do Release** (CI, autoritativo): `build-linux` job no
  `release.yml` gera o miniroot e sobe como asset. O `build-windows`
  job baixa esse asset antes do ISCC empacotar o setup.exe.

## Instalador

`xemonitor.iss` [Files] referencia **um** miniroot (o da release autoritativa).
O `install_windows.bat` seleciona o tarball mais recente em
`%APP_DIR%\packaging\windows\miniroots\alpine-bridge-*.tar.gz`.

Não há fallback de download em runtime: se o miniroot sumiu, a
instalação falha com erro claro. O instalador nunca usa um miniroot
que não foi validado pelo `build_miniroot.sh`.

## Próximos passos (pós-v0.8.0)

- Bumpar `bridge_version` no `build.zig` deve rodar `zig build
  build-bridge-miniroot` automaticamente (hook de pre-commit?).
- Adicionar `bridge` ao release workflow (compilar Linux + gerar
  miniroot + upload como asset + compilar Windows com miniroot
  embarcado).
- Cache `zig-out/.bridge_build` em CI para evitar colisões entre
  jobs paralelos.
