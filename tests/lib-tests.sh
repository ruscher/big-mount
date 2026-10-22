#!/bin/bash
# shellcheck disable=SC2016,SC2317  # bash -c '...$1' snippets and helpers called through check()
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
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

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

begin "read-only causes (docs/04-modo-somente-leitura.md)"
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
unset -f bm_mounts bm_kernel_messages bm_boot_status bm_ntfs3g_fallback findmnt
# shellcheck source=../big-mount/usr/lib/big-mount/lib.sh
# shellcheck source=../big-mount/usr/lib/big-mount/lib.sh
. "$BIGMOUNT_LIB/lib.sh"

begin "process policy (docs/06-desmontagem-segura.md)"
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
unset -f fake_drive bm_facts bm_system_use bm_drive_members bm_diskseq bm_mounts bm_has_holders bm_other_holders bm_udisks
. "$BIGMOUNT_LIB/lib.sh"

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
kdialog() { printf 'kdialog %s\n' "$*" >> "$WORK/n.log"; }
: > "$WORK/n.log"; DBUS_SESSION_BUS_ADDRESS=fake BM_UI=kdialog bm_notify info drive-harddisk "Safe to disconnect" "Pen <b>"
check "info: notify-send, 5000 ms, transient" grep -q -- "--expire-time 5000 --hint string:desktop-entry:big-mount --transient" "$WORK/n.log"
check "  ... body escaped" grep -q "Pen &lt;b&gt;" "$WORK/n.log"
check "  ... and never a second popup" eq "$(wc -l < "$WORK/n.log")" 1
: > "$WORK/n.log"; DBUS_SESSION_BUS_ADDRESS=fake bm_notify warning dialog-warning "Read-only device" "x" "details=View details" >/dev/null
check "warning: 15000 ms, kept in history, with actions" grep -q -- "--expire-time 15000 --hint string:desktop-entry:big-mount --action details=View details" "$WORK/n.log"
: > "$WORK/n.log"; DBUS_SESSION_BUS_ADDRESS="" BM_UI=kdialog bm_notify info drive-harddisk "Safe to disconnect" "Pen"
check "no session bus: kdialog --passivepopup for 5 s" grep -q -- "--passivepopup Pen 5" "$WORK/n.log"
: > "$WORK/n.log"; out="$(DBUS_SESSION_BUS_ADDRESS="" BM_UI=tty bm_notify info x "Safe to disconnect" "Pen" 2>&1)"
check "no desktop at all: plain text" eq "$out" "Safe to disconnect: Pen"
check "  ... and no GUI program started" test ! -s "$WORK/n.log"
unset -f notify-send kdialog
BM_UI="tty"

begin "administrator view leaves no file behind"
mkdir -p "$WORK/tmpdir"
printf 'p77\ncsecret-app\nu0\nLroot\nfcwd\na \ntDIR\nn/home/other/private\n' > "$WORK/priv.out"
pkexec() { cat "$WORK/priv.out"; }
kdialog() { echo "$*" >> "$WORK/kd.log"; KD_N=$((KD_N + 1)); case "$KD_N" in 1) return 1 ;; 2) echo admin ;; 3) return 1 ;; 4) echo details; return 0 ;; *) return 2 ;; esac; }
bm_busy_collect() {
    BUSY_PID=() BUSY_PIDS=() BUSY_APP=() BUSY_COMM=() BUSY_FD=() BUSY_ACCESS=() BUSY_UID=() BUSY_USER=() O_KIND=() O_WHAT=() BUSY_COUNT=0
    if [ -n "${2:-}" ] && grep -q secret "$2"; then
        BUSY_PID=(77) BUSY_PIDS=(77) BUSY_APP=(secret-app) BUSY_COMM=(secret-app) BUSY_FD=(cwd) BUSY_ACCESS=("") BUSY_UID=(0) BUSY_USER=(root) BUSY_COUNT=1
    fi
}
bm_facts() { F=([NAME]=/dev/sdz1 [LABEL]=X [FSTYPE]=ext4); }
bm_mounts() { M_TARGET=(/run/media/u/X) M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); }
bm_ui_text() { :; }
command() { [ "$2" = pkexec ] && return 0; builtin command "$@"; }
KD_N=0; : > "$WORK/kd.log"
( export TMPDIR="$WORK/tmpdir"; BM_UI=kdialog; bm_gui_busy_dialog /dev/sdz1 ) > /dev/null 2>&1
check "the privileged list was shown" grep -q "secret-app" "$WORK/kd.log"
check "no temporary file left after the dialog" test -z "$(ls -A "$WORK/tmpdir")"
unset -f pkexec kdialog bm_busy_collect bm_facts bm_mounts bm_ui_text command
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
bm_doc_new; bm_doc_kv "Device" '<img src=x onerror=alert(1)> & "q"'
bm_doc_render_markup html
check "HTML: tags escaped" bash -c '[[ $1 == *"&lt;img src=x onerror=alert(1)&gt; &amp; &quot;q&quot;"* ]]' _ "$REPLY"
bm_doc_render_markup pango
check "Pango: tags escaped" bash -c '[[ $1 == *"&lt;img"* && $1 != *"<img"* ]]' _ "$REPLY"
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

echo ""
echo "========================================="
echo "lib result: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
