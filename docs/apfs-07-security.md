# APFS 07 — Security and integrity of the data

## Nothing is written to the APFS partition

- apfs-fuse has no write code and forces `ro`; Big-Mount also gives `ro`.
- The kernel driver writes only with `readwrite`, which appears nowhere in
  the code; `ro` is given anyway, and a mount that comes out without `ro` in
  `/proc/mounts` is unmounted at once.
- No repair, check, format, erase or trim tool is run: `apfsck`, `mkapfs`,
  `fsck`, `mkfs`, `wipefs`, `dd`, `blkdiscard`, `fstrim`, `sgdisk`, `parted`,
  `fdisk`, `hdparm` — a test fails if one appears in `apfs.sh`.
- `-l` of apfs-fuse (possibly corrupt data) is never given.
- The partition table, the identifiers and the encryption are never touched.
- A read error stops the attempt and points to Big Storage Rescue, which
  makes an image of a failing disk before anything else. Tested with the
  real driver: the image is byte for byte the same after open and close.

## Root

- The user side runs as the user; only `bigmount --apfs-helper` runs as root
  (through sudo), with three commands and fixed argument counts. Device
  paths are resolved (`readlink -f`), must be block devices named
  `/dev/[A-Za-z0-9._-]+`, must carry the APFS signature (`blkid -p`); volume
  numbers are 0–99. The person is `SUDO_UID`/`PKEXEC_UID`, never an argument.
- The configuration is read as data, never sourced.
- The helper unmounts only APFS mounts, and only under `/run/media/*/` or
  `/mnt/` (what Big-Mount makes); others are refused.
- Mount points: never through a symlink; `/run/media/<user>` made root-owned
  with an ACL for that user only; mount options `nosuid,nodev`.
- No `chmod -R`, `chown -R`, `kill`, `umount -l/-f`: tested.
- The file manager is never started as root (tested: `xdg-open` runs with
  the user's id).

## Passwords

See apfs-05: typed into apfs-fuse on the terminal, never in argv, the
environment, a file or a log. Tested.

## Removable devices

The boot run never mounts an external disk, APFS or not (tested with an APFS
SSD on USB and `APFS=readonly`). `--open-apfs` is an explicit request of the
person for one partition.

## Boot

APFS is off by default at boot. With `APFS=readonly`, no prompt, encrypted
volumes skipped, timeouts on every read, and a missing driver is one journal
line. The boot run with or without this change: same time and the same
number of processes (`tests/bench.sh`, 30 runs, median 77.2 vs 77.3 ms, 30
processes).
