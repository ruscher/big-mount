# 10 — Segurança

## Corrigido

| Item | Antes | Agora |
|---|---|---|
| Rótulo `..`/`.` | montava sobre `/` ou `/mnt` | rejeitado; usa o nome do dispositivo |
| Caracteres de controle e rótulos longos | viravam nomes de diretório | `_`; acima de 200 bytes, nome do dispositivo |
| Rótulo com `$()`/crases | não executava, mas passava por `echo` | nunca passa por shell; teste dedicado |
| Escape de HTML | — | aspas na substituição (`patsub_replacement` do Bash 5.2 transformava `&lt;` em `<lt;`, bug pego por teste) |
| Saída no terminal | — | sequências de escape de rótulos/arquivos neutralizadas |
| Catálogos de tradução | — | `noexpand_translation`: um `.mo` não pode expandir código |
| Corrida na montagem | nenhuma proteção | `flock` + `diskseq` |
| Daemon FUSE no cgroup do serviço | morria com `systemctl stop` | `KillMode=process` |
| `ntfsfix` automático | toda montagem NTFS | removido |

## Fronteira de privilégio

- **root**: só o boot (`big-mount.service`) e o auxiliar
  `/usr/lib/big-mount/bigmount-holders`, que é somente leitura, aceita um
  argumento (ponto de montagem exato de dispositivo local), roda via
  `pkexec` com ambiente limpo e tem ação Polkit própria
  (`org.biglinux.big-mount.inspect-processes`, `auth_admin_keep`).
- **usuário**: diagnóstico, diálogos, notificações. Desmontar, montar,
  desligar e trocar dono passam pelo UDisks2, então quem decide é a política
  Polkit do próprio UDisks. O Big-Mount não amplia nenhuma permissão.
- Como usuário, o `lsof` só enxerga os processos do próprio usuário. Os de
  outros usuários só aparecem com autenticação de administrador.
- O processo raiz nunca lê nada da sessão. A sessão lê
  `/run/big-mount/status` (root, 0644) apenas como dados.

## Permissões de FAT/NTFS internos

Por padrão continua `umask=000` + `exec`: qualquer conta local lê, grava e
executa. Não permite *setuid* (modo base `0777 & ~umask`). Mudar o padrão
quebraria o compartilhamento entre contas e serviços (Samba, servidores de
mídia) de quem depende disso hoje, e o projeto põe compatibilidade acima de
segurança. Para quem precisa restringir, existe `PERMISSIONS=owner` ou
`private` em `/etc/big-mount.conf` (ver `03-sistemas-arquivos.md`). O
arquivo é analisado como dados; um teste prova que um valor `$(...)` não é
executado.
