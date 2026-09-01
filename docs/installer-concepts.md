# Conceitos de Instalação (XeMonitor) — reutilizáveis entre instaladores

Este documento registra os **princípios e padrões** derivados da experiência de
estabilizar o instalador Windows (`install_windows.bat`) e o bridge. O objetivo é
que os **mesmos conceitos sejam reutilizados no instalador Linux** (`install.sh`)
e em qualquer evolução futura, evitando reincidência dos problemas já enfrentados.

> Referência do problema motivador (2026-08-30): o fluxo "bridge→client" não
> funcionava porque a instalação abortava na Fase 1 com `ERROR_ALREADY_EXISTS` ao
> tentar reimportar a distro WSL `Alpine`. Causa: uma **instalação anterior**
> deixou estado residual (distro WSL registrada, `.conf`, tarefas) que blindou o
> reimport e derrubou o instalador.

---

## 1. Instalações anteriores interferem nas seguintes (estado residual)

Uma instalação nunca é só "arquivos numa pasta". Ela deixa **estado em vários
canais do sistema** que persistem e interferem na próxima instalação:

| Canal | Onde | Impacto |
|---|---|---|
| Registro de distros WSL | `wsl -l -v`, VHD em `C:\wsl\<distro>` | `wsl --import` falha com `ERROR_ALREADY_EXISTS` |
| Config do app | `%APPDATA%\xemonitor\` | Instalador detecta `EXISTING=1` → entra em modo auto-reparo |
| Tarefas agendadas | `schtasks` | Re-criadas/inconsistentes se não removidas |
| Binários/scripts instalados | `<InstallDir>` | Versões antigas persistem se não sobrescritas |
| Logs | `%APPDATA%\xemonitor\logs\` | Diagnóstico, mas acumulam histórico |

**Conceito chave:** antes de instalar, o instalador deve **sanear os canais de
estado** e **validar que o saneamento funcionou** — não assumir que "desinstalar
arquivos" basta.

---

## 2. Sanitização pré-instalação (pré-fluxo de limpeza)

**Padrão:** um bloco de *pre-flight* que roda **sempre** (instalação nova ou
auto-reparo), antes de qualquer lógica de detecção `EXISTING`, e que:

1. **Mata processos** do app (evita arquivos locked).
2. **Remove/derruba** contêineres ou ambientes auxiliares (ex.: `wsl --terminate`
   + `wsl --unregister` da distro, com remoção do VHD residual).
3. **Apaga a pasta de config do app** (fresh total) — removendo o marcador que
   dispararia `EXISTING=1`.
4. **Remove tarefas agendadas** de forma idempotente (`/F`, ignorando "não existe").
5. **Loga cada passo + valida o resultado.** Se uma validação de remoção falhar,
   abortar com erro claro (nunca travar "mudo").

**Benefício:** toda instalação começa em estado limpo e previsível. O instalador
entra sempre em modo *fresh* (`EXISTING=0`), sem depender do desinstalador do
empacotador (que só remove arquivos do app, não resíduos de sistema).

> **Reutilizar no `install.sh` (Linux):** aplicar o mesmo pre-flight antes de
> reinstalar — parar o serviço (`systemctl`/`rc-service`), remover binários
> antigos, apagar `~/.config/xemonitor`, limpar `udev`/grupos/serviços residuais,
> **validando** cada remoção com erro claro. Isso evita que um reinstall sobre um
> estado parcial (ex.: unit systemd antiga, grupo órfão) quebre o novo.

---

## 3. "Golden image" do ambiente auxiliar (imagem pré-configurada e testada)

**Problema que resolve:** configurar o ambiente auxiliar (distro WSL / container)
do zero a cada instalação é lento e frágil (rede para `apk`, falhas de rede,
passos ao vivo que quebram).

**Padrão:** gerar **uma vez**, offline, uma imagem do ambiente **já configurada e
testada** (pacotes + config + binário + serviço habilitado), exportá-la e
distribuí-la embutida no instalador / como asset de release. A instalação então
só **importa a imagem** + **inicia/valida o serviço**, pulando as fases de
configuração ao vivo.

**O que separar entre "estático (vai na imagem)" e "dinâmico (instalador faz)":**

| Item | Estático na imagem | Dinâmico (instalador) |
|---|---|---|
| Pacotes do ambiente (ex.: openrc/kmod/eudev) | ✅ | — |
| Config fixa (udev rules, `.conf`, modulos) | ✅ | — |
| Init/unit do serviço | ✅ (versiona com o app) | — |
| **Binário principal do serviço** | ⚠️ varia por build | sobrescrever se o pacote for mais novo |
| Habilitar/iniciar serviço | (habilitado na imagem) | `rc-service/systemctl start` + validar |
| Tarefas/atalhos/ícone do sistema host | — | instalador |

**Regra para o binário:** a imagem vem "pronta pra rodar", mas o instalador
**sobrescreve o binário principal** pelo da versão do pacote **se o do pacote for
mais novo** — assim a imagem é autossuficiente **e** sempre atual.

> **Reutilizar no `install.sh` (Linux):** em vez de um *script* que recompila/roda
> setup ao vivo, gerar/baixar um pacote (`.tar.gz`) já preparado com binários +
> units + udev + config e apenas *extrair* no destino + habilitar/validar. Reduz
> passos ao vivo e falhas de rede durante a instalação.

---

## 4. Hosting/entrega da golden image

Duas vias complementares:

1. **Embutida no instalador** → instala **offline** (sem depender de rede).
   Custo: tamanho do instalador cresce (ex.: ~19 MB a mais).
2. **Asset de release** (ex.: `releases/download/{VERSION}/...`) → permite baixar
   a versão mais recente sem rebuild do instalador e serve de fonte para
   reinstalação online.

**Recomendação:** ambas — embutida (funciona offline) **+** asset de release
(atualização sem rebuild). O instalador prioriza a embutida; se ausente, baixa do
release.

> **Reutilizar no `install.sh` (Linux):** o projeto já baixa o tarball do release
> (`BASE_URL=.../releases/download/${VERSION}`). Manter essa estratégia: tarball
> pronto + checksum + extração, sem etapas de build ao vivo.

---

## 5. Validação pós-instalação (nunca confiar só no exit code da etapa)

Para cada etapa que "sobe" algo (serviço, porta, dispositivo), **validar o
resultado de fato**:

- **Serviço:** `rc-service status` / `systemctl is-active` (não só "start sem erro").
- **Porta:** confirmar que o listener existe (ex.: `ss -tln | grep :9000`).
- **Dispositivo:** confirmar `/dev/ttyUSB*` criado e com permissões (`udev rule`).
- Se a validação falhar, emitir **erro descritivo** + comando de diagnóstico,
  e abortar com código de saída distinto (ex.: `_FATAL`), nunca `exit 0` mudo.

> **Reutilizar no `install.sh` (Linux):** após instalar o injetor/serviço, validar
> service ativo + porta + device com mensagens de diagnóstico acionáveis.

---

## 6. Robustez de subprocessos com timeout e captura de stderr

Chamadas a utilitários de sistema (WSL, `apk`, `systemctl`) devem:

- Ter **timeout** (evitar travar o instalador em hung de rede/serviço).
- **Capturar + logar stdout/stderr** em arquivo (WSL grava UTF-16; redirecionar
  para arquivo e ler com ferramenta em vez de pipe que corrompe).
- **Result code distinto** por falha (ex.: 200=TIMEOUT, 201=erro de processo,
  rc real do child), para o chamador diagnosticar.
- **Não engolir erro** com `>nul 2>&1` cego quando o sucesso importa (ex.:
  `--unregister` falho validado depois).

> **Reutilizar no `install.sh` (Linux):** `set -e` + traps + `timeout` nos comandos
> de rede/serviço; logar stderr; validar códigos de saída reais.

---

## 7. Binário do bridge: estático/musl e re-tentativa no device

- O bridge é **estático (musl)** no Linux → roda em glibc (Arch/CachyOS) e musl
  (Alpine) sem recompilação. Validado via `readelf` (sem dynamic interpreter).
- O bridge **re-tenta o `/dev/ttyUSB0` a cada 2s** → não precisa de *wait* pelo
  device no boot; **DTR+RTS** devem ser afirmados (Honeywell 1900 só transmite
  com ambas ativas) — ver `src/bridge.zig` (`TIOCMBIS`).
- O modo TCP **aceita múltiplas conexões** (cliente reconecta a cada 2s).

> **Reutilizar no `install.sh` (Linux):** manter o binário musl-estático já
> empacotado; reforçar DTR/RTS; garantir que o serviço re-tente o device sem
> depender de hotplug em tempo de boot.
