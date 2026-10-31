#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329,SC2218,SC2030,SC2031,SC2178,SC2319  # bash -c '...$1' snippets, helpers called through check(), library functions replaced by stubs later on
# Unit tests for /usr/lib/big-mount (diagnosis decisions, process policy,
# escaping, parsing). System facts are replaced by shell functions that
# shadow the real helpers, so nothing on the machine is read or changed,
# except for one throw-away `sleep` process started by the tests themselves.
#
# Usage: tests/lib-tests.sh

set -u
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
BIGMOUNT_LIB="$REPO/big-mount/usr/lib/big-mount"
# shellcheck source=../big-mount/usr/lib/big-mount/cli.sh
. "$BIGMOUNT_LIB/cli.sh"
# shellcheck disable=SC2034  # read by bm_ui_init
BM_UI="tty"
bm_ui_init

PASS=0 FAIL=0 FAILED=()
check() {
    local msg="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$msg"
    else FAIL=$((FAIL + 1)); FAILED+=("$msg"); printf '  \033[31m✗\033[0m %s\n' "$msg"; fi
}
eq() { [ "$1" = "$2" ] || { printf '      got: [%s]\n expected: [%s]\n' "$1" "$2"; return 1; }; }
begin() { echo "— $1"; }

WORK="$(mktemp -d)"
# Not /tmp: it is often mounted noexec, and the stand-in dialog must run
EXE="$(mktemp -d -p "${TMPDIR:-/var/tmp}")"
ORIG_HOME="$HOME"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK" "$EXE"' EXIT

# ----- fake facts for bm_diagnose_write ----------------------------------------
# fake DEV MP FSTYPE MOUNTTYPE VFSOPTS FSOPTS [PART_RO] [DISK_RO]
fake() {
    F=([NAME]="$1" [KNAME]="${1##*/}" [DISK]="/dev/sdz" [FSTYPE]="$3" [RO]="${7:-0}" [DISK_RO]="${8:-0}")
    FAKE_MP="$2" FAKE_TYPE="$4" FAKE_VFS="$5" FAKE_FS="$6"
    FAKE_KMSG=() FAKE_BOOT="" FAKE_FSTAB=0 FAKE_NTFS_FALLBACK=1
}
bm_mounts() {
    M_TARGET=() M_FSTYPE=() M_VFSOPT=() M_FSOPT=()
    [ -n "$FAKE_MP" ] || return 0
    M_TARGET=("$FAKE_MP") M_FSTYPE=("$FAKE_TYPE") M_VFSOPT=("$FAKE_VFS") M_FSOPT=("$FAKE_FS")
}
bm_kernel_messages() { KMSG=("${FAKE_KMSG[@]}"); }
bm_boot_status() { REPLY="$FAKE_BOOT"; [ -n "$FAKE_BOOT" ]; }
bm_ntfs3g_fallback() { return "$FAKE_NTFS_FALLBACK"; }
findmnt() { [ "$1" = --fstab ] && return $((1 - FAKE_FSTAB)); command findmnt "$@"; }

mkdir -p "$WORK/rw" "$WORK/locked" "$WORK/os/@/etc" "$WORK/win/Windows/System32" "$WORK/media/run/media/u/X"
touch "$WORK/os/@/etc/os-release"
chmod 555 "$WORK/locked"
RUNMEDIA="$WORK/media/run/media/u/X"

diag() { bm_diagnose_write "${F[NAME]}"; }

echo "========================================="
echo "Library unit tests"
echo "========================================="

begin "read-only causes (docs/04-read-only-diagnostics.md)"
fake /dev/sdz1 "$WORK/rw" ext4 ext4 rw,relatime rw; diag
check "writable -> ok" eq "$D_CAUSE" ok
fake /dev/sdz1 "" ext4 "" "" ""; diag
check "not mounted -> not-mounted" eq "$D_CAUSE" not-mounted
fake /dev/sdz1 "$WORK/rw" vfat vfat ro ro 1; diag
check "partition ro flag -> hw-readonly (E)" eq "$D_CAUSE" hw-readonly
fake /dev/sdz1 "$WORK/rw" vfat vfat ro ro 0 1; diag
check "disk ro flag -> hw-readonly (E)" eq "$D_CAUSE" hw-readonly
check "E: no fix" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/rw" hfsplus hfsplus ro ro; diag
check "journaled HFS+ -> unsupported (G)" eq "$D_CAUSE" unsupported
fake /dev/sdz1 "$WORK/rw" ntfs ntfs ro ro; diag
check "legacy read-only ntfs driver -> unsupported (G)" eq "$D_CAUSE" unsupported
fake /dev/sdz1 "$WORK/rw" ntfs fuseblk ro,nosuid ro; FAKE_NTFS_FALLBACK=0; diag
check "NTFS read-only -> ntfs-unsafe (D)" eq "$D_CAUSE" ntfs-unsafe
check "D: driver fallback recorded" eq "${D_DETAIL%%:*}" ntfs-3g
check "D: never offers a fix" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/rw" ntfs fuseblk ro ro; FAKE_BOOT="ro ntfs-hibernated"; diag
check "D: reason from the boot status" eq "$D_DETAIL" "big-mount: ntfs-hibernated"
fake /dev/sdz1 "" ntfs "" "" ""; FAKE_BOOT="failed ntfs-inconsistent"; diag
check "NTFS that big-mount could not mount -> ntfs-unsafe" eq "$D_CAUSE" ntfs-unsafe
fake /dev/sdz1 "$WORK/rw" ext4 ext4 ro ro,errors=remount-ro
FAKE_KMSG=("EXT4-fs (sdz1): Remounting filesystem read-only"); diag
check "kernel remounted read-only -> fs-errors (C)" eq "$D_CAUSE" fs-errors
check "C: never offers to remount" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/rw" btrfs btrfs ro ro
FAKE_KMSG=("BTRFS error (device sdz1 state EA): forced readonly"); diag
check "btrfs forced readonly -> fs-errors (C)" eq "$D_CAUSE" fs-errors
fake /dev/sdz1 "$WORK/rw" exfat exfat ro ro
FAKE_KMSG=("I/O error, dev sdz, sector 2048 op 0x1:(WRITE)"); diag
check "I/O errors -> io-errors (F)" eq "$D_CAUSE" io-errors
check "F: no fix" eq "$D_FIX" ""
fake /dev/sdz1 /run/media/u/X ext4 ext4 ro,nosuid ro; diag
check "clean, mounted ro -> mounted-ro (A)" eq "$D_CAUSE" mounted-ro
check "A: remount offered for a UDisks mount" eq "$D_FIX" remount
fake /dev/sdz1 /run/media/u/X ext4 ext4 ro,nosuid ro; FAKE_FSTAB=1; diag
check "A: fstab entry -> never remounted behind the admin's back" eq "$D_FIX" ""
fake /dev/sdz1 "$RUNMEDIA" ext4 ext4 ro ro; diag
check "A: mount made by someone else (not UDisks) -> no fix" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/locked" ext4 ext4 rw rw; diag
check "rw but root folder not ours -> permission (B)" eq "$D_CAUSE" permission
check "B: take ownership offered" eq "$D_FIX" take-ownership
fake /dev/sdz1 "$WORK/os" btrfs btrfs rw rw
chmod 555 "$WORK/os"; diag; chmod 755 "$WORK/os"
check "B on a Btrfs install (@/etc/os-release) -> no fix" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/win" ext4 ext4 rw rw
chmod 555 "$WORK/win"; diag; chmod 755 "$WORK/win"
check "B on a Windows partition -> no fix" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/locked" vfat vfat rw,uid=1234 rw; diag
check "FAT mounted for another uid -> permission-other-user" eq "$D_CAUSE" permission-other-user
fake /dev/sdz1 "$WORK/rw" ext4 ext4 rw rw; diag
check "ok has no fix" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/rw" ext4 ext4 rw rw; bm_diagnose_write /dev/sdz1 "$WORK/locked"
check "a folder of someone else inside a writable mount -> permission-folder" eq "$D_CAUSE" permission-folder
check "  ... judged at that folder, not at the mount root" eq "$D_PATH" "$WORK/locked"
check "  ... never offers to change owners there" eq "$D_FIX" ""
fake /dev/sdz1 "$WORK/rw" ext4 ext4 rw rw; bm_diagnose_write /dev/sdz1 "$WORK/rw"
check "a writable folder -> ok" eq "$D_CAUSE" ok
fake /dev/sdz1 / ext4 ext4 rw rw
if [ -w / ]; then echo "  (skipped: / is writable here)"; else
    diag
    check "the running system's root -> system, no fix" eq "$D_CAUSE:$D_FIX" "system:"
fi
fake /dev/sdz2 "" swap "" "" ""; diag
check "swap partition -> swap" eq "$D_CAUSE" swap
unset -f bm_mounts bm_kernel_messages bm_boot_status bm_ntfs3g_fallback findmnt
# shellcheck source=../big-mount/usr/lib/big-mount/lib.sh
# shellcheck source=../big-mount/usr/lib/big-mount/lib.sh
. "$BIGMOUNT_LIB/lib.sh"

begin "process policy (docs/06-safe-removal.md)"
H_PID=(10 11 12 13 14 15 16) H_UID=("$EUID" "$EUID" "$EUID" "$EUID" 0 "$EUID" "$EUID")
H_COMM=(dolphin kioworker bash plasmashell udisksd sleep rsync)
H_ACCESS=(r r "" r r "" w)
bm_close_refusal 0; check "own reader (dolphin) can be closed" eq "$REPLY" ""
bm_close_refusal 1; check "own kioworker can be closed" eq "$REPLY" ""
bm_close_refusal 2; check "shell: never closed, user is told to cd" eq "${REPLY:0:10}" "a terminal"
bm_close_refusal 3; check "desktop session process: never closed" eq "$REPLY" "part of the desktop session"
bm_close_refusal 4; check "other user's/system process: never closed" eq "$REPLY" "belongs to another user or to the system"
bm_close_refusal 6; check "writer (rsync): never closed" eq "${REPLY:0:12}" "has a file o"
H_PID+=(10) H_UID+=("$EUID") H_COMM+=(dolphin) H_ACCESS+=(u)
bm_close_refusal 0; check "process with ANY file open for writing is kept" eq "${REPLY:0:12}" "has a file o"

sleep 300 & SPID=$!
bm_proc_state "$SPID"; SSTART="$PROC_START"
bm_close_processes "$SPID" "$((SSTART + 1))"
check "pid reused (start time differs): not signalled" kill -0 "$SPID"
bm_close_processes 1 0
check "pid 1 is never signalled" test -d /proc/1
bm_close_processes "$SPID" "$SSTART"
check "same process: asked to exit with SIGTERM" bash -c '! kill -0 "$1" 2>/dev/null' _ "$SPID"
wait "$SPID" 2>/dev/null; rc=$?
check "it ended by SIGTERM (143), never SIGKILL (137)" eq "$rc" 143

