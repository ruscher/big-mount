#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets and helpers called through check()
# Tests of the APFS options (big-mount/usr/lib/big-mount/apfs.sh): detection,
# volumes, the drivers, encryption, mount points, unmounting, and that
# nothing is ever written or run as root that should not be.
#
# Every tool that reads a disk or mounts is a stub (tests/stubs-apfs), and
# PATH holds nothing else besides basic tools: no disk of the machine is
# touched. The "real driver" test at the end mounts a scratch APFS image with
# the real apfs-fuse when these are given (it is skipped otherwise):
#   APFS_FUSE_BUILD=DIR   folder with the apfs-fuse and apfsutil programs
#   MKAPFS=FILE           mkapfs of apfsprogs, to make the image
#
# Usage: tests/apfs-tests.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STUBS="$HERE/stubs-apfs"

PASS=0 FAIL=0 SKIP=0 FAILED=()
check() {
    local msg="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$msg"
    else FAIL=$((FAIL + 1)); FAILED+=("$T: $msg"); printf '  \033[31m✗\033[0m %s\n' "$msg"; fi
}
skip() { SKIP=$((SKIP + 1)); printf '  \033[33m-\033[0m %s\n' "$1"; }
begin() { T="$1"; echo "— $1"; }
WORK="$(mktemp -d)"
cleanup() {
    # A real mount of the last test, if it failed half way
    grep -F " $WORK/" /proc/mounts 2>/dev/null | while read -r _ mp _; do
        fusermount3 -u "$(printf '%b' "${mp//\\/\\0}")" 2>/dev/null
    done
    [ -n "${KEEP:-}" ] && { echo "kept: $WORK"; return; }
    rm -rf -- "${WORK:?}"
}
trap cleanup EXIT

# Basic tools the scripts may use; everything that touches devices is a stub
TOOLS=(bash readlink grep sed ls mkdir rmdir chmod chown mktemp rm tee timeout getent cat id
       dirname mountpoint awk head tail tr mv sort wc touch printf fusermount3 sleep sha256sum stat pgrep)

# R: the scratch root of the current test. A fake device is a file R/dev/NAME
new_root() {
    R="$WORK/$1"
    mkdir -p "$R"/{tree/usr/bin,tree/usr/lib/big-mount,bin,dev,proc,run/media,etc} \
             "$R"/{fake-blkid-p,fake-apfsutil,fake-apfs-label,fake-fuse,fake-kernel}
    : > "$R/proc/mounts"; : > "$R/filesystems"; : > "$R/kmsg"; : > "$R/fake-lsblk"
    cp "$REPO/big-mount/usr/bin/bigmount" "$REPO/big-mount/usr/bin/mount.apfs" "$R/tree/usr/bin/"
    cp "$REPO/big-mount/usr/lib/big-mount/cli.sh" "$R/tree/usr/lib/big-mount/"
    cp -r "$REPO/big-mount/usr/share" "$R/tree/usr/"
    sed -e "s|^APFS_MEDIA=.*|APFS_MEDIA=$R/run/media|" \
        -e "s|^APFS_MOUNTS=.*|APFS_MOUNTS=${REAL_MOUNTS:-$R/proc/mounts}|" \
        -e "s|^APFS_CONF=.*|APFS_CONF=$R/etc/big-mount.conf|" \
        -e "s|^APFS_FILESYSTEMS=.*|APFS_FILESYSTEMS=$R/filesystems|" \
        -e "s|^APFS_KMSG=.*|APFS_KMSG=$R/kmsg|" \
        -e "s|\[ ! -e \"\$r\" \]|[ ! -e \"$R/dev/\${r#/dev/}\" ]|" \
        -e "s|\[ ! -b \"\$r\" \]|[ ! -f \"$R/dev/\${r#/dev/}\" ]|" \
        -e '/# root-check$/s/"\$EUID"/"${FAKE_EUID:-$EUID}"/' \
        "$REPO/big-mount/usr/lib/big-mount/apfs.sh" > "$R/tree/usr/lib/big-mount/apfs.sh"
    local t s
    for t in "${TOOLS[@]}"; do
        s="$(PATH=/usr/bin:/bin command -v "$t")" && ln -s "$s" "$R/bin/$t"
    done
    # The stubs, but not the APFS drivers: each test installs those it needs
    for s in "$STUBS"/*; do
        case "${s##*/}" in apfs-fuse | apfsutil | apfs-label | thunar | big-storage-rescue) continue ;; esac
        ln -sf "$s" "$R/bin/${s##*/}"
    done
}
with_fuse() { ln -sf "$STUBS/apfs-fuse" "$R/bin/apfs-fuse"; ln -sf "$STUBS/apfsutil" "$R/bin/apfsutil"; }
with_kernel() { touch "$R/has-kernel-apfs"; }
with_apfsprogs() { ln -sf "$STUBS/apfs-label" "$R/bin/apfs-label"; }

# part NAME DISK FSTYPE PARTLABEL PARTTYPE [TRAN]: a partition known to udev
part() {
    printf '%s|part|%s|111,6G|%s||%s|%s\n' "$1" "$3" "$2" "$4" "$5" >> "$R/fake-lsblk"
    printf '%s|disk||111,8G||%s||\n' "$2" "${6:-usb}" >> "$R/fake-lsblk"
    : > "$R/dev/$1"
}
sig() { printf '%s\n' "$2" > "$R/fake-blkid-p/$1"; }
APFS_GUID=7c3457ef-0000-11aa-aa11-00306543ecac
MSDATA_GUID=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7

