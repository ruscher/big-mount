# APFS 02 — Detection

## Four names that are not the same thing

| What | Where it comes from | Example (the SSD of the report) | Decides? |
| --- | --- | --- | --- |
| `PARTLABEL` | name in the GPT entry, free text | `Basic data partition` | no |
| `PARTTYPE` | type GUID in the GPT entry | `7c3457ef-0000-11aa-aa11-00306543ecac` (APFS container) | no |
| `FSTYPE` | signature on the partition (`NXSB` magic of the container superblock), probed by libblkid | `apfs` | **yes** |
| volume name | inside the container, one per volume | e.g. `Macintosh HD - Data` | names the folder |

`Basic data partition` is only a name, often written by the tool that made
the partition; the Microsoft basic data GUID is
`ebd0a0a2-b9e5-4433-87c0-68b6b72699c7`. Neither decides: the signature does.
`bigmount --apfs-info` shows all four, and says so when the table and the
signature disagree. The partition table is never changed to "fix" a label or
a type.

An APFS partition is a **container**; a container holds **volumes**
(macOS 10.15 and later: `Macintosh HD` (System), `Macintosh HD - Data`
(Data), `Preboot`, `Recovery`, `VM`; an external disk formatted on a Mac
usually has one volume with no special role).

## How Big-Mount decides

1. **As the user** (`--open-apfs`, `--apfs-info`): `lsblk` (udev database):
   partitions whose `FSTYPE` is `apfs`. A whole disk given on the command
   line is resolved to its APFS partition through `PKNAME`, never by name
   prefix (`sdf` is not `sdfa`).
2. **As root** (the helper): `blkid -p` reads the signature from the device
   itself, not from the udev cache, right before mounting. Only `TYPE=apfs`
   goes on. Another signature is named ("`/dev/sdf2` is not APFS: it contains
   ntfs"); none is said too. An input/output error stops everything (exit 7).
3. **Volumes**: `apfsutil` (apfs-fuse; role and encryption too), else
   `apfs-label` (apfsprogs; names only), both under a 60-second timeout. A
   signature whose container cannot be read is reported as damaged or
   unknown (exit 3), not retried.

The volume proposed is the one with the files of the users: the Data role;
else (apfs-label, no roles) a name ending in ` - Data`; else the first with
no special role; else the first that is not Preboot, Recovery, VM, Update,
Hardware, xART or System. It is proposed and marked, never imposed: all
volumes are listed.

## The SSD of the report (`/dev/sdf2`)

Inspected without root and without reading the disk, from the udev database
and sysfs (2026-11-15):

```
NAME  SIZE   TYPE FSTYPE PARTLABEL            PARTTYPE                             TRAN RM HOTPLUG
sdf   111,8G disk                                                                usb   0       1
sdf1    200M part vfat   EFI System Partition c12a7328-f81f-11d2-ba4b-00a0c93ec93b       0       1
sdf2  111,6G part apfs   Basic data partition 7c3457ef-0000-11aa-aa11-00306543ecac       0       1
```

- The GPT type is the APFS container GUID, and udev's libblkid probe found
  the APFS signature: it **is** APFS. `Basic data partition` is just its name.
- Layout of a disk formatted by macOS (EFI + one APFS container).
- Connected through USB (`TRAN=usb`, `HOTPLUG=1`, `RM=0`): an external
  device. The boot run leaves it to UDisks, as every USB disk; it is opened
  with `bigmount --open-apfs /dev/sdf2`.
- Read later as root with apfs-fuse (`bigmount --apfs-info /dev/sdf2`): the
  container has **one volume, `ssd`**, with no special role (a disk
  formatted on a Mac for data, not a macOS system disk), **not encrypted**.
  It opened read-only and closed cleanly; no read error was seen.