begin "unmount: the mount table is the judge (docs/06-safe-removal.md)"
FAKE_TABLE=("/run/media/u/X")
bm_mounts() { M_TARGET=("${FAKE_TABLE[@]}"); M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); }
bm_udisks() { UD_CALLS+=("$*"); UD_ERROR="$FAKE_UD_ERROR"; UD_MESSAGE="fake"; [ -n "$FAKE_UNMOUNTS" ] && FAKE_TABLE=(); [ -z "$FAKE_UD_ERROR" ]; }
FAKE_UD_ERROR="org.freedesktop.UDisks2.Error.NotMounted" FAKE_UNMOUNTS=1 UD_CALLS=()
bm_unmount_all /dev/sdz1; check "mount vanished meanwhile (NotMounted) -> success" eq "$?" 0
FAKE_TABLE=("/run/media/u/X") FAKE_UD_ERROR="" FAKE_UNMOUNTS="" UD_CALLS=()
bm_unmount_all /dev/sdz1; rc=$?
check "udisks says ok but the mount stays -> failure" eq "$rc" 1
check "  ... with an explicit reason" eq "$UD_ERROR" still-mounted
check "  ... and a bounded number of attempts" eq "${#UD_CALLS[@]}" 8
FAKE_TABLE=("/run/media/u/X") FAKE_UD_ERROR="org.freedesktop.UDisks2.Error.DeviceBusy" FAKE_UNMOUNTS=""
bm_unmount_all /dev/sdz1; check "busy stays busy" eq "$UD_ERROR" org.freedesktop.UDisks2.Error.DeviceBusy
unset -f bm_mounts bm_udisks
. "$BIGMOUNT_LIB/lib.sh"

begin "safe removal protections"
# A removable drive sdz with two partitions (+ a LUKS one) simulated end to end
fake_drive() {
    FAKE_SEQ=(7) MOUNTED=([/dev/sdz1]=/run/media/u/A [/dev/sdz2]=/run/media/u/B) BUSY_ON="" CALLS=() HOLDERS=""
}
bm_facts() { F=([NAME]="$1" [DISK]=/dev/sdz [DISK_TYPE]=disk [TRAN]=usb [HOTPLUG]=1 [RM]=0 [FSTYPE]=ext4); }
bm_system_use() { return 1; }
bm_drive_members() { DRIVE_DEVS=(/dev/sdz /dev/sdz1 /dev/sdz2 /dev/sdz3) DRIVE_FSTYPES=("" ext4 vfat crypto_LUKS); }
bm_diskseq() { REPLY="${FAKE_SEQ[0]}"; [ "${#FAKE_SEQ[@]}" -gt 1 ] && FAKE_SEQ=("${FAKE_SEQ[@]:1}"); }
bm_mounts() { M_TARGET=() M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); [ -n "${MOUNTED[$1]:-}" ] && M_TARGET=("${MOUNTED[$1]}"); }
bm_has_holders() { [[ " $HOLDERS " == *" $1 "* ]]; }
bm_other_holders() { O_KIND=() O_WHAT=(); }
declare -A DEPS_ON=()
bm_mount_dependents() { DEP_UNITS=() DEP_NAMES=(); [ -n "${DEPS_ON[$1]:-}" ] && DEP_UNITS=("${DEPS_ON[$1]}") DEP_NAMES=("Photo server"); return 0; }
udevadm() { :; }
sleep() { :; }
bm_udisks() {
    CALLS+=("$*"); UD_ERROR="" UD_MESSAGE=""
    local dev="${*: -1}"
    case "$1" in
        unmount) if [ "$dev" = "$BUSY_ON" ]; then UD_ERROR=org.freedesktop.UDisks2.Error.DeviceBusy; return 1; fi; unset "MOUNTED[$dev]" ;;
        lock) HOLDERS="${HOLDERS/$dev/}" ;;
    esac
    return 0
}
declare -A MOUNTED
called() { [[ " ${CALLS[*]} " == *" $1 "* ]]; }

fake_drive
bm_remove_core remove /dev/sdz1; rc=$?
check "two partitions unmounted, then powered off" eq "$rc:$RM_POWERED" "0:1"
check "power-off came after both unmounts" eq "${CALLS[*]}" "unmount -b /dev/sdz2 unmount -b /dev/sdz1 power-off -b /dev/sdz"

fake_drive; BUSY_ON=/dev/sdz1
bm_remove_core remove /dev/sdz1; rc=$?
check "partial failure (second partition busy) -> busy" eq "$rc" 3
check "  ... and the drive is NOT powered off" bash -c '[[ $1 != *power-off* ]]' _ "${CALLS[*]}"

fake_drive; FAKE_SEQ=(7 7 9)
bm_remove_core remove /dev/sdz1; rc=$?
check "device replaced between two steps -> stop" eq "$rc" 1
check "  ... the reason says so" bash -c '[[ $1 == *replaced* ]]' _ "$RM_REASON"
check "  ... nothing done to the new device" eq "${#CALLS[@]}" 1

fake_drive
bm_udisks() { CALLS+=("$*"); UD_ERROR=""; [ "$1" = unmount ] && unset "MOUNTED[${*: -1}]"; [ "$1" = unmount ] && [ "${*: -1}" = /dev/sdz1 ] && MOUNTED[/dev/sdz2]=/run/media/u/B2; return 0; }
bm_remove_core remove /dev/sdz1; rc=$?
check "a partition mounted again meanwhile -> no success" eq "$rc" 1
check "  ... and no power-off" bash -c '[[ $1 != *power-off* ]]' _ "${CALLS[*]}"

fake_drive; HOLDERS="/dev/sdz3"
bm_udisks() { CALLS+=("$*"); UD_ERROR=""; case "$1" in unmount) unset "MOUNTED[${*: -1}]" ;; lock) HOLDERS="" ;; esac; return 0; }
bm_remove_core remove /dev/sdz1; rc=$?
check "open LUKS volume is locked before the power-off" eq "${CALLS[*]: -2}" "lock -b /dev/sdz3 power-off -b /dev/sdz"
check "  ... and the removal succeeds" eq "$rc" 0

fake_drive
bm_facts() { F=([NAME]="$1" [DISK]=/dev/sda [DISK_TYPE]=disk [TRAN]=sata [HOTPLUG]=0 [RM]=0 [FSTYPE]=ext4); }
bm_remove_core remove /dev/sdz1; rc=$?
check "internal disk: unmounted, never powered off" eq "$rc:$RM_POWERED" "0:0"
check "  ... no power-off request at all" bash -c '[[ $1 != *power-off* ]]' _ "${CALLS[*]}"

bm_facts() { F=([NAME]="$1" [DISK]=/dev/sdz [DISK_TYPE]=disk [TRAN]=usb [HOTPLUG]=1 [RM]=0 [FSTYPE]=ext4); }
fake_drive; DEPS_ON=([/run/media/u/B]=photos.service); RM_ALLOW_SERVICES=0
bm_remove_core remove /dev/sdz1; rc=$?
check "a service bound to a mount -> asks first (9)" eq "$rc" 9
check "  ... names the service" eq "${RM_DEP_UNITS[*]}:${RM_DEP_NAMES[*]}" "photos.service:Photo server"
check "  ... and nothing was unmounted" eq "${#CALLS[@]}" 0
fake_drive; RM_ALLOW_SERVICES=1
bm_remove_core remove /dev/sdz1; rc=$?
check "after the user agrees -> removed" eq "$rc:$RM_POWERED" "0:1"
DEPS_ON=() RM_ALLOW_SERVICES=0

fake_drive
bm_udisks() {
    CALLS+=("$*"); UD_ERROR="" UD_MESSAGE=""
    case "$1" in
        unmount) unset "MOUNTED[${*: -1}]" ;;
        power-off) UD_ERROR=org.freedesktop.UDisks2.Error.Failed UD_MESSAGE="GDBus.Error:org.freedesktop.UDisks2.Error.Failed: Error powering off drive: target is busy"; return 1 ;;
    esac
    return 0
}
bm_remove_core remove /dev/sdz1; rc=$?
check "power-off keeps failing after the unmount -> 8 (not 7)" eq "$rc" 8
check "  ... after three attempts" eq "$(printf '%s\n' "${CALLS[@]}" | grep -c power-off)" 3
check "  ... with the reason from UDisks, without the D-Bus prefix" eq "$RM_REASON" "target is busy"
fake_drive
bm_udisks() { CALLS+=("$*"); UD_ERROR="" UD_MESSAGE=""; case "$1" in unmount) unset "MOUNTED[${*: -1}]" ;; power-off) UD_ERROR=org.freedesktop.UDisks2.Error.NotSupported UD_MESSAGE="No usb device"; return 1 ;; esac; return 0; }
bm_remove_core remove /dev/sdz1; rc=$?
check "drive that cannot be powered off -> 7, at once" eq "$rc:$(printf '%s\n' "${CALLS[@]}" | grep -c power-off)" "7:1"
fake_drive; POWER_TRIES=0
bm_udisks() { CALLS+=("$*"); UD_ERROR="" UD_MESSAGE=""; case "$1" in unmount) unset "MOUNTED[${*: -1}]" ;; power-off) POWER_TRIES=$((POWER_TRIES + 1)); [ "$POWER_TRIES" -ge 2 ] && return 0; UD_ERROR=org.freedesktop.UDisks2.Error.Failed; return 1 ;; esac; return 0; }
bm_remove_core remove /dev/sdz1; rc=$?
check "power-off that succeeds on the second attempt -> success" eq "$rc:$RM_POWERED" "0:1"
fake_drive
bm_udisks() { CALLS+=("$*"); UD_ERROR="" UD_MESSAGE=""; [ "$1" = unmount ] && { UD_ERROR="no-object"; UD_MESSAGE="Error looking up object for device ${*: -1}"; return 1; }; return 0; }
bm_remove_core remove /dev/sdz1; rc=$?
check "device unknown to UDisks2 during the unmount -> stop, marked as gone" eq "$rc:$RM_GONE" "1:1"
check "  ... in plain words, not the udisksctl message" bash -c '[[ $1 == *disconnected* && $1 != *"looking up"* ]]' _ "$RM_REASON"
check "  ... and no power-off" bash -c '[[ $1 != *power-off* ]]' _ "${CALLS[*]}"
fake_drive; FAKE_SEQ=(7 "")
bm_udisks() { CALLS+=("$*"); UD_ERROR=""; [ "$1" = unmount ] && unset "MOUNTED[${*: -1}]"; return 0; }
bm_remove_core remove /dev/sdz1; rc=$?
check "drive unplugged between two steps (no diskseq any more) -> gone" eq "$rc:$RM_GONE" "1:1"
fake_drive
bm_facts() { return 1; }
bm_remove_core remove /dev/sdz1; rc=$?
check "device unknown from the start -> gone, nothing called" eq "$rc:$RM_GONE:${#CALLS[@]}" "1:1:0"
bm_facts() { F=([NAME]="$1" [DISK]=/dev/sdz [DISK_TYPE]=disk [TRAN]=usb [HOTPLUG]=1 [RM]=0 [FSTYPE]=ext4); }
unset -f fake_drive bm_facts bm_system_use bm_drive_members bm_diskseq bm_mounts bm_has_holders bm_other_holders bm_udisks bm_mount_dependents udevadm sleep
. "$BIGMOUNT_LIB/lib.sh"

