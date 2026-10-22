#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets and helpers called through check()
# Integration tests for the session tools (diagnosis, busy device, safe
# removal, notifier) against REAL mounts.
#
# Disposable images are attached as loop devices through UDisks2 and mounted
# exactly as Plasma mounts a USB stick, so no real disk is ever touched. It
# needs a local active session (polkit lets it set up loop devices without a
# password) and runs as a normal user. Never run it as root.
#
# Usage: tests/integration.sh
#        BM=/usr/bin/bigmount tests/integration.sh   (test the installed package)

set -u
# English messages, but UTF-8 so that accented labels are printed as they are
export LC_ALL=C.UTF-8

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
BM="${BM:-$REPO/big-mount/usr/bin/bigmount}"

if [ "$EUID" -eq 0 ]; then
    echo "integration: do not run as root" >&2
    exit 2
fi

PASS=0 FAIL=0 SKIP=0 FAILED=()
ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33m-\033[0m %s (skipped: %s)\n' "$1" "$2"; }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }
begin() { echo "— $1"; }

# Images live in /tmp (no exec needed); helper binaries need an exec mount
IMG="$(mktemp -d "${TMPDIR:-/tmp}/bigmount-integ.XXXXXX")"
BIN="$(mktemp -d "$HERE/.integ.XXXXXX")"
LOOPS=() PIDS=()

cleanup() {
    local p d
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    for d in "${LOOPS[@]}"; do
        while findmnt -n --source "$d" >/dev/null 2>&1; do
            udisksctl unmount --no-user-interaction -b "$d" >/dev/null 2>&1 || break
        done
        # An unlocked LUKS volume keeps the loop device busy
        for h in /sys/class/block/"${d##*/}"/holders/*; do
            [ -e "$h" ] || continue
            udisksctl unmount --no-user-interaction -b "/dev/${h##*/}" >/dev/null 2>&1
            udisksctl lock --no-user-interaction -b "$d" >/dev/null 2>&1
        done
        udisksctl loop-delete --no-user-interaction -b "$d" >/dev/null 2>&1
    done
    rm -rf "$IMG" "$BIN"
}
trap cleanup EXIT

# attach IMAGE [ro] -> DEV ; mount DEV [opts] -> MP
attach() {
    local out ro=()
    [ "${2:-}" = ro ] && ro=(-r)
    out="$(udisksctl loop-setup --no-user-interaction "${ro[@]}" -f "$1" 2>&1)" || return 1
    DEV="$(grep -o '/dev/loop[0-9]*' <<< "$out" | head -n1)"
    [ -n "$DEV" ] || return 1
    LOOPS+=("$DEV")
    udevadm settle --timeout=5 2>/dev/null
}
mountdev() {
    local opts=()
    [ -n "${2:-}" ] && opts=(-o "$2")
    udisksctl mount --no-user-interaction -b "$1" "${opts[@]}" >/dev/null 2>&1 || return 1
    MP="$(findmnt -n -o TARGET --source "$1" | head -n1)"
    [ -n "$MP" ]
}
img() { rm -f "$IMG/$1"; truncate -s "${2:-64M}" "$IMG/$1"; }
diag() { BM_OUT="$("$BM" --diagnose "$1" 2>&1)"; BM_RC=$?; }
has() { grep -qF -- "$1" <<< "$BM_OUT"; }
mounted() { findmnt -n --source "$1" >/dev/null 2>&1; }
bg() { "$@" & PIDS+=("$!"); LASTPID=$!; }

# ----- preconditions ---------------------------------------------------------
img probe.img 4M
if ! command -v udisksctl >/dev/null || ! attach "$IMG/probe.img"; then
    echo "integration: cannot set up loop devices through UDisks2 (no active local session?)."
    echo "integration: SKIPPED, nothing was tested."
    exit 77
fi
udisksctl loop-delete --no-user-interaction -b "$DEV" >/dev/null 2>&1
LOOPS=()
JOURNAL=0
[ -n "$(journalctl -k -b -n 1 -q 2>/dev/null)" ] && JOURNAL=1

echo "========================================="
echo "Integration tests (real UDisks2 mounts on loop devices)"
echo "bigmount: $BM"
echo "========================================="

