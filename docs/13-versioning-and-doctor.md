# 13 — Traceable versions, `--version` and `--doctor`

Round 7, item F10 of [12](12-field-report.md). The question it answers is:
*which Big-Mount is installed, and which code is it running?*

## 1. The problem

`pkgbuild/PKGBUILD` used `pkgver=$(date +%y.%m.%d)` and
`pkgrel=$(date +%H%M)`, which is the time of the **build**. Two builds of
the same commit got different versions, and nothing in a package said
which commit it came from. On the development machine,
`big-mount 26.10.22-1342` is installed. The integration suite shows that it
predates v2.1.3 (it fails the v2.1.3 tests), but its version cannot tell
which commit it is. The same problem hid the six months in which the
stable repository kept the December 2025 script (12, E1–E2).

## 2. Versioning

- `pkgver()` returns the UTC date and time of the **commit**, as
  `YY.MM.DD.HHMM`, and `pkgrel=1`.
- Ordering with the versions already published (checked with `vercmp` in
  `tests/package-check.sh`):
  `26.10.25.1342-1 > 26.10.22-1342 > 26.04.24-0149 > 25.12.23-2237`. A
  version with one more numeric field is newer, so no `epoch` is needed,
  and the BigLinux convention (dates) is kept. The real build
  `26.10.26.0139-1` was checked with `vercmp` against the three published
  versions.
- The same commit always gives the same version. Commits less than a
  minute apart would share it, which is acceptable for a repository
  updated by hand.
- The static `pkgver=` is a single word. makepkg writes the result of
  `pkgver()` back with `${line/#pkgver=*([^ ])/…}`
  (`/usr/bin/makepkg`, `update_pkgver`), which stops at the first space. A
  first draft used `pkgver=$(date -u …)`: the first build worked, and the
  second failed with a syntax error. Two real `makepkg` runs in a row now
  give the same `26.10.26.0139-1`, and `package-check.sh` applies the same
  substitution twice.
- `package()` writes `/usr/lib/big-mount/version`:

  ```text
  revision=<full commit hash>
  date=<commit date, UTC, ISO 8601>
  source=<url of the PKGBUILD>
  ```

  `bigmount --version` reads it as data and checks every value against a
  strict pattern. It is never sourced: a test with `$(…)` and backticks in
  it shows nothing is executed.
- `conflicts=('big-mount-git')` was added next to `replaces=`/`provides=`,
  as the Arch packaging guidelines ask: the old `-git` package is still in
  `biglinux-stable` (`23.08.28`).

`bigmount --version`:

```text
Big-Mount 2.2.0
  package:   big-mount <pkgver>-<pkgrel>      (pacman, when installed by a package)
  revision:  <commit> (<date>)               (version file; in a checkout, git describe)
  source:    <url>
```

`BM_VERSION` (2.2.0) lives in `doctor.sh` and follows the release tags.

## 3. `bigmount --doctor`

A read-only self-check, run as the user, that needs no password. It is
loaded only by this command (`/usr/lib/big-mount/doctor.sh`), so the other
modes and the boot path do not pay for it. Every line is `OK`, `INFO`,
`WARN` or `FAIL`. It exits 1 when there is a FAIL.

| Section | Checks |
| --- | --- |
| Big-Mount | version and revision; every `bigmount` in `PATH` (a copy in `/usr/local/bin` hides the package); whether the installed `/usr/bin/bigmount` carries a defect of the legacy script (name cutting, unchecked SDDM read, no options); missing package files; owner and mode of code that runs as root; `pacman -Qkk`; repository version vs. installed (`vercmp`); obsolete `big-mount-git` (checked with `pacman -Qq`, because `pacman -Q NAME` also answers for a package that only *provides* NAME) |
| Boot service | enabled, active and result; the unit replaced in `/etc/systemd/system`, drop-ins; `/etc/bigmountall-no`; the boot status (failed or read-only mounts, by device); `PERMISSIONS`; warnings of this boot in the journal |
| Desktop session | session type, desktop, language; KDialog or Zenity and its version; `notify-send`; session D-Bus; whether the notifier is running (its lock is held); Plasma and Dolphin versions |
| Storage stack | kernel, bash, util-linux, udisks, systemd versions; required programs; UDisks2 on the system bus; the polkit action; the kernel log; for **every disk the kernel shows**, that `/sys/block/<name>` exists and that UDisks2 knows it under the same name (the lookup that failed with `/dev/nvme`); NVMe controllers and their namespaces; read-only mounts |
| Outside Big-Mount | files in `~/.config` that do not belong to the user; packages with newer versions in the last synchronized list (never "update only some") |

### Privacy

The output is meant to be attached to an issue or a forum post. It never
contains:

- volume labels;
- serial numbers or UUIDs;
- mount points (they usually carry the label: journal lines get
  `/mnt/…`, `/run/media/…`);
- the home folder (it becomes `~`);
- the user's folder under `/run/media` or `/media` (it becomes `<user>`).

The bare user name is not replaced. It could be part of anything, such as
a repository URL, and replacing it there gave a wrong result in the first
draft. The integration suite checks that no label of the mounted test
devices and no `$HOME` appear.

### Legacy detection

`bm_dr_legacy_check` looks for the three defects of section 3 of
[12](12-field-report.md) in the installed `/usr/bin/bigmount`. It was
checked against the script of the stable package (3 failures), the
official April 2026 script (1 failure: it ignores options) and the current
script (none).

## 4. Measurements

| Command | Time (development machine) |
| --- | --- |
| `bigmount --version` (checkout, runs `git describe`) | < 0.1 s |
| `bigmount --doctor` | 0.6 s |
| boot path (`tests/bench.sh`, 30 runs, median) | 41.2–41.7 ms before, 42.0–42.4 ms after, within run-to-run noise; **28 → 27 processes** |

The boot path got one process cheaper: the second `getent` is gone, and
the translation directory is looked up only when a person reads the
output, as before. A first draft moved that lookup out of its condition and
cost one process (+2 ms). The benchmark caught it, and it was put back.