begin "services bound to a mount point (systemd)"
systemctl() {
    case "$1" in
        list-dependencies) printf '%s\n' photos.service other.service default.target ;;
        show) case "${*: -1}" in
            photos.service) printf '%s\n' 'BindsTo="run-media-u-My\\x20Disk.mount"' 'Requires=sysinit.target' \
                'WantedBy=multi-user.target' 'ActiveState=active' 'Description=Photo server' ;;
            other.service) printf '%s\n' 'BindsTo=run-media-u-Other.mount' 'WantedBy=run-media-u-Other.mount multi-user.target' \
                'ActiveState=active' 'Description=Other' ;;
        esac ;;
    esac
}
bm_mount_dependents "/run/media/u/My Disk"
check "a service with BindsTo= on the (escaped) mount unit is found" eq "${DEP_UNITS[*]}" photos.service
check "  ... with its description" eq "${DEP_NAMES[*]}" "Photo server"
check "  ... and not started again with the mount" eq "${DEP_BACK[*]}" 0
RM_DEP_BACK=(0); bm_dep_restart_text
check "  ... which the user is told" bash -c '[[ $1 == *"do not start again"* ]]' _ "$REPLY"
bm_mount_dependents /run/media/u/Other
check "WantedBy= the mount -> systemd starts it again" eq "${DEP_UNITS[*]}:${DEP_BACK[*]}" "other.service:1"
RM_DEP_BACK=(1); bm_dep_restart_text
check "  ... which the user is told" bash -c '[[ $1 == *"start again by themselves when"* ]]' _ "$REPLY"
bm_mount_dependents /run/media/u/Nothing
check "no service bound -> none" eq "${#DEP_UNITS[@]}" 0
unset -f systemctl

begin "FUSE drivers finish writing before the drive is powered off"
FAKE_TABLE=("/run/media/u/N")
bm_mounts() { M_TARGET=("${FAKE_TABLE[@]}"); M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); }
bm_udisks() { FAKE_TABLE=(); UD_ERROR=""; return 0; }
fake_fuse() { bash -c 'printf mount.ntfs-3g > /proc/$$/comm; sleep "$2"; true' _ /dev/fakez9 "$1" & FUSE_PID=$!; command sleep 0.2; }
fake_fuse 1.5
bm_fuse_daemons /dev/fakez9
check "the FUSE daemon of the device is recognized" eq "${FUSE_PIDS[*]}" "$FUSE_PID"
bm_fuse_daemons /dev/fakez
check "  ... never the one of a similar name" eq "${#FUSE_PIDS[@]}" 0
bash -c 'printf mount.lowntfs-3g > /proc/$$/comm; sleep 1; true' _ /dev/fakez8 & LOW_PID=$!; command sleep 0.2
bm_fuse_daemons /dev/fakez8
check "  ... also with a name longer than the 15 characters of comm" eq "${FUSE_PIDS[*]}" "$LOW_PID"
wait "$LOW_PID"
bm_unmount_all /dev/fakez9; rc=$?
check "unmount returns only after the daemon exited" bash -c '[ "$1" = 0 ] && ! kill -0 "$2" 2>/dev/null' _ "$rc" "$FUSE_PID"
wait "$FUSE_PID" 2>/dev/null
FAKE_TABLE=("/run/media/u/N"); fake_fuse 3
BM_FUSE_WAIT=1 bm_unmount_all /dev/fakez9; rc=$?
check "daemon still running after the limit -> failure, still-writing" eq "$rc:$UD_ERROR" "1:still-writing"
kill "$FUSE_PID" 2>/dev/null; wait "$FUSE_PID" 2>/dev/null
unset -f bm_mounts bm_udisks fake_fuse
. "$BIGMOUNT_LIB/lib.sh"

begin "safe removal in dialogs: services are stopped only after consent"
bm_resolve() { R_DEV=/dev/sdz1; }
bm_facts() { F=([NAME]=/dev/sdz1 [LABEL]=X [FSTYPE]=ntfs [DISK]=/dev/sdz); }
bm_remove_core() {
    CORE_CALLS+=("$RM_ALLOW_SERVICES")
    if [ "$RM_ALLOW_SERVICES" != 1 ]; then RM_DEP_UNITS=(photos.service) RM_DEP_NAMES=("Photo server") RM_DEP_BACK=(1); return 9; fi
    RM_POWERED=1; return 0
}
bm_notify() { printf '%s\n' "$3" >> "$WORK/gn.log"; }  # runs in the background
CONFIRM=1; bm_ui_confirm_risky() { CONFIRM_TITLE="$1"; return "$CONFIRM"; }
CORE_CALLS=() RM_ALLOW_SERVICES=1; : > "$WORK/gn.log"
bm_gui_remove /dev/sdz1; rc=$?
check "Cancel: nothing stopped, nothing removed" eq "${CORE_CALLS[*]}:$(cat "$WORK/gn.log")" "0:"
check "  ... the consent of an earlier removal is not reused" eq "${CORE_CALLS[0]}" 0
check "  ... the dialog names the problem" eq "$CONFIRM_TITLE" "Services use this device"
CONFIRM=0 CORE_CALLS=(); : > "$WORK/gn.log"
bm_gui_remove /dev/sdz1; rc=$?; wait
check "Stop them and remove: removal goes on" eq "${CORE_CALLS[*]}:$rc" "0 1:0"
check "  ... and ends with Safe to disconnect" eq "$(cat "$WORK/gn.log")" "Safe to disconnect"
BM_GUI_NAME=X BM_GUI_SLOW_SHOWN=0; : > "$WORK/gn.log"
bm_gui_slow_notice; bm_gui_slow_notice; wait
check "the 'do not disconnect' notice is shown once per removal" eq "$(wc -l < "$WORK/gn.log")" 1
unset -f bm_resolve bm_facts bm_remove_core bm_notify bm_ui_confirm_risky
. "$BIGMOUNT_LIB/lib.sh"; . "$BIGMOUNT_LIB/ui.sh"; . "$BIGMOUNT_LIB/cli.sh"; BM_UI="tty"; bm_ui_init

begin "slow operations announce themselves after 2 s, without polling"
udisksctl() { sleep "$FAKE_DELAY"; }
slow_hook() { SLOW_CALLED=1; }
BM_SLOW_HOOK=slow_hook SLOW_CALLED=0 FAKE_DELAY=0.1; bm_udisks unmount -b /dev/x
check "fast unmount: no notice" eq "$SLOW_CALLED" 0
BM_SLOW_HOOK=slow_hook SLOW_CALLED=0 FAKE_DELAY=2.6; bm_udisks unmount -b /dev/x; rc=$?
check "slow unmount: one notice" eq "$SLOW_CALLED" 1
check "  ... and the real result is still returned" eq "$rc" 0
BM_SLOW_HOOK=""; unset -f udisksctl slow_hook

begin "notifications: one path, durations from one place"
notify-send() { printf 'notify-send %s\n' "$*" >> "$WORK/n.log"; }
: > "$WORK/n.log"; DBUS_SESSION_BUS_ADDRESS=fake BM_UI=gtk bm_notify info drive-harddisk "Safe to disconnect" "Pen <b>"
check "info: notify-send, 5000 ms, transient" grep -q -- "--expire-time 5000 --hint string:desktop-entry:big-mount --transient" "$WORK/n.log"
check "  ... body escaped" grep -q "Pen &lt;b&gt;" "$WORK/n.log"
check "  ... and never a second popup" eq "$(wc -l < "$WORK/n.log")" 1
: > "$WORK/n.log"; DBUS_SESSION_BUS_ADDRESS=fake bm_notify warning dialog-warning "Read-only device" "x" "details=View details" >/dev/null
check "warning: 15000 ms, kept in history, with actions" grep -q -- "--expire-time 15000 --hint string:desktop-entry:big-mount --action details=View details" "$WORK/n.log"
: > "$WORK/n.log"; out="$(DBUS_SESSION_BUS_ADDRESS="" BM_UI=gtk bm_notify info drive-harddisk "Safe to disconnect" "Pen" 2>&1)"
check "no session bus: plain text, no window instead" eq "$out" "Safe to disconnect: Pen"
check "  ... and no notification program started" test ! -s "$WORK/n.log"
notify-send() { return 1; }
out="$(DBUS_SESSION_BUS_ADDRESS=fake bm_notify info x $'Pen\e[2J' $'Body\nForged line' 2>&1)"
check "notify-send failed: the message goes to the terminal instead, on one line" eq "$out" "Pen?[2J: Body; Forged line"
unset -f notify-send
BM_UI="tty"