# The output of the real apfsutil for a container of macOS 10.15 or later
volumes_catalina() {
    cat > "$R/fake-apfsutil/$1" <<'EOF'
Volume 0 3D1F0D6B-0C70-4C2A-9F3E-7A3C6E7B0001
---------------------------------------------
Role:               System
Name:               Macintosh HD (Case-insensitive)
Capacity Consumed:  15032385536 Bytes
FileVault:          No
Snapshots:

Volume 1 3D1F0D6B-0C70-4C2A-9F3E-7A3C6E7B0002
---------------------------------------------
Role:               Data
Name:               Macintosh HD - Data (Case-insensitive)
Capacity Consumed:  80032385536 Bytes
FileVault:          ${ENC:-No}
Snapshots:

Volume 2 3D1F0D6B-0C70-4C2A-9F3E-7A3C6E7B0003
---------------------------------------------
Role:               Preboot
Name:               Preboot (Case-insensitive)
Capacity Consumed:  80385536 Bytes
FileVault:          No

Volume 3 3D1F0D6B-0C70-4C2A-9F3E-7A3C6E7B0004
---------------------------------------------
Role:               Recovery
Name:               Recovery (Case-insensitive)
Capacity Consumed:  530385536 Bytes
FileVault:          No

Volume 4 3D1F0D6B-0C70-4C2A-9F3E-7A3C6E7B0005
---------------------------------------------
Role:               VM
Name:               VM (Case-insensitive)
Capacity Consumed:  20480 Bytes
FileVault:          No

EOF
    sed -i "s/\${ENC:-No}/${ENC:-No}/" "$R/fake-apfsutil/$1"
}
volume_single() { # NAME VOLNAME [ENC]
    printf 'Volume 0 A-B\n---\nRole:               No specific role\nName:               %s (Case-sensitive)\nFileVault:          %s\n\n' \
        "$2" "${3:-No}" > "$R/fake-apfsutil/$1"
}

# bm ARGS...: bigmount of the scratch tree, as the person (not root), no
# terminal. Output in R/out (stdout) and R/err (stderr), exit code in RC.
bm() {
    env -i TESTROOT="$R" PATH="$R/bin" HOME="$HOME" LANGUAGE="${LANGUAGE_T:-C}" LANG="${LANG_T:-C.UTF-8}" \
        FAKE_EUID="${FAKE_EUID_T:-1000}" ${DISPLAY_T:+DISPLAY=$DISPLAY_T} \
        bash "$R/tree/usr/bin/bigmount" "$@" < /dev/null > "$R/out" 2> "$R/err"
    RC=$?
}
# mapfs ARGS...: /usr/bin/mount.apfs of the scratch tree, as mount(8) runs it
# for UDisks: as root (FAKE_EUID_T to change it), no terminal
mapfs() {
    env -i TESTROOT="$R" PATH="$R/bin" HOME="$HOME" LANGUAGE="${LANGUAGE_T:-C}" LANG="${LANG_T:-C.UTF-8}" \
        FAKE_EUID="${FAKE_EUID_T:-0}" \
        bash "$R/tree/usr/bin/mount.apfs" "$@" < /dev/null > "$R/out" 2> "$R/err"
    RC=$?
}
# The same, with a terminal: TTY_INPUT is typed into it
bm_tty() {
    local cmd
    printf -v cmd '%q ' env -i TESTROOT="$R" PATH="$R/bin" HOME="$HOME" LANGUAGE=C LANG=C.UTF-8 FAKE_EUID=1000 \
        bash "$R/tree/usr/bin/bigmount" "$@"
    printf '%s' "$TTY_INPUT" | script -qec "$cmd; echo \"RC=\$?\"" /dev/null > "$R/tty" 2>&1
    RC="$(grep -ao 'RC=[0-9]*' "$R/tty" | tail -n1 | cut -d= -f2)"
}
has() { grep -qF -- "$2" "$R/$1" 2>/dev/null; }
logged() { [ -s "$R/$1" ]; }
me="$(id -un)"
MEDIA() { printf '%s' "$R/run/media/$me"; }

echo "========================================="
echo "APFS tests"
echo "========================================="

begin "help"
new_root help
bm --help
check "--help names --open-apfs, --close-apfs and --apfs-info" bash -c '[[ $1 == *--open-apfs* && $1 == *--close-apfs* && $1 == *--apfs-info* ]]' _ "$(cat "$R/out")"

begin "no driver installed"
new_root nodriver
part sdz2 sdz apfs "Basic data partition" "$APFS_GUID"; sig sdz2 TYPE=apfs
bm --open-apfs /dev/sdz2
check "exit 4" test "$RC" = 4
check "says it is APFS and that no driver is installed" has err "no APFS driver is installed"
check "  ... and how to install one (apfs-fuse-git, linux-apfs-rw-dkms)" bash -c 'grep -q apfs-fuse-git "$1" && grep -q linux-apfs-rw-dkms "$1"' _ "$R/err"
check "no administrator password asked for nothing" bash -c '! test -s "$1"' _ "$R/sudo.log"
bm --doctor
check "--doctor warns: APFS partition without a driver" has out "No APFS driver installed"

