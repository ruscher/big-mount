# 02 — Identificação de dispositivos internos e externos

## Problema

O boot só deve montar partições de discos **internos**. Até aqui, a única
prova de "externo" além de `/sys/block/X/removable` era o texto `-usb-` na
saída do `udisksctl`. Muitos HDs e SSDs USB informam `RM=0`, e o `udisksctl`
depende de o `udisksd` estar ativo e de o udev já ter processado o disco,
coisa que não é garantida em `After=local-fs.target` (auditoria A5).

Caso real desta máquina:

```
$ lsblk -dn -o NAME,TYPE,TRAN,RM,HOTPLUG /dev/sdd
sdd  disk usb   0       1          # SanDisk Portable SSD (UAS)
$ udevadm info -q property -n /dev/sdd | grep -E 'ID_BUS|ID_PATH='
ID_BUS=usb
ID_PATH=pci-0000:04:00.0-usb-0:2:1.0-scsi-0:0:0:0
```

## Decisão

Um dispositivo é deixado para o UDisks/Plasma quando **qualquer** destes fatos
independentes vale para ele ou para o seu disco:

| Fonte | Fato | Cobre |
|---|---|---|
| sysfs | `removable = 1` | pendrives, leitores de cartão |
| sysfs (`lsblk TRAN`) | `usb`, `ieee1394`, `sbp` | HD/SSD USB com `RM=0`, docks, FireWire |
| sysfs (`lsblk HOTPLUG`) | porta marcada removível pelo kernel | USB, NVMe em Thunderbolt/USB4 |
| sysfs | `device/type = SD` | cartões SD em leitor interno (MMC); `MMC` = eMMC soldado = interno |
| udev | `ID_BUS=usb/ieee1394`, `ID_PATH` com `-usb-` | mesma informação vista pelo udev |
| udev | `ID_DRIVE_FLASH_SD`, `ID_DRIVE_MEDIA_FLASH_SD` | cartões SD |
| udev | `UDISKS_SYSTEM=0` | regra do administrador (baias eSATA) |

E é **ignorado** quando `UDISKS_IGNORE=1`. É a mesma propriedade que o UDisks
expõe como `HintIgnore` (ESP, MSR, recuperação do Windows). A equivalência
foi conferida dispositivo a dispositivo nesta máquina.

Os sinais do kernel não dependem nem do udev nem do D-Bus. Os do udev entram
como confirmação. Por isso nenhuma propriedade isolada, ausente ou errada,
faz um disco externo ser tratado como interno.

### udev ainda não processou o dispositivo

Se faltar `USEC_INITIALIZED` para um candidato, o bigmount espera **uma vez**
(`udevadm settle --timeout=10`). Se ainda assim faltar, o dispositivo **não é
montado** e um aviso vai para o journal. O custo só existe quando o caso
acontece.

### Outros tipos

| Caso | Comportamento |
|---|---|
| Partição no `/etc/fstab` (inclusive `noauto`) | nunca tocada (igual a antes) |
| `loop`, `zram`, `ram`, `/dev/mapper`, `dm-*` | ignorados; antes o mapper falhava sempre, por caminho errado |
| LUKS, LVM, membros de RAID/ZFS, BitLocker, sem `TYPE` | ignorados, sem `mkdir` |
| md RAID | o disco considerado é o primeiro membro (topo da cadeia `PKNAME`) |
| Troca de dispositivo durante a varredura | `diskseq` diferente: não monta |

## Validação

- `bigmount --dry-run` nesta máquina, com `/proc/mounts` vazio, decide as
  mesmas três montagens que estão ativas hoje (`/mnt/Dados`, `/mnt/root`,
  `/mnt/Basic_data_partition`) e reconhece `sdd1` como externo por
  `transport=usb hotplug ID_BUS=usb ID_PATH=usb`.
- 17 cenários em `tests/run-tests.sh`: USB com `RM=0` (por cada sinal
  isolado), USB com várias partições, Thunderbolt, NVMe interno, SD, eMMC,
  eSATA, udev atrasado, udev ausente, virtuais, contêineres, fstab, troca
  de dispositivo.

## Pendente de validação com hardware

eSATA real, NVMe em gabinete Thunderbolt, leitor SD interno de notebook.