begin "dialogs: GTK, one answer from a person, the terminal when there is no window"
cat > "$EXE/fake-dialog" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
tr '\0' '|' >> "$FAKE_LOG"; echo >> "$FAKE_LOG"
n=$(($(cat "$FAKE_N" 2>/dev/null || echo 0) + 1)); echo "$n" > "$FAKE_N"
line="$(sed -n "${n}p" "$FAKE_ANSWERS")"
[ -n "$line" ] || exit 1
rc="${line%% *}"; out="${line#"$rc"}"; out="${out# }"
[ -n "$out" ] && printf '%s\n' "$out"
exit "$rc"
EOF
chmod +x "$EXE/fake-dialog"
dlg() { # ANSWER... : the answers the fake dialog gives, in order ("RC [OUTPUT]")
    printf '%s\n' "$@" > "$WORK/answers"; : > "$WORK/dlg.log"; rm -f "$WORK/dlg.n"
}
export FAKE_LOG="$WORK/dlg.log" FAKE_N="$WORK/dlg.n" FAKE_ANSWERS="$WORK/answers"
BM_UI=""; BM_DIALOG_PROGRAM="$EXE/fake-dialog" WAYLAND_DISPLAY=fake bm_ui_init
check "a graphical session uses the GTK dialogs" eq "$BM_UI" gtk
BM_UI=""; WAYLAND_DISPLAY="" DISPLAY="" bm_ui_init
check "no graphical session: the terminal" eq "$BM_UI" tty
BM_UI=gtk BM_DIALOG_PROGRAM="$EXE/fake-dialog"
bm_doc_new; bm_doc_h "Pen <b>x</b>"; bm_doc_kv "Device" $'/dev/sdz1\e[2J'
dlg "0"; bm_ui_show info "Title"
check "message: the document goes as data, kind and text" grep -qF "h|Pen <b>x</b>|kv|Device	/dev/sdz1" "$WORK/dlg.log"
check "  ... with its title" grep -q -- "^message --title=Title$" "$WORK/dlg.log"
dlg "0 yes"; bm_ui_confirm "T" "" "Open" "Close"; rc=$?
check "confirm: yes when the person says yes" eq "$rc" 0
check "  ... and yes is the default" grep -q -- "--button=no=Close --button=yes=Open --default=yes --cancel=no --suggested=yes" "$WORK/dlg.log"
dlg "0 no"; bm_ui_confirm "T" "" "Open" "Close"; rc=$?
check "confirm: no" eq "$rc" 1
dlg "1"; bm_ui_confirm "T" "" "Open" "Close"; rc=$?
check "confirm: a closed window is no" eq "$rc" 1
dlg "0 yes"; bm_ui_confirm_risky "T" "" "Close them" "Cancel"; rc=$?
check "risky: yes only when chosen" eq "$rc" 0
check "  ... the safe answer is the default, the other marked as risky" grep -q -- "--default=no --cancel=no --destructive=yes" "$WORK/dlg.log"
dlg "0 2"; bm_ui_choice "T" "" "Try again" "More" "Cancel"
check "choice: the second button" eq "$REPLY" 2
dlg "0 bogus"; bm_ui_choice "T" "" "Try again" "More" "Cancel"
check "choice: anything unexpected is cancel" eq "$REPLY" 3
dlg "0 admin"; bm_ui_menu "T" "Pick:" refresh "Refresh" admin "All users"
check "menu: the key of the item" eq "$REPLY" admin
check "  ... items as key=label, no document" grep -qxF "menu --title=T --text=Pick: --item=refresh=Refresh --item=admin=All users" "$WORK/dlg.log"
dlg "1"; bm_ui_menu "T" "Pick:" refresh "Refresh"
check "menu: closed is no choice" eq "$REPLY" ""
dlg "0 sdz"; bm_ui_input "T" "Type:"; rc=$?
check "input: the line typed" bash -c '[ "$1" = 0 ] && [ "$2" = sdz ]' _ "$rc" "$REPLY"
dlg "1"; bm_ui_input "T" "Type:"; rc=$?
check "input: cancel fails" eq "$rc" 1
dlg "25"; bm_doc_new; bm_doc_p "fallback text"; out="$(bm_ui_confirm "T" "" "Yes" "No" < /dev/null)"; rc=$?
check "no window after all: never a yes" eq "$rc" 1
check "  ... the text is still shown" grep -q "fallback text" <<< "$out"
dlg "25"; bm_ui_confirm "T" "" "Yes" "No" < /dev/null > /dev/null
check "  ... and the terminal is used from then on" eq "$BM_UI" tty
unset BM_DIALOG_PROGRAM
BM_UI="tty"

begin "administrator view leaves no file behind"
mkdir -p "$WORK/tmpdir"
printf 'p77\ncsecret-app\nu0\nLroot\nfcwd\na \ntDIR\nn/home/other/private\n' > "$WORK/priv.out"
pkexec() { cat "$WORK/priv.out"; }
bm_busy_collect() {
    BUSY_PID=() BUSY_PIDS=() BUSY_APP=() BUSY_COMM=() BUSY_FD=() BUSY_ACCESS=() BUSY_UID=() BUSY_USER=() BUSY_STATE=() BUSY_PATH=() O_KIND=() O_WHAT=() BUSY_COUNT=0
    if [ -n "${2:-}" ] && grep -q secret "$2"; then
        BUSY_PID=(77) BUSY_PIDS=(77) BUSY_APP=(secret-app) BUSY_COMM=(secret-app) BUSY_FD=(cwd) BUSY_ACCESS=("") BUSY_UID=(0) BUSY_USER=(root) BUSY_STATE=(S) BUSY_PATH=(/run/media/u/X) BUSY_COUNT=1
    fi
}
bm_facts() { F=([NAME]=/dev/sdz1 [LABEL]=X [FSTYPE]=ext4); }
bm_mounts() { M_TARGET=(/run/media/u/X) M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); }
bm_ui_text() { :; }
command() { [ "$2" = pkexec ] && return 0; builtin command "$@"; }
# More options, the list of all users, More options, technical details, Cancel
dlg "0 2" "0 admin" "0 2" "0 details" "0 3"
# A subshell on purpose: TMPDIR and BM_UI must not leak into the next tests
# shellcheck disable=SC2030
( export TMPDIR="$WORK/tmpdir" BM_DIALOG_PROGRAM="$EXE/fake-dialog"; BM_UI=gtk; bm_gui_busy_dialog /dev/sdz1 ) > /dev/null 2>&1
check "the privileged list was shown" grep -q "secret-app" "$WORK/dlg.log"
check "no temporary file left after the dialog" test -z "$(ls -A "$WORK/tmpdir")"
check "  ... after the technical details too, and Cancel ended it" eq "$(grep -cE "^(question|menu) " "$WORK/dlg.log")" 5
unset -f pkexec bm_busy_collect bm_facts bm_mounts bm_ui_text command
. "$BIGMOUNT_LIB/cli.sh"; BM_UI="tty"; bm_ui_init

begin "busy summary speaks plain language"
summary_for() { BUSY_PID=("$@") BUSY_PIDS=("$@"); }
O_KIND=() O_WHAT=()
BUSY_PID=(1) BUSY_PIDS=(1) BUSY_COMM=(dolphin) BUSY_APP=("Dolphin (file manager)") BUSY_FD=(12) BUSY_ACCESS=(r)
bm_busy_summary; check "file manager" eq "$BUSY_ADVICE" "Close the window or tab that shows the device, then try again."
BUSY_PID=(1 2) BUSY_PIDS=(1 2) BUSY_COMM=(dolphin bash) BUSY_APP=(Dolphin Shell) BUSY_FD=(12 cwd) BUSY_ACCESS=(r "")
bm_busy_summary; check "a terminal outranks the file manager" eq "$BUSY_SUMMARY" "A terminal is open in a folder of this device. In total, 2 programs are using it."
BUSY_PID=(1 2) BUSY_PIDS=(1 2) BUSY_COMM=(bash rsync) BUSY_APP=(Shell "Copy or archive operation") BUSY_FD=(cwd 4) BUSY_ACCESS=("" w)
bm_busy_summary; check "a writer outranks everything" eq "${BUSY_SUMMARY%%.*}" "Copy or archive operation has a file open for writing on this device"
BUSY_PID=(1) BUSY_PIDS=(1) BUSY_COMM=(sleep) BUSY_APP=(sleep) BUSY_FD=(cwd) BUSY_ACCESS=("")
bm_busy_summary; check "a non-terminal program in a folder is named, not called a terminal" eq "$BUSY_SUMMARY" "sleep is running inside a folder of this device."
BUSY_PID=(1 2) BUSY_PIDS=(1 2) BUSY_COMM=(vlc rsync) BUSY_APP=("Media player" "Copy or archive operation") BUSY_FD=(cwd 4) BUSY_ACCESS=("" w)
bm_busy_summary; check "a writer still outranks a program in a folder" eq "${BUSY_SUMMARY%%.*}" "Copy or archive operation has a file open for writing on this device"
BUSY_PID=() BUSY_PIDS=() O_KIND=(mount) O_WHAT=(/var/lib/os-prober/mount)
bm_busy_summary; check "no process, but the system holds it" eq "${BUSY_SUMMARY:0:22}" "No program is using it"
unset -f summary_for

begin "lsof field parsing"
cat > "$WORK/lsof" <<'EOF'
p4242
csleep
u1000
Luser
fcwd
a
tDIR
n/run/media/u/My Disk
f3
ar
tREG
n/run/media/u/My Disk/a b.txt
p4343
cbaloo_file
u1000
Luser
f12
aw
tREG
n/run/media/u/My Disk/.index
EOF
bm_holders "/run/media/u/My Disk" "$WORK/lsof"
check "three open files" eq "${#H_PID[@]}" 3
check "two processes" eq "${#H_PIDS[@]}" 2
check "cwd recorded" eq "${H_FD[0]}" cwd
check "path with spaces kept" eq "${H_PATH[1]}" "/run/media/u/My Disk/a b.txt"
check "access mode of writer" eq "${H_ACCESS[2]}" w
check "friendly name for baloo" eq "${H_APP[2]}" "Baloo file indexer"
bm_access_label cwd "" DIR; check "cwd label" eq "$REPLY" "Current folder is on the device"
bm_access_label 12 w REG; check "write label says open, not transferring" eq "$REPLY" "Open for writing"

begin "other holders (needs no root: findmnt and mounts are simulated)"
bm_mounts() { M_TARGET=("/mnt/Dados" "/var/lib/os-prober/mount") M_FSTYPE=(btrfs btrfs) M_VFSOPT=(rw rw) M_FSOPT=(rw rw); }
findmnt() { if [ "$*" = "-n -r -o TARGET -R -- /mnt/Dados" ]; then printf '%s\n' /mnt/Dados /mnt/Dados/inner; fi; }
bm_other_holders /dev/sdz1
check "second mount (os-prober leftover) reported" bash -c '[[ " $1 " == *" /var/lib/os-prober/mount "* ]]' _ "${O_WHAT[*]}"
check "nested mount reported" bash -c '[[ " $1 " == *" /mnt/Dados/inner "* ]]' _ "${O_WHAT[*]}"
unset -f bm_mounts findmnt
# shellcheck source=../big-mount/usr/lib/big-mount/lib.sh
. "$BIGMOUNT_LIB/lib.sh"
bm_main_mountpoint $'/var/lib/os-prober/mount\n/mnt/Dados'
check "os-prober leftover is not the main mount point" eq "$REPLY" /mnt/Dados
bm_main_mountpoint $'/var/log\n/home\n/'
check "system mount wins for the system disk" eq "$REPLY" /home

begin "untrusted text is escaped"
bm_doc_new; bm_doc_p $'evil\e[2J\e]0;title\a label'
bm_doc_render_text
check "terminal: escape sequences neutralised" bash -c '[[ $1 != *$'"'"'\e'"'"'* ]]' _ "$REPLY"
bm_unescape 'A\x22B \x24x\x5cy'
check "lsblk/findmnt \\xHH decoding" eq "$REPLY" 'A"B $x\y'
bm_parse_pairs 'NAME="/dev/sdd1" LABEL="Novo volume" MOUNTPOINTS="/a\x0a/b"'
check "pairs: value with space" eq "${KV[LABEL]}" "Novo volume"
check "pairs: multiple mount points" eq "${KV[MOUNTPOINTS]}" $'/a\n/b'

bm_doc_new; bm_doc_tr "App"$'\n'"comm" 42 "Open"
bm_doc_render_text
check "terminal: table keeps the second line of a cell" bash -c '[[ $1 == *"App  |  comm  |  42  |  Open"* ]]' _ "$REPLY"

begin "an empty target is refused (it must not mean the current folder)"
( cd / && bm_main --busy "" >/dev/null 2>&1 ); rc=$?
check "--busy '' exits 2" eq "$rc" 2

begin "dialogs never confirm on their own"
bm_doc_new
bm_ui_choice "t" "" A B C < /dev/null > /dev/null
check "three-button dialog without a user -> cancel" eq "$REPLY" 3
if bm_ui_confirm t "" Yes No < /dev/null > /dev/null; then r=0; else r=1; fi
check "yes/no dialog without a user -> no" eq "$r" 1