begin "Basic data partition with the APFS type: opened (only one volume)"
new_root single
with_fuse
part sdz2 sdz apfs "Basic data partition" "$APFS_GUID"; sig sdz2 TYPE=apfs
volume_single sdz2 "Fotos"
DISPLAY_T=:0 bm --open-apfs /dev/sdz2
check "exit 0" test "$RC" = 0
check "no question with a single volume" bash -c '! grep -q "Volume to open" "$1"' _ "$R/err"
check "apfs-fuse mounts volume 0" has apfs-fuse.log "vol=0"
check "  ... read-only (ro), with no write option" bash -c 'grep -q "\[ro," "$1" && ! grep -qE "(^|,|\[)(rw|readwrite)(,|\])" "$1"' _ "$R/apfs-fuse.log"
check "  ... never with -l (possibly corrupt data) or a password option" bash -c '! grep -qE "\[-l\]|\[-r\]|pass=" "$1"' _ "$R/apfs-fuse.log"
check "  ... files owned by the person who asked (uid, gid)" has apfs-fuse.log "uid=$(id -u),gid=$(id -g)"
check "  ... nosuid,nodev, and readable by that person (allow_other,default_permissions)" bash -c 'grep -q "nosuid,nodev,allow_other,default_permissions" "$1"' _ "$R/apfs-fuse.log"
check "mounted on /run/media/<user>/<volume name>" has apfs-fuse.log "[$(MEDIA)/Fotos]"
check "that folder is readable by that person only (ACL u:<uid>:r-x)" has setfacl.log "u:$(id -u):r-x"
check "the root part ran through sudo: probe and mount only" bash -c '[ "$(grep -c -- "--apfs-helper" "$1")" = 2 ] && grep -q "apfs-helper probe /dev/sdz2" "$1" && grep -q "apfs-helper mount /dev/sdz2" "$1"' _ "$R/sudo.log"
check "the file manager opens the files (the root folder of apfs-fuse)" has xdg-open.log "$(MEDIA)/Fotos/root"
check "  ... as the person, never as root" bash -c '! grep -q "euid=0" "$1" && grep -q "euid=1000" "$1"' _ "$R/xdg-open.log"
check "says it is read-only and how to close it" bash -c 'grep -q "Opened read-only" "$1" && grep -q -- "--close-apfs /dev/sdz2" "$1"' _ "$R/err"
check "prints the folder (for scripts)" has out "$(MEDIA)/Fotos/root"
: > "$R/sudo.log"
bm --open-apfs /dev/sdz2 --no-open
check "opened again: shown again, no second mount and no password" bash -c '[ "$1" = 0 ] && grep -q "already open" "$2" && [ "$(grep -c "^apfs-fuse" "$3")" = 1 ] && ! test -s "$4"' _ "$RC" "$R/err" "$R/apfs-fuse.log" "$R/sudo.log"

begin "file manager (not the web browser)"
new_root fm
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 ssd
ln -s "$STUBS/thunar" "$R/bin/thunar"; echo thunar.desktop > "$R/mime-default"
DISPLAY_T=:0 bm --open-apfs /dev/sdz2
check "the file manager set for folders (Thunar) opens the files, not xdg-open" \
    bash -c 'grep -q "^thunar euid=1000 $1/ssd/root$" "$2" && ! test -s "$3"' _ "$(MEDIA)" "$R/filemanager.log" "$R/xdg-open.log"
bm --close-apfs; : > "$R/filemanager.log"; echo firefox.desktop > "$R/mime-default"
DISPLAY_T=:0 bm --open-apfs /dev/sdz2
check "folders set to open in a web browser: an installed file manager instead" \
    bash -c 'grep -q "^thunar " "$1" && ! test -s "$2"' _ "$R/filemanager.log" "$R/xdg-open.log"
bm --close-apfs; rm "$R/bin/thunar"
DISPLAY_T=:0 bm --open-apfs /dev/sdz2
check "no known file manager installed: xdg-open" has xdg-open.log "$(MEDIA)/ssd/root"

begin "volumes of macOS 10.15+: the Data volume is proposed, nothing is guessed"
new_root multi
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
volumes_catalina sdz2
bm --open-apfs /dev/sdz2
check "without a terminal and without --volume: exit 2, nothing mounted" bash -c '[ "$1" = 2 ] && ! test -s "$2"' _ "$RC" "$R/apfs-fuse.log"
check "  ... the volumes are listed, with their roles" bash -c 'for v in "Macintosh HD - Data" "(Data)" "(System)" Preboot Recovery VM; do grep -qF "$v" "$1" || exit 1; done' _ "$R/err"
check "  ... the Data volume is marked as the one with the files" bash -c 'grep "Macintosh HD - Data" "$1" | grep -q "files of the users"' _ "$R/err"
check "  ... and how to choose" has err "--open-apfs /dev/sdz2 --volume N"
bm --open-apfs /dev/sdz2 --volume 1 --no-open
check "--volume 1: mounts volume 1" bash -c '[ "$1" = 0 ] && grep -q "vol=1" "$2"' _ "$RC" "$R/apfs-fuse.log"
check "  ... on a folder with the volume name" has apfs-fuse.log "[$(MEDIA)/Macintosh HD - Data]"
check "  ... and does not open the file manager (--no-open)" bash -c '! test -s "$1"' _ "$R/xdg-open.log"
bm --open-apfs /dev/sdz2 --volume 9 --no-open
check "--volume of a volume that does not exist: refused" bash -c '[ "$1" != 0 ] && grep -q "has no volume 9" "$2"' _ "$RC" "$R/err"
bm --open-apfs /dev/sdz2 --volume 'x;id'
check "--volume that is not a number: exit 2" test "$RC" = 2
if command -v script >/dev/null; then
    new_root multi-tty
    with_fuse
    part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
    volumes_catalina sdz2
    TTY_INPUT=$'\n' bm_tty --open-apfs /dev/sdz2 --no-open
    check "in a terminal: Enter takes the proposed volume (Data, 1)" bash -c '[ "$1" = 0 ] && grep -q "vol=1" "$2"' _ "$RC" "$R/apfs-fuse.log"