# ----- A..G: why can't I write? ----------------------------------------------
begin "healthy ext4 owned by the user"
img ok.img; mkfs.ext4 -q -F -L BMOK -E root_owner="$(id -u):$(id -g)" "$IMG/ok.img"
attach "$IMG/ok.img" && mountdev "$DEV"
diag "$MP"
check "diagnosis: ok (exit 0)" test "$BM_RC" -eq 0
check "reports 'Device ready'" has "Device ready"
OK_DEV="$DEV" OK_MP="$MP"

begin "B: ext4 whose root folder belongs to root"
img perm.img; mkfs.ext4 -q -F -L BMPERM -E root_owner=0:0 "$IMG/perm.img"
attach "$IMG/perm.img" && mountdev "$DEV"
diag "$DEV"
check "cause: permission" has "diagnosis:   permission"
check "safe fix offered: take ownership (not recursive)" has "fix=take-ownership"
check "explains that only the main folder changes" has "Only that folder changes"

begin "B: partition that contains an operating system"
img os.img; mkfs.ext4 -q -F -L BMOS -E root_owner=0:0 -d "$REPO/tests/fixtures/os-root" "$IMG/os.img" 2>/dev/null \
    || mkfs.ext4 -q -F -L BMOS -E root_owner=0:0 "$IMG/os.img"
attach "$IMG/os.img" && mountdev "$DEV"
OS_DEV="$DEV"
if [ -e "$MP/etc/os-release" ]; then
    diag "$DEV"
    check "cause: permission" has "diagnosis:   permission (root directory root:root 755)"
    check "explains it contains an operating system" has "contains an operating system"
    check "take ownership NOT offered" bash -c '! grep -q "fix=take-ownership" <<< "$1"' _ "$BM_OUT"
else
    skip "operating system partition" "mkfs.ext4 -d unsupported"
fi

begin "E: write-protected device"
img wp.img; mkfs.ext4 -q -F -L BMWP "$IMG/wp.img"
attach "$IMG/wp.img" ro && mountdev "$DEV"
WP_DEV="$DEV"
diag "$DEV"
check "cause: hw-readonly" has "diagnosis:   hw-readonly"
check "explains the lock switch" has "lock switch"
check "no fix offered" bash -c '! grep -q "fix=" <<< "$1"' _ "$BM_OUT"

begin "A: healthy filesystem mounted read-only"
img ro.img; mkfs.ext4 -q -F -L BMRO -E root_owner="$(id -u):$(id -g)" "$IMG/ro.img"
attach "$IMG/ro.img" && mountdev "$DEV" ro
diag "$DEV"
check "cause: mounted-ro" has "diagnosis:   mounted-ro"
if [ "$JOURNAL" -eq 1 ]; then
    check "remount offered (no evidence of errors)" has "fix=remount"
else
    skip "remount offered" "kernel log not readable"
fi
RO_DEV="$DEV"

begin "A: the remount correction itself"
(
    BIGMOUNT_LIB="$(dirname "$(readlink -f "$BM")")/../lib/big-mount"
    # The library of whichever bigmount is being tested
    # shellcheck source=/dev/null
    . "$BIGMOUNT_LIB/lib.sh"
    bm_unmount_all "$RO_DEV" && bm_udisks mount -b "$RO_DEV" >/dev/null
)
diag "$RO_DEV"
check "after remount the device is writable" test "$BM_RC" -eq 0

begin "C: ext4 with recorded errors"
img err.img 32M; mkfs.ext4 -q -F -L BMERR -E root_owner="$(id -u):$(id -g)" "$IMG/err.img"
debugfs -w -R "ssv error_count 3" "$IMG/err.img" >/dev/null 2>&1
attach "$IMG/err.img" && mountdev "$DEV"
diag "$DEV"
check "still writable, but warns about the errors" has "warning:     ext4 errors_count=3"
check "advises to copy files and check it" has "Attention: the filesystem has recorded errors"
udisksctl unmount --no-user-interaction -b "$DEV" >/dev/null 2>&1
mountdev "$DEV" ro
diag "$DEV"
check "read-only + errors -> cause fs-errors" has "diagnosis:   fs-errors"
check "never offers to remount a damaged filesystem" bash -c '! grep -q "fix=remount" <<< "$1"' _ "$BM_OUT"