begin "small helpers"
bm_human_size 2000398934016; check "2 TB" eq "$REPLY" "2 TB"
bm_human_size 67108864; check "67.1 MB" eq "$REPLY" "67.1 MB"
bm_human_size 512; check "512 B" eq "$REPLY" "512 B"
bm_is_system_mount /home && r=0 || r=1; check "/home is a system mount" eq "$r" 0
bm_is_system_mount /run/media/u/X && r=0 || r=1; check "/run/media/... is not" eq "$r" 1
bm_opt_value "rw,uid=1000,gid=1007" uid; check "option value" eq "$REPLY" 1000

begin "targets are validated, never guessed from a name (field report: /dev/nvme)"
bm_resolve /dev/nvme; rc=$?
check "/dev/nvme (a name cut at the first digit) is refused" eq "$rc:$R_ERR" "1:missing"
bm_resolve_message /dev/nvme
check "  ... with an explanation, not a technical error" bash -c '[[ $1 == *"does not exist"*disconnected* ]]' _ "$REPLY"
bm_resolve /dev/null; check "a character device is not storage" eq "$R_ERR" not-block
bm_resolve /proc/self; check "a folder on a filesystem without a device" eq "$R_ERR" not-local
bm_resolve ""; check "an empty target" eq "$R_ERR" empty
ctrl="$(for c in /sys/class/nvme/nvme*; do [ -c "/dev/${c##*/}" ] && { echo "/dev/${c##*/}"; break; }; done)"
if [ -n "$ctrl" ]; then
    bm_resolve "$ctrl"; check "the NVMe controller $ctrl is not taken for its storage" eq "$R_ERR" controller
    bm_resolve_message "$ctrl"
    check "  ... and the message names its namespace" bash -c '[[ $1 == *"NVMe controller"*"/dev/nvme"*n* ]]' _ "$REPLY"
else
    echo "  - no NVMe controller on this machine: controller case not exercised"
fi
nvp="$(lsblk -nrpo NAME,TYPE 2>/dev/null | awk '$1 ~ /nvme[0-9]+n[0-9]+p[0-9]+$/ && $2 == "part" { print $1; exit }')"
# In a container lsblk sees the disks of the host, and /dev does not have them
if [ -n "$nvp" ] && [ -b "$nvp" ]; then
    bm_resolve "$nvp"; check "a real NVMe partition ($nvp) resolves to itself" eq "$R_DEV" "$nvp"
    bm_facts "$nvp"; check "  ... and its disk is the namespace, not 'nvme'" bash -c '[[ $1 =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]' _ "${F[DISK]}"
fi

begin "UDisks2 objects come from UDisks2"
udisksctl() { case "$*" in "info -b /dev/sdz1") printf '%s\n' "/org/freedesktop/UDisks2/block_devices/sdz1:" "  org.freedesktop.UDisks2.Block:" ;;
    "info -b /dev/dm-3") printf '%s\n' "/org/freedesktop/UDisks2/block_devices/dm_2d3:" ;;
    "unmount -b /dev/nvme") echo "Error looking up object for device /dev/nvme" >&2; return 1 ;;
    *) echo "Error looking up object for device ${*: -1}" >&2; return 1 ;; esac; }
bm_udisks_object /dev/sdz1; check "object path read from udisksctl" eq "$REPLY" /org/freedesktop/UDisks2/block_devices/sdz1
bm_udisks_object /dev/dm-3; check "  ... with UDisks2's own escaping (dm-3 -> dm_2d3)" eq "$REPLY" /org/freedesktop/UDisks2/block_devices/dm_2d3
bm_udisks_object /dev/nvme; check "  ... none for an unknown device" eq "$?:$REPLY" "1:"
bm_udisks unmount -b /dev/nvme; check "udisksctl lookup failure is classified (no-object)" eq "$UD_ERROR" no-object
# gdbus runs in a $(...) subshell: its arguments are kept in a file
gdbus() { printf '%s' "$*" > "$WORK/gdbus.args"; }
: > "$WORK/gdbus.args"; bm_take_ownership /dev/nvme; rc=$?
check "take ownership of an unknown device: refused before any D-Bus call" eq "$rc:$UD_ERROR:$(cat "$WORK/gdbus.args")" "1:no-object:"
bm_take_ownership /dev/dm-3; GDBUS_ARGS="$(cat "$WORK/gdbus.args")"
check "take ownership talks to the object UDisks2 named" bash -c '[[ $1 == *"--object-path /org/freedesktop/UDisks2/block_devices/dm_2d3 "* ]]' _ "$GDBUS_ARGS"
check "  ... never recursive" bash -c '[[ $1 == *"<false>"* ]]' _ "$GDBUS_ARGS"
unset -f udisksctl gdbus

begin "one removal of a drive at a time"
XDG_RUNTIME_DIR="$WORK" bm_drive_lock /dev/sdz; rc=$?
check "first operation takes the lock" eq "$rc" 0
( XDG_RUNTIME_DIR="$WORK" bm_drive_lock /dev/sdz ); rc=$?
check "a second, concurrent one is refused" eq "$rc" 1
( XDG_RUNTIME_DIR="$WORK" bm_drive_lock /dev/sdy ); rc=$?
check "another drive is not blocked" eq "$rc" 0
sleep 30 & SPID=$!
bm_drive_unlock
( XDG_RUNTIME_DIR="$WORK" bm_drive_lock /dev/sdz ); rc=$?
check "released even while a child (a notification) still holds the fd" eq "$rc" 0
kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
exec {held}>"$WORK/big-mount-drive-sdz.lock"; flock -n "$held"
bm_resolve() { R_DEV=/dev/sdz1; }
bm_facts() { F=([NAME]=/dev/sdz1 [DISK]=/dev/sdz); }
bm_remove_core() { CORE_RAN=1; return 0; }
CORE_RAN=0; XDG_RUNTIME_DIR="$WORK" bm_cmd_remove remove /dev/sdz1 >/dev/null 2>&1; rc=$?
check "bigmount --safe-remove while another removal runs -> 10, nothing done" eq "$rc:$CORE_RAN" "10:0"
exec {held}>&-
CORE_RAN=0; XDG_RUNTIME_DIR="$WORK" bm_cmd_remove remove /dev/sdz1 >/dev/null 2>&1; rc=$?
check "  ... and works once it is free" eq "$rc:$CORE_RAN" "0:1"
unset -f bm_resolve bm_facts bm_remove_core
. "$BIGMOUNT_LIB/lib.sh"; . "$BIGMOUNT_LIB/ui.sh"; . "$BIGMOUNT_LIB/cli.sh"; BM_UI="tty"; bm_ui_init

begin "terminal tables count characters, not bytes"
bm_pad "Não" 5; check "accented text padded to 5 columns" eq "$REPLY" "Não  "
bm_pad "Fotografias" 6; check "long text shortened with an ellipsis, never cut mid-character" eq "$REPLY" "Fotog…"
bm_pad "Ação" 3; check "  ... also when the cut falls on an accent" eq "$REPLY" "Aç…"
bm_pad $'A\033[31mB' 8; check "  ... and control characters are neutralized" eq "$REPLY" "A?[31mB "

begin "graphical commands: a device that cannot be found"
bm_ui_choice() { CHOICE_TITLE="$1"; CHOICES=$((CHOICES + 1)); REPLY="${PICK[CHOICES-1]:-3}"; }
bm_ui_text() { DETAILS="$(cat "$2")"; }
bm_notify() { NOTIFIED="$3|$4"; }
CHOICES=0 PICK=(3) NOTIFIED=""
bm_gui_target /dev/sdq9 "T" "X"; rc=$?
check "missing device: 'Unable to access storage device' dialog, Close -> 1" eq "$rc:$CHOICE_TITLE" "1:Unable to access storage device"
CHOICES=0 PICK=(2 3) DETAILS=""
bm_gui_target /dev/sdq9 "T" "X"
check "  ... Technical details explain the reason" bash -c '[[ $1 == *"reason: missing"*"does not exist"* ]]' _ "$DETAILS"
R_ERR=unavailable; bm_resolve_message /dev/loop9
check "a node without a device behind it: 'not available', may be disconnected" bash -c '[[ $1 == *"is not available"*disconnected* ]]' _ "$REPLY"
CHOICES=0 PICK=(1 3)
bm_gui_target /dev/sdq9 "T" "X"
check "  ... Try again looks again" eq "$CHOICES" 2
CHOICES=0 PICK=() NOTIFIED=""
bm_gui_target /proc/self "Storage diagnostics" "Not local"
check "a folder that is not on a local device: a notification, no error dialog" eq "$CHOICES:$NOTIFIED" "0:Storage diagnostics|Not local"
unset -f bm_ui_choice bm_ui_text bm_notify
. "$BIGMOUNT_LIB/ui.sh"; BM_UI="tty"; bm_ui_init

begin "drive health (docs/14-drive-health-and-secure-erase.md)"
readlink() { case "${*: -1}" in
    /sys/block/sda) echo /sys/devices/pci0000:00/0000:00:1f.2/ata1/host0/target0:0:0/0:0:0:0/block/sda ;;
    /sys/block/nvme0n1) echo /sys/devices/pci0000:00/0000:00:1d.0/0000:3d:00.0/nvme/nvme0/nvme0n1 ;;
    *) command readlink "$@" ;; esac; }
bm_drive_port /dev/sda; check "a SATA disk is reported on its ata port" eq "$REPLY" ata1
bm_drive_port /dev/nvme0n1; check "an NVMe namespace on its controller" eq "$REPLY" nvme0
unset -f readlink
# Kernel messages of the field case: an AL-SSD-256 that dropped every write
FIELD_KMSG=(
    "EXT4-fs (sda): VFS: Can't find ext4 filesystem"
    "ata1.00: exception Emask 0x0 SAct 0x80000 SErr 0x0 action 0x6 frozen"
    "ata1.00: failed command: READ FPDMA QUEUED"
    "ata1.00: cmd 60/20:98:e8:1e:01/00:00:00:00:00/40 tag 19 ncq dma 16384 in"
    "ata1: hard resetting link"
    "ata1: SATA link up 3.0 Gbps (SStatus 123 SControl 300)"
    "ata1.00: qc timeout after 15000 msecs (cmd 0x47)"
    "sd 0:0:0:0: [sda] tag#19 Sense Key : Aborted Command [current] "
    "I/O error, dev sda, sector 73448 op 0x0:(READ) flags 0x80700 phys_seg 1 prio class 2"
    "ata1: limiting SATA link speed to 1.5 Gbps"
    "ata1.00: failed command: READ DMA"
    "I/O error, dev sda, sector 409672 op 0x0:(READ) flags 0x80700 phys_seg 3 prio class 2"
    "I/O error, dev sdab, sector 8 op 0x0:(READ) flags 0x0 phys_seg 1 prio class 2"
)
FAKE_DKMSG=() FAKE_KLOG=0 FAKE_SMART="" FAKE_DRIVE=""
declare -A FAKE_UP=()
bm_drive_port() { REPLY=ata1; }
bm_drive_kmsg() { DKMSG=("${FAKE_DKMSG[@]}"); [ "$FAKE_KLOG" = 1 ]; }
bm_udev_props() { UP=(); local k; for k in "${!FAKE_UP[@]}"; do UP[$k]="${FAKE_UP[$k]}"; done; }
bm_udisks_drive() { REPLY="$FAKE_DRIVE"; [ -n "$FAKE_DRIVE" ]; }
busctl() { printf '%s\n' "${FAKE_SMART[@]}"; }
sata_up() { FAKE_UP=([ID_ATA]=1 [ID_BUS]=ata [ID_ATA_FEATURE_SET_SECURITY]=1 [ID_ATA_FEATURE_SET_SECURITY_ENABLED]=0 \
    [ID_ATA_FEATURE_SET_SECURITY_FROZEN]=1 [ID_ATA_FEATURE_SET_SECURITY_ERASE_UNIT_MIN]=2); }
