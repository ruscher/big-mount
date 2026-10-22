# 11 — Final report

## Round 6 (the pending validations, release v2.1.3)

With v2.1.2 installed, the remaining items were checked on the machine:

- the Dolphin menu, through Dolphin's own code path;
- accessibility, through the AT-SPI tree that Orca reads;
- Breeze Light at 125 %, and X11;
- the Zenity dialogs of the GNOME edition;
- LUKS, with `dm_crypt` loaded;
- the administrator helper.

That found one high-severity bug: safe removal of an encrypted drive left
it unlocked and would not power it off (B30). It also found a notifier lock
leak that silently disabled the notifier after any restart (B31), an
overclaiming "nothing in the system" message (B32), a helper that accepted
`/` (B33) and a Zenity spacing flaw (B34).

All are fixed. Each fix has a test that fails on v2.1.2: unit 136,
integration 119 (7 checks fail on v2.1.2).

Left for a person: Windows Fast Startup (needs a Windows boot), hearing
Orca, the physical click, the password prompts, other hardware, a real
GNOME session.

## Round 5 (real devices after a reboot, release v2.1.2)

The user installed v2.1.1, rebooted and allowed tests on the connected
devices. The boot was clean (716 ms). The tests found three high-severity
problems in safe removal, all on a USB SSD used by a Docker service
(Immich):

- **B23:** the drive was powered off while `ntfs-3g` was still writing.
  The power-off failed, and the message blamed the drive.
- **B24:** systemd services bound to the mount were stopped without a word.
- **B25:** a container's own mount of the device was not seen, so the
  filesystem could have been reported safe while still in use.

The diagnosis also judged a folder by the root of its partition (B26). It
explained system partitions, swap and whole disks poorly (B27, B28).

All were fixed and tested: 135 unit tests, 110 integration tests (5 of them
fail on v2.1.1), and a real removal, power-off and reconnection of the SSD
in which the service came back by itself. Two mistakes in the first draft
of the fixes were caught before release: FUSE daemon names cut to 15
characters, and a wrong "do not start again" sentence.

## Round 4 (live tests on the real screen, release v2.1.1)

The dialogs and notifications were exercised on the real Plasma desktop of
the development machine, with disposable devices (see 09). Three wording and
layout problems seen there were fixed (B20–B22), and `--busy` on a free
device now says it is not in use. The README shows real screenshots. During
this round a screenshot safeguard failed once (it captured the user's
terminal instead of the dialog); those files were deleted unopened, and the
capture rule now requires class, PID and title to match.

## Round 3 (installed package, release v2.1.0)

The package built from round 2 was installed on the development machine
and tested there:

- integration suite against `/usr/bin/bigmount`;
- a live service restart with a mounted NTFS volume;
- real Plasma notifications;
- root timings.

Two problems found that way were fixed: B16, the lock fd inherited by the
NTFS FUSE daemon, which would have blocked every later run; and B17,
warnings at every login about partitions holding another operating system.

`pkgbuild/PKGBUILD` now builds this fork, because the official repository
does not have the code yet. It gained `pkgbuild/big-mount.install`, which
only prints messages. Releases: `v2.0.0` (round 1) and `v2.1.0` (rounds 2
and 3), each with its package attached.

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

Since round 3, `pkgbuild/PKGBUILD` builds `ruscher/big-mount`. Point it back
to `biglinux/big-mount` once the official repository carries this code.
