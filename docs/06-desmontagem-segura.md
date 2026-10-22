# 06 — Desmontagem segura

`bigmount --unmount ALVO` (um sistema de arquivos), `--safe-remove ALVO`
(a unidade inteira e o desligamento) e o diálogo `--gui-remove`.

| Fase | O que acontece |
|---|---|
| A — diagnóstico | resolve o dispositivo e a unidade; **recusa** se ela contém o sistema em execução (`/`, `/home`, `/boot`, ... ou swap ativa) |
| B — tentativa normal | `udisksctl unmount` em cada montagem de cada partição (camadas empilhadas primeiro); o Polkit decide sobre senha |
| C — bloqueios | erro `org.freedesktop.UDisks2.Error.DeviceBusy` → lista os responsáveis; o usuário tenta de novo, atualiza ou fecha programas |
| D — sincronização | garantida pelo próprio unmount; o sucesso só é declarado quando o `findmnt` confirma que não resta montagem |
| E — power-off | `udisksctl power-off` só para unidades removíveis, depois de conferir que nada mais (LUKS, LVM, swap) usa a unidade; discos internos são só desmontados |

## Fechar programas

Oferecido apenas para processos que:

- pertencem ao próprio usuário;
- não fazem parte da sessão (plasmashell, kwin, dbus, pipewire, ...);
- não são shells (shells interativos ignoram SIGTERM; a orientação é `cd`);
- **não têm nenhum arquivo aberto para escrita** (encerrar no meio de uma
  cópia deixaria um arquivo incompleto).

Sempre com confirmação explícita, que avisa sobre alterações não salvas. O
sinal é só SIGTERM, nunca SIGKILL. Antes de sinalizar, o horário de início do
processo é comparado com o registrado no diagnóstico, para não atingir outro
processo que tenha herdado o PID. A espera é de até 5 segundos, e quem não
fechar é informado.

## O que não existe, por decisão

Nenhum caminho usa `umount -f`, `umount -l`, `kill -9`, `fuser -k` ou
`--force`. Um teste verifica isso no código distribuído. Não existe
desmontagem forçada sem risco de corrupção. Quando a remoção segura não é
possível, o dispositivo continua montado e o motivo é mostrado.

## Mensagens finais (só depois de verificadas)

| Situação | Mensagem |
|---|---|
| desmontado e desligado | "Dispositivo removido com segurança — Todas as operações necessárias foram concluídas. O dispositivo está pronto para ser desconectado." |
| desmontado, unidade sem power-off | "Desmontado... já pode ser desconectada" |
| disco interno | "Dispositivo desmontado" (sem sugerir desconectar) |
| ocupado / sem permissão / sistema | o motivo; nada é forçado |

Códigos de saída do CLI: 0 ok, 3 ocupado, 4 sistema em uso, 5 sem
autorização, 6 desmontado mas a unidade continua em uso, 7 desmontado sem
power-off.
