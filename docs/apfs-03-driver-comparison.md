# APFS 03 — Drivers compared, and the choice

| | apfs-fuse | linux-apfs-rw (kernel) | libfsapfs (fsapfsmount) |
| --- | --- | --- | --- |
| Package | AUR `apfs-fuse-git` | Arch extra `linux-apfs-rw-dkms` + `apfsprogs` | AUR |
| Maintenance | none since 2023-03 | active (2026-11) | active (2026-11), "experimental" |
| Writes | impossible (no write code, forces `ro`) | only with `readwrite` | none |
| Encrypted volumes | **yes** (user password or recovery key, typed on the terminal) | **no**, and mounts them anyway as garbage | yes, but the password goes on the command line |
| Compression | zlib, LZVN, LZFSE, LZBITMAP | zlib, LZVN, LZFSE, LZBITMAP | zlib, LZVN, LZFSE |
| Volume list | `apfsutil` (roles, encryption) | `apfs-label` (names) | `fsapfsinfo` |
| Snapshots / fusion | `snap=` / `-f` | `snap=` / `tier2=` | partial |
| A damaged container | ends one process | can oops the kernel | ends one process |
| Process to manage | a FUSE daemon per mount | none | a FUSE daemon |
| Speed | FUSE: slower on many small files | native | FUSE |
| Build | needs two patches; DKMS not needed | DKMS per kernel update (headers) | autotools |

## Choice

Both supported, behind one interface, in this order (`APFS_DRIVER=auto`):

1. **apfs-fuse** first: it cannot write by construction, a damaged container
   cannot take the kernel down, and it is the only one that opens FileVault
   volumes safely. Its age is the cost: it is used read-only, never with
   `-l`, and the kernel driver is tried when it cannot read a container.
2. **linux-apfs-rw** next (or alone, `APFS_DRIVER=kernel`): maintained, in
   the official repository, faster; always with `ro`, never `readwrite`,
   never for a volume known to be encrypted, and unmounted at once when the
   kernel says the volume was encrypted after all.

Neither is a dependency of Big-Mount (optdepends): the boot needs none,
and a missing driver is explained, with the package to install, instead of
failing. Nothing is installed, built or loaded by Big-Mount without being
asked: the kernel module is loaded only when an APFS volume is opened with
it. libfsapfs is left out: its password handling would expose the secret,
and it adds nothing the other two lack for reading files.

What a driver cannot do is reported as such: an encrypted volume with only
the kernel driver, a T2/Apple-silicon hardware-encrypted disk (no tool can),
an unknown compression (a read error, never wrong content).
