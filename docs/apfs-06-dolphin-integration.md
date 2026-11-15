# APFS 06 — The files in Dolphin

1. Connect the disk of the Mac. Plasma shows the partition; clicking it
   fails without a driver (UDisks cannot mount APFS on its own).
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
- Dolphin's "Unmount" on that folder belongs to UDisks, which did not mount
  it: use `bigmount --close-apfs` (it says when a window or a terminal still
  uses the volume).
- With the kernel driver installed, Plasma can also mount APFS by itself
  through UDisks (read-only), but without the owner mapping: private folders
  of the Mac then stay closed. `--open-apfs` is the way that works for them.

A graphical "Open Mac disk" action (choice of volume and password in a
window) belongs to Big Storage Rescue; it can drive the same helper through
`pkexec` (apfs-04, "Interface for other programs").
