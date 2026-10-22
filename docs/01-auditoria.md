# 01 — Auditoria do Big-Mount

Auditoria do estado em `master` (commit `871f392`), feita antes de qualquer
alteração. Todo item marcado como **confirmado** foi reproduzido com um teste
ou observado nesta máquina de desenvolvimento (BigLinux, Plasma 6.7.4, kernel
7.2.11, udisks2 2.11.2, ntfs-3g 2026.7.7, util-linux 2.42.3).

## Como o Big-Mount funciona hoje

1. `big-mount.service` (`Type=oneshot`, `After=local-fs.target`) executa
   `/usr/bin/bigmount` como root a cada boot.
2. O script cria os links de compatibilidade `/media → /mnt` e
   `/mnt/user-mount → /run/media`.
3. Detecta o "último usuário" pelo SDDM/LightDM (ou o primeiro UID ≥ 1000)
   para usar o UID/GID dele nas opções de montagem de FAT/NTFS.
4. Percorre a saída do `blkid`, descarta `swap` e `squashfs` e, para cada
   partição:
   - pula se houver entrada no `/etc/fstab` (`findmnt --fstab --source`);
   - descobre o disco pai (`lsblk -no PKNAME`);
   - escolhe `/mnt/<LABEL>` (ou `PARTLABEL`, ou o nome do dispositivo), com
     sufixo numérico em caso de colisão;
   - considera "removível" se `/sys/block/<pai>/removable = 1`, se o
     `udisksctl info` do pai contiver `-usb-`, se o UDisks marcar
     `HintIgnore` ou se a partição já estiver montada;
   - para partições não removíveis: `mkdir`, `ntfsfix` (só NTFS) e `mount`
     com opções por tipo; cria o link reverso `/mnt/<dispositivo>`.

## O que está correto e deve ser preservado

| Item | Avaliação |
|---|---|
| Enumeração com `blkid` | Correta. Como root, o `blkid` sonda o dispositivo e não depende do banco do udev. Mantida. |
| Pular partições do `/etc/fstab` (mesmo `noauto`) | Correto e essencial: configuração explícita sempre vence. Mantido com a mesma chamada. |
| `lsblk PKNAME` para achar o disco pai | Correto para `sdX`, `nvmeXnYpZ` e `mmcblkXpY`. Mantido (agora numa única chamada). |
| `HintIgnore` do UDisks | **Importante**: esconde ESP, MSR e partições de recuperação do Windows. Na máquina, `sdb1`, `sdb2`, `sdc1` e `nvme0n1p1` têm `HintIgnore=true`. O UDisks lê isso da propriedade `UDISKS_IGNORE` do udev; a equivalência foi verificada dispositivo a dispositivo. |
| Pontos de montagem por rótulo + link reverso | Comportamento consolidado (commits `055d33d`, `498366d`). Mantido. |
| `lowntfs-3g` para NTFS | Driver estável e com suporte a nomes sem diferenciação de maiúsculas. Mantido. |
| `uid`/`gid`/`umask=000` em FAT/NTFS | Permissivo, mas é o que garante o compartilhamento entre usuários hoje. Mantido (ver A15). |
| `Type=oneshot` + `RemainAfterExit` | Adequado: nenhum processo residente. Mantido. |
| `/etc/bigmountall-no` | Mecanismo de desativação existente. Mantido. |

## Problemas encontrados

Severidade: **Crítica** (pode danificar o sistema ou dados), **Alta**
(perda de acesso ou alteração de dados sem consentimento), **Média**
(comportamento incorreto), **Baixa** (qualidade/eficiência).

### A1 — Rótulo `.` ou `..` monta sobre `/mnt` ou sobre `/` — Crítica, confirmado

O rótulo do volume vira um componente de caminho sem validação além de trocar
espaço e `/` por `_`. Uma partição interna com `LABEL=".."` resulta em
`mount /dev/sda1 /mnt/..`, ou seja, **montagem sobre a raiz do sistema**;
`LABEL="."` esconde todo o `/mnt`. Reproduzido no harness:

```
[LABEL=".."] mount -o noatime,rw,nodev,nofail,x-gvfs-show /dev/sda1 <ROOT>/mnt/..
```

Rótulos vêm de dispositivos externos e não são confiáveis (um disco USB pode
ser classificado como interno no boot, ver A5).

### A2 — Parar ou reiniciar o serviço derruba os volumes NTFS — Crítica, confirmado

O daemon FUSE `mount.lowntfs-3g` é filho do script e fica no cgroup do
serviço. Com o `KillMode=control-group` padrão, um `systemctl stop` ou
`restart big-mount` mata o daemon e o volume fica em estado
`Transport endpoint is not connected` com arquivos possivelmente abertos.
Observado nesta máquina:

```
CGroup: /system.slice/big-mount.service
        └─1599 /usr/bin/mount.lowntfs-3g /dev/sdb3 /mnt/Basic_data_partition -o rw,...
KillMode=control-group
```

Para comparação, o NTFS montado via fstab vive no cgroup da própria unidade
`.mount`, que o systemd desmonta na ordem correta.

### A3 — `ntfsfix` executado em toda montagem NTFS — Alta, confirmado

`ntfsfix` é uma ferramenta de reparo: segundo o manual, ela "reseta o
journal do NTFS e agenda uma verificação de consistência". Sem `-d`, liga o
*dirty bit*. Teste com imagem descartável:

```
$ mkntfs ... a.img              # volume saudável, Volume Flags: 0x0000
$ ntfsfix b.img                 # cópia de a.img; o que o bigmount faz a cada boot
$ ntfsinfo -m b.img
Volume is scheduled for check.
Please boot into Windows TWICE, or use the 'force' option.
```

O bit continua ligado depois de montar e desmontar com ntfs-3g. Efeitos:

- Em dual boot, o Windows roda verificação de disco a cada inicialização.
- Drivers que respeitam o *dirty bit* (o `ntfs3` do kernel) recusam escrita:
  é uma causa plausível de "HD aparece somente leitura" quando o disco é
  levado para outra máquina.
- O próprio ntfs-3g já faz a recuperação do journal sozinho (opção padrão
  `recover`), então o `ntfsfix` não acrescenta nada à montagem normal.

Reparos não podem ser automáticos. **Recomendação:** remover a chamada.

### A4 — NTFS hibernado / Inicialização Rápida não é montado e ninguém avisa — Alta

O bigmount passa `rw` explicitamente. Com `rw`, o ntfs-3g **recusa** volumes
hibernados (código de saída 14, documentado em `ntfs-3g.probe(8)`) em vez de
cair para somente leitura. Resultado: a partição do Windows some, um
diretório vazio fica em `/mnt` e não há nenhuma mensagem para o usuário.
**Recomendação:** nesses códigos (13, 14, 15), tentar de novo em `ro` (leitura
não altera o volume), registrar o motivo e avisar o usuário.

### A5 — Detecção de USB depende do UDisks estar pronto no boot — Alta

A única verificação de transporte USB é `udisksctl info | grep -- -usb-`, que
precisa (a) ativar o `udisksd` via D-Bus durante o boot e (b) que o udev já
tenha processado o dispositivo. Nada garante isso em `After=local-fs.target`.
Se alguma das duas falhar, sobra só `/sys/block/X/removable`, e **HDs/SSDs
USB comuns informam `RM=0`**. Esta máquina tem exatamente esse caso:

```
NAME TYPE TRAN RM HOTPLUG  MODEL
sdd  disk usb   0       1  Portable SSD   (SanDisk, UAS)
```

O kernel já informa `TRAN=usb` e `HOTPLUG=1` pelo sysfs, sem depender de udev
nem de D-Bus, e o script não usa nenhum dos dois. Consequência de um falso
"interno": o disco externo é montado como root em `/mnt`, recebe `ntfsfix`
(A3), e o Dolphin não consegue desmontá-lo sem senha de administrador.

### A6 — Regex de FAT atravessa campos — Média, confirmado