FAKE_DKMSG=("${FIELD_KMSG[@]}") FAKE_KLOG=1; sata_up; FAKE_DRIVE=/org/freedesktop/UDisks2/drives/AL
FAKE_SMART=("b true" "b true" "b false" "x 0")
bm_drive_health /dev/sda
check "field case: timeouts, I/O errors and a slowed link" eq "${DH_FIND[*]}" "timeouts io-errors slow-link"
check "  ... timeouts counted by failed or timed-out command" eq "${DH_COUNT[timeouts]}" 3
check "  ... I/O errors of this disk only (never sdab)" eq "${DH_COUNT[io-errors]}" 2
check "  ... probing noise and a link that came back up are not errors" eq "${#DH_LINES[@]}" 6
check "  ... SMART still says ok: the kernel log is what tells" eq "$DH_SMART" ok
check "  ... ATA security read from udev: frozen, 2 minutes" eq "$DH_ATA:$DH_SEC:$DH_FROZEN:$DH_ERASE_MIN" "1:off:1:2"
FAKE_DKMSG=("Buffer I/O error on dev sda1, logical block 0, async page read"); bm_drive_health /dev/sda
check "a partition of the drive counts for the drive" eq "${DH_FIND[*]}" io-errors
FAKE_DKMSG=("nvme nvme0: I/O tag 25 (1019) opcode 0x2 (Admin Cmd) QID 0 timeout, aborting"); bm_drive_health /dev/nvme0n1
check "an NVMe command timeout" eq "${DH_FIND[*]}" timeouts
FAKE_DKMSG=("ata1: SATA link up 6.0 Gbps (SStatus 133 SControl 300)" "EXT4-fs (sda): mounted filesystem"); bm_drive_health /dev/sda
check "a healthy boot: nothing found" eq "${#DH_FIND[@]}:$DH_KLOG" "0:1"
FAKE_SMART=("b true" "b true" "b false" "x 1"); bm_drive_health /dev/sda
check "one damaged sector replaced (the development SSD): shown, never an alarm" eq "${#DH_FIND[@]}:$DH_BAD" "0:1"
FAKE_SMART=("b true" "b true" "b true" "x 0"); FAKE_DKMSG=("${FIELD_KMSG[@]}"); bm_drive_health /dev/sda
check "SMART predicts a failure: first finding" eq "${DH_FIND[0]}:$DH_SMART" "smart-failing:failing"
FAKE_SMART=("b true" "b false" "b true" "x 9"); bm_drive_health /dev/sda
check "SMART disabled: no verdict from it" eq "$DH_SMART:$DH_BAD" ":0"
FAKE_SMART=("b true" "b true" "b false" "x 0" "t 126000000" "d 311.15" "i 0" "i 2"); FAKE_DKMSG=(); bm_drive_health /dev/sda
check "UDisks2 without a password: hours, temperature, values failing now and in the past" eq "$DH_HOURS:$DH_TEMP:$DH_ATTR_FAIL:$DH_ATTR_PAST" "35000:38:0:2"
FAKE_SMART=("b true" "b true" "b false" "x 0" "t 0" "d 0.0" "i 0" "i 0"); bm_drive_health /dev/sda
check "  ... a drive that does not say them: unknown, never 0 hours or -273 °C" eq "$DH_HOURS:$DH_TEMP" ":"
FAKE_UP=(); FAKE_SMART=()
FAKE_NVME=("t 1793464880" 'as 2 "spare" "temperature"' "t 7610" "q 330")
FAKE_NVME_ATTRS='a{sv} 4 "avail_spare" y 9 "percent_used" y 93 "media_errors" t 2 "wctemp" q 356'
busctl() {
    case "$*" in
        *SmartGetAttributes*) printf '%s\n' "$FAKE_NVME_ATTRS" ;;
        *NVMe.Controller*) printf '%s\n' "${FAKE_NVME[@]}" ;;
        *) printf '%s\n' "${FAKE_SMART[@]}" ;;
    esac
}
bm_drive_health /dev/nvme0n1
check "NVMe through UDisks2: its warnings, life used, media errors and limits" \
    eq "$DH_SMART|$DH_NVME_WARN|$DH_HOURS|$DH_TEMP|$DH_NVME_USED|$DH_NVME_MEDIA|$DH_NVME_HOT" "ok|spare,temperature|7610|57|93|2|83"
FAKE_NVME=("t 0" "as 0" "t 0" "q 0"); bm_drive_health /dev/nvme0n1
check "  ... never updated by UDisks2: nothing is said" eq "$DH_SMART:$DH_NVME_USED" ":"
FAKE_NVME=("t 1793464880" "as 0" "t 10" "q 300"); FAKE_NVME_ATTRS='a{sv} 1 "percent_used" y 5'; bm_drive_health /dev/nvme0n1
check "  ... no warning: none" eq "$DH_SMART:$DH_NVME_WARN:$DH_NVME_USED" "ok::5"
busctl() { printf '%s\n' "${FAKE_SMART[@]}"; }
sata_up
FAKE_KLOG=0 FAKE_DKMSG=(); bm_drive_health /dev/sda
check "unreadable kernel log: no finding, and it is known" eq "${#DH_FIND[@]}:$DH_KLOG" "0:0"
FAKE_UP=([ID_ATA]=1 [ID_BUS]=usb [ID_ATA_FEATURE_SET_SECURITY]=1); bm_drive_health /dev/sda
check "a SATA drive behind a USB bridge is not an ATA drive here" eq "$DH_ATA" 0
sata_up; FAKE_UP[ID_ATA_FEATURE_SET_SECURITY_ENABLED]=1; bm_drive_health /dev/sda
check "a security password is seen" eq "$DH_SEC" enabled
FAKE_UP[ID_ATA_FEATURE_SET_SECURITY_ERASE_UNIT_MIN]='$(id)'; bm_drive_health /dev/sda
check "an estimate that is not a number is ignored" eq "$DH_ERASE_MIN" 0

begin "who may be erased"
bm_system_use() { return 1; }
erase_facts() { F=([NAME]=/dev/sda [DISK]=/dev/sda [TYPE]=disk [TRAN]=sata [HOTPLUG]=0 [RM]=0); }
erase_facts; sata_up; bm_drive_health /dev/sda
bm_erase_check /dev/sda; check "an internal SATA drive with security support" eq "$?:$ER_WHY" "0:"
F[NAME]=/dev/sda1 F[TYPE]=part; bm_erase_check /dev/sda1; check "never a partition" eq "$ER_WHY" not-disk
erase_facts; bm_system_use() { REPLY="/dev/sda2 → /"; return 0; }
bm_erase_check /dev/sda; check "never the drive of the running system" eq "$ER_WHY:$ER_DETAIL" "system:/dev/sda2 → /"
bm_system_use() { return 1; }
F[TRAN]=usb; bm_erase_check /dev/sda; check "never through USB" eq "$ER_WHY" removable
erase_facts; F[HOTPLUG]=1; bm_erase_check /dev/sda; check "  ... nor a hot-plug bay" eq "$ER_WHY" removable
erase_facts; FAKE_UP=([ID_ATA]=0); bm_drive_health /dev/sda
bm_erase_check /dev/sda; check "not an ATA drive (NVMe, SCSI)" eq "$ER_WHY" not-ata
FAKE_UP=([ID_ATA]=1 [ID_BUS]=ata); bm_drive_health /dev/sda
bm_erase_check /dev/sda; check "no ATA security feature set" eq "$ER_WHY" unsupported
sata_up; FAKE_UP[ID_ATA_FEATURE_SET_SECURITY_ENABLED]=1; bm_drive_health /dev/sda
bm_erase_check /dev/sda; check "a password is already set: refused, it could lock the drive" eq "$ER_WHY" password
unset -f bm_drive_port bm_drive_kmsg bm_udisks_drive busctl erase_facts bm_system_use

begin "Secure Erase: only what was confirmed, and checked afterwards"
# lsblk answers what a probe of the drive would read at each stage
ER_CALLS=() LS_PT="gpt OLDID" ERASE_SEQ=7 FAKE_MOUNTED="" FAKE_HELD="" ERASE_ERR="" ERASE_KEEPS="" FORMAT_ERR="" FORMAT_KEEPS=1 FORMAT_ID=NEWID
bm_diskseq() { REPLY="$ERASE_SEQ"; }
bm_drive_members() { DRIVE_DEVS=(/dev/sda /dev/sda1 /dev/sda2) DRIVE_FSTYPES=("" vfat apfs); }
bm_mounts() { M_TARGET=() M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); [ "$1" = "$FAKE_MOUNTED" ] && M_TARGET=(/mnt/x); return 0; }
bm_has_holders() { [ "$1" = "$FAKE_HELD" ]; }
bm_udisks_drive() { REPLY=/org/freedesktop/UDisks2/drives/AL; }
bm_udisks_object() { REPLY=/org/freedesktop/UDisks2/block_devices/sda; }
udevadm() { :; }
lsblk() { case "$*" in *PTTYPE,PTUUID*) echo "$LS_PT" ;; *PTTYPE*) echo "${LS_PT% *}" ;; *PTUUID*) echo "${LS_PT#* }" ;; esac; }
bm_gdbus() {
    ER_CALLS+=("${2##*.} ${*:3} timeout=${BM_GDBUS_TIMEOUT:-}")
    UD_ERROR="" UD_MESSAGE=""
    case "$2" in
        *SecurityEraseUnit)
            if [ -n "$ERASE_ERR" ]; then UD_ERROR="$ERASE_ERR" UD_MESSAGE="GDBus.Error:$ERASE_ERR: Error erasing: drive is frozen"; return 1; fi
            [ -z "$ERASE_KEEPS" ] && LS_PT=" "; return 0 ;;
        *Format)
            if [ -n "$FORMAT_ERR" ]; then UD_ERROR=unknown UD_MESSAGE="GDBus.Error:x: $FORMAT_ERR"; return 1; fi
            [ "$FORMAT_KEEPS" = 1 ] && LS_PT="${3//\'/} $FORMAT_ID"; return 0 ;;
    esac
    return 0
}
erase_case() { ER_CALLS=() LS_PT="gpt OLDID"; sata_up; FAKE_UP[ID_ATA_FEATURE_SET_SECURITY_FROZEN]=0; }
# Not a block device: the name is gone, even with the same sequence number
erase_case; bm_erase_run /dev/null 7 dos; rc=$?
check "what is no longer a block device -> 1, nothing sent to it" eq "$rc:${#ER_CALLS[@]}" "1:0"
# The drive of these tests does not exist. Whether the machine has a /dev/sda must not matter
bm_is_block() { :; }
erase_case; bm_erase_run /dev/sda 7 dos; rc=$?
check "erased, a new empty table written and read back -> 0" eq "$rc" 0
check "  ... erase (never enhanced), then table, then a fresh read" eq "${ER_CALLS[*]}" \
    "SecurityEraseUnit {'enhanced': <false>} timeout=540 Format 'dos' {} timeout= Rescan {} timeout="