begin "D: hibernated NTFS (Windows Fast Startup)"
img hib.img; mkntfs -q -F -f -L BMHIBER "$IMG/hib.img" >/dev/null 2>&1
{ printf 'hibr'; head -c 8188 /dev/zero; } > "$IMG/hiberfil"
ntfscp -f "$IMG/hib.img" "$IMG/hiberfil" hiberfil.sys >/dev/null 2>&1
if ntfs-3g.probe --readwrite "$IMG/hib.img" >/dev/null 2>&1; then
    skip "hibernated NTFS" "could not create the hibernation marker"
else
    attach "$IMG/hib.img"
    # ntfs-3g either refuses read-write or silently falls back to read-only
    if mountdev "$DEV" || mountdev "$DEV" ro; then
        diag "$DEV"
        check "cause: ntfs-unsafe" has "diagnosis:   ntfs-unsafe"
        check "explains Fast Startup" has "Fast Startup"
        check "no repair offered (needs Windows)" bash -c '! grep -q "fix=" <<< "$1"' _ "$BM_OUT"
        check "image still hibernated: nothing was written" bash -c '! ntfs-3g.probe --readwrite "$1" >/dev/null 2>&1' _ "$IMG/hib.img"
    else
        skip "hibernated NTFS diagnosis" "read-only mount failed"
    fi
fi

begin "NTFS (FUSE): unmount returns only after the driver finished writing"
img fuse.img 96M; mkntfs -q -F -f -L BMFUSE "$IMG/fuse.img" >/dev/null 2>&1
if attach "$IMG/fuse.img" && mountdev "$DEV" && [ "$(findmnt -n -o FSTYPE --source "$DEV")" = fuseblk ]; then
    head -c 48M /dev/urandom > "$MP/data.bin"
    BM_OUT="$("$BM" --unmount "$DEV" 2>&1)"; BM_RC=$?
    check "--unmount exits 0" test "$BM_RC" -eq 0
    check "  ... and no FUSE daemon of the device is left when it returns" \
        bash -c '! pgrep -f -- "ntfs[^ ]* $1 " >/dev/null' _ "$DEV"
    check "the volume is clean afterwards (nothing left half written)" ntfs-3g.probe --readwrite "$IMG/fuse.img"
    # A bind mount made inside another mount namespace (as Docker does for a
    # volume) keeps the filesystem and its FUSE daemon alive after the
    # unmount here; a plain copy of the mount does not
    mkdir -p "$IMG/bindto"
    if mountdev "$DEV" && mkdir -p "$MP/vol" && unshare -r -m --propagation private true 2>/dev/null; then
        bg unshare -r -m --propagation private bash -c 'mount --bind "$1" "$2" && sleep 4; true' _ "$MP/vol" "$IMG/bindto"
        sleep 0.5
        BM_OUT="$("$BM" --busy "$DEV" 2>&1)"
        check "--busy shows the bind mount of the other namespace" has "Also mounted inside an isolated environment"
        check "  ... and only that one (not plain copies)" test "$(grep -c "isolated environment" <<< "$BM_OUT")" -eq 1
        BM_OUT="$("$BM" --unmount "$DEV" 2>&1)"; BM_RC=$?
        check "--unmount waits until it is gone (exit 0)" test "$BM_RC" -eq 0
        check "  ... the mount and the FUSE daemon are gone when it returns" \
            bash -c '! grep -qsF " $1 " /proc/[0-9]*/mountinfo && ! pgrep -f -- "ntfs[^ ]* $1 " >/dev/null' _ "$DEV"
    else
        skip "private mount namespace" "unprivileged user namespaces are disabled"
    fi
else
    skip "NTFS through FUSE" "UDisks did not mount the image with ntfs-3g"
fi

begin "a folder is judged where it is, not at the root of its partition"
diag /usr/share
check "a system folder owned by root -> permission-folder" has "diagnosis:   permission-folder"
check "  ... names the owner" has "This folder belongs to root"
check "  ... and offers no fix" bash -c '! grep -q "fix=" <<< "$1"' _ "$BM_OUT"

begin "G: filesystem without write support (ISO 9660 or SquashFS)"
mkdir -p "$IMG/isodir"; echo data > "$IMG/isodir/file.txt"
G_DONE=0
if xorriso -as mkisofs -quiet -V BMISO -o "$IMG/iso.img" "$IMG/isodir" >/dev/null 2>&1 \
    && attach "$IMG/iso.img" && mountdev "$DEV"; then
    diag "$DEV"; check "ISO 9660: cause unsupported" has "diagnosis:   unsupported"; G_DONE=1