`grep -q 'TYPE=".*fat.*"'` é aplicado à linha inteira; `.*` atravessa aspas.
Uma partição ext4 com `PARTLABEL` contendo `fat` recebe opções de FAT, que o
ext4 rejeita, e nunca é montada:

```
[ext4 com PARTLABEL=backup-fat32-old]
mount -o uid=1000,gid=1007,noatime,rw,umask=000,... /dev/sda1 .../mnt/Dados
```

### A7 — Links reversos obsoletos apontam para o disco errado — Média, confirmado

Se a ordem dos discos muda entre boots, `/mnt/sdb1 → /mnt/Data` continua
apontando para a montagem de outro dispositivo, porque o link só é criado
quando `/mnt/<dispositivo>` não existe (`-e` segue o link, e o destino
existe).

### A8 — Tipos não montáveis deixam diretórios vazios em `/mnt` — Média

`crypto_LUKS`, `LVM2_member`, `*_raid_member`, `BitLocker`, `zfs_member` e
partições sem `TYPE` (por exemplo a MSR quando o `blkid` só mostra
`PARTLABEL`) passam pelo filtro, ganham um `mkdir` e uma tentativa de
`mount` que falha. O diretório criado nunca é removido.

### A9 — Dispositivos virtuais tratados como discos — Média

- `/dev/mapper/*`: o caminho é reconstruído como `/dev/<basename>`
  (`/dev/luks-xxx`), que não existe; a montagem sempre falhou.
- `loop*`, `zram*`, `ram*`: são configurados explicitamente por quem os usa
  e não deveriam ser montados automaticamente.

### A10 — Falhas silenciosas — Média

Não há log, código de saída significativo nem estado consultável. Uma
montagem que falha (A4, A6, A8) só aparece como diretório vazio.

### A11 — Testes não são isolados do sistema real — Média, confirmado

- `findmnt` não tem stub: os testes leem o `/etc/fstab` real. Nesta máquina,
  `nvme0n1p1` está no fstab, então `nvme-removable-detection` **passa pelo
  motivo errado** (a partição é pulada pelo fstab, não pela detecção).