else
    skip "volume chosen in a terminal (script(1) unavailable)"
fi

begin "the signature decides, not the partition table"
new_root signature
with_fuse
part sdz2 sdz apfs "Basic data partition" "$MSDATA_GUID"; sig sdz2 TYPE=apfs
volume_single sdz2 "Mac"
bm --apfs-info /dev/sdz2
check "--apfs-info: Microsoft basic data in the table, APFS on the partition" bash -c 'grep -q "Microsoft basic data" "$1" && grep -q "the signature is what counts" "$2"' _ "$R/out" "$R/err"
check "  ... GPT name shown as only a name" has out "partition name (GPT, only a name):"
check "  ... the volumes, read through sudo" bash -c 'grep -q " 0  Mac" "$1" && grep -q "apfs-helper probe" "$2"' _ "$R/out" "$R/sudo.log"
check "  ... nothing mounted" bash -c '! test -s "$1"' _ "$R/apfs-fuse.log"
bm --open-apfs /dev/sdz2 --no-open
check "opened anyway (the table is left as it is)" test "$RC" = 0
new_root not-apfs
with_fuse
part sdz2 sdz ntfs "Basic data partition" "$MSDATA_GUID"; sig sdz2 TYPE=ntfs
bm --open-apfs /dev/sdz2
check "Basic data partition with NTFS: not APFS (exit 3, says what it is)" bash -c '[ "$1" = 3 ] && grep -q "is not APFS: it contains ntfs" "$2"' _ "$RC" "$R/err"
check "  ... nothing mounted" bash -c '! test -s "$1"' _ "$R/apfs-fuse.log"
new_root no-sig
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"
bm --open-apfs /dev/sdz2
check "udev says APFS, but no signature on the partition (stale): exit 3" bash -c '[ "$1" = 3 ] && grep -q "no APFS signature" "$2"' _ "$RC" "$R/err"
new_root broken-container
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
bm --open-apfs /dev/sdz2
check "signature, but the container cannot be read: exit 3, explained" bash -c '[ "$1" = 3 ] && grep -q "container cannot be read" "$2"' _ "$RC" "$R/err"

begin "devices"
new_root devices
with_fuse
bm --open-apfs /dev/sdy9
check "a disk that is not connected: exit 3, says so" bash -c '[ "$1" = 3 ] && grep -q "does not exist" "$2"' _ "$RC" "$R/err"
bm --open-apfs relative/path
check "not a /dev path: exit 3" test "$RC" = 3
bm --open-apfs
check "no APFS partition connected: exit 3, says how to look" bash -c '[ "$1" = 3 ] && grep -q "lsblk -f" "$2"' _ "$RC" "$R/err"
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
bm --open-apfs --no-open
check "no device given, one APFS partition connected: that one" bash -c '[ "$1" = 0 ] && grep -q "/dev/sdz2" "$2"' _ "$RC" "$R/apfs-fuse.log"
new_root whole-disk
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac; : > "$R/dev/sdz"
printf 'sdza1|part|apfs|1G|sdza|||%s\n' "$APFS_GUID" >> "$R/fake-lsblk"
bm --open-apfs /dev/sdz --no-open
check "a whole disk: its APFS partition (not one of another disk with a similar name)" bash -c '[ "$1" = 0 ] && grep -q "\[/dev/sdz2\]" "$2"' _ "$RC" "$R/apfs-fuse.log"
new_root two
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; part sdy2 sdy apfs "" "$APFS_GUID"
bm --open-apfs
check "two APFS partitions, no terminal: both listed, exit 2" bash -c '[ "$1" = 2 ] && grep -q sdz2 "$2" && grep -q sdy2 "$2"' _ "$RC" "$R/err"
new_root eio
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; : > "$R/fake-blkid-p/sdz2.eio"
bm --open-apfs /dev/sdz2
check "a device that cannot be read: exit 7, stops, points to Big Storage Rescue" bash -c '[ "$1" = 7 ] && grep -q "input/output error" "$2" && grep -q "Big Storage Rescue" "$2"' _ "$RC" "$R/err"
check "  ... no driver is even tried" bash -c '! test -s "$1" && ! test -s "$2"' _ "$R/apfs-fuse.log" "$R/apfsutil.log"
new_root eio-fuse
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac; : > "$R/fake-fuse/sdz2.eio"
with_kernel
bm --open-apfs /dev/sdz2 --no-open
check "read error in the driver: exit 7, the other driver is not tried on a failing disk" bash -c '[ "$1" = 7 ] && ! test -s "$2"' _ "$RC" "$R/mount.log"
check "  ... the empty folder is removed" bash -c '[ -z "$(ls -A "$1")" ]' _ "$(MEDIA)"

begin "administrator rights"
new_root sudo-refused
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
touch "$R/sudo-refuse"
bm --open-apfs /dev/sdz2
check "sudo refused: exit 5, nothing mounted" bash -c '[ "$1" = 5 ] && ! test -s "$2"' _ "$RC" "$R/apfs-fuse.log"
rm -f "$R/sudo-refuse"
bm --apfs-helper probe /dev/sdz2
check "the helper refuses to run as a user (exit 5)" bash -c '[ "$1" = 5 ] && ! test -s "$2"' _ "$RC" "$R/apfsutil.log"
FAKE_EUID_T=0 bm --apfs-helper probe /dev/sdz2
check "the helper as root: probe format v1" bash -c 'head -n1 "$1" | grep -q "^# big-mount apfs probe v1" && grep -q "^volume	0	No specific role	no	1	Mac$" "$1"' _ "$R/out"
FAKE_EUID_T=0 bm --apfs-helper format /dev/sdz2
check "the helper knows only its own commands (exit 2)" test "$RC" = 2

