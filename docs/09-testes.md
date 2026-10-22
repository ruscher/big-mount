# 09 — Testes

| Suíte | O que usa | Resultado nesta máquina |
|---|---|---|
| `tests/run-tests.sh new` | stubs de `blkid`, `lsblk`, `udevadm`, `udisksctl`, `findmnt`, `mount`, `ntfsfix`; caminhos reescritos para um diretório temporário | **81 aprovados, 0 falhas** |
| `tests/run-tests.sh old` | o script original, como referência | 34/81 (as falhas são os bugs corrigidos) |
| `tests/lib-tests.sh` | biblioteca com fatos simulados por funções | **66 aprovados, 0 falhas** |
| `tests/integration.sh` | imagens descartáveis em loop devices montados pelo UDisks2, sem root | **60 aprovados, 0 falhas, 2 pulados** |
| `shellcheck -x` | código distribuído e testes | sem avisos |
| `bash -n`, `msgfmt --check`, `desktop-file-validate`, `xmllint`, `systemd-analyze verify` | — | ok |
| `tests/bench.sh` | ver `08-performance.md` | — |

Pulados na integração: ISO 9660/SquashFS (o kernel desta máquina não tem
esses módulos) e montagem dupla/aninhada (exige root; coberta por teste
unitário).

## Segurança dos testes

- Todos os stubs recusam rodar sem `TESTROOT`.
- `run-tests.sh` e `bench.sh` abortam se qualquer ferramenta de disco não
  resolver para o stub. Isso foi criado depois de um incidente nesta
  auditoria: num diretório `noexec`, o Bash ignorou o stub e executou o
  `ntfsfix`/`mount` reais como usuário comum. Os dois recusaram, sem efeito.
- O `findmnt` tem stub: antes os testes liam o `/etc/fstab` real.
- A integração só usa arquivos de imagem, recusa rodar como root e desfaz
  tudo no `trap EXIT`.

## Cobertura de cenários pedidos

Dispositivos: HD interno, HD/SSD USB com `RM=0` (cada sinal isolado), USB com
várias partições, NVMe interno, NVMe Thunderbolt, SD, eMMC, eSATA, nomes
parecidos (`sda1`/`sda10`), virtuais, contêineres, troca durante a varredura.

Sistemas de arquivos: NTFS saudável, hibernado (imagem real) e com fallback
silencioso, NTFS inconsistente, FAT32, exFAT, ext4 (com erros registrados),
Btrfs, XFS, F2FS, HFS+ (unitário), tipo desconhecido, somente leitura.

Estados: rw, ro limpo (com a remontagem testada de verdade), sem permissão,
partição com SO (Btrfs `@`, Windows), protegido contra gravação, ocupado
(shell com pasta atual, leitor, escritor, kioworker), desmontagem recusada e
depois concluída, sistema em uso, sessão sem interface gráfica, notificador
com e sem repetição.

Segurança: nenhum comando destrutivo no código distribuído (teste de
política); não encerra escritores, shells, processos da sessão ou de outros
usuários; PID reutilizado não é sinalizado; só SIGTERM; não desmonta a
partição errada; não informa sucesso em caso de falha; rótulos com `$()`,
crases, aspas, `..`, Unicode e HTML não executam nem injetam nada; diálogos
sem usuário nunca confirmam sozinhos.

## Validação manual pendente (exige hardware/sessão real)

1. Boot real com a versão nova: `systemd-analyze blame | grep big-mount` e
   `journalctl -b -u big-mount`.
2. HD/SSD USB conectado **durante o boot**: deve aparecer no Dolphin,
   montado pelo UDisks, e não em `/mnt`.
3. Dual boot com Inicialização Rápida ligada: notificação ao entrar na
   sessão; o Windows não deve mais rodar chkdsk a cada boot.
4. Dolphin: menu de contexto → Dispositivo de armazenamento → Remover com
   segurança, com a pasta do pendrive aberta no terminal do Dolphin.
5. Diálogos KDialog no tema Breeze claro/escuro, com escala 150%/200% e
   leitor de tela (Orca).
6. Power-off de HD USB real (a integração usa loop devices, que não
   desligam).
7. "Mostrar programas de todos os usuários" (pkexec, senha de
   administrador) e "Tornar-me proprietário" (Polkit `TakeOwnership`).
8. Edição GNOME (Zenity) e sessão X11.
9. Múltiplos usuários simultâneos: cada sessão vê só os próprios processos.