check "  ... the erase may take twice the drive's own estimate (2 min)" bash -c '[[ $1 == *"timeout=540"* ]]' _ "${ER_CALLS[0]}"
erase_case; ERASE_SEQ=8; bm_erase_run /dev/sda 7 dos; rc=$?; ERASE_SEQ=7
check "another drive took the name -> 1, nothing sent to it" eq "$rc:${#ER_CALLS[@]}" "1:0"
erase_case; FAKE_MOUNTED=/dev/sda2; bm_erase_run /dev/sda 7 dos; rc=$?; FAKE_MOUNTED=""
check "a partition is mounted again -> 3, nothing erased" eq "$rc:${#ER_CALLS[@]}" "3:0"
erase_case; FAKE_HELD=/dev/sda1; bm_erase_run /dev/sda 7 dos; rc=$?; FAKE_HELD=""
check "encryption/LVM still open on it -> 3, nothing erased" eq "$rc:${#ER_CALLS[@]}" "3:0"
erase_case; FAKE_UP[ID_ATA_FEATURE_SET_SECURITY_FROZEN]=1; bm_erase_run /dev/sda 7 dos; rc=$?
check "still frozen -> 11, the erase is not even tried" eq "$rc:${#ER_CALLS[@]}" "11:0"
erase_case; ERASE_ERR=org.freedesktop.UDisks2.Error.NotAuthorizedCanObtain; bm_erase_run /dev/sda 7 dos; rc=$?; ERASE_ERR=""
check "administrator password refused -> 5" eq "$rc" 5
erase_case; ERASE_ERR=org.freedesktop.UDisks2.Error.Failed; bm_erase_run /dev/sda 7 dos; rc=$?; ERASE_ERR=""
check "the drive answered frozen to UDisks2 -> 11" eq "$rc" 11
erase_case; ERASE_KEEPS=1; bm_erase_run /dev/sda 7 dos; rc=$?; ERASE_KEEPS=""
check "the old table survived the erase (field case) -> 12 erase-ignored" eq "$rc:$ER_STAGE" "12:erase-ignored"
check "  ... and nothing is written on top of it" eq "${#ER_CALLS[@]}" 1
erase_case; FORMAT_KEEPS=0; bm_erase_run /dev/sda 7 dos; rc=$?; FORMAT_KEEPS=1
check "the new table was not kept -> 12 table-lost" eq "$rc:$ER_STAGE" "12:table-lost"
erase_case; FORMAT_ID=OLDID; bm_erase_run /dev/sda 7 gpt; rc=$?; FORMAT_ID=NEWID
check "the old identifier read back is not the new table -> 12 table-lost" eq "$rc:$ER_STAGE" "12:table-lost"
erase_case; FORMAT_ERR="Permission denied"; bm_erase_run /dev/sda 7 dos; rc=$?; FORMAT_ERR=""
check "erased, but the table could not be written -> 12 unverified" eq "$rc:$ER_STAGE:$ER_REASON" "12:unverified:Permission denied"
unset -f bm_diskseq bm_drive_members bm_mounts bm_has_holders bm_udisks_drive bm_udisks_object udevadm lsblk bm_gdbus erase_case

begin "Secure Erase in the terminal and in dialogs"
bm_remove_core() { SE_CALLS+=("$1:$2:$RM_ALLOW_SERVICES"); return "$FAKE_RELEASE"; }
bm_erase_run() { SE_CALLS+=("erase:$3"); return "$FAKE_RUN"; }
bm_erase_unfreeze() { SE_CALLS+=(unfreeze); FAKE_UP[ID_ATA_FEATURE_SET_SECURITY_FROZEN]=0; return 0; }
bm_ui_input() { REPLY="$TYPED"; [ -n "$TYPED" ]; }
bm_diskseq() { REPLY=7; }
lsblk() { :; }
bm_erase_table() { REPLY=dos; }
se_case() { SE_CALLS=() FAKE_RELEASE=0 FAKE_RUN=0 TYPED=sda; sata_up; F=([NAME]=/dev/sda [DISK]=/dev/sda [TYPE]=disk [TRAN]=sata [SIZE]=256060514304 [MODEL]=AL-SSD-256); }
se_case; TYPED=sdb; bm_secure_erase_tty /dev/sda > /dev/null 2>&1; rc=$?
check "terminal: another name typed -> nothing done, 5" eq "$rc:${#SE_CALLS[@]}" "5:0"
se_case; TYPED=""; bm_secure_erase_tty /dev/sda > /dev/null 2>&1; rc=$?
check "  ... no answer (no terminal) -> nothing done" eq "$rc:${#SE_CALLS[@]}" "5:0"
se_case; bm_ui_confirm() { return 1; }; bm_secure_erase_tty /dev/sda > /dev/null 2>&1; rc=$?
check "  ... frozen, the user does not want the computer to sleep -> 11, no erase" eq "$rc:${SE_CALLS[*]}" "11:release:/dev/sda:0"
se_case; bm_ui_confirm() { return 0; }; bm_secure_erase_tty /dev/sda > "$WORK/se.out" 2>&1; rc=$?
check "  ... frozen, sleep accepted: release, unfreeze, erase with the table of this computer" eq "$rc:${SE_CALLS[*]}" "0:release:/dev/sda:0 unfreeze erase:dos"
check "  ... and the result says the drive keeps what is written" grep -q "keeps what is written again" "$WORK/se.out"
se_case; FAKE_RUN=12 ER_STAGE=erase-ignored; bm_secure_erase_tty /dev/sda > "$WORK/se.out" 2>&1; rc=$?
check "  ... a drive that ignored the erase is called failing" eq "$rc:$(grep -c 'Replace it' "$WORK/se.out")" "12:1"
se_case; FAKE_RELEASE=4 RM_REASON="/dev/sda2 → /"; bm_secure_erase_tty /dev/sda > /dev/null 2>&1; rc=$?
check "  ... the system appeared on it meanwhile -> 4, no erase" eq "$rc:${#SE_CALLS[@]}" "4:1"