begin "encrypted volumes (FileVault)"
new_root enc-notty
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
volume_single sdz2 Secret Yes; echo "s3cr3t-pw" > "$R/fake-fuse/sdz2.password"
bm --open-apfs /dev/sdz2
check "no terminal to type the password: exit 6, says to use a terminal" bash -c '[ "$1" = 6 ] && grep -q "only be typed in a terminal" "$2"' _ "$RC" "$R/err"
check "  ... apfs-fuse not started" bash -c '! test -s "$1"' _ "$R/apfs-fuse.log"
new_root enc-kernel
with_kernel; ln -sf "$STUBS/apfsutil" "$R/bin/apfsutil"
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
volume_single sdz2 Secret Yes
bm --open-apfs /dev/sdz2
check "only the kernel driver, encrypted volume: exit 6, apfs-fuse proposed" bash -c '[ "$1" = 6 ] && grep -q "cannot decrypt" "$2" && grep -q apfs-fuse-git "$2"' _ "$RC" "$R/err"
check "  ... the kernel driver is not even tried (it would show garbage)" bash -c '! test -s "$1"' _ "$R/mount.log"
if command -v script >/dev/null; then
    new_root enc-tty
    with_fuse
    part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
    volume_single sdz2 Secret Yes; echo "s3cr3t-pw" > "$R/fake-fuse/sdz2.password"
    TTY_INPUT=$'s3cr3t-pw\n' bm_tty --open-apfs /dev/sdz2 --no-open
    check "in a terminal, right password: opened" bash -c '[ "$1" = 0 ] && grep -q "Opened read-only" "$2"' _ "$RC" "$R/tty"
    check "  ... the password is asked by apfs-fuse itself (on the terminal)" grep -q "Enter Password" "$R/tty"
    check "  ... and is in no command line and no log" bash -c '! grep -rqs "s3cr3t-pw" "$1"/*.log' _ "$R"
    new_root enc-wrong
    with_fuse
    part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
    volume_single sdz2 Secret Yes; echo "s3cr3t-pw" > "$R/fake-fuse/sdz2.password"
    TTY_INPUT=$'a\nb\nc\n' bm_tty --open-apfs /dev/sdz2 --no-open
    check "wrong password three times: exit 6, volume stays locked" bash -c '[ "$1" = 6 ] && grep -q "stays locked" "$2"' _ "$RC" "$R/tty"
    check "  ... three tries, then it stops" bash -c '[ "$(grep -c "^apfs-fuse" "$1")" = 3 ]' _ "$R/apfs-fuse.log"
    check "  ... no folder left behind" bash -c '[ -z "$(ls -A "$1")" ]' _ "$(MEDIA)"
else
    skip "password typed in a terminal (script(1) unavailable)"
fi

begin "kernel driver"
new_root kernel
with_kernel; with_apfsprogs
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
printf '0\tMacintosh HD\n1\tMacintosh HD - Data\n2\tPreboot\n' > "$R/fake-apfs-label/sdz2"
bm --open-apfs /dev/sdz2 --no-open
check "apfs-label lists the volumes: the one named Data is proposed" bash -c 'grep "Macintosh HD - Data" "$1" | grep -q "files of the users"' _ "$R/err"
bm --open-apfs /dev/sdz2 --volume 1 --no-open
check "mount -i -t apfs (never mount.apfs again), read-only, owner mapped, volume 1" has mount.log "mount -i -t apfs -o ro,nosuid,nodev,uid=$(id -u),gid=$(id -g),vol=1 -- /dev/sdz2"
check "  ... never the readwrite option" bash -c '! grep -q readwrite "$1"' _ "$R/mount.log"
check "  ... encryption checked in the kernel log after a mark" has kmsg "big-mount: apfs mount"
check "  ... the file manager gets the volume itself (no root folder)" bash -c 'grep -q "Macintosh HD - Data$" "$1"' _ "$R/out"
check "  ... the module is loaded only now, when needed" has modprobe.log "apfs"
bm --close-apfs /dev/sdz2
check "--close-apfs: unmounted (no -l, no -f), folder removed" bash -c '[ "$1" = 0 ] && grep -qx "umount -- $2" "$3" && [ ! -e "$2" ]' _ "$RC" "$(MEDIA)/Macintosh HD - Data" "$R/umount.log"
new_root kernel-enc
with_kernel; with_apfsprogs
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
printf '0\tSecret\n' > "$R/fake-apfs-label/sdz2"; : > "$R/fake-kernel/sdz2.encrypted"
bm --open-apfs /dev/sdz2 --no-open
check "encryption unknown beforehand, the driver warns: unmounted at once, exit 6" bash -c '[ "$1" = 6 ] && grep -q "umount" "$2" && [ ! -s "$3" ]' _ "$RC" "$R/umount.log" "$R/proc/mounts"
check "  ... no folder left behind" bash -c '[ -z "$(ls -A "$1")" ]' _ "$(MEDIA)"
new_root kernel-rw
with_kernel; with_apfsprogs
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
printf '0\tMac\n' > "$R/fake-apfs-label/sdz2"; : > "$R/fake-kernel/sdz2.rw"
bm --open-apfs /dev/sdz2 --no-open
check "a mount that comes out writable is undone at once" bash -c '[ "$1" != 0 ] && grep -q "writable" "$2" && [ ! -s "$3" ]' _ "$RC" "$R/err" "$R/proc/mounts"
new_root fallback
with_fuse; with_kernel
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
: > "$R/fake-fuse/sdz2.fail"
bm --open-apfs /dev/sdz2 --no-open
check "apfs-fuse cannot read the container: the kernel driver is tried next" bash -c '[ "$1" = 0 ] && grep -q "^apfs-fuse" "$2" && grep -q "mount -i -t apfs" "$3"' _ "$RC" "$R/apfs-fuse.log" "$R/mount.log"
new_root driver-choice
with_fuse; with_kernel
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
echo "APFS_DRIVER=kernel" > "$R/etc/big-mount.conf"
bm --open-apfs /dev/sdz2 --no-open
check "APFS_DRIVER=kernel in big-mount.conf: only the kernel driver" bash -c '[ "$1" = 0 ] && ! test -s "$2" && grep -q "mount -i -t apfs" "$3"' _ "$RC" "$R/apfs-fuse.log" "$R/mount.log"
new_root both-fail
with_fuse; with_kernel
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
: > "$R/fake-fuse/sdz2.fail"; : > "$R/fake-kernel/sdz2.fail"
bm --open-apfs /dev/sdz2 --no-open
check "both drivers fail: exit 1, says the disk was not changed, no folder left" bash -c '[ "$1" = 1 ] && grep -q "was not changed" "$2" && [ -z "$(ls -A "$3")" ]' _ "$RC" "$R/err" "$(MEDIA)"

