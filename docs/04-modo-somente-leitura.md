# 04 — Dispositivos somente leitura: diagnóstico e correção segura

`bigmount --diagnose DISPOSITIVO|PASTA` (texto) e `bigmount --gui` (diálogo)
respondem "por que não consigo gravar aqui?". A decisão está em
`bm_diagnose_write` (`usr/lib/big-mount/lib.sh`), nesta ordem:

| Caso | Evidência (estruturada sempre que possível) | Correção oferecida |
|---|---|---|
| ok | montado rw e `access(W_OK)` do usuário | — |
| E — protegido fisicamente | `/sys/block/*/ro = 1` (partição ou disco) | nenhuma (trava física) |
| G — sem suporte de escrita | tipo montado: iso9660, udf, squashfs, erofs, hfs/hfsplus, apfs, `ntfs` legado | nenhuma |
| D — NTFS inseguro | NTFS montado `ro`; motivo vindo do `/run/big-mount/status` ou do journal do ntfs-3g (pediu `rw`, montou `Read-Only`) | nenhuma: exige o Windows |
| C — erros no sistema de arquivos | `/sys/fs/ext4/*/errors_count`; mensagens do kernel (`Remounting filesystem read-only`, `forced readonly`, ...) | nenhuma; orienta copiar os dados e verificar desmontado |
| F — hardware | mensagens `I/O error` do kernel | nenhuma |
| A — montado `ro` sem problema conhecido | opção `ro`, nenhum dos anteriores | **Montar novamente com gravação**, só para montagens do UDisks, nunca para entradas do fstab e só com o journal legível |
| B — sem permissão (POSIX) | rw, raiz pertence a outro usuário | **Tornar-me proprietário da pasta principal** (UDisks `TakeOwnership`, `recursive=false`, Polkit) |
| B — partição com sistema operacional | `etc/os-release`, `*/etc/os-release` (subvolumes Btrfs), `@`, `Windows/System32`... | nenhuma |
| B — FAT/NTFS de outro usuário | `uid=` diferente | **Montar novamente para o meu usuário** (só montagens do UDisks) |

Regras invioláveis, cobertas por testes: nenhuma correção roda `fsck`,
`ntfsfix`, `chmod -R` ou `chown -R`; nada é remontado em `rw` quando há
indício de erro; toda correção pede confirmação, é verificada depois e, se
falhar, o usuário é informado de que nada foi alterado.

### Por que o `ioerr_cnt` não é usado como causa

O SSD USB saudável desta máquina tem `/sys/block/sdd/device/ioerr_cnt =
0xf`. Dispositivos UAS acumulam erros de comandos SCSI não suportados, então
o contador sozinho daria falsos alarmes de "disco com defeito".

### Caso encontrado na máquina de desenvolvimento

`/mnt/root` é o nível superior do Btrfs de outra instalação BigLinux
(`subvolid=5`, com `@`, `@home`, ...). A primeira versão da detecção de
"sistema operacional" só olhava `etc/os-release` na raiz e ofereceu trocar o
dono. Isso deixaria o usuário renomear `@` pelo Dolphin e impedir o boot
daquele sistema. A detecção agora olha também um nível abaixo, e há teste
para isso.