fi
if mksquashfs "$IMG/isodir" "$IMG/sq.img" -quiet -noappend >/dev/null 2>&1 \
    && attach "$IMG/sq.img" && mountdev "$DEV"; then
    diag "$DEV"; check "SquashFS: cause unsupported" has "diagnosis:   unsupported"; G_DONE=1
fi
[ "$G_DONE" -eq 1 ] || skip "read-only filesystems" "kernel supports neither iso9660 nor squashfs"

begin "FAT32 and exFAT mounted by UDisks"
for t in vfat exfat; do
    img "$t.img" 64M
    if [ "$t" = vfat ]; then mkfs.vfat -n BMFAT "$IMG/$t.img" >/dev/null; else mkfs.exfat -L BMEXFAT "$IMG/$t.img" >/dev/null; fi
    attach "$IMG/$t.img" && mountdev "$DEV"
    diag "$DEV"
    check "$t: writable" test "$BM_RC" -eq 0
done

# ----- busy device -------------------------------------------------------------
begin "busy: terminal folder, reader, writer, kioworker"
img busy.img; mkfs.ext4 -q -F -L "BM Família" -E root_owner="$(id -u):$(id -g)" "$IMG/busy.img"
attach "$IMG/busy.img" && mountdev "$DEV"
BUSY_DEV="$DEV" BUSY_MP="$MP"
check "label with spaces and accents mounted" test -d "$BUSY_MP"
echo hello > "$BUSY_MP/a.txt"; : > "$BUSY_MP/thumbnail"
# A shell sitting in a folder of the device, without child processes
mkfifo "$BIN/idle"
bg bash -c 'cd "$1" && read -r -t 300 _ <> "$2"' _ "$BUSY_MP" "$BIN/idle"; P_SHELL=$LASTPID
bg bash -c 'exec 3< "$1/a.txt"; exec sleep 300' _ "$BUSY_MP"; P_READ=$LASTPID
bg bash -c 'exec 4>> "$1/b.txt"; exec sleep 300' _ "$BUSY_MP"; P_WRITE=$LASTPID
cp /usr/bin/tail "$BIN/kioworker"
bg bash -c 'cd "$1" && exec "$2" -f thumbnail' _ "$BUSY_MP" "$BIN/kioworker"; P_KIO=$LASTPID
sleep 1
BM_OUT="$("$BM" --busy "$BUSY_MP" 2>&1)"; BM_RC=$?
check "--busy exits 3 (busy)" test "$BM_RC" -eq 3
check "lists the shell with its folder on the device" has "Command shell (terminal)  |  bash  |  $P_SHELL  |  Current folder is on the device"
check "lists the reader" has "sleep  |  $P_READ  |  Open for reading"
check "lists the writer as writing (not as a transfer)" has "sleep  |  $P_WRITE  |  Open for writing"
check "recognises a kioworker by its protocol" has "KDE thumbnail generator  |  kioworker  |  $P_KIO"
check "no invented progress or speed" bash -c '! grep -qiE "[0-9]+ ?%|MB/s|remaining" <<< "$1"' _ "$BM_OUT"

begin "busy: unmount is refused and nothing is forced"
BM_OUT="$("$BM" --unmount "$BUSY_DEV" 2>&1)"; BM_RC=$?
check "--unmount exits 3" test "$BM_RC" -eq 3
check "device still mounted" mounted "$BUSY_DEV"
check "no success message" bash -c '! grep -qE "Unmounted|removed safely" <<< "$1"' _ "$BM_OUT"
check "all holders still alive" kill -0 "$P_SHELL" "$P_READ" "$P_WRITE" "$P_KIO"

begin "busy: closing programs only closes what is safe"
BM_OUT="$("$BM" --unmount "$BUSY_DEV" --close-apps --assume-yes 2>&1)"; BM_RC=$?
check "still busy because of the writer (exit 3)" test "$BM_RC" -eq 3
check "the writer was NOT closed" kill -0 "$P_WRITE"
check "the shell was NOT closed (user must cd)" kill -0 "$P_SHELL"
check "the reader was closed" bash -c '! kill -0 "$1" 2>/dev/null' _ "$P_READ"
check "the kioworker was closed" bash -c '! kill -0 "$1" 2>/dev/null' _ "$P_KIO"
check "explains why the writer is kept" has "has a file open for writing"
check "device still mounted" mounted "$BUSY_DEV"