begin "mount points"
new_root mp
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 "Fotos/2024"
mkdir -p "$(MEDIA)/Fotos_2024"; touch "$(MEDIA)/Fotos_2024/other"
bm --open-apfs /dev/sdz2 --no-open
check "a slash in the volume name never makes a path; a taken folder gets a number" has apfs-fuse.log "[$(MEDIA)/Fotos_2024 1]"
check "  ... the other folder is untouched" test -e "$(MEDIA)/Fotos_2024/other"
new_root mp-link
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
mkdir -p "$R/elsewhere"; ln -s "$R/elsewhere" "$(MEDIA)"
bm --open-apfs /dev/sdz2 --no-open
check "/run/media/<user> is a symlink: refused, nothing mounted" bash -c '[ "$1" != 0 ] && ! test -s "$2" && [ -z "$(ls -A "$3")" ]' _ "$RC" "$R/apfs-fuse.log" "$R/elsewhere"

begin "closing"
new_root close
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
bm --open-apfs /dev/sdz2 --no-open
touch "$R/busy"
bm --close-apfs
check "in use: exit 8, says to close the files, nothing forced" bash -c '[ "$1" = 8 ] && grep -q "still in use" "$2" && ! grep -qE "umount .*-[a-z]*[lf]" "$3"' _ "$RC" "$R/err" "$R/umount.log"
check "  ... still mounted" has proc/mounts "$(MEDIA | sed 's/ /\\040/g')/Mac"
check "  ... Big Storage Rescue not installed: not run" bash -c '! test -s "$1"' _ "$R/bsr.log"
ln -s "$STUBS/big-storage-rescue" "$R/bin/big-storage-rescue"
bm --close-apfs /dev/sdz2
check "Big Storage Rescue installed: it shows the programs in the folder, run as the person" \
    bash -c '[ "$1" = 8 ] && grep -qx "big-storage-rescue euid=1000 --busy $2/Mac" "$3" && grep -q "current folder is on the device" "$4"' _ "$RC" "$(MEDIA)" "$R/bsr.log" "$R/err"
rm -f "$R/busy"
bm --close-apfs "$(MEDIA)/Mac/root"
check "closed by the folder shown in the file manager" bash -c '[ "$1" = 0 ] && grep -q "Closed" "$2" && [ ! -e "$3" ]' _ "$RC" "$R/err" "$(MEDIA)/Mac"
bm --close-apfs
check "nothing open: says so, exit 0" bash -c '[ "$1" = 0 ] && grep -q "No APFS volume" "$2"' _ "$RC" "$R/err"
echo "/dev/sdz1 /home ext4 rw 0 0" >> "$R/proc/mounts"
FAKE_EUID_T=0 bm --apfs-helper unmount /home
check "the helper never unmounts what is not APFS" bash -c '[ "$1" = 3 ] && ! grep -q home "$2"' _ "$RC" "$R/umount.log"
echo "/dev/sdz2 /srv/mac apfs ro 0 0" >> "$R/proc/mounts"
FAKE_EUID_T=0 bm --apfs-helper unmount /dev/sdz2
check "  ... nor an APFS volume someone else mounted elsewhere" bash -c '[ "$1" = 3 ] && grep -q "not opened by Big-Mount" "$2"' _ "$RC" "$R/err"

