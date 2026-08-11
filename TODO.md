# TODO — XeMonitor

Plano de trabalho da sessão atual. Atualizado conforme o progresso.

## Infra / Git (concluído)
- [x] Tarefa agendada `init Docker WSL` ajustada (Boot + Logon) para iniciar WSL/Arch e garantir Docker via systemd
- [x] Docker ativo no WSL (v29.4.3, `systemctl enable docker`)
- [x] Excluir `ORIENTACAO.md` (obsoleto, conteúdo fundido no README/AGENTS)
- [x] Instalar `gh` (GitHub CLI 2.97.0) e autenticar como `isaacangello`
- [x] Chave SSH `ed25519` gerada com `isaacangello@inf.ufpel.edu.br` e adicionada ao GitHub
- [x] Remote `origin` trocado para SSH `git@github.com:isaacangello/XeMonitor.git`
- [x] `user.name`/`user.email` configurados no repositório

## Documentação
- [x] Criar `TODO.md` (este arquivo)
- [x] Criar `AGENTS.md`
- [x] Atualizar `.checkpoint.md` com o estado real
- [x] Atualizar `CHANGELOG.md`

## Bridge
- [x] Corrigir modo TCP do `src/bridge.zig` para aceitar múltiplas conexões (thread leitora serial → `SharedState`, loop `accept`, thread escritora por cliente)
- [x] Adicionar testes (`readSince`/`currentSeq`) e corrigir teste pré-existente
- [x] `zig build test-bridge` compilando + 13 testes passando (executados no WSL)

## Automação do bridge (systemd no WSL)
- [x] Criar `systemd/xemonitor-bridge.service` (ExecStartPre aguarda `/dev/ttyUSB0`, Restart=always)
- [x] Criar `scripts/install_bridge_service.sh` (copia binário para `/usr/local/bin/xemonitor-bridge`, instala/habilita, `--reinstall`)
- [x] Serviço instalado e habilitado no WSL (`systemctl is-enabled` = enabled)
- [x] Validado: TCP multi-conexão + reconexão após desconexão (2 clients simultâneos)
- [x] Atualizar `run_bridge.bat` para usar `wsl systemctl start xemonitor-bridge`
- [x] Atualizar `stop_bridge.bat` (stop serviço + taskkill)
- [x] Criar `status_bridge.bat`
- [x] Robustecer `setup_usb.bat` com fallback do caminho do usbipd

## Autostart no Windows
- [x] Criar `scripts/install_autostart.bat` (3 tarefas: USB attach, bridge, xemonitor) — **instaladas**
- [x] Criar `scripts/uninstall_autostart.bat`

## Validação final
- [x] `zig build` e `zig build test` sem erros
- [ ] Commit das mudanças
- [ ] `git push -u origin main`

## Pendências históricas (bridge)
- [ ] Testar leitura real escaneando um código de barras (Honeywell 1900)