- Não há trava que garanta que `mount`/`ntfsfix` resolvam para os stubs. Num
  diretório montado com `noexec`, o Bash ignora o stub e executa o binário
  real. Isso aconteceu durante esta auditoria, no primeiro benchmark em
  `/tmp`: o `ntfsfix` e o `mount` reais foram chamados como usuário comum
  contra `/dev/sdb3`, e os dois recusaram (o usuário não pertence ao grupo
  `disk`; o `ntfsfix` parou em "Refusing to operate on read-write mounted
  device"). Nada foi alterado, mas o risco é real para quem roda os testes
  como root.

### A12 — Sem proteção contra execução concorrente — Baixa

Duas instâncias (serviço + execução manual) podem escolher o mesmo ponto de
montagem ao mesmo tempo.

### A13 — Sem verificação de identidade entre detecção e montagem — Baixa

Se um dispositivo for trocado durante a varredura e o novo receber o mesmo
nome (`sdd`), a decisão tomada para o anterior seria aplicada ao novo. O
kernel expõe `/sys/block/X/diskseq`, que muda a cada novo dispositivo.

### A14 — Desempenho — Baixa

Cada partição gera cerca de 20 processos: `findmnt`, `lsblk`, `head`, dois
`udisksctl` (clientes D-Bus), `cat`, e vários `echo | sed/grep/tr`. Medido com
`tests/bench.sh` (dispositivos reais, `mount` simulado, 20 execuções, 9
partições):

| Métrica | Valor |
|---|---|
| Tempo de parede (mediana) | 133,6 ms |
| CPU (mediana) | 136 ms |
| Processos criados (mínimo) | 194 |
| `big-mount.service` no último boot real (`systemd-analyze blame`) | 1,019 s |

A diferença entre 134 ms e 1 s no boot vem principalmente da ativação do
`udisksd` pela primeira chamada a `udisksctl` e da disputa de CPU no boot.

### A15 — `umask=000` e `exec` em FAT/NTFS — Baixa (risco documentado)

Qualquer conta local lê, grava e executa qualquer arquivo dessas partições.
Não foi alterado: o comportamento é antigo, usuários podem depender dele
(várias contas, Samba, servidores de mídia) e não permite *setuid*, porque o
modo base é `0777 & ~umask`. Fica registrado para uma decisão futura dos
mantenedores (ver `10-seguranca.md`).

### A16 — Raiz de ext4/Btrfs/XFS pertencente a root — Informativo

Um sistema de arquivos POSIX criado como root tem a raiz `root:root 0755`.
Montado com `rw`, ele **parece** somente leitura para o usuário. Não é bug do
bigmount, mas é uma causa frequente do relato "não consigo gravar no HD", e
hoje não há nenhum diagnóstico para isso.

### A17 — Montagem obsoleta do os-prober — Observação de ambiente

Nesta máquina, `sda1` está montado duas vezes: em `/mnt/Dados` e em
`/var/lib/os-prober/mount` (sobra de um `grub-mkconfig` interrompido). Uma
montagem extra como essa impede o desligamento do disco mesmo depois que o
usuário desmonta o ponto que ele conhece. Isso não aparece em nenhum
`lsof`, então o diagnóstico de "dispositivo ocupado" precisa listar **todas**
as montagens do dispositivo, não só processos.

### A18 — Integração com o Plasma — Observação

O applet "Discos e dispositivos" do Plasma 6 já roda `lsof` como usuário
quando a desmontagem falha (`queryBlockingApps`, verificado nas strings de
`org.kde.plasma.devicenotifier.so`) e mostra o nome do aplicativo quando o
encontra. A mensagem genérica "um ou mais arquivos estão abertos" aparece
justamente quando o `lsof` do usuário **não enxerga** o responsável: processo
de root/outro usuário, montagem extra (A17), swap, loop ou montagem aninhada.
O Plasma não expõe um ponto de extensão suportado para acrescentar ações a
essa notificação.

### A19 — Análise estática

`shellcheck` no script principal: sem avisos. Nos testes: SC2317 (funções
chamadas indiretamente) e SC2015 (`A && B || C`) — informativos.

## Recomendações e decisões

| Item | Decisão |
|---|---|
| A1 | Rejeitar `.`/`..`, remover caracteres de controle, limitar tamanho; usar o nome do dispositivo como alternativa. |
| A2 | `KillMode=process` no serviço: o systemd deixa de matar os daemons FUSE ao parar a unidade; o desligamento continua desmontando normalmente. |
| A3 | Remover o `ntfsfix` automático. A orientação de reparo vai para o diagnóstico. |
| A4 | Reexecutar em `ro` nos códigos 13/14/15 do ntfs-3g, registrar e notificar. |
| A5 | Decisão por várias fontes independentes: sysfs (`removable`, `TRAN`, `HOTPLUG`, tipo MMC), udev (`ID_BUS`, `ID_PATH`, `ID_DRIVE_FLASH_SD`, `UDISKS_SYSTEM`, `UDISKS_IGNORE`). Se o udev ainda não processou o dispositivo, esperar uma única vez (`udevadm settle`) e, se persistir, **não** montar. |
| A6 | Comparar só o valor de `TYPE`. |
| A7 | Substituir o link reverso quando for um link apontando para outro lugar. |
| A8, A9 | Pular tipos que não são sistemas de arquivos e dispositivos virtuais; remover o diretório criado quando a montagem falha. |
| A10 | Log no journal com prioridade, arquivo de estado em `/run/big-mount/status`, notificações na sessão do usuário. |
| A11 | Stub de `findmnt` com fstab falso e trava que aborta se `mount`/`ntfsfix` não forem os stubs. |
| A12 | `flock` em `/run/lock/big-mount.lock`. |
| A13 | Comparar o `diskseq` capturado antes da varredura com o valor no momento da montagem. |
| A14 | Uma chamada de `blkid`, `lsblk` e `udevadm` para tudo; parsing com builtins do Bash. |
| A16–A18 | Diagnóstico de somente leitura, de dispositivo ocupado e desmontagem segura (documentos 04–07). |