begin "at boot (big-mount.service, internal disks, APFS=readonly)"
new_root boot
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volumes_catalina sdz2
mkdir -p "$R/mnt/Mac"
FAKE_EUID_T=0 bm --apfs-helper boot-mount /dev/sdz2 "$R/mnt/Mac" 1000 1000
check "the volume with the files of the users (Data, 1), on the folder given" bash -c '[ "$1" = 0 ] && grep -q "vol=1" "$2" && grep -q "\[$3\]" "$2"' _ "$RC" "$R/apfs-fuse.log" "$R/mnt/Mac"
check "  ... owned by the user given, read-only" bash -c 'grep -q "\[ro,.*uid=1000,gid=1000" "$1"' _ "$R/apfs-fuse.log"
check "  ... nothing on stdout, no sudo, no file manager" bash -c '! test -s "$1" && ! test -s "$2" && ! test -s "$3"' _ "$R/out" "$R/sudo.log" "$R/xdg-open.log"
new_root boot-enc
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; ENC=Yes volumes_catalina sdz2
mkdir -p "$R/mnt/Mac"
LANGUAGE_T=pt_BR LANG_T=pt_BR.UTF-8 FAKE_EUID_T=0 bm --apfs-helper boot-mount /dev/sdz2 "$R/mnt/Mac" 1000 1000
check "encrypted at boot: left alone (exit 6), no password asked" bash -c '[ "$1" = 6 ] && ! test -s "$2"' _ "$RC" "$R/apfs-fuse.log"
check "  ... the message is in English, for the journal" grep -q "is encrypted" "$R/err"
new_root boot-none
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
mkdir -p "$R/mnt/Mac"
FAKE_EUID_T=0 bm --apfs-helper boot-mount /dev/sdz2 "$R/mnt/Mac" 1000 1000
check "no driver at boot: exit 4 at once, says which packages" bash -c '[ "$1" = 4 ] && grep -q linux-apfs-rw-dkms "$2"' _ "$RC" "$R/err"

begin "file manager click (UDisks runs mount -t apfs, mount(8) runs mount.apfs)"
UUID_DIR=92319c2f-9cef-43a8-b73a-86562c5c47ec
new_root fs
with_kernel; with_apfsprogs
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
printf '0\tMacintosh HD\n1\tMacintosh HD - Data\n2\tPreboot\n' > "$R/fake-apfs-label/sdz2"
mkdir -p "$(MEDIA)/$UUID_DIR"
mapfs /dev/sdz2 "$(MEDIA)/$UUID_DIR" -o nosuid,nodev,uhelper=udisks2
check "mounted (exit 0), by the kernel driver on the folder UDisks made" bash -c '[ "$1" = 0 ] && grep -q -- "-- /dev/sdz2 $2\$" "$3"' _ "$RC" "$(MEDIA)/$UUID_DIR" "$R/mount.log"
check "  ... mount -i: the driver itself, never mount.apfs again" has mount.log "mount -i -t apfs"
check "  ... the volume with the files of the users (Data, 1), not volume 0" has mount.log ",vol=1 --"
check "  ... read-only, files of the person of /run/media/<user>" has mount.log "-o ro,nosuid,nodev,uid=$(id -u),gid=$(id -g),vol=1"
check "  ... encryption checked in the kernel log, nothing on stdout, no sudo" bash -c 'grep -q "big-mount: apfs mount" "$1" && ! test -s "$2" && ! test -s "$3"' _ "$R/kmsg" "$R/out" "$R/sudo.log"
check "  ... the module loaded only now" has modprobe.log "apfs"
mapfs /dev/sdz2 "$(MEDIA)/$UUID_DIR" -o rw,vol=0,uid=1234,gid=4321
check "vol=, uid=, gid= given are used; rw is not: read-only all the same" has mount.log "-o ro,nosuid,nodev,uid=1234,gid=4321,vol=0"
check "  ... no readwrite option, ever" bash -c '! grep -qE "readwrite|-o rw" "$1"' _ "$R/mount.log"
: > "$R/mount.log"
mapfs /dev/sdz2 "$(MEDIA)/$UUID_DIR" -f -o nosuid
check "-f (fake): exit 0, nothing mounted" bash -c '[ "$1" = 0 ] && ! test -s "$2"' _ "$RC" "$R/mount.log"
mapfs /dev/sdz2
check "no folder: exit 1 (usage), nothing mounted" bash -c '[ "$1" = 1 ] && ! test -s "$2"' _ "$RC" "$R/mount.log"
mapfs /dev/sdz2 "$R/nowhere" -o nosuid
check "a folder that does not exist: exit 1, nothing mounted" bash -c '[ "$1" = 1 ] && ! test -s "$2"' _ "$RC" "$R/mount.log"
FAKE_EUID_T=1000 mapfs /dev/sdz2 "$(MEDIA)/$UUID_DIR" -o nosuid
check "not run as root: exit 32, nothing mounted" bash -c '[ "$1" = 32 ] && ! test -s "$2"' _ "$RC" "$R/mount.log"
sig sdz2 TYPE=ext4
mapfs /dev/sdz2 "$(MEDIA)/$UUID_DIR" -o nosuid
check "no APFS signature on the partition: exit 32, nothing mounted" bash -c '[ "$1" = 32 ] && ! test -s "$2"' _ "$RC" "$R/mount.log"
new_root fs-fuse
with_fuse
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; volume_single sdz2 Mac
mkdir -p "$(MEDIA)/$UUID_DIR"
LANGUAGE_T=pt_BR LANG_T=pt_BR.UTF-8 mapfs /dev/sdz2 "$(MEDIA)/$UUID_DIR" -o nosuid,nodev
check "only apfs-fuse: exit 32, never mounted with FUSE (UDisks could not see it)" bash -c '[ "$1" = 32 ] && ! test -s "$2" && ! test -s "$3"' _ "$RC" "$R/apfs-fuse.log" "$R/mount.log"
check "  ... says which package, and bigmount --open-apfs, in English for the journal" bash -c 'grep -q linux-apfs-rw-dkms "$1" && grep -q -- "--open-apfs /dev/sdz2" "$1"' _ "$R/err"
new_root fs-enc
with_kernel; ln -sf "$STUBS/apfsutil" "$R/bin/apfsutil"
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs; ENC=Yes volumes_catalina sdz2
mkdir -p "$(MEDIA)/$UUID_DIR"
mapfs /dev/sdz2 "$(MEDIA)/$UUID_DIR" -o nosuid,nodev
check "encrypted Data volume: exit 32, not mounted (it would be garbage)" bash -c '[ "$1" = 32 ] && ! test -s "$2"' _ "$RC" "$R/mount.log"
check "  ... says to open it with bigmount --open-apfs" bash -c 'grep -q "encrypted" "$1" && grep -q -- "--open-apfs /dev/sdz2" "$1"' _ "$R/err"