begin "busy -> released -> unmounted"
kill "$P_WRITE" "$P_SHELL" 2>/dev/null; sleep 0.5
BM_OUT="$("$BM" --unmount "$BUSY_DEV" 2>&1)"; BM_RC=$?
check "--unmount exits 0" test "$BM_RC" -eq 0
check "really unmounted" bash -c '! findmnt -n --source "$1" >/dev/null' _ "$BUSY_DEV"
check "success reported only now" has "Unmounted."

begin "other holders: a second mount and a nested mount"
img outer.img; mkfs.ext4 -q -F -L BMOUTER -E root_owner="$(id -u):$(id -g)" "$IMG/outer.img"
attach "$IMG/outer.img" && mountdev "$DEV"
OUT_DEV="$DEV"
BM_OUT="$("$BM" --busy "$OUT_DEV" 2>&1)"; BM_RC=$?
check "--busy on an unused device exits 0" test "$BM_RC" -eq 0
check "  ... and says none of your programs uses it (not 'still in use')" bash -c 'grep -q "None of your programs is using BMOUTER" <<< "$1" && ! grep -q "still in use" <<< "$1"' _ "$BM_OUT"
check "  ... without claiming that nothing in the system uses it" bash -c '! grep -qi "nothing in the system" <<< "$1"' _ "$BM_OUT"
skip "second/nested mount detection" "needs root to create the extra mount (covered by tests/lib-tests.sh)"

begin "only the requested filesystem is unmounted"
BM_OUT="$("$BM" --unmount "$OUT_DEV" 2>&1)"; BM_RC=$?
check "--unmount exits 0" test "$BM_RC" -eq 0
check "the other device stays mounted" mounted "$OK_DEV"

begin "safe removal of a loop 'drive' (nothing to power off)"
BM_OUT="$("$BM" --safe-remove "$OK_MP" 2>&1)"; BM_RC=$?
check "--safe-remove exits 0" test "$BM_RC" -eq 0
check "really unmounted" bash -c '! findmnt -n --source "$1" >/dev/null' _ "$OK_DEV"
check "does not claim a power-off" bash -c '! grep -q "removed safely" <<< "$1"' _ "$BM_OUT"
check "reports the unmount" has "Unmounted."

begin "drive with two partitions (GPT: ext4 + FAT)"
img disk.img 80M
printf 'label: gpt\nstart=2048, size=65536, type=L\nstart=67584, size=65536, type=L\n' | sfdisk -q "$IMG/disk.img"
img p1.img 32M; mkfs.ext4 -q -F -L BMPART1 -E root_owner="$(id -u):$(id -g)" "$IMG/p1.img"
img p2.img 32M; mkfs.vfat -n BMPART2 "$IMG/p2.img" >/dev/null
dd if="$IMG/p1.img" of="$IMG/disk.img" bs=512 seek=2048 conv=notrunc status=none
dd if="$IMG/p2.img" of="$IMG/disk.img" bs=512 seek=67584 conv=notrunc status=none
attach "$IMG/disk.img"; DISK="$DEV"
if mountdev "${DISK}p1" && P1_MP="$MP" && mountdev "${DISK}p2"; then
    P2_MP="$MP"; echo x > "$P2_MP/f"
    bg bash -c 'exec 3< "$1/f"; exec sleep 300' _ "$P2_MP"; P_P2=$LASTPID; sleep 0.5
    BM_OUT="$("$BM" --safe-remove "$P1_MP" 2>&1)"; BM_RC=$?
    check "one busy partition -> the whole removal stops (exit 3)" test "$BM_RC" -eq 3
    check "the busy partition stays mounted" mounted "${DISK}p2"
    check "no success message" bash -c '! grep -qE "Unmounted|removed safely" <<< "$1"' _ "$BM_OUT"
    check "names the program on the busy partition" has "$P_P2"
    kill "$P_P2" 2>/dev/null; sleep 0.5
    BM_OUT="$("$BM" --safe-remove "$P1_MP" 2>&1)"; BM_RC=$?
    check "released -> both partitions unmounted (exit 0)" test "$BM_RC" -eq 0
    check "partition 1 unmounted" bash -c '! findmnt -n --source "$1" >/dev/null' _ "${DISK}p1"
    check "partition 2 unmounted" bash -c '! findmnt -n --source "$1" >/dev/null' _ "${DISK}p2"
