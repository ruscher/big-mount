# 04 — Dependencies

| | 2.6 | 3.0 |
| --- | --- | --- |
| `depends` | bash, util-linux, udisks2, polkit, ntfs-3g, lsof, rsync, smartmontools, python, python-gobject, gtk4, libadwaita>=1.5, libnotify (13) | **acl, bash, coreutils, gawk, glibc, grep, kmod, ntfs-3g, procps-ng, sed, systemd, util-linux** (12) |
| `optdepends` | ddrescue, testdisk | big-storage-rescue |
| installed files | 45, 803 KB | 37, 291 KB (with the version file and 31 translations) |

What Big-Mount calls, and the package of each program:

| Package | Programs |
| --- | --- |
| util-linux | `blkid`, `lsblk`, `findmnt`, `mount`, `flock` |
| ntfs-3g | `mount.lowntfs-3g` (NTFS) |
| systemd | `udevadm`; `systemctl` and `journalctl` in `--doctor`; the service itself |
| coreutils | `readlink`, `dirname`, `mkdir`, `ln`, `rm`, `rmdir`, `stat`, `head`, `tail` |
| glibc | `getent` |
| gawk | `awk` |
| sed | `sed` in `--doctor` |
| grep | `grep` (APFS) |
| acl | `setfacl`: `/run/media/<user>` for an opened APFS volume |
| kmod | `modinfo`, `modprobe`: the APFS kernel driver, only when it is used |
| procps-ng | `pgrep` in `big-mount.install`: a 2.x copy still running on upgrade |

APFS drivers are optional (`apfs-fuse-git` from the AUR, or
`linux-apfs-rw-dkms` and `apfsprogs` from extra), as are `sudo` and
`xdg-utils` for `--open-apfs`: the boot run needs none of them
(docs/apfs-03-driver-comparison.md).

systemd, glibc, gawk, sed, coreutils and procps-ng are on every Arch system,
so the six of them install nothing new. They are listed all the same, as the Arch
packaging guidelines ask for every direct dependency. `namcap` cannot see the
programs a shell script calls, so it marks every one of them "may not be
needed": the table above is the check. FAT32, exFAT, ext4, Btrfs, XFS and F2FS are mounted by kernel drivers,
which need no package.

`udisks2` and `polkit` were needed by the diagnosis and removal tools, not by
the boot run, and are dropped. On a desktop they are pulled in by Plasma or
GNOME anyway.

`big-storage-rescue` is optional, never required and never in conflict:
`tests/package-check.sh` checks it, and that no installed path is named after it
(`storage-rescue`, `bsr-`). That the two packages share no file is checked by
`tests/coexistence-check.sh` of Big Storage Rescue, which installs both with
pacman: pacman refuses a file that two packages own.