begin "translations"
new_root i18n
part sdz2 sdz apfs "" "$APFS_GUID"; sig sdz2 TYPE=apfs
LANGUAGE_T=pt_BR LANG_T=pt_BR.UTF-8 bm --open-apfs /dev/sdz2
check "pt_BR: the person reads Portuguese" grep -q "nenhum driver APFS" "$R/err"
LANGUAGE_T=pt_BR LANG_T=pt_BR.UTF-8 bm --help
check "pt_BR: --help" grep -q "somente leitura" "$R/out"

begin "safety of the code"
code() { grep -nE "$1" "$REPO/big-mount/usr/lib/big-mount/apfs.sh" | grep -vE '^[0-9]+:[[:space:]]*#'; }
check "apfs.sh never gives readwrite, rw, -l, -r or pass= to a driver" bash -c '! grep -nE "readwrite|apfs-fuse .*(-l|-r)\b|pass=|-o \"?rw" "$1" | grep -vE "^[0-9]+:[[:space:]]*#" | grep -v "never given"' _ "$REPO/big-mount/usr/lib/big-mount/apfs.sh"
check "apfs.sh runs no repair, check, format or erase tool" bash -c '! grep -nE "(^|[[:space:]])(apfsck|mkapfs|fsck|mkfs|wipefs|dd|blkdiscard|fstrim|sgdisk|parted|fdisk|hdparm)[[:space:]]" "$1" | grep -vE "^[0-9]+:[[:space:]]*#"' _ "$REPO/big-mount/usr/lib/big-mount/apfs.sh"
check "no forced or lazy unmount, no kill" bash -c '! grep -nE "umount[[:space:]]+-[a-zA-Z]*[fl]|kill " "$1" | grep -vE "^[0-9]+:[[:space:]]*#"' _ "$REPO/big-mount/usr/lib/big-mount/apfs.sh"
check "the file manager is never started as root" bash -c 'grep -A3 "^apfs_open_folder()" "$1" | grep -q "\[ \"\$EUID\" -ne 0 \] || return 1"' _ "$REPO/big-mount/usr/lib/big-mount/apfs.sh"

begin "real driver: apfs-fuse on a scratch APFS image"
if [ -n "${APFS_FUSE_BUILD:-}" ] && [ -x "${APFS_FUSE_BUILD}/apfs-fuse" ] && [ -x "${MKAPFS:-}" ] && [ -e /dev/fuse ] && command -v fusermount3 >/dev/null; then
    REAL_MOUNTS=/proc/mounts new_root real
    img="$R/mac.img"
    truncate -s 64M "$img" && "$MKAPFS" -L "Dados Mac ç" "$img" >/dev/null
    sum_before="$(sha256sum < "$img")"
    printf '%s' "$img" > "$R/real-image"; printf '%s' "$APFS_FUSE_BUILD" > "$R/real-bin"
    with_fuse
    part sdz2 sdz apfs "Basic data partition" "$APFS_GUID"
    bm --apfs-info /dev/sdz2
    check "the real blkid -p finds the APFS signature, the real apfsutil the volume" bash -c '[ "$1" = 0 ] && grep -q "Dados Mac ç" "$2"' _ "$RC" "$R/out"
    bm --open-apfs /dev/sdz2 --no-open
    mp="$(MEDIA)/Dados Mac ç"
    check "mounted by the real apfs-fuse (exit 0)" test "$RC" = 0
    check "  ... the kernel lists it read-only, as fuse.apfs-fuse" bash -c 'awk -v m="$(printf "%s" "$1" | sed "s/ /\\\\\\\\040/g")" "\$2 == m { print \$3, \$4 }" /proc/mounts | grep -q "^fuse.apfs-fuse ro,"' _ "$mp"
    check "  ... its files are the person's (uid of the caller)" test "$(stat -c %u "$mp/root" 2>/dev/null)" = "$(id -u)"
    check "  ... the folder printed is the volume root, readable" bash -c '[ "$(cat "$1")" = "$2/root" ] && ls "$2/root" >/dev/null' _ "$R/out" "$mp"
    check "  ... writing is refused by the kernel (read-only filesystem)" bash -c '! touch "$1/root/x" 2>/dev/null && ! mkdir "$1/root/d" 2>/dev/null' _ "$mp"
    bm --close-apfs "$mp"
    check "closed: nothing mounted, folder removed, no apfs-fuse left running" bash -c '! grep -qF "$1" /proc/mounts && [ ! -e "$1" ] && ! pgrep -f "[a]pfs-fuse.*$2" >/dev/null' _ "$mp" "$img"
    check "the image is byte for byte what mkapfs made" test "$(sha256sum < "$img")" = "$sum_before"
else
    skip "set APFS_FUSE_BUILD (apfs-fuse, apfsutil) and MKAPFS to run it"
fi

echo ""
echo "========================================="
echo "APFS result: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
