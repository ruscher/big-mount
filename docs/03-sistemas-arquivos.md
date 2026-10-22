# 03 — Sistemas de arquivos e opções de montagem

As opções de montagem do boot **não mudaram**:

| Tipo | Opções |
|---|---|
| NTFS | `-t lowntfs-3g -o uid,gid,rw,noatime,exec,umask=000,nodev,nofail,x-gvfs-show` |
| FAT/exFAT (`TYPE` contendo `fat`) | `uid,gid,noatime,rw,umask=000,nodev,nofail,x-gvfs-show` |
| demais (ext4, Btrfs, XFS, F2FS...) | `noatime,rw,nodev,nofail,x-gvfs-show` |

O que mudou:

- **Escolha do tipo**: compara só o valor de `TYPE`. Antes, uma ext4 com
  `PARTLABEL` contendo "fat" recebia opções de FAT e não montava (A6).
- **NTFS sem `ntfsfix`** (A3). O `ntfsfix` liga o *dirty bit* em todo boot
  (demonstrado com imagem: "Volume is scheduled for check"). O ntfs-3g já
  recupera o journal sozinho (opção padrão `recover`).
- **NTFS inseguro** (hibernado, Inicialização Rápida, desligamento
  incompleto): o ntfs-3g atual monta somente leitura em silêncio. O bigmount
  lê o estado real em `/proc/mounts` e registra `ro ntfs-readonly`. Versões
  que recusam (códigos 13/14/15) são tentadas de novo com `ro`. A opção
  `remove_hiberfile` nunca é usada, porque apagaria a sessão do Windows.
- **Falha de montagem**: o diretório criado é removido; um diretório que já
  existia fica como estava.

## Comportamento observado por tipo (testes com imagens reais via UDisks2)

| Tipo | Resultado |
|---|---|
| ext4 do usuário | gravável |
| ext4 com raiz `root:root` | rw, mas sem permissão: caso B |
| ext4 com `error_count=3` | gravável com aviso; se montada `ro`: caso C |
| NTFS saudável | gravável (ntfs-3g) |
| NTFS hibernado | ntfs-3g monta `ro` sozinho: caso D; a imagem continua hibernada (nada é gravado) |
| FAT32, exFAT | graváveis |
| ISO 9660 / SquashFS | não testado: este kernel não tem esses módulos |
| HFS+ | não testado: kernel sem `hfsplus`; coberto por teste unitário |

## Fora do escopo desta mudança

Trocar `lowntfs-3g` pelo `ntfs3` do kernel e mudar `umask=000` (ver
`10-seguranca.md`) são decisões de política que pedem validação com usuários.