else
    skip "two partitions" "the kernel did not expose the loop partitions"
fi

begin "a device that disappears"
img gone.img 32M; mkfs.ext4 -q -F -L BMGONE "$IMG/gone.img"
attach "$IMG/gone.img"; GONE="$DEV"
udisksctl loop-delete --no-user-interaction -b "$GONE" >/dev/null 2>&1; udevadm settle
BM_OUT="$("$BM" --diagnose "$GONE" 2>&1)"; BM_RC=$?
check "diagnosis of a vanished device fails cleanly (exit 1, message)" bash -c '[ "$1" -eq 1 ] && [ -n "$2" ] && ! grep -qiE "unbound|syntax|command not found" <<< "$2"' _ "$BM_RC" "$BM_OUT"
BM_OUT="$("$BM" --safe-remove "$GONE" 2>&1)"; BM_RC=$?
check "removal of a vanished device does not claim success" bash -c '[ "$1" -ne 0 ] && ! grep -qE "Unmounted|removed safely" <<< "$2"' _ "$BM_RC" "$BM_OUT"

begin "encrypted (LUKS) drive: removal from the mount point locks it"
img luks.img 64M
if ! grep -qw crypt <<< "$(cat /proc/misc /proc/modules 2>/dev/null)" && ! [ -d /sys/module/dm_crypt ]; then
    skip "encrypted (LUKS) drive" "dm-crypt is not loaded (modprobe dm_crypt as root)"
elif attach "$IMG/luks.img" && LUKS="$DEV" \
    && gdbus call --system --dest org.freedesktop.UDisks2 --object-path "/org/freedesktop/UDisks2/block_devices/${LUKS##*/}" \
        --method org.freedesktop.UDisks2.Block.Format ext4 \
        "{'encrypt.passphrase': <'bm-test'>, 'label': <'BMLUKS'>, 'auth.no_user_interaction': <true>}" >/dev/null 2>&1 \
    && udevadm settle && CLEAR="$(lsblk -nrpo NAME "$LUKS" | sed -n 2p)" && [ -n "$CLEAR" ] && mountdev "$CLEAR"; then
    BM_OUT="$("$BM" --diagnose "$MP" 2>&1)"
    check "the drive of the decrypted volume is the loop device, not the volume itself" has "disk $LUKS"
    BM_OUT="$("$BM" --safe-remove "$MP" 2>&1)"; BM_RC=$?
    check "--safe-remove from the mount point exits 0" test "$BM_RC" -eq 0
    check "  ... unmounted" bash -c '! findmnt -n --source "$1" >/dev/null' _ "$CLEAR"
    check "  ... and the encrypted volume is locked" bash -c '[ -z "$(lsblk -nrpo NAME "$1" | sed -n 2p)" ]' _ "$LUKS"
else
    skip "encrypted (LUKS) drive" "UDisks could not format or mount the image"
fi

begin "the running system is never unmounted"
BM_OUT="$("$BM" --safe-remove / 2>&1)"; BM_RC=$?
check "--safe-remove / refused (exit 4)" test "$BM_RC" -eq 4
check "/ still mounted" findmnt -n / >/dev/null
if findmnt -n /home >/dev/null; then
    BM_OUT="$("$BM" --unmount /home 2>&1)"; BM_RC=$?
    check "--unmount /home refused (exit 4)" test "$BM_RC" -eq 4
fi

