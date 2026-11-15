# APFS 04 — Read-only mount

Code: `big-mount/usr/lib/big-mount/apfs.sh`, loaded by `cli.sh` only for the
APFS options. The boot run (`bigmount` without options) reads one more
configuration key and, only for an internal APFS partition with
`APFS=readonly`, starts `bigmount --apfs-helper boot-mount`.

## Commands

```bash
bigmount --open-apfs [DEVICE] [--volume N] [--no-open]
bigmount --close-apfs [DEVICE | FOLDER]
bigmount --apfs-info [DEVICE]
```

Without DEVICE, the only APFS partition connected (or a choice, in a
terminal). A whole disk (`/dev/sdf`) means its APFS partition.

`--open-apfs` runs as the person, in their session:

1. finds and checks the device (`lsblk`); if it is already open, shows it
   again;
2. stops at once, with the packages to install, when no driver is installed
   (no password is asked for nothing);
3. `sudo bigmount --apfs-helper probe DEV`: signature and volumes (root);
4. one volume: opened; several: listed with roles and encryption, the Data
   volume proposed (Enter); without a terminal, `--volume N` is required;
5. `sudo bigmount --apfs-helper mount DEV [N]`: read-only mount (root);
   sudo asks for the password once (its timestamp covers both calls);
6. checks that this user can read the folder, warns when the volume is empty
   (on macOS 10.15+ the files are in the Data volume);
7. opens the folder in the file manager **as the person** — the program set
   for folders (`xdg-mime query default inode/directory`: Dolphin, Thunar,
   Nautilus…), else the first one installed, else `xdg-open` — and prints the
   folder and how to close it. Not `xdg-open` first: outside Plasma and GNOME
   it sees a mount point as `inode/mount-point`, which nothing handles, and
   opens the web browser (seen on BigLinux with wlmaker and Thunar).

`--close-apfs` unmounts through the helper (`umount`, never `-l` or `-f`)
and removes the empty folder. A volume still in use is left mounted (exit
8), with how to find the programs that use it.

## Mount

| | apfs-fuse | kernel |
| --- | --- | --- |
| command | `apfs-fuse -o ro,nosuid,nodev,allow_other,default_permissions,subtype=apfs-fuse,uid=U,gid=G,vol=N DEV DIR` | `mount -t apfs -o ro,nosuid,nodev,uid=U,gid=G,vol=N -- DEV DIR` |
| type in `/proc/mounts` | `fuse.apfs-fuse` | `apfs` |
| folder shown | `DIR/root` | `DIR` |

- **Folder**: `/run/media/<user>/<volume name>`, next to what UDisks mounts.
  `/run/media/<user>` is made as UDisks makes it (root's, mode 0750, ACL
  `u:<uid>:r-x`): no other account can look in. A `/` in the name becomes
  `_`; a taken folder gets ` 1`, ` 2`…; a symlink is refused.
- **Owner**: `uid=`/`gid=` of the person who asked (`SUDO_UID`, or
  `PKEXEC_UID`): the Mac's own owner (501) and its private folders would
  otherwise be unreadable. No `chmod`/`chown` of any file.
- **Read-only, checked**: after mounting, `/proc/mounts` must show `ro`, or
  the volume is unmounted at once and the open fails.
- **Lifecycle**: apfs-fuse becomes a daemon after mounting (setsid, stdio on
  `/dev/null`): it holds no file of the caller, no lock of bigmount, and is
  not killed when the terminal closes or sudo ends; it ends when the volume
  is unmounted. At boot, `run()` closes the lock fd and the unit keeps
  `KillMode=process`, as for NTFS.
- **Timeouts**: listing volumes 60 s; a mount without a terminal 120 s
  (`timeout --foreground`, which never touches the daemon). In a terminal no
  timeout: the person may be typing a password, and Ctrl+C works.
- **Failures**: a read error stops everything (exit 7, no second driver on
  a failing disk). Otherwise the next driver is tried; if none can, the
  empty folder is removed and the message says the disk was not changed.

## At boot (internal disks)

`/etc/big-mount.conf`:

```ini
APFS=off        # default: not mounted at boot, logged with the command to open it
APFS=readonly   # mounted read-only on /mnt/<label>, the Data volume, for the last user
APFS_DRIVER=auto  # or fuse, or kernel
```

External disks (USB, Thunderbolt, SD…) stay with UDisks whatever the value.
With `readonly`: encrypted volumes are skipped (no prompt at boot); a
missing driver is a journal line and a `failed apfs-no-driver` status, the
boot goes on. Status reasons: `apfs` (ro), `apfs-no-driver`,
`apfs-encrypted`, `apfs-io-error`, `mount-exit-N`. `--doctor` does not warn
about APFS being read-only: it is on purpose.

## Interface for other programs (v1)

`bigmount --apfs-helper` runs as root only (exit 5 otherwise). Big Storage
Rescue or a graphical front end can run it through `pkexec` and give the
choice and the password itself (a terminal is needed only for encrypted
volumes, see apfs-05).

```
--apfs-helper probe DEVICE
# big-mount apfs probe v1
device	/dev/sdf2
lister	apfsutil | apfs-label | none
drivers	fuse kernel | none
volume	INDEX	ROLE|-	yes|no|unknown	RECOMMENDED(1|0)	NAME

--apfs-helper mount DEVICE [VOLUME]
mounted	MOUNTPOINT	FOLDER-TO-SHOW	fuse|kernel	VOLUME
already	MOUNTPOINT	FOLDER-TO-SHOW          (no VOLUME given, already open)

--apfs-helper unmount DEVICE|FOLDER
unmounted	MOUNTPOINT (TYPE)
```

Exit codes: 0 done, 1 failed, 2 usage, 3 not a usable APFS partition or
volume, 4 no driver, 5 not root / rights refused, 6 encrypted and not
unlocked, 7 read error of the device, 8 in use. Messages go to stderr, in
the language of the caller (English for `boot-mount`, for the journal).
