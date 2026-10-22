# 06 — Safe removal

`bigmount --unmount TARGET` unmounts one filesystem. `--safe-remove TARGET`
handles the whole drive and powers it off, and `--gui-remove` is the same in
dialogs (and in the Dolphin menu). The core is `bm_remove_core` in
`usr/lib/big-mount/cli.sh`.

## Sequence

| Phase | What happens |
| --- | --- |
| A — diagnosis | resolve the filesystem and its drive; **refuse** if the drive holds the running system (`/`, `/home`, `/boot`, ... or active swap); record the disk sequence number |
| B — normal attempt | `udisksctl unmount` for every mount of every partition (stacked layers first); polkit decides about passwords |
| C — busy | `org.freedesktop.UDisks2.Error.DeviceBusy` → show what holds it; try again, refresh, or close programs |
| D — verification | the mount table decides, not the answer of udisksctl. A mount that vanished meanwhile counts as success; a "successful" unmount that left the mount counts as failure (bounded to 8 attempts, explicit reason). After the last unmount, **every** partition of the drive is checked again: if anything was mounted again meanwhile (an automounter, a script), nothing is reported as safe |
| E — encryption | open LUKS volumes on the drive are locked (`udisksctl lock`), as Plasma does before a safe removal |
| F — power off | `udisksctl power-off`, only for removable drives and only when nothing else (LVM, RAID, swap) uses the drive. Internal disks are unmounted, never powered off |

Before every step that cannot be undone, the disk sequence number is read
again. If another device took the name (the drive was pulled and a new one
plugged in), the operation stops and says so.

When an unmount or power-off is still running after 2 seconds, which happens
while pending writes reach the device, a popup says "Writing pending data to
the device. Do not disconnect it yet." It is implemented with `wait -n` on
the operation and a 2-second timer, with no polling.

## Closing programs

Closing is only offered for processes that:

- belong to the user;
- are not part of the desktop session (plasmashell, kwin, dbus, pipewire, ...);
- are not shells (an interactive shell ignores the request; the advice is
  `cd`);
- have **no** file open for writing (closing in the middle of a copy would
  leave an incomplete file).

Closing always needs an explicit confirmation that warns about unsaved
changes. **Cancel is the default button**, so an accidental Enter closes
nothing.

The signal is `SIGTERM` (what closing the window does), never `SIGKILL`.
Before sending it, the start time of the process is compared with the one
recorded at diagnosis, so that a process that inherited the PID is never
hit. The tool waits up to 5 seconds and reports what did not close, then
the unmount is attempted again. If a program opens files again, the device
is reported busy again; there is no automatic loop.

## What does not exist, by design

No code path uses `umount -f`, `umount -l`, `kill -9`, `fuser -k` or
`--force`. A test checks the shipped code for them. There is no forced
unmount without a risk of corruption: when a safe removal is not possible,
the device stays mounted and the reason is shown.

## Final messages (shown only after verification)

| Outcome | Popup |
| --- | --- |
| unmounted and powered off | **Safe to disconnect** — Successfully unmounted and powered off. You can disconnect it now. |
| removable, unmounted, no power-off available | **Safe to disconnect** — Successfully unmounted... you can disconnect it now. |
| internal disk | **Device unmounted** (does not suggest unplugging it) |
| busy | the busy dialog (a decision is needed) |
| holds the running system | **Unable to remove device** |
| authorization refused | **Unable to unmount device** — Permission was not granted. The device remains mounted. |
| still in use after the unmount | **Unable to power off device** — ... Do not disconnect it yet. |

CLI exit codes: 0 done, 1 error, 2 usage, 3 busy, 4 running system,
5 not authorized, 6 unmounted but still in use, 7 unmounted without
power-off.

## Tests

Unit tests (`tests/lib-tests.sh`, simulated drive):

- two partitions are unmounted, then powered off, in that order;
- one busy partition means busy, and no power-off;
- a device replaced between two steps stops the operation with nothing
  done to the new device;
- a partition mounted again meanwhile means no success;
- LUKS is locked before the power-off;
- internal disks are never powered off;
- races and inconsistent udisks answers;
- the slow-operation notice.

Integration (`tests/integration.sh`, real UDisks2 mounts): busy device
with cwd, reader, writer and kioworker holders; closing only what is safe;
a GPT drive with two partitions; a device that disappears; the running
system refused; GUI flows with scripted clicks, including an accidental
Enter.