begin "Secure Erase from the application: a ticket, the typed name, and nothing else"
(
   . "$BIGMOUNT_LIB/drive.sh"
   . "$BIGMOUNT_LIB/drive-erase.sh"
   export XDG_RUNTIME_DIR="$WORK/run-er"
   mkdir -p "$XDG_RUNTIME_DIR"
   bm_drive_health() { :; }
   bm_facts() { F=([NAME]="$1" [DISK]=/dev/sda [TYPE]="${FAKE_TYPE:-disk}" [DISK_TYPE]=disk [TRAN]="${FAKE_TRAN:-sata}" [HOTPLUG]=0 [RM]=0 [SIZE]=1000); }
   bm_system_use() { [ -n "${FAKE_SYSTEM:-}" ] && { REPLY="/dev/sda2 → /"; return 0; }; return 1; }
   bm_is_block() { return 0; }
   DH_ATA=1 DH_SEC=disabled DH_ERASE_MIN=4
   bm_diskseq() { REPLY="${FAKE_SEQ:-7}"; }
   lsblk() { case " $* " in *" SERIAL "*) printf '%s\n' "${FAKE_SERIAL:-SN1}" ;; esac; }
   FAKE_TRAN=sata FAKE_TYPE=disk
   bm_drive_lock() { [ -z "${FAKE_HELD:-}" ]; }
   bm_drive_unlock() { SE_CALLS+=(unlock); }
   bm_display_name() { REPLY="sda (Samsung)"; }
   bm_remove_core() { SE_CALLS+=("release:$RM_ALLOW_SERVICES"); RM_BUSY_DEV=/dev/sda1; RM_REASON=""; RM_DEP_UNITS=(plex.service) RM_DEP_NAMES=(Plex); return "${FAKE_RELEASE:-0}"; }
   bm_busy_doc() { bm_doc_new; }
   bm_busy_summary() { BUSY_SUMMARY="Dolphin is reading it." BUSY_ADVICE="Close it."; }
   bm_erase_unfreeze() { SE_CALLS+=(unfreeze); FAKE_FROZEN=0; return "${FAKE_UNFREEZE:-0}"; }
   bm_udev_props() { UP=([ID_ATA_FEATURE_SET_SECURITY_FROZEN]="${FAKE_FROZEN:-0}"); }
   bm_erase_run() { SE_CALLS+=("erase:$1:$2:$3"); return "${FAKE_RUN:-0}"; }
   bm_erase_table() { REPLY=gpt; }
   SE_CALLS=() FAIL=0
   bm_drive_disk() { R_DEV="$1" DD_DISK=/dev/sda R_PATH=""; bm_facts "$1"; return 0; }
   token_of() { python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("token",""))'; }
   new_ticket() { bm_er_cmd_prepare /dev/sda --json | token_of; }

   T="$(new_ticket)"
   check "a ticket for an eligible drive" bash -c '[[ $1 =~ ^[0-9a-f]{32}$ ]]' _ "$T"
   f="$XDG_RUNTIME_DIR/big-mount/erase-$T"
   check "  ... kept private" eq "$(stat -c %a "$f")" 600
   FAKE_SYSTEM=1; out="$(bm_er_cmd_prepare /dev/sda --json)"; rc=$?; FAKE_SYSTEM=""
   check "no ticket for the drive of the running system" eq "$rc:$(token_of <<< "$out")" "20:"
   FAKE_TRAN=usb; out="$(bm_er_cmd_prepare /dev/sda --json)"; rc=$?; FAKE_TRAN=sata
   check "  ... nor through USB" eq "$rc:$(token_of <<< "$out")" "20:"
   FAKE_TYPE=part; out="$(bm_er_cmd_prepare /dev/sda --json)"; rc=$?; FAKE_TYPE=disk
   check "  ... nor for a partition" eq "$rc:$(token_of <<< "$out")" "20:"
   DH_ATA=0; out="$(bm_er_cmd_prepare /dev/sda --json)"; rc=$?; DH_ATA=1
   check "  ... nor for NVMe or anything that is not ATA" eq "$rc:$(token_of <<< "$out")" "20:"
   DH_SEC=""; out="$(bm_er_cmd_prepare /dev/sda --json)"; rc=$?; DH_SEC=disabled
   check "  ... nor without the security feature" eq "$rc:$(token_of <<< "$out")" "20:"

   SE_CALLS=(); bm_er_cmd_run "" --typed sda >/dev/null; check "without a ticket: refused, nothing done" eq "$?:${#SE_CALLS[@]}" "20:0"
   SE_CALLS=(); bm_er_cmd_run "../../etc/x" --typed sda >/dev/null; check "  ... a ticket that is a path: refused" eq "$?:${#SE_CALLS[@]}" "20:0"
   SE_CALLS=(); bm_er_cmd_run "$(printf '%032d' 0)" --typed sda >/dev/null; check "  ... a ticket nobody issued: refused" eq "$?:${#SE_CALLS[@]}" "20:0"
   T="$(new_ticket)"; SE_CALLS=(); out="$(bm_er_cmd_run "$T" --typed SDA)"; rc=$?
   check "a name that is almost right: nothing done" eq "$rc:${#SE_CALLS[@]}" "5:0"
   [ ! -e "$XDG_RUNTIME_DIR/big-mount/erase-$T" ]; check "  ... and the ticket is gone" eq "$?" 0
   T="$(new_ticket)"; SE_CALLS=(); out="$(bm_er_cmd_run "$T")"; rc=$?
   check "no name at all: nothing done" eq "$rc:${#SE_CALLS[@]}" "5:0"
   T="$(new_ticket)"; FAKE_SEQ=8; SE_CALLS=(); bm_er_cmd_run "$T" --typed sda >/dev/null; rc=$?; FAKE_SEQ=7
   check "another drive took the name: refused" eq "$rc:${#SE_CALLS[@]}" "24:0"
   T="$(new_ticket)"; FAKE_SERIAL=SN2; SE_CALLS=(); bm_er_cmd_run "$T" --typed sda >/dev/null; rc=$?; FAKE_SERIAL=""
   check "  ... another serial: refused" eq "$rc:${#SE_CALLS[@]}" "24:0"
   T="$(new_ticket)"; printf '/dev/sda\n7|SN1\n1000\n' > "$XDG_RUNTIME_DIR/big-mount/erase-$T"; SE_CALLS=(); bm_er_cmd_run "$T" --typed sda >/dev/null; rc=$?
   check "an expired ticket: refused" eq "$rc:${#SE_CALLS[@]}" "20:0"
   T="$(new_ticket)"; FAKE_SYSTEM=1; SE_CALLS=(); bm_er_cmd_run "$T" --typed sda >/dev/null; rc=$?; FAKE_SYSTEM=""
   check "the system appeared on it meanwhile: refused, checked again" eq "$rc:${#SE_CALLS[@]}" "20:0"
   T="$(new_ticket)"; FAKE_HELD=1; SE_CALLS=(); bm_er_cmd_run "$T" --typed sda >/dev/null; rc=$?; FAKE_HELD=""
   check "another operation on the drive: 10, nothing done" eq "$rc:${#SE_CALLS[@]}" "10:0"
   T="$(new_ticket)"; FAKE_RELEASE=3; SE_CALLS=(); out="$(bm_er_cmd_run "$T" --typed sda)"; rc=$?; FAKE_RELEASE=0
   check "busy: says who, nothing erased" eq "$rc:$(grep -c 'Dolphin' <<< "$out")" "3:1"
   SE_CALLS=(); bm_er_cmd_run "$T" --typed sda >/dev/null; rc=$?; check "  ... the ticket survives to try again" eq "$rc" 0
   T="$(new_ticket)"; FAKE_RELEASE=9; SE_CALLS=(); out="$(bm_er_cmd_run "$T" --typed sda)"; rc=$?
   check "services use it: never stopped without asking" eq "$rc:$(grep -c 'plex.service' <<< "$out")" "9:1"
   bm_er_cmd_run "$T" --typed sda --allow-services > "$WORK/er.out"; FAKE_RELEASE=0
   T="$(new_ticket)"; FAKE_FROZEN=1; SE_CALLS=(); out="$(bm_er_cmd_run "$T" --typed sda)"; rc=$?
   check "frozen: the computer does not sleep without a decision" eq "$rc:$(grep -c '"stage":"frozen"' <<< "$out")" "11:1"
   FAKE_FROZEN=1; SE_CALLS=(); bm_er_cmd_run "$T" --typed sda --unfreeze >"$WORK/er.out"; rc=$?
   check "  ... with it, it sleeps and then erases" eq "$rc" 0
   T="$(new_ticket)"; FAKE_RUN=12; ER_STAGE=erase-ignored; SE_CALLS=(); bm_er_cmd_run "$T" --typed sda > "$WORK/er.json"; rc=$?; FAKE_RUN=0
   check "a drive that ignored the erase is not called erased" eq "$rc:$(grep -c '"ok":false' "$WORK/er.json")" "12:1"
   python3 -I -m json.tool "$WORK/er.json" >/dev/null; check "  ... the answer is valid JSON" eq "$?" 0
   T="$(new_ticket)"; bm_er_cmd_run "$T" --typed sda > "$WORK/er.json"; rc=$?
   check "typed and confirmed: erased with the table of this computer" eq "$rc:$(grep -c '"ok":true' "$WORK/er.json")" "0:1"
   bm_er_cmd_run "$T" --typed sda >/dev/null; check "  ... a ticket works once" eq "$?" 20
   bm_er_cmd_check /dev/sda --json | python3 -I -m json.tool >/dev/null; check "the check is valid JSON, and it changes nothing" eq "$?" 0
   exit "$FAIL"
) 2>&1 | sed 's/^/ /'
er_rc="${PIPESTATUS[0]}"
check "Secure Erase from the application: all of the above" eq "$er_rc" 0
unset -f bm_remove_core bm_erase_run bm_erase_unfreeze bm_ui_input bm_diskseq lsblk bm_erase_table se_case bm_ui_confirm \
    bm_ui_confirm_risky bm_notify bm_ui_show bm_udev_props sata_up
. "$BIGMOUNT_LIB/lib.sh"; . "$BIGMOUNT_LIB/ui.sh"; . "$BIGMOUNT_LIB/cli.sh"; BM_UI="tty"; bm_ui_init

begin "release before an erase: unmounted and locked, never powered off"
fake_rel() { F=([NAME]="$1" [DISK]=/dev/sdz [DISK_TYPE]=disk [TRAN]="$REL_TRAN" [HOTPLUG]=0 [RM]=0 [FSTYPE]=""); }
bm_facts() { fake_rel "$@"; }
bm_system_use() { return 1; }
bm_drive_members() { DRIVE_DEVS=(/dev/sdz /dev/sdz1 /dev/sdz2) DRIVE_FSTYPES=("" ext4 crypto_LUKS); }
bm_diskseq() { REPLY=1; }
bm_mounts() { M_TARGET=() M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); }
bm_has_holders() { [ "$1" = /dev/sdz2 ]; }
bm_other_holders() { O_KIND=() O_WHAT=(); }
bm_mount_dependents() { DEP_UNITS=() DEP_NAMES=() DEP_BACK=(); }
bm_udisks() { REL_CALLS+=("$1 ${*: -1}"); UD_ERROR=""; return 0; }
REL_CALLS=() REL_TRAN=sata; bm_remove_core release /dev/sdz; rc=$?
check "an open LUKS volume is locked" eq "$rc:${REL_CALLS[*]}" "0:lock /dev/sdz2"
REL_CALLS=() REL_TRAN=usb; bm_remove_core release /dev/sdz; rc=$?
check "  ... and even a removable drive is not powered off" eq "$rc:${REL_CALLS[*]}:$RM_POWERED" "0:lock /dev/sdz2:0"
unset -f fake_rel bm_facts bm_system_use bm_drive_members bm_diskseq bm_mounts bm_has_holders bm_other_holders bm_mount_dependents bm_udisks
. "$BIGMOUNT_LIB/lib.sh"; . "$BIGMOUNT_LIB/ui.sh"; . "$BIGMOUNT_LIB/cli.sh"; BM_UI="tty"; bm_ui_init

begin "a partition diagnosis mentions the errors of its drive"
F=([NAME]=/dev/sda2 [DISK]=/dev/sda [FSTYPE]=apfs [SIZE]=1) D_CAUSE=not-mounted D_FIX="" D_MP="" D_PATH="" D_WARN=()
DH_DISK=/dev/sda DH_FIND=(timeouts); bm_diag_doc /dev/sda2; bm_doc_render_text
check "the drive's errors are mentioned" grep -q "the drive that holds this device reported errors" <<< "$REPLY"
DH_DISK=/dev/sdb; bm_diag_doc /dev/sda2; bm_doc_render_text
check "  ... never the findings of another drive" bash -c '! grep -q "drive that holds" <<< "$1"' _ "$REPLY"
DH_DISK="" DH_FIND=()

begin "bigmount --version and --doctor"
bm_load doctor.sh
printf '%s\n' 'revision=0123456789abcdef0123456789abcdef01234567' 'date=2026-10-25T13:42:00Z' \
    'source=https://github.com/biglinux/big-mount' > "$WORK/version"
( BM_LIB_DIR="$WORK"; bm_version_info; printf '%s|%s|%s' "$V_REVISION" "$V_DATE" "$V_SOURCE" ) > "$WORK/v.out"
check "version file of the package is read" eq "$(cat "$WORK/v.out")" "0123456789abcdef0123456789abcdef01234567|2026-10-25T13:42:00Z|https://github.com/biglinux/big-mount"
printf '%s\n' 'revision=$(touch '"$WORK"'/pwned)' 'date=`id`' 'source=javascript:alert(1)' > "$WORK/version"
( BM_LIB_DIR="$WORK"; bm_version_info; printf '%s|%s|%s' "$V_REVISION" "$V_DATE" "$V_SOURCE" ) > "$WORK/v.out"
check "  ... values that are not a revision, date or URL are dropped" eq "$(cat "$WORK/v.out")" "||"
check "  ... and never executed" test ! -e "$WORK/pwned"
DR_WARN=0 DR_FAIL=0 DR_COLOR="" DR_USER=maria HOME=/home/maria
bm_dr_anon "/home/maria/x /run/media/maria/Fotos https://github.com/maria/x"
# shellcheck disable=SC2088  # the report shows a literal ~
check "report: home and media folders anonymized, URLs kept" eq "$REPLY" "~/x /run/media/<user>/Fotos https://github.com/maria/x"
HOME="$ORIG_HOME"
bm_dr_legacy_check "$HERE/bigmount.old.sh" > /dev/null; rc=$?
check "the script of the biglinux-stable package is recognized as legacy" eq "$rc:$DR_FAIL" "1:3"
DR_FAIL=0
bm_dr_legacy_check "$REPO/big-mount/usr/bin/bigmount" > /dev/null; rc=$?
check "the current script is not" eq "$rc:$DR_FAIL" "0:0"
bm_cmd_doctor --fix >/dev/null 2>&1; rc=$?
check "--doctor takes no option (it never changes anything)" eq "$rc" 2

echo ""
echo "========================================="
echo "lib result: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