# ----- graphical flows with scripted clicks -------------------------------------
# A fake kdialog answers from a script ("RC [STDOUT]" per dialog) and logs
# every call; when the script ends it answers "cancel", so no loop can hang.
mkdir -p "$BIN/fake"
cat > "$BIN/fake/kdialog" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_KD_LOG"
n=$(($(cat "$FAKE_KD_STATE" 2>/dev/null || echo 0) + 1)); echo "$n" > "$FAKE_KD_STATE"
line="$(sed -n "${n}p" "$FAKE_KD_ANSWERS")"
[ -n "$line" ] || exit 2
rc="${line%% *}"; out="${line#"$rc"}"; out="${out# }"
[ -n "$out" ] && printf '%s\n' "$out"
exit "$rc"
EOF
cat > "$BIN/fake/notify-send" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_NOTIFY_LOG"
EOF
chmod +x "$BIN/fake/kdialog" "$BIN/fake/notify-send"
gui() { # ANSWER... -- bigmount args
    local answers=()
    while [ "$1" != -- ]; do answers+=("$1"); shift; done; shift
    printf '%s\n' "${answers[@]}" > "$BIN/answers"; : > "$BIN/kd.log"; : > "$BIN/notify.log"; rm -f "$BIN/state"
    BM_UI=kdialog WAYLAND_DISPLAY=fake DBUS_SESSION_BUS_ADDRESS=fake PATH="$BIN/fake:$PATH" \
        FAKE_KD_ANSWERS="$BIN/answers" FAKE_KD_STATE="$BIN/state" FAKE_KD_LOG="$BIN/kd.log" \
        FAKE_NOTIFY_LOG="$BIN/notify.log" "$BM" "$@" < /dev/null > /dev/null 2>&1
    GUI_RC=$?
    sleep 1
}
kd_has() { grep -qF -- "$1" "$BIN/kd.log"; }

begin "GUI remove: busy -> More options -> Close programs -> removed"
img gui.img; mkfs.ext4 -q -F -L BMGUI -E root_owner="$(id -u):$(id -g)" "$IMG/gui.img"
attach "$IMG/gui.img" && mountdev "$DEV"
GUI_DEV="$DEV" GUI_MP="$MP"; echo x > "$GUI_MP/f"
bg bash -c 'exec 3< "$1/f"; exec sleep 300' _ "$GUI_MP"; P_GUI=$LASTPID; sleep 0.5
gui "1" "0 close" "1" -- --gui-remove "$GUI_MP/f"
check "flow ends successfully (exit 0)" test "$GUI_RC" -eq 0
check "busy dialog shown with the holder's PID" kd_has "$P_GUI"
check "busy dialog title names the device" kd_has "BMGUI is still in use"
check "plain-language summary first" kd_has "Close that program, then try again."
check "confirmation listed the program before closing it" bash -c 'grep -F -- "--warningyesno" "$1" | grep -qF "PID $2"' _ "$BIN/kd.log" "$P_GUI"
check "the safe answer (Cancel) is the default button" kd_has "--yes-label Cancel --no-label Close them"
check "the reader was closed" bash -c '! kill -0 "$1" 2>/dev/null' _ "$P_GUI"
check "really unmounted" bash -c '! findmnt -n --source "$1" >/dev/null' _ "$GUI_DEV"
check "notification only after success" grep -q "Device unmounted" "$BIN/notify.log"
check "information popup is transient and lasts 5 s" grep -q -- "--expire-time 5000 .*--transient" "$BIN/notify.log"
check "no power-off claimed for a loop device" bash -c '! grep -q "removed safely" "$1"' _ "$BIN/notify.log"

begin "GUI remove: an accidental Enter in the close confirmation closes nothing"
mountdev "$GUI_DEV"; GUI_MP="$MP"
bg bash -c 'exec 3< "$1/f"; exec sleep 300' _ "$GUI_MP"; P_GUI=$LASTPID; sleep 0.5
gui "1" "0 close" "0" -- --gui-remove "$GUI_MP"
check "Enter (default button) keeps the program running" kill -0 "$P_GUI"
check "still mounted" mounted "$GUI_DEV"
kill "$P_GUI" 2>/dev/null; sleep 0.3
udisksctl unmount --no-user-interaction -b "$GUI_DEV" >/dev/null 2>&1

begin "GUI remove: busy -> Cancel keeps everything as it was"
mountdev "$GUI_DEV"; GUI_MP="$MP"
bg bash -c 'exec 3< "$1/f"; exec sleep 300' _ "$GUI_MP"; P_GUI=$LASTPID; sleep 0.5
gui "2" -- --gui-remove "$GUI_MP"
check "exit 3 (busy)" test "$GUI_RC" -eq 3
check "still mounted" mounted "$GUI_DEV"
check "holder untouched" kill -0 "$P_GUI"
check "no notification" test ! -s "$BIN/notify.log"
kill "$P_GUI" 2>/dev/null

begin "GUI remove: the running system is refused"
gui -- --gui-remove /
check "exit 4" test "$GUI_RC" -eq 4
check "notification explains it" grep -q "It holds the operating system that is running now." "$BIN/notify.log"
check "errors stay 15 s and are kept in the history" bash -c 'grep -q -- "--expire-time 15000" "$1" && ! grep -q -- "--transient" "$1"' _ "$BIN/notify.log"
check "no dialog for a mere error" test ! -s "$BIN/kd.log"

