# APFS 05 — Encrypted volumes (FileVault)

| Case | What happens |
| --- | --- |
| Not encrypted | opened by either driver |
| Software encryption / FileVault (Intel Macs without T2) | apfs-fuse, in a terminal: the password of a user of the Mac or the personal recovery key |
| Encrypted, only the kernel driver | refused before mounting (exit 6), apfs-fuse proposed |
| Encryption unknown (apfs-label lists no flags), kernel driver | mounted after a mark in the kernel log; if the driver then warns "volume is encrypted", unmounted at once (exit 6) |
| ... and the kernel log cannot be written | refused (exit 6): it cannot be checked |
| Hardware encryption (T2, Apple silicon) | not possible for any tool off that Mac: reported as encrypted, never "fixed" |
| Wrong password | three tries in the same run, then exit 6; the volume stays locked |
| At boot | encrypted volumes are skipped; no prompt |

## The password

- It is typed **into apfs-fuse itself**, which reads it from the terminal
  with echo off. It is never a command-line argument (`-r`, `pass=` are
  never used: they show in `/proc/PID/cmdline`), never an environment
  variable, never a file, and never passes through Big-Mount's variables,
  logs or the journal. The output of apfs-fuse is copied to a temporary file
  (mode 0600, root's, removed at once) to tell a wrong password from other
  errors; the password is not echoed, so it is not in that copy.
- sudo's own password is asked by sudo, as always.
- Without a terminal (a graphical caller), an encrypted volume is refused
  with "its password can only be typed in a terminal", before apfs-fuse is
  started: apfs-fuse cannot take a password safely any other way.
- Nothing tries to unlock a volume without the credentials of its owner.

Tested in `tests/apfs-tests.sh` ("encrypted volumes"): the password typed
in a real pseudo-terminal opens the volume, and the password appears in no
argument and no log; three wrong ones leave it locked and no folder behind.
