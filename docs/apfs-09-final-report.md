# APFS 09 — Final report

## Result

Big-Mount opens APFS partitions (disks of a Mac) **read-only**, on any disk,
through either installed driver, and shows the files in Dolphin:

```bash
bigmount --apfs-info /dev/sdf2     # what the partition is, its volumes, the driver
bigmount --open-apfs /dev/sdf2     # opens it read-only in the file manager
bigmount --close-apfs /dev/sdf2    # closes it, then the disk can be unplugged
```

Internal APFS partitions can also be mounted read-only at boot
(`APFS=readonly` in `/etc/big-mount.conf`, off by default). External disks
stay with UDisks at boot, as before.

## Validated, and how

| | How | Result |
| --- | --- | --- |
| apfs-fuse built and run on this machine (kernel 6.18.55, fuse3 3.18) | real binaries, scratch image made by `mkapfs` | mounts read-only, files owned by the caller, writing refused, closes with no daemon left, image unchanged |
| the whole flow (detection, volumes, both drivers, encryption, errors, mount points, closing, boot) | `tests/apfs-tests.sh`, stubbed devices | 106 passed, 0 failed |
| no regression of the boot run | `tests/run-tests.sh new` (+ 4 APFS cases) | 177 passed, 0 failed |
| boot time | `tests/bench.sh`, 30 runs | median 77.2 ms before, 77.3 ms after; 30 processes both |
| translations, package | `tests/i18n-tests.sh`, `tests/package-check.sh` | 270 and 101 passed |
| `/dev/sdf2`, the real 120 GB USB SSD | apfs-fuse-git installed from the AUR; `--apfs-info`, `--open-apfs`, `--close-apfs` run from the source checkout, in a terminal | APFS container with one volume, `ssd`, no special role, not encrypted; mounted read-only on `/run/media/ruscher/ssd` (Dolphin given `…/ssd/root`); closed: nothing mounted, no apfs-fuse left, folder removed; `/run/media/ruscher` root's, mode 0750, ACL `user:ruscher:r-x` |

**Not validated**: FileVault and multi-volume containers on real hardware
(this SSD has one unencrypted volume), compressed files, and the kernel
driver on real hardware.

## Commands on a real SSD

```bash
# 1. a driver (one of the two; apfs-fuse also opens FileVault volumes)
pamac build apfs-fuse-git                         # AUR
sudo pacman -S linux-apfs-rw-dkms apfsprogs       # or: official repository, no encryption

# 2. what is in it (asks for your password; nothing is written)
bigmount --apfs-info /dev/sdf2

# 3. open it (choose the volume; Enter takes the one with your files)
bigmount --open-apfs /dev/sdf2

# 4. when done
bigmount --close-apfs /dev/sdf2
```

If step 2 or 3 reports an input/output error, stop and make an image of the
disk with Big Storage Rescue before any further attempt.

## Files

| File | What |
| --- | --- |
| `big-mount/usr/lib/big-mount/apfs.sh` (new) | the APFS options and the root helper |
| `big-mount/usr/lib/big-mount/cli.sh` | options, help, `--doctor` APFS section |
| `big-mount/usr/bin/bigmount` | `APFS=`, never `mount -o rw` on APFS, boot helper |
| `big-mount/etc/big-mount.conf` | `APFS`, `APFS_DRIVER` |
| `pkgbuild/PKGBUILD` | depends `acl grep kmod`; optdepends `apfs-fuse-git`, `linux-apfs-rw-dkms`, `apfsprogs`, `sudo`, `xdg-utils` |
| `locale/*` | 97 new messages: en and pt_BR complete; the 29 others prepared (shown in English until translated) |
| `tests/apfs-tests.sh`, `tests/stubs-apfs/*` (new) | APFS tests |
| `tests/run-tests.sh`, `tests/stubs/bigmount-apfs-helper` | APFS at boot |
| `tests/i18n-tests.sh` | completeness required for en and pt_BR; others reported |
| `tests/package-check.sh`, `.github/workflows/tests.yml` | new file, dependencies, APFS suite in CI |
| `docs/apfs-0[1-9]*.md`, `README.md` | this documentation |

## Limits and risks

- apfs-fuse has had no upstream change since 2023; newer macOS features may
  stop it from reading a container (then the kernel driver is tried).
- The kernel driver cannot decrypt; Big-Mount refuses or undoes such mounts.
- Hardware-encrypted disks (T2, Apple silicon) cannot be read off their Mac.
- Fusion Drives and snapshots are not offered by `--open-apfs` (both drivers
  can, by hand: `apfs-fuse -f`, `snap=`; `tier2=`, `snap=`).
- Encrypted volumes need a terminal for the password.
- The kernel driver is a DKMS module: it must build for each new kernel.
- `/run/media/<user>` is made with an ACL when UDisks has not made it yet;
  without `setfacl` support on `/run`, the folder is given to the user.
