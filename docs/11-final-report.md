# 11 — Final report

## Round 2 (branch `feature/bigmount-ng-2`)

Starting point: `master` at `ee044f9`, the modernized version. Mounting at
boot behaves exactly as before. The boot path was measured before and after
(40 ms, 27 processes, both times), and every existing suite still passes.

### Bugs fixed

| # | Finding |
| --- | --- |
| B1 | the administrator process list (other users' processes and paths) was left in `/tmp`, one file per use |
| B2 | a test artifact (a copy of `/usr/bin/tail`) was versioned |
| B3 | every read-only warning left a `notify-send` process waiting indefinitely |
| B4 | unmount races reported false failures; a "successful" unmount that left the mount produced a misleading message |
| B5 | removal did not re-check the disk identity or re-verify mounts before the power-off, and did not lock open LUKS volumes |
| B6 | 22 wrong fuzzy translations produced by `msgmerge` |
| B7 | boot messages, `.desktop` and polkit strings outside the catalog |
| B8 | the busy dialog started with a technical table, without a plain explanation |
| B9 | Enter confirmed "Close these programs?" |
| B10 | an artificial 1 s delay before every notification |

### Improvements

- English source everywhere, one gettext catalog for scripts, `.desktop`
  files and the polkit policy, and a complete pt_BR translation (249
  messages). Boot messages are translated on a terminal and stay English
  in the journal.
- Notifications: a single path. Information disappears after 5 s, problems
  after 15 s and stay in the history, and decisions are persistent dialogs.
  Durations are defined in one place, and
  `kdialog --passivepopup` is the fallback.
- Busy dialog: a plain-language summary and advice from the holder that
  matters most, before the technical details.
- "Writing pending data, do not disconnect" when an unmount takes more than
  2 s.
- Safe removal: race-safe unmount, disk identity checked before every
  irreversible step, final re-verification, LUKS locked before the
  power-off.
- New suites: `tests/i18n-tests.sh`, `tests/package-check.sh` and
  `tests/measure-session.sh`, plus integration cases for a GPT drive with
  two partitions, a vanishing device and an accidental Enter.
- CI runs translations and packaging. `build-package.yml` is documented
  (work branches never trigger an official build) and ignores docs/tests-only
  pushes.
- Documentation and README in English, with English file names.

### Measurements

See 08. Mount → notification went from 1044 ms to 45 ms; everything else is
unchanged.

### Limits and manual validation

See the end of 09. Notably:

- nothing was verified on a real Plasma screen (Breeze, scaling, Orca, the
  Dolphin menu);
- LUKS and read-only images need a kernel with those modules;
- the power-off of a real USB drive and a real boot with the package
  installed are still pending. Installing the package needs root, which was
  not available to the automation.

## Round 1 (merged as PR #1 and #2)

- Boot fixes A1–A14 (see 01): mounting over `/`, the FUSE daemon killed by
  the service, `ntfsfix` on every boot, silent read-only NTFS, USB disks
  with `RM=0`, the FAT regex, stale symlinks, empty directories, untested
  fstab isolation, races.
- Introduced the diagnosis, busy-device inspection, safe removal, the
  notifier, the Dolphin menu, the launcher, the pt_BR translation,
  `/etc/big-mount.conf`, and the test suites.

The package source in `pkgbuild/PKGBUILD` is still `biglinux/big-mount`, so
official packages only change when the work reaches that repository.
