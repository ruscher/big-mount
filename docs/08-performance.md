# 08 — Desempenho do boot

Medição reproduzível: `tests/bench.sh SCRIPT N`. Roda o script contra os
dispositivos **reais** desta máquina (`blkid`, `lsblk`, `udevadm`/`udisksctl`,
`findmnt` e sysfs reais), com `mount`/`ntfsfix` substituídos por stubs,
`/proc/mounts` vazio (situação de boot) e uma trava que aborta se os stubs não
forem os executados. Sem root.

Máquina: 16 CPUs, 9 entradas no `blkid` (NVMe, 3 SATA, 1 SSD USB, zram).
Ambas as versões decidem as mesmas 3 montagens.

| Métrica (mediana de 20–30 execuções) | Antes (`master`) | Depois |
|---|---|---|
| Tempo de parede | 126,6–133,6 ms | 36,7–40,5 ms |
| CPU (usuário + sistema) | 129–136 ms | 38–42 ms |
| Processos criados | 194 | 27 |
| Chamadas a `ntfsfix` | 1 | 0 |
| Clientes D-Bus (`udisksctl`) | 10 | 0 |

De onde veio o ganho:

- um `blkid`, um `lsblk -P` e um `udevadm info` com todos os candidatos, em
  vez de `lsblk`, `head`, `cat` e dois `udisksctl` por partição;
- parsing com expressões regulares e arrays do Bash, sem `echo | sed/grep`;
- funções que devolvem resultado em `REPLY` (sem um subshell por chamada);
- filtros baratos (tipo, virtual, já montado) antes do `findmnt --fstab`, que
  continua uma chamada por candidato para manter exatamente a mesma
  semântica de correspondência do fstab.

No boot o ganho tende a ser maior que o medido, porque a primeira chamada a
`udisksctl` ativava o `udisksd` via D-Bus. O último boot desta máquina, ainda
com a versão antiga, registrou `big-mount.service` em **1,019 s**
(`systemd-analyze blame`). **Ainda não medi um boot com a versão nova**: isso
exige instalar o pacote e reiniciar.

Pico de memória do serviço antigo no boot: 20,6 MB, segundo `systemctl
status`. A maior parte vem do daemon FUSE do NTFS, que continua igual.

O diagnóstico (`lsof`, `journalctl`) só roda quando pedido ou quando uma
montagem não é gravável. O boot não executa nada disso.
