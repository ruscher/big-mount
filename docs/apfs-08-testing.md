# APFS 08 — Tests

```bash
bash tests/apfs-tests.sh              # APFS: stubbed devices and drivers
bash tests/run-tests.sh new           # boot run, including APFS at boot
bash tests/i18n-tests.sh              # translations
bash tests/package-check.sh           # package
# also the real driver on a scratch image (optional):
APFS_FUSE_BUILD=/path/to/apfs-fuse/build MKAPFS=/path/to/apfsprogs/mkapfs/mkapfs \
    bash tests/apfs-tests.sh
```

`tests/apfs-tests.sh` copies `bigmount`, `cli.sh` and `apfs.sh` into a scratch
tree with the system paths moved there; PATH holds only basic tools and the
stubs of `tests/stubs-apfs` (lsblk, blkid, apfsutil, apfs-label, apfs-fuse,
mount, umount, dmesg, modinfo, modprobe, sudo, setfacl, xdg-open, setsid):
no disk of the machine is read or mounted. Run on 2026-11-15: 106 passed,
0 failed, 0 skipped (with the real driver).

| Area | Cases |
| --- | --- |
| identification | APFS with `Basic data partition` and the APFS GUID; Microsoft basic data GUID with an APFS signature (opened, table left alone); NTFS with Microsoft basic data (refused, named); udev says APFS but no signature; signature with an unreadable container; device not connected; not a /dev path; no APFS partition; a whole disk (and a disk with a similar name); two partitions |
| volumes | one volume (no question); macOS 10.15 container: all listed with roles, Data proposed, `--volume N`, a volume that does not exist, an invalid number; Enter in a terminal takes Data; apfs-label (no roles): the ` - Data` name proposed |
| drivers | none installed (no sudo asked); apfs-fuse options (ro, nosuid, nodev, owner, allow_other, subtype; never rw, readwrite, -l, -r, pass=); kernel driver options; module loaded only when used; apfs-fuse fails → kernel tried; `APFS_DRIVER=kernel`; both fail; a mount that comes out writable is undone |
| encryption | no terminal → refused before apfs-fuse; kernel only → refused before mounting; kernel warns after mounting → unmounted; password in a real pseudo-terminal → opened, password in no argv and no log; three wrong passwords → locked, no folder left |
| errors | read error at the signature → exit 7, no driver run; read error in the driver → no second driver; sudo refused → exit 5; helper as a user → exit 5; unknown helper command → exit 2 |
| mount points | `/run/media/<user>/<volume>`, ACL for the user; `/` in a name; taken folder → suffix, untouched; symlinked parent → refused |
| Dolphin | xdg-open with the volume root, as the user, never as root; `--no-open`; already open → shown again without a second mount or sudo |
| closing | busy → exit 8, still mounted, no forced unmount; by the folder shown; nothing open; never a non-APFS mount; never an APFS mount made elsewhere |
| boot helper | Data volume on the given folder, owner given, nothing on stdout, no sudo, no file manager; encrypted → skipped, English message; no driver → exit 4 |
| translations | pt_BR messages and help |
| code | no write option, no repair/format tool, no forced unmount or kill, file manager never as root |
| real driver | real `blkid -p` and `apfsutil` on an image made by `mkapfs` (volume `Dados Mac ç`); real apfs-fuse mount: `fuse.apfs-fuse ro`, files owned by the caller, writing refused by the kernel; closed with no daemon left; image unchanged byte for byte |

Boot run (`tests/run-tests.sh`, 177 passed): internal APFS not mounted by
default (journal says how to open it, no folder, never `mount -o rw`);
`APFS=readonly` → helper with `/mnt/<label>` and the owner, lock not
inherited, status `ro apfs`, reverse link; no driver → status
`apfs-no-driver`, folder removed, boot goes on; encrypted → `apfs-encrypted`;
APFS on USB with `APFS=readonly` → left to UDisks; dry run; unknown value.

## Not tested here

- Files inside a real macOS volume (folders, photos, compressed files,
  snapshots, FileVault): no APFS writer exists on Linux without the
  experimental write mode of the kernel driver, and root was not available
  to load it. The real SSD (`/dev/sdf2`, one unencrypted volume) was opened
  and closed with the real apfs-fuse by hand: see apfs-09.
- `--doctor` APFS section: run by hand (it reads the real lsblk).
- ShellCheck: run by the CI (it was not available on the machine of this work).