begin "GUI diagnose: read-only mount -> Mount again with writing"
udisksctl unmount --no-user-interaction -b "$GUI_DEV" >/dev/null 2>&1
mountdev "$GUI_DEV" ro
if [ "$JOURNAL" -eq 1 ]; then
    gui "0" "0" "1" -- --gui "$GUI_DEV"
    check "fix offered in the dialog" kd_has "--yes-label Mount again with writing"
    check "confirmation explains nothing is changed" kd_has "Nothing on it is changed."
    check "success reported by a popup, not a dialog" grep -q "You can now write to this device." "$BIN/notify.log"
    diag "$GUI_DEV"
    check "device really writable now" test "$BM_RC" -eq 0
else
    skip "GUI remount" "kernel log not readable"
fi

begin "GUI diagnose: write-protected device has no fix button"
gui "1" -- --gui "$WP_DEV"
check "no fix label offered" bash -c '! grep -qE "Mount again|Become owner" "$1"' _ "$BIN/kd.log"
check "explains the lock switch" kd_has "lock switch"

# ----- notifier ------------------------------------------------------------------
begin "notifier: warns once about a read-only device"
NOTE_HOME="$(mktemp -d)"
img note.img; mkfs.ext4 -q -F -L BMNOTE "$IMG/note.img"
(
    exec env -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY -u DISPLAY \
        XDG_RUNTIME_DIR="$NOTE_HOME" XDG_STATE_HOME="$NOTE_HOME/state" "$BM" --notifier
) 2> "$NOTE_HOME/notes" &
P_NOTE=$!; PIDS+=("$P_NOTE")
sleep 1
attach "$IMG/note.img" ro && mountdev "$DEV"
sleep 3
notes_for() { grep -c "^Read-only device: Device: $1 " "$NOTE_HOME/notes"; }
check "initial scan: warns about the device already mounted read-only (BMWP)" test "$(notes_for BMWP)" -eq 1
check "hot-plugged read-only device: one notification" test "$(notes_for BMNOTE)" -eq 1
check "the notification names the reason" grep -q "write-protected" "$NOTE_HOME/notes"
udisksctl unmount --no-user-interaction -b "$DEV" >/dev/null 2>&1; mountdev "$DEV" ro
sleep 3
check "same device and cause again: no repeated notification" test "$(notes_for BMNOTE)" -eq 1
check "writable devices produce no notification" bash -c '! grep -qE "Device: (BMOK|BMOUTER|BMFAT|BMEXFAT) " "$1"' _ "$NOTE_HOME/notes"
if mounted "$OS_DEV"; then
    check "a partition holding an operating system produces no notification" bash -c '! grep -q "Device: BMOS " "$1"' _ "$NOTE_HOME/notes"
fi
NOTE_POLL="$(pgrep -P "$P_NOTE" -x findmnt | tr '\n' ' ')"
check "the notifier waits on findmnt --poll" test -n "$NOTE_POLL"
kill "$P_NOTE" 2>/dev/null; sleep 0.5
# shellcheck disable=SC2086  # a list of PIDs
check "a stopped notifier leaves no findmnt behind" bash -c '! kill -0 "$@" 2>/dev/null' _ $NOTE_POLL
NOTE_LOCK_HELD=0
for f in /proc/[0-9]*/fd/*; do
    [ "$(readlink "$f" 2>/dev/null)" = "$NOTE_HOME/big-mount-notifier.lock" ] && NOTE_LOCK_HELD=1
done
check "  ... nor anything holding its lock" test "$NOTE_LOCK_HELD" -eq 0
(
    exec env -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY -u DISPLAY \
        XDG_RUNTIME_DIR="$NOTE_HOME" XDG_STATE_HOME="$NOTE_HOME/state" "$BM" --notifier
) 2>/dev/null &
P_NOTE2=$!; PIDS+=("$P_NOTE2"); sleep 1
check "  ... so a new notifier can start" kill -0 "$P_NOTE2"
kill "$P_NOTE2" 2>/dev/null; sleep 0.3
rm -rf "$NOTE_HOME"

echo ""
echo "========================================="
echo "integration result: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
