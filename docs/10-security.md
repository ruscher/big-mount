# 10 — Security

## Privilege boundary

- **root** runs only:
  - the boot service (`big-mount.service`);
  - the helper `/usr/lib/big-mount/bigmount-holders`. It is read-only and
    accepts exactly one argument, which must be an exact mount point of a
    local block device. It runs through `pkexec` with a clean environment,
    under its own polkit action (`org.biglinux.big-mount.inspect-processes`,
    `auth_admin_keep`). Authorizing it gives access to no other mode as
    root.
- **The user** runs diagnosis, dialogs and notifications. Mounting,
  unmounting, locking, powering off and taking ownership all go through
  UDisks2, so UDisks' own polkit policy decides. Big-Mount widens no
  permission.
- As a user, `lsof` sees only the user's processes. Other accounts appear
  only after administrator authentication. **Their list is deleted as soon
  as the dialog closes**: it used to stay in `/tmp`, and a regression test
  now covers it.
- The root side never reads anything from a session. The session reads
  `/run/big-mount/status` (root, 0644) as data only.

## Fixed

| Item | Before | Now |
| --- | --- | --- |
| Label `..`/`.` | mounted over `/` or `/mnt` | rejected; the device name is used |
| Control characters, overlong labels | became directory names | `_`; over 200 bytes, the device name |
| Label with `$()`/backticks | never executed, but went through `echo` | never goes through a shell; dedicated test |
| HTML escaping | — | quoted replacements (bash 5.2 `patsub_replacement` turned `&lt;` into `<lt;`, caught by a test) |
| Terminal output | — | escape sequences from labels/files neutralized |
| Translation catalogs | — | `noexpand_translation`: a `.mo` cannot expand code |
| Values in `/etc/big-mount.conf` | — | parsed as data, never sourced; printed as arguments, never as printf formats |
| Mount races | none | `flock`, `diskseq` at boot and before every irreversible removal step |
| FUSE daemon in the service cgroup | died on `systemctl stop` | `KillMode=process` |
| Automatic `ntfsfix` | every NTFS mount | removed |
| Administrator process list | left in `/tmp` | deleted on return and on signals |
| Close confirmation | Enter confirmed | Cancel is the default |

## What is never done automatically

None of these runs automatically, and a test checks the shipped code for
them:

- repairs (`fsck`, `ntfsfix`, `btrfs check --repair`, `xfs_repair`);
- formatting;
- recursive `chown`/`chmod`;
- forced or lazy unmount;
- `SIGKILL`, `fuser -k`;
- `remove_hiberfile`;
- closing session, system or foreign processes.

Taking ownership is never recursive, and never offered on a partition that
holds an operating system.

## Permissions of internal FAT/NTFS

The default stays `umask=000` + `exec`: every local account can read, write
and run files. It cannot create *setuid* files, because the base mode is
`0777 & ~umask`. Changing the default would break sharing between accounts
and services (Samba, media servers) for people who rely on it, and the
project ranks compatibility above security. `PERMISSIONS=owner` or `private`
in `/etc/big-mount.conf` restricts it (see 03).
