# APFS 06 — The files in Dolphin

With the kernel driver (`sudo pacman -S linux-apfs-rw-dkms apfsprogs`),
clicking the partition in the file manager opens it, read-only (below,
"Clicking the partition"). Otherwise, and for an encrypted volume:

1. Connect the disk of the Mac. The file manager shows the partition;
   clicking it fails without the kernel driver.
2. In a terminal (Konsole): `bigmount --open-apfs` (the partition is found
   by itself when it is the only APFS one). sudo asks for your password.
3. With several volumes, choose one (Enter takes the proposed Data volume).
   An encrypted volume asks for the password of the Mac.
4. Dolphin opens the files, read-only. Copy what you need to another disk.
5. `bigmount --close-apfs`, then unplug the disk.

Details:

- The file manager set for folders (Dolphin, Thunar, Nautilus, Nemo, Caja,
  PCManFM…; else the first installed; else `xdg-open`) is started by the
  user's own process, in the user's session — never by root, never through
  sudo. `xdg-open` is not used first: outside Plasma and GNOME it opened the
  web browser for a mount point. Without a
  graphical session (a console, ssh) the folder is only printed.
- Every file appears as the user's (`uid=`/`gid=` of the mount), so the
  folders a Mac keeps private (`Documents`, `Desktop`… mode 700 for user 501)
  open. The permission bits stay those of the Mac. Other local accounts
  cannot reach the folder (`/run/media/<user>`, ACL for that user only).
- Volume names with accents make folders with the same name (tested with the
  real driver: `Dados Mac ç`). Names of files inside are UTF-8 on APFS and
  are shown as they are; symlinks are shown as symlinks, and their targets
  are paths of the Mac.
- A file whose compression the driver does not know gives a read error when
  opened or copied; it is never shown as content (apfs-fuse returns EIO
  unless `-l` is given, and Big-Mount never gives it).
- Dolphin's "Unmount" on a folder opened by `--open-apfs` belongs to UDisks,
  which did not mount it: use `bigmount --close-apfs` (it says when a window
  or a terminal still uses the volume).

## Clicking the partition

UDisks mounts with `mount -t apfs`, and mount(8) runs `/usr/bin/mount.apfs`
(installed by Big-Mount) before asking the kernel. It hands the mount to
`bigmount --apfs-helper fs-mount` (apfs-04), which mounts with the kernel
driver only:

- the volume with the files of the users (`Macintosh HD - Data`), not volume
  0, which on a Mac system disk is the sealed system; `vol=N` in the mount
  options (fstab) chooses another;
- read-only, whatever the options ask for, and owned by the person whose
  folder UDisks made (`/run/media/<user>/…`), so the private folders of the
  Mac open;
- an encrypted volume is refused (the kernel driver would show garbage):
  `bigmount --open-apfs` asks for its password.

The file manager then shows the partition as mounted, and its own unmount
and eject work: the kernel driver mounts on the device number of the
partition, which is how UDisks knows a mount is the partition's. apfs-fuse
is never used here for that reason: a FUSE mount has a device number of its
own, so UDisks would not see it (it looks past that only for btrfs), the
partition would stay "not mounted", and a second click would mount it again.
With apfs-fuse only, the click fails and the journal of udisks2.service
says to install the kernel driver or use `bigmount --open-apfs`; the error
window itself only says that the mount helper failed.

A graphical "Open Mac disk" action (choice of volume and password in a
window) belongs to Big Storage Rescue; it can drive the same helper through
`pkexec` (apfs-04, "Interface for other programs").
