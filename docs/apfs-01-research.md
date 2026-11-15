# APFS 01 — Research

What exists to read APFS on Linux, checked on 2026-11-15 against the source
code of each project (cloned and, for the first two, built), not against
their READMEs alone. The comparison and the choice are in
[apfs-03-driver-comparison.md](apfs-03-driver-comparison.md).

## sgan81/apfs-fuse — FUSE driver

- Last commit `66b86bd`, 2023-03-12. No release since; issues and pull
  requests stay open. Builds today only with the two patches of the AUR
  package `apfs-fuse-git` (`#include <cstdint>`, CMake minimum 3.5); it was
  built here with them, against fuse3 3.18 and kernel 6.18.
- Not in Arch, Manjaro or BigLinux repositories: AUR `apfs-fuse-git`
  (depends on fuse3, bzip2, zlib; lzfse is a git submodule).
- **Read-only by construction**: it adds `ro` to the mount options itself and
  implements no write operation (`ops` has getattr, lookup, open, read,
  readdir, readlink, xattrs, statfs only).
- Volumes: `-v N` or `-o vol=N`; snapshots: `-o snap=XID`; fusion drives:
  `-f DEVICE`; `uid=`/`gid=` override the owner of every file.
- **Encryption** (software encryption, FileVault on Macs without a T2 chip):
  supported. Every key-encryption key of the volume keybag is tried, so the
  password of any user of the Mac and the personal recovery key both work
  (`KeyMgmt.cpp`, loop over `KB_TAG_VOLUME_UNLOCK_RECORDS`).
- **Where the password comes from**: `-r PASS` or `-o pass=PASS`, both
  visible in `/proc/PID/cmdline`; otherwise it asks on standard input with
  echo turned off (`Util.cpp: GetPassword`, `tcgetattr` on stdin). Without a
  terminal that call fails and the volume is reported as a wrong password.
  Big-Mount never uses `-r` or `pass=`.
- Compression: zlib, LZVN, LZFSE and LZBITMAP (decmpfs types 3–14). An
  unknown method is a read error (EIO) unless `-l` is given, which returns
  possibly corrupt data; Big-Mount never gives `-l`.
- Shows the volume under `root/` and its private metadata under
  `private-dir/` (the file manager is pointed at `root/`).
- Exit codes seen here: 0 mounted (it then becomes a daemon), 22
  "Unable to load container.", 1 "Unable to get volume!" (also a wrong
  password), 5 the device cannot be opened.
- Includes `apfsutil DEVICE`: index, UUID, role, name, consumed space,
  `FileVault: Yes/No` and snapshots of every volume, read-only.

## linux-apfs/linux-apfs-rw — kernel module

- Maintained: last commit `4986b63`, 2026-11-10. Packaged in Arch **extra**
  as `linux-apfs-rw-dkms` 0.3.21 (DKMS: needs the headers of the running
  kernel, e.g. `linux618-headers` on BigLinux/Manjaro).
- **Read-only by default**: without the mount option `readwrite`, a
  read-write request is turned read-only (`super.c`: "experimental writes
  disabled to avoid data loss"). Snapshots are always read-only.
- Options `vol=N`, `snap=LABEL`, `tier2=DEVICE` (fusion), `uid=`, `gid=`,
  `cknodes`. Compression: zlib, LZVN, LZFSE, LZBITMAP.
- **Encryption is not implemented**, and worse for us: a volume with the
  encrypted flag is mounted anyway, with only the kernel warning "volume is
  encrypted, may not be read correctly" (`super.c`). Its files would be
  garbage. Big-Mount checks for that warning and unmounts
  ([apfs-05](apfs-05-encrypted-volumes.md)).
- Runs in the kernel: a bug triggered by a damaged container can oops the
  kernel instead of ending one process.

## linux-apfs/apfsprogs — tools of the kernel driver

- Maintained (last commit 2026-11-12), Arch **extra** `apfsprogs` 0.2.1.
- `apfs-label DEVICE`: the index and label of each volume, read-only. That is
  what Big-Mount uses to list volumes when apfs-fuse is not installed. It
  does not say which volume is encrypted, nor its role.
- `apfsck` (checker), `mkapfs` (creates a filesystem), `apfs-snap`: never run
  by Big-Mount. `mkapfs` is used by the tests, on scratch image files only.

## libyal/libfsapfs

- Maintained (last commit 2026-11-11), "experimental" status; not in the
  Arch repositories (AUR). Provides `fsapfsinfo` and `fsapfsmount` (FUSE).
- Encryption: password or recovery password given **as command-line
  options** (`-p`, `-r`): visible to every user through `ps`. Not suitable
  without a wrapper that hands the secret over another way.
- Kept as a forensic alternative (Big Storage Rescue could use it for
  extraction); not used by Big-Mount.

## UDisks2 and the desktop

- UDisks2 2.11 identifies the partition (`IdType=apfs`,
  `IdUsage=filesystem`) and has no default mount options for APFS. With the
  kernel module installed, Dolphin can mount it through UDisks — read-only,
  because the driver needs `readwrite` to write — but without `uid=`, so the
  folders a Mac keeps private (owner 501, mode 700, such as `Documents`)
  cannot be opened by the Linux user. Big-Mount maps the owner.
- Without a driver, Dolphin shows the partition and fails to mount it.

## Others looked at

- `hfsprogs`/`hfsplus`: HFS+, not APFS (older Macs; mounted by the kernel).
- `apfs-fuse` forks: none with a maintained history worth taking over.
- Apple's APFS reference (2020) documents the on-disk format; encryption on
  T2 and Apple-silicon Macs is tied to the hardware of that Mac: such a disk
  cannot be decrypted elsewhere by any tool, which is why no tool claims it.
