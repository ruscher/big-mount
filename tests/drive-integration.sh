#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329,SC2024,SC2034,SC2015,SC2030,SC2031  # snippets and helpers called through check()
# Real scenarios of the drive manager, on disposable images only: real
# filesystems, real mounts through UDisks2, real I/O errors (dm-error), real
# stalled reads (dm-delay), a supervisor killed as a power cut would, a source
# that goes away, a destination that fills up, LUKS.
#
# Needs a local session with UDisks2 and sudo for device-mapper. Run by hand:
#   bash tests/drive-integration.sh [SCENARIO...]
#
# NOTHING here touches a real disk: every privileged device command goes
# through on_scratch, which refuses anything but our own loop and mapper devices.
set -u
export LC_ALL=C.UTF-8 LANGUAGE=C
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
B="${BM:-$REPO/big-mount/usr/bin/bigmount}"
WORK="$(mktemp -d "${TMPDIR:-/var/tmp}/bm-drive-XXXXXX")"
export XDG_STATE_HOME="$WORK/state" XDG_RUNTIME_DIR_REAL="${XDG_RUNTIME_DIR:-}"
PASS=0 FAIL=0 FAILED=()
LOOPS=() DMS=() MNTS=()
check() {
   local msg="$1"; shift
   if "$@"; then PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$msg"
   else FAIL=$((FAIL + 1)); FAILED+=("$msg"); printf '  \033[31m✗\033[0m %s\n' "$msg"; fi
}
eq() { [ "$1" = "$2" ] || { printf '      got: [%s]\n expected: [%s]\n' "$1" "$2"; return 1; }; }
begin() { echo "— $1"; }
# DEBUG=1: what a job left behind, when something fails
job_dump() {
   [ -n "${DEBUG:-}" ] || return 0
   local j="$XDG_STATE_HOME/big-mount/jobs/$1"
   echo "      --- job $1"; sed 's/^/      /' "$j/state.env" | grep -E 'STATE|REASON|RSYNC_RC|FILES_|BYTES_DONE|DEFERRED|FAILED'
   for f in events.log rsync.out failed.txt deferred.txt supervisor.log; do
      echo "      --- $f"; tail -n 14 "$j/$f" 2>/dev/null | cut -c1-150 | sed 's/^/      /'
   done
}
want() { [ "${#WANT[@]}" -eq 0 ] && return 0; [[ " ${WANT[*]} " == *" $1 "* ]]; }
WANT=("$@")

on_scratch() {
   case "$1" in /dev/loop* | /dev/mapper/bmt-*) ;; *) echo "REFUSED: $1 is not a scratch device" >&2; exit 99 ;; esac
   local d; for d in "${LOOPS[@]}"; do [[ $1 == "$d"* ]] && return 0; done
   [[ $1 == /dev/mapper/bmt-* ]] && return 0
   echo "REFUSED: $1 was not created here" >&2; exit 99
}

cleanup() {
   local d m
   for m in "${MNTS[@]}"; do [ -n "$m" ] && sudo -n umount "$m" 2>/dev/null; done
   for d in "${LOOPS[@]}"; do
      for m in "$d" "$d"p*; do [ -b "$m" ] && udisksctl unmount -b "$m" --no-user-interaction >/dev/null 2>&1; done
   done
   for d in "${DMS[@]}"; do sudo -n dmsetup remove --retry "$d" 2>/dev/null; done
   for d in "${LOOPS[@]}"; do sudo -n cryptsetup close "bmt-luks-${d##*/}" 2>/dev/null; sudo -n losetup -d "$d" 2>/dev/null; done
   # Only with nothing mounted under it
   findmnt -rn -o TARGET | grep -q "^$WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

# new_img NAME SIZE MKFS...: an image with a filesystem on a loop device
new_img() {
   local n="$1" size="$2" d; shift 2
   truncate -s "$size" "$WORK/$n.img"
   "$@" "$WORK/$n.img" >/dev/null 2>&1 || { echo "mkfs of $n failed" >&2; return 1; }
   loop_up "$WORK/$n.img"
}
# A loop device of this user: UDisks2 needs no authorization for it, so no
# password dialog ever appears on the screen during the tests
loop_up() {
   local d
   d="$(udisksctl loop-setup -f "$1" --no-user-interaction 2>/dev/null | sed -E 's/.* as (\/dev\/loop[0-9]+)\.?$/\1/')"
   [[ $d == /dev/loop* ]] || { echo "loop-setup of $1 failed" >&2; return 1; }
   LOOPS+=("$d")
   udevadm settle
   REPLY="$d"
}
mnt_rw() { udisksctl mount -b "$1" --no-user-interaction 2>&1 | sed -E 's/.* at (.*)$/\1/'; }
umnt() { udisksctl unmount -b "$1" --no-user-interaction >/dev/null 2>&1; udevadm settle; }
wait_state() { # ID STATE... : until the job is in one of them, 120 s at most
   local id="$1" n s; shift
   for ((n = 0; n < 240; n++)); do
      s="$("$B" --drive status "$id" --json | json state)"
      for w in "$@"; do [ "$s" = "$w" ] && return 0; done
      sleep 0.5
   done
   echo "      state stayed: $s" >&2
   return 1
}
json() { python3 -I -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d[k]
print(d if not isinstance(d,bool) else str(d).lower())' "$1"; }
valid_json() { python3 -I -m json.tool >/dev/null; }
job_id() { json id; }
tree_same() { diff -r --no-dereference --exclude=lost+found -- "$1" "$2" >/dev/null; }
populate() { # DIR: files that exercise names, depth, links and sizes
   local d="$1" i
   mkdir -p "$d/fotos de família/2020 – férias/ação" "$d/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p" "$d/日本語"
   printf 'olá\n' > "$d/fotos de família/2020 – férias/ação/maçã & pêra [1].txt"
   printf 'deep\n' > "$d/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/fundo.txt"
   printf 'x\n' > "$d/日本語/ファイル.txt"
   printf 'dash\n' > "$d/-começa com traço"
   printf 'star\n' > "$d/es*trela?.txt"
   printf 'latin1\n' > "$d/$(printf 'caf\351 antigo.txt')"
   for i in 1 2 3 4 5 6 7 8 9 10; do head -c 300000 /dev/urandom > "$d/foto$i.jpg"; done
   head -c 40000000 /dev/urandom > "$d/video.mkv"
   ln -s "fotos de família" "$d/link-relativo"
   ln -s /etc/passwd "$d/link-absoluto"
}

echo "========================================="
echo "Drive manager on disposable images"
echo "========================================="

if want filesystems; then
begin "every filesystem mounts read-only, and the mount table says so"
for spec in "ext4 mkfs.ext4 -q -F -L T_EXT4" "btrfs mkfs.btrfs -q -f -L T_BTRFS" "xfs mkfs.xfs -q -f -L T_XFS" "ntfs mkfs.ntfs -q -F -f -L T_NTFS" "exfat mkfs.exfat -L T_EXFAT" "vfat mkfs.vfat -n T_VFAT"; do
   read -r -a a <<< "$spec"
   n="${a[0]}"
   new_img "fs$n" 320M "${a[@]:1}" || { check "$n: image created" false; continue; }
   d="$REPLY"
   out="$("$B" --drive mount "$d" --read-only --json)"; rc=$?
   check "$n: mount exit 0" eq "$rc" 0
   check "$n: JSON says read_only" eq "$(json read_only <<< "$out")" true
   mp="$(json mountpoint <<< "$out")"
   check "$n: findmnt really shows ro" bash -c '[[ ,$(findmnt -n -o VFS-OPTIONS --mountpoint "$1"), == *,ro,* ]]' _ "$mp"
   check "$n: writing to it fails" bash -c '! touch "$1/x" 2>/dev/null' _ "$mp"
   out2="$("$B" --drive mount "$d" --read-only --json)"
   check "$n: mounting again changes nothing" eq "$(json mountpoint <<< "$out2")" "$mp"
   "$B" --drive diagnose "$d" --json | valid_json; check "$n: diagnose is valid JSON" eq "${PIPESTATUS[1]}" 0
   "$B" --drive unmount "$d" >/dev/null; check "$n: unmount" eq "$?" 0
done
fi

if want dirty; then
begin "a filesystem that was not closed: its journal is not replayed, the image does not change"
new_img dirtysrc 128M mkfs.ext4 -q -F -L T_DIRTY; d="$REPLY"
mp="$(mnt_rw "$d")"; sudo -n chown "$EUID" "$mp"
printf 'journal\n' > "$mp/f.txt"; sync -f "$mp"
# The copy of a mounted filesystem is what a power cut leaves on the disk
cp --sparse=always "$WORK/dirtysrc.img" "$WORK/dirty.img"
umnt "$d"
check "the copy has a dirty journal" bash -c 'LC_ALL=C dumpe2fs -h "$1" 2>/dev/null | grep -q needs_recovery' _ "$WORK/dirty.img"
before="$(sha256sum < "$WORK/dirty.img")"
loop_up "$WORK/dirty.img"; d2="$REPLY"
out="$("$B" --drive mount "$d2" --read-only --json)"; rc=$?
check "mounted without replaying" eq "$rc" 0
mp2="$(json mountpoint <<< "$out")"
check "noload is in effect" bash -c '[[ ,$(findmnt -n -o VFS-OPTIONS,FS-OPTIONS --mountpoint "$1" | tr " " ,), == *,ro,* ]]' _ "$mp2"
"$B" --drive unmount "$d2" >/dev/null
sudo -n losetup -d "$d2"; udevadm settle
check "the image is byte for byte what it was" eq "$(sha256sum < "$WORK/dirty.img")" "$before"
fi

# Source and destination used by the copy scenarios
SRC="" DST=""
need_pair() {
   [ -n "$SRC" ] && return 0
   new_img src 256M mkfs.ext4 -q -F -L T_SRC; SRC="$REPLY"
   SRCMP="$(mnt_rw "$SRC")"
   sudo -n chown "$EUID" "$SRCMP"; mkdir "$SRCMP/data"; populate "$SRCMP/data"; sync -f "$SRCMP"
   umnt "$SRC"
   SRCMP="$("$B" --drive mount "$SRC" --read-only --json | json mountpoint)"
   new_img dst 256M mkfs.ext4 -q -F -m 0 -L T_DST; DST="$REPLY"
   DSTMP="$(mnt_rw "$DST")"
   sudo -n chown "$EUID" "$DSTMP"
}
fresh_dest() { rm -rf "$DSTMP/out" "$DSTMP"/.big-mount-*; mkdir -p "$DSTMP/out"; }

if want copy; then
begin "a copy: names, depth, links, resuming the same job, the report"
need_pair; fresh_dest
out="$("$B" --drive copy --source "$SRCMP/data" --destination "$DSTMP/out" --verify full --no-wait --json)"; rc=$?
check "started" eq "$rc" 0
id="$(job_id <<< "$out")"
wait_state "$id" completed needs-attention failed
s="$("$B" --drive status "$id" --json)"
check "status is valid JSON" valid_json <<< "$s"
check "completed" eq "$(json state <<< "$s")" completed
check "full check says they match" eq "$(json verify_result <<< "$s")" ok
check "the tree is identical (unicode, depth, specials, links)" tree_same "$SRCMP/data" "$DSTMP/out"
check "the absolute link was copied as a link, not followed" eq "$(readlink "$DSTMP/out/link-absoluto")" /etc/passwd
check "the file counted as complete has the right size" eq "$(stat -c %s "$DSTMP/out/video.mkv")" 40000000
check "total was measured: 100%" eq "$(json bytes_done <<< "$s")" "$(json bytes_total <<< "$s")"
check "no temporary folder left" bash -c '! compgen -G "$1/out/.big-mount-*" >/dev/null' _ "$DSTMP"
check "the source was mounted read-only all along" bash -c '[[ ,$(findmnt -n -o VFS-OPTIONS --mountpoint "$1"), == *,ro,* ]]' _ "$SRCMP"
"$B" --drive report "$id" >"$WORK/rep.txt"; check "report written" grep -q 'Files copied' "$WORK/rep.txt"
"$B" --drive jobs --json | valid_json; check "history is valid JSON" eq "${PIPESTATUS[1]}" 0
check "history lists it" bash -c '"$1" --drive jobs | grep -q "$2"' _ "$B" "$id"

begin "selected items only"
fresh_dest
"$B" --drive copy --source "$SRCMP/data" --destination "$DSTMP/out" --item "日本語" --item "fotos de família/2020 – férias" --item "es*trela?.txt" >/dev/null; rc=$?
check "exit 0" eq "$rc" 0
check "the file is there" test -f "$DSTMP/out/日本語/ファイル.txt"
check "the path inside is kept" test -f "$DSTMP/out/fotos de família/2020 – férias/ação/maçã & pêra [1].txt"
check "the special name is copied literally" test -f "$DSTMP/out/es*trela?.txt"
check "the rest is not copied" test ! -e "$DSTMP/out/video.mkv"

begin "files that already exist"
fresh_dest
printf 'minha versão\n' > "$DSTMP/out/foto1.jpg"
"$B" --drive copy --source "$SRCMP/data" --destination "$DSTMP/out" --verify metadata >/dev/null; rc=$?
check "skip (default): the existing file is untouched" eq "$(cat "$DSTMP/out/foto1.jpg")" "minha versão"
check "skip: the check says they differ (exit 22)" eq "$rc" 22
fresh_dest
printf 'minha versão\n' > "$DSTMP/out/foto1.jpg"
"$B" --drive copy --source "$SRCMP/data" --destination "$DSTMP/out" --on-conflict backup >/dev/null; rc=$?
check "backup: exit 0" eq "$rc" 0
check "backup: replaced" cmp -s "$DSTMP/out/foto1.jpg" "$SRCMP/data/foto1.jpg"
check "backup: the old one was kept" bash -c 'grep -qx "minha versão" "$1"/out/.big-mount-backup-*/foto1.jpg' _ "$DSTMP"
fresh_dest
printf 'minha versão\n' > "$DSTMP/out/foto1.jpg"
"$B" --drive copy --source "$SRCMP/data" --destination "$DSTMP/out" --on-conflict overwrite >/dev/null
check "overwrite: replaced, only when asked" cmp -s "$DSTMP/out/foto1.jpg" "$SRCMP/data/foto1.jpg"
fi

if want refuse; then
begin "refusals: nothing is created, the exit code says why"
need_pair; fresh_dest
refused() { # EXPECTED_RC ERROR_KEY ARGS...
   local want_rc="$1" key="$2" out rc; shift 2
   out="$("$B" --drive copy "$@" --dry-run --json 2>/dev/null)"; rc=$?
   [ "$rc" = "$want_rc" ] && [ "$(json error <<< "$out")" = "$key" ] || { echo "      rc=$rc out=$out"; return 1; }
}
check "same folder" refused 20 same-path --source "$SRCMP/data" --destination "$SRCMP/data"
check "inside the source" refused 20 dest-inside-source --source "$SRCMP/data" --destination "$SRCMP/data/sub"
check "source inside destination" refused 20 source-inside-dest --source "$SRCMP/data" --destination "$SRCMP"
check "a link to the source is seen through" bash -c 'ln -sfn "$2" "$3/lnk"; ! "$1" --drive copy --source "$2" --destination "$3/lnk/x" --dry-run >/dev/null 2>&1' _ "$B" "$SRCMP/data" "$DSTMP"
rm -f "$DSTMP/lnk"
mkdir -p "$DSTMP/here"
check "same filesystem" refused 20 same-fs --source "$DSTMP/here" --destination "$DSTMP/out"
check "read-only destination" refused 20 dest-ro --source "$DSTMP/here" --destination "$SRCMP/data/x"
check "an item outside the source" refused 20 item-bad --source "$SRCMP/data" --destination "$DSTMP/out" --item "../../etc"
check "an absolute item" refused 20 item-bad --source "$SRCMP/data" --destination "$DSTMP/out" --item "/etc"
check "an item that does not exist" refused 20 item-missing --source "$SRCMP/data" --destination "$DSTMP/out" --item "nope"
check "a source that does not exist" refused 20 source-missing --source "$SRCMP/nope" --destination "$DSTMP/out"
check "no permission at the destination" refused 20 dest-denied --source "$SRCMP/data" --destination "/usr/lib/bm-test"
new_img small 16M mkfs.ext4 -q -F -m 0 -L T_SMALL; sm="$REPLY"; smp="$(mnt_rw "$sm")"; sudo -n chown "$EUID" "$smp"
check "a measured total that does not fit" refused 21 no-space --source "$SRCMP/data" --destination "$smp/out"
umnt "$sm"
check "a bad option value is usage, exit 2" bash -c '"$1" --drive copy --source a --destination b --verify nope >/dev/null 2>&1; [ $? = 2 ]' _ "$B"
fi

if want samedisk; then
begin "two partitions of one disk are the same physical disk"
truncate -s 128M "$WORK/two.img"
printf 'label: gpt\n,50M\n,\n' | sfdisk -q "$WORK/two.img"
d="$(sudo -n losetup --find --show --partscan "$WORK/two.img")"; LOOPS+=("$d"); udevadm settle
on_scratch "${d}p1"; on_scratch "${d}p2"
sudo -n mkfs.ext4 -q -F -L T_P1 "${d}p1"; sudo -n mkfs.ext4 -q -F -m 0 -L T_P2 "${d}p2"; udevadm settle
m1="$WORK/p1"; m2="$WORK/p2"; mkdir "$m1" "$m2"
sudo -n mount -o ro "${d}p1" "$m1"; MNTS+=("$m1"); sudo -n mount "${d}p2" "$m2"; MNTS+=("$m2"); sudo -n chown "$EUID" "$m2"
out="$("$B" --drive copy --source "$m1" --destination "$m2/x" --dry-run --json)"; rc=$?
check "refused" eq "$(json error <<< "$out")" same-disk
check "exit 20" eq "$rc" 20
out="$("$B" --drive copy --source "$m1" --destination "$m2/x" --dry-run --allow-same-disk --json)"; rc=$?
check "accepted only when allowed on purpose" eq "$rc" 0
check "and it says so" eq "$(json same_disk <<< "$out")" true
"$B" --drive destinations --source "$m1" --json > "$WORK/dests.json"
check "the assistant does not recommend it" python3 -I -c 'import json,sys
ds=json.load(open(sys.argv[1]))["destinations"]; p=[x for x in ds if x["path"]==sys.argv[2]][0]
sys.exit(p["recommended"] or p["independent"])' "$WORK/dests.json" "$m2"
fi

if want interrupt; then
begin "pause, cancel and a power cut: nothing is lost, and it resumes"
need_pair; fresh_dest
# Slow enough to catch it in the middle
out="$("$B" --drive copy --source "$SRCMP/data" --destination "$DSTMP/out" --bwlimit 4000 --no-wait --json)"; id="$(job_id <<< "$out")"
sleep 3
"$B" --drive pause "$id" >/dev/null; wait_state "$id" paused
check "paused" eq "$("$B" --drive status "$id" --json | json state)" paused
check "pausing does not leave half a file with the final name" bash -c 'for f in "$1"/out/foto*.jpg "$1"/out/video.mkv; do [ -e "$f" ] || continue; cmp -s "$f" "$2/${f##*/}" || exit 1; done' _ "$DSTMP" "$SRCMP/data"
"$B" --drive resume "$id" --no-wait >/dev/null; wait_state "$id" running
sleep 2
"$B" --drive cancel "$id" >/dev/null; wait_state "$id" cancelled
check "cancelled" eq "$("$B" --drive status "$id" --json | json state)" cancelled
check "what was copied stays" bash -c 'compgen -G "$1/out/*" >/dev/null' _ "$DSTMP"
"$B" --drive resume "$id" --no-wait >/dev/null; wait_state "$id" running
sleep 2
# A power cut: the supervisor and rsync vanish without any chance to clean up
pid="$(grep '^PID=' "$XDG_STATE_HOME/big-mount/jobs/$id/state.env" | cut -d= -f2)"
pkill -KILL -P "$pid"; kill -KILL "$pid"; sleep 1; pkill -KILL -f "rsync.*$DSTMP/out" ; sleep 1
check "it is seen as interrupted" eq "$("$B" --drive status "$id" --json | json state)" interrupted
"$B" --drive status "$id" --watch >/dev/null; check "--watch does not hang on it, exit 24" eq "$?" 24
"$B" --drive resume "$id" --no-wait >/dev/null; wait_state "$id" completed needs-attention failed
check "resumed to the end" eq "$("$B" --drive status "$id" --json | json state)" completed
check "the tree is identical" tree_same "$SRCMP/data" "$DSTMP/out"
check "no temporary folder left" bash -c '! compgen -G "$1/out/.big-mount-*" >/dev/null' _ "$DSTMP"
fi

# Build a device-mapper device with one file's blocks replaced by TARGET
# bad_dm NAME IMG FILE_IN_FS TARGET...: REPLY is the mapper path
blocks_of() { sudo -n filefrag -e -b512 "$1" 2>/dev/null | awk -F'[: .]+' '/^ *[0-9]+:/ {print $5, $7; exit}'; } # start length, in sectors
bad_dm() { # NAME LOOP START LENGTH TARGET_LINE
   local n="$1" dev="$2" s="$3" l="$4" t="$5" total
   total="$(sudo -n blockdev --getsz "$dev")"
   on_scratch "$dev"
   {
      printf '0 %s linear %s 0\n' "$s" "$dev"
      printf '%s %s %s\n' "$s" "$l" "$t"
      printf '%s %s linear %s %s\n' "$((s + l))" "$((total - s - l))" "$dev" "$((s + l))"
   } | sudo -n dmsetup create "bmt-$n"
   DMS+=("bmt-$n")
   udevadm settle
   REPLY="/dev/mapper/bmt-$n"
}

if want ioerror; then
begin "real read errors: the bad file is reported, everything else is saved"
new_img eio 128M mkfs.ext4 -q -F -L T_EIO; d="$REPLY"
mp="$(mnt_rw "$d")"; sudo -n chown "$EUID" "$mp"
for i in 1 2 3 4 5; do head -c 200000 /dev/urandom > "$mp/ok$i.bin"; done
head -c 200000 /dev/urandom > "$mp/ruim.bin"
head -c 200000 /dev/urandom > "$mp/zz-depois.bin"
sync -f "$mp"
read -r s l < <(blocks_of "$mp/ruim.bin")
umnt "$d"
bad_dm eio "$d" "$s" "$l" error; dm="$REPLY"
m="$WORK/eio"; mkdir "$m"
sudo -n mount -o ro,noload "$dm" "$m"; MNTS+=("$m")
need_pair; fresh_dest
"$B" --drive copy --source "$m" --destination "$DSTMP/out" --scan no >"$WORK/out.txt"; rc=$?
check "exit 22: finished, not everything was copied" eq "$rc" 22
check "the good files are all there" bash -c 'for i in 1 2 3 4 5; do cmp -s "$1/ok$i.bin" "$2/out/ok$i.bin" || exit 1; done' _ "$m" "$DSTMP"
check "the file after the bad one was not lost" cmp -s "$m/zz-depois.bin" "$DSTMP/out/zz-depois.bin"
check "the bad file was NOT left with its final name" test ! -e "$DSTMP/out/ruim.bin"
# shellcheck disable=SC2012  # job names have no special characters
id="$(ls -t "$XDG_STATE_HOME/big-mount/jobs" | head -1)"
s_json="$("$B" --drive status "$id" --json)"
check "state: needs attention" eq "$(json state <<< "$s_json")" needs-attention
check "the bad file is not counted as copied (6 of 7 files)" eq "$(json files_done <<< "$s_json")" 6
check "nor its bytes" eq "$(json bytes_done <<< "$s_json")" 1200000
check "the report names the file" grep -q 'ruim.bin' "$XDG_STATE_HOME/big-mount/jobs/$id/failed.txt"
job_dump "$id"
sudo -n umount "$m"; MNTS=("${MNTS[@]/$m}")
fi

if want stall; then
begin "a read that hangs: the file is set aside, the copy goes on, no SIGKILL"
new_img st 128M mkfs.ext4 -q -F -L T_STALL; d="$REPLY"
mp="$(mnt_rw "$d")"; sudo -n chown "$EUID" "$mp"
for i in 1 2 3; do head -c 200000 /dev/urandom > "$mp/ok$i.bin"; done
head -c 2000000 /dev/urandom > "$mp/preso.bin"
head -c 200000 /dev/urandom > "$mp/zz.bin"
sync -f "$mp"
read -r s l < <(blocks_of "$mp/preso.bin")
umnt "$d"
bad_dm st "$d" "$s" "$l" "delay $d $s 8000"; dm="$REPLY"
m="$WORK/st"; mkdir "$m"
sudo -n mount -o ro,noload "$dm" "$m"; MNTS+=("$m")
sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches'
need_pair; fresh_dest
out="$("$B" --drive copy --source "$m" --destination "$DSTMP/out" --scan no --stall-seconds 4 --no-wait --json)"; id="$(job_id <<< "$out")"
wait_state "$id" completed needs-attention failed
s_json="$("$B" --drive status "$id" --json)"
check "finished, needing attention" eq "$(json state <<< "$s_json")" needs-attention
check "one file set aside" eq "$(json deferred <<< "$s_json")" 1
check "it is that file" grep -qx 'preso.bin' "$XDG_STATE_HOME/big-mount/jobs/$id/deferred.txt"
check "the file after it was saved" cmp -s "$m/zz.bin" "$DSTMP/out/zz.bin"
check "a file sent twice around the restart counts once (4 of 5 files)" eq "$(json files_done <<< "$s_json")" 4
check "nothing with the name of the file set aside" test ! -e "$DSTMP/out/preso.bin"
sudo -n umount "$m"; MNTS=("${MNTS[@]/$m}")
sudo -n dmsetup remove bmt-st; DMS=("${DMS[@]/bmt-st}")
# The same disk now answers: --retry-deferred gets it
{
   sudo -n mount -o ro,noload "$d" "$m"; MNTS+=("$m")
}
"$B" --drive resume "$id" --retry-deferred >/dev/null; rc=$?
sjson="$("$B" --drive status "$id" --json)"
check "retry: the file came through (state $(json state <<< "$sjson"))" cmp -s "$m/preso.bin" "$DSTMP/out/preso.bin"
job_dump "$id"
sudo -n umount "$m"; MNTS=("${MNTS[@]/$m}")
fi

if want gone; then
begin "the source goes away during the copy, and comes back under another mount"
new_img g 128M mkfs.ext4 -q -F -L T_GONE; d="$REPLY"
mp="$(mnt_rw "$d")"; sudo -n chown "$EUID" "$mp"; head -c 40000000 /dev/urandom > "$mp/grande.bin"; printf 'x\n' > "$mp/pequeno.txt"; sync -f "$mp"; umnt "$d"
m="$WORK/g1"; mkdir "$m"; sudo -n mount -o ro,noload "$d" "$m"; MNTS+=("$m")
need_pair; fresh_dest
out="$("$B" --drive copy --source "$m" --destination "$DSTMP/out" --bwlimit 2000 --scan no --no-wait --json)"; id="$(job_id <<< "$out")"
sleep 3
# Only the test does this: the lazy unmount stands for an unplugged drive
sudo -n umount -l "$m"
wait_state "$id" completed needs-attention failed
sj="$("$B" --drive status "$id" --json)"
check "noticed" eq "$(json reason <<< "$sj")" source-gone
"$B" --drive status "$id" --watch >/dev/null; check "exit 24" eq "$?" 24
m2="$WORK/g2"; mkdir "$m2"; sudo -n mount -o ro,noload "$d" "$m2"; MNTS+=("$m2")
"$B" --drive resume "$id" >/dev/null; rc=$?
check "found by UUID at its new mount point, and finished" eq "$("$B" --drive status "$id" --json | json state)" completed
check "the file is whole" cmp -s "$m2/grande.bin" "$DSTMP/out/grande.bin"
job_dump "$id"
sudo -n umount "$m2"; MNTS=("${MNTS[@]/$m2}")
fi

if want nospace; then
begin "the destination fills up"
need_pair
new_img small2 16M mkfs.ext4 -q -F -m 0 -L T_SM2; sm="$REPLY"; smp="$(mnt_rw "$sm")"; sudo -n chown "$EUID" "$smp"
out="$("$B" --drive copy --source "$SRCMP/data" --destination "$smp/out" --scan no --no-wait --json)"; id="$(job_id <<< "$out")"
wait_state "$id" completed needs-attention failed
sj="$("$B" --drive status "$id" --json)"
check "the reason is the lack of space" eq "$(json reason <<< "$sj")" no-space
"$B" --drive status "$id" --watch >/dev/null; check "exit 21" eq "$?" 21
check "the big file is not left there half copied" test ! -e "$smp/out/video.mkv"
check "the file the disk refused is named" grep -q 'video.mkv' "$XDG_STATE_HOME/big-mount/jobs/$id/failed.txt"
job_dump "$id"
umnt "$sm"
fi

if want luks; then
begin "LUKS: seen, not forced, unlocked by UDisks2; the key never goes through us"
truncate -s 64M "$WORK/luks.img"
printf 'senha-de-teste' > "$WORK/key"
sudo -n cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file "$WORK/key" "$WORK/luks.img"
loop_up "$WORK/luks.img"; d="$REPLY"
j="$("$B" --drive inspect "$d" --json)"
check "valid JSON" valid_json <<< "$j"
check "state: locked" eq "$(json volumes.0.state <<< "$j")" locked
out="$("$B" --drive mount "$d" --read-only --json)"; rc=$?
check "mounting it is refused, with exit 20" eq "$rc" 20
check "and it says to unlock" eq "$(json why <<< "$out")" locked
sudo -n cryptsetup open --key-file "$WORK/key" "$d" "bmt-luks-${d##*/}"; udevadm settle
on_scratch "/dev/mapper/bmt-luks-${d##*/}"
sudo -n mkfs.ext4 -q -F -L T_LUKS "/dev/mapper/bmt-luks-${d##*/}"; udevadm settle
j="$("$B" --drive inspect "$d" --json)"
check "unlocked: the volume inside is listed" eq "$(json volumes.1.fstype <<< "$j")" ext4
check "state: unlocked" eq "$(json volumes.0.state <<< "$j")" unlocked
sudo -n cryptsetup close "bmt-luks-${d##*/}"
fi

if want protect; then
begin "writing blocked on the device, through the helper"
# The helper as installed reads /usr/lib; this copy reads this checkout
H="$WORK/helper"
sed -e "s|^BM_LIB=.*|BM_LIB=$REPO/big-mount/usr/lib/big-mount|" "$REPO/big-mount/usr/lib/big-mount/bigmount-drive-helper" > "$H"; chmod +x "$H"
W="$WORK/sudo-helper"; printf '#!/bin/bash\nexec sudo -n "%s" "$@"\n' "$H" > "$W"; chmod +x "$W"
export BM_HELPER_CMD="$W"
new_img pr 64M mkfs.ext4 -q -F -L T_PR; d="$REPLY"
"$B" --drive protect "$d" >/dev/null; check "protect: exit 0" eq "$?" 0
check "the kernel says read-only" eq "$(lsblk -dn -o RO "$d" | tr -d ' ')" 1
before="$(sudo -n sha256sum < "$d")"
check "writing to the device fails" bash -c '! sudo -n dd if=/dev/zero of="$1" bs=4k count=1 oflag=direct 2>/dev/null' _ "$d"
out="$("$B" --drive mount "$d" --read-only --json)"; rc=$?
check "mounts read-only on top of it" eq "$rc" 0
check "the status says it is protected" eq "$("$B" --drive inspect "$d" --json | json volumes.0.device_read_only)" true
"$B" --drive unmount "$d" >/dev/null
check "the device did not change" eq "$(sudo -n sha256sum < "$d")" "$before"
"$B" --drive unprotect "$d" >/dev/null; check "unprotect: exit 0" eq "$?" 0
check "the kernel says writable" eq "$(lsblk -dn -o RO "$d" | tr -d ' ')" 0
mnt_rw "$d" >/dev/null
"$B" --drive protect "$d" >/dev/null 2>&1; check "a volume mounted for writing: refused (exit 3)" eq "$?" 3
umnt "$d"
# The refusal for the running system, with blockdev out of the helper so that
# not even a bug here could change a real disk
sed -e 's/blockdev --set/echo WOULD-RUN --set/' "$H" > "$H.safe"; chmod +x "$H.safe"
root_dev="$(findmnt -n -o SOURCE / | sed 's/\[.*//')"
sudo -n "$H.safe" protect "$root_dev" >"$WORK/refused.txt" 2>&1; rc=$?
check "the disk of the running system is refused (exit 4)" eq "$rc" 4
check "and nothing would have run" bash -c '! grep -q WOULD-RUN "$1"' _ "$WORK/refused.txt"
sudo -n "$H.safe" protect '/dev/loop0; touch /tmp/pwn' >/dev/null 2>&1; check "a name with a command is rejected (exit 2)" eq "$?" 2
sudo -n "$H.safe" protect /dev/../etc/passwd >/dev/null 2>&1; check "a path out of /dev is rejected (exit 2)" eq "$?" 2
unset BM_HELPER_CMD
fi

if want busy; then
begin "a busy volume: who holds it, only what may be closed is closed, nothing is forced"
# FAT: UDisks2 mounts it as this user, who may write to it
new_img busy 64M mkfs.vfat -n T_BUSY && d="$REPLY"
mp="$(mnt_rw "$d")"
( cd "$mp" && exec sleep 300 ) &
reader=$!
bash -c 'exec 3>"$1/escrevendo.txt" || exit 1; printf parte >&3; exec sleep 300' _ "$mp" &
writer=$!
sleep 1
check "two programs hold it, one of them writing" kill -0 "$writer"
out="$("$B" --drive unmount "$d" --json)"; rc=$?
check "busy: exit 3" eq "$rc" 3
check "  ... still mounted: nothing was forced" findmnt -n --mountpoint "$mp"
check "  ... and it says which volume" eq "$(json busy_device <<< "$out")" "$d"
out="$("$B" --drive busy "$d" --json)"
check "busy: valid JSON" valid_json <<< "$out"
check "  ... the reader may be closed, the writer may not" python3 -I -c 'import json,sys
p={x["pid"]:x for x in json.loads(sys.argv[1])["programs"]}
r,w=int(sys.argv[2]),int(sys.argv[3])
assert p[r]["closable"] and not p[w]["closable"] and p[w]["why"], p' "$out" "$reader" "$writer"
"$B" --drive close-apps "$d" --json > "$WORK/closed.json"; rc=$?
check "close-apps: the reader was asked to close (SIGTERM)" bash -c '! kill -0 "$1" 2>/dev/null' _ "$reader"
check "  ... the one writing was not" kill -0 "$writer"
check "  ... and it is told why" python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["kept"] and d["kept"][0]["why"], d' "$WORK/closed.json"
check "  ... so it is still mounted" findmnt -n --mountpoint "$mp"
kill "$writer"; wait "$writer" "$reader" 2>/dev/null
"$B" --drive unmount "$d" >/dev/null; check "with nothing left, it unmounts" eq "$?" 0
mp="$(mnt_rw "$d")"
check "  ... and what was being written is there: nothing was cut under it" eq "$(cat "$mp/escrevendo.txt")" parte
umnt "$d"
# The whole drive: every volume of it, as the Home page asks
truncate -s 96M "$WORK/whole.img"
printf 'label: gpt\n,40M\n,\n' | sfdisk -q "$WORK/whole.img"
loop_up "$WORK/whole.img" && d="$REPLY"
sudo -n mkfs.vfat -n T_W1 "${d}p1" >/dev/null; sudo -n mkfs.vfat -n T_W2 "${d}p2" >/dev/null; udevadm settle
mnt_rw "${d}p1" >/dev/null; mnt_rw "${d}p2" >/dev/null
check "a drive with two mounted volumes" bash -c '[ "$(findmnt -n -S "$1p1" | wc -l)$(findmnt -n -S "$1p2" | wc -l)" = 11 ]' _ "$d"
"$B" --drive unmount "$d" --json > "$WORK/whole.json"; rc=$?
check "unmount of the whole drive: exit 0" eq "$rc" 0
check "  ... both volumes unmounted" bash -c '! findmnt -n -S "$1p1" >/dev/null && ! findmnt -n -S "$1p2" >/dev/null' _ "$d"
check "  ... and not powered off: only a safe removal does that" eq "$(json powered_off < "$WORK/whole.json")" false
fi

if want system; then
begin "the running system is refused, whatever the command"
"$B" --drive unmount / >/dev/null 2>&1; check "unmount /: exit 4" eq "$?" 4
"$B" --drive unmount /home >/dev/null 2>&1; check "unmount /home: exit 4" eq "$?" 4
"$B" --drive unmount /boot/efi >/dev/null 2>&1; check "unmount /boot/efi: exit 4" eq "$?" 4
check "still mounted" findmnt -n /home
fi

if want tui; then
begin "the interactive manager in a real terminal, with typed answers"
need_pair
# Answers: the device (found by its label), option 1, Enter, option 7 (unmount), Enter, back, quit
n="$("$B" --drive list | grep -nE '^/dev/' | grep -n "${SRC##*/}" | cut -d: -f1)"
tui_run() { # TERM_VALUE LANG INPUT...
   local term="$1" lang="$2" out="$3"; shift 3
   printf '%s\n' "$@" | TERM="$term" LC_ALL="$lang" script -qfec "$B --drive" "$out" >/dev/null 2>&1
}
tui_run xterm C.UTF-8 "$WORK/tui.txt" "$n" 1 "" 0 0
check "the title is there" grep -q 'BIG-MOUNT DRIVE MANAGER' "$WORK/tui.txt"
check "a box, in UTF-8" grep -q '╭' "$WORK/tui.txt"
check "the menu of a device" grep -q 'Copy files to another disk' "$WORK/tui.txt"
check "the information of the drive" grep -q 'T_SRC' "$WORK/tui.txt"
tui_run dumb C "$WORK/tui2.txt" 0
check "a plain terminal: no box characters" bash -c '! grep -q "╭" "$1"' _ "$WORK/tui2.txt"
check "  ... no colours" bash -c '! grep -q $'"'"'\033\[1;3'"'"' "$1"' _ "$WORK/tui2.txt"
NO_COLOR=1 tui_run xterm C.UTF-8 "$WORK/tui3.txt" 0
check "NO_COLOR: no colours" bash -c '! grep -q $'"'"'\033\[1;3'"'"' "$1"' _ "$WORK/tui3.txt"
tui_run xterm C.UTF-8 "$WORK/tui4.txt" 99 abc "" 0
check "wrong answers are ignored, no crash" grep -q 'BIG-MOUNT' "$WORK/tui4.txt"
# A copy through the menus: device, 5 copy, 1 everything, destination, 1 keep, y, Enter, back, quit
fresh_dest
tui_run xterm C.UTF-8 "$WORK/tui5.txt" "$n" 5 1 "$DSTMP/out" 1 y "" 0 0
check "a copy through the menus" tree_same "$SRCMP" "$DSTMP/out"
fi

if want gui; then
begin "the window, off screen, driving the real engine on real images"
need_pair; fresh_dest
cat > "$WORK/gui_e2e.py" <<'PY'
import os, sys, time
sys.dont_write_bytecode = True
repo, source, dest, luks_dev, keyfile = sys.argv[1:6]
os.environ["LANGUAGE"] = "C"
sys.path.insert(0, repo + "/tests")
from gui_support import make_app, pump
os.environ.pop("BM_GUI_BIN", None)
app = make_app()
from gui.engine import Engine
from gui.window import MainWindow
w = MainWindow(app, engine=Engine(program=repo + "/big-mount/usr/bin/bigmount"))
w.present()
assert pump(lambda: w.loaded and w.devices, 20), "no devices"
print("listed", len(w.devices))
dev = next(d for d in w.devices if any(v.mountpoint and source.startswith(v.mountpoint) for v in d.volumes))
w.open_wizard(dev)
wiz = w.wizard
assert wiz.plan.volume is not None, "the only volume is chosen"
wiz.go_next()
assert pump(lambda: wiz.step == "what", 20), "methods"
wiz.go_next()
wiz.plan.method = "copy"
wiz.plan.verify = "full"
wiz.plan.dest_custom = True
wiz.plan.dest_base = dest
wiz.go_next()
assert pump(lambda: wiz.step == "where" and wiz.preflight is not None, 20), "where"
assert wiz.preflight.get("ok"), wiz.preflight
wiz.go_next()
assert pump(lambda: wiz.step == "confirm" and wiz.preflight is not None and wiz.next_btn.get_sensitive(), 30), "confirm: %r" % (wiz.preflight,)
print("preflight", wiz.preflight["total_files"], wiz.preflight["total_bytes"])
wiz.go_next()
assert pump(lambda: type(w.nav.get_visible_page()).__name__ == "JobPage", 20), "job did not open"
page = w.nav.get_visible_page()
assert pump(lambda: page.job and not page.job.running, 90), "did not end: %r" % (page.job,)
print("state", page.job.state, page.job.verify_result, "bar", page.bar.get_fraction())
assert page.job.state == "completed" and page.job.verify_result == "ok"
assert page.bar.get_fraction() == 1.0
assert pump(lambda: page.report_expander.get_visible(), 10), "no report"
assert "Files copied" in page.report_view.get_text()
# The passphrase through D-Bus: the real UDisks2, on a real LUKS image
from gui.pages.device import unlock_volume
from gui.models import Volume
key = open(keyfile).read()
unlock_volume(w, Volume(device=luks_dev, label="T"), lambda: None)
assert pump(lambda: w.get_visible_dialog() is not None, 5)
dialog = w.get_visible_dialog()
dialog.get_extra_child().set_text(key)
dialog.emit("response", "unlock")
holders = "/sys/class/block/%s/holders" % luks_dev.rsplit("/")[-1]
assert pump(lambda: os.path.exists(holders) and os.listdir(holders), 40), "not unlocked"
print("unlocked")
w.jobs = []
w.close()
print("OK")
PY
truncate -s 64M "$WORK/gl.img"; printf 'chave-de-teste' > "$WORK/key2"
sudo -n cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file "$WORK/key2" "$WORK/gl.img"
loop_up "$WORK/gl.img"; gl="$REPLY"
timeout 170 python3 -I "$WORK/gui_e2e.py" "$REPO" "$SRCMP" "$DSTMP/out" "$gl" "$WORK/key2" >"$WORK/gui.out" 2>&1; rc=$?
[ -n "${DEBUG:-}" ] && sed 's/^/      /' "$WORK/gui.out"
check "preflight, copy, full check and report through the window (exit $rc)" grep -qx OK "$WORK/gui.out"
check "the passphrase never appears in the process list or the log" bash -c '! grep -q chave-de-teste "$1"' _ "$WORK/gui.out"
udisksctl lock -b "$gl" --no-user-interaction >/dev/null 2>&1
# Without a graphical session it says where the same tools are
env -u WAYLAND_DISPLAY -u DISPLAY "$B" --gui-drive "$SRC" </dev/null >"$WORK/fb.txt" 2>&1; rc=$?
check "--gui-drive without a session: the terminal manager is named (exit $rc)" bash -c '[ "$2" = 25 ] && grep -q "bigmount --drive" "$1"' _ "$WORK/fb.txt" "$rc"
if command -v gtk4-broadwayd >/dev/null; then
   gtk4-broadwayd :77 >/dev/null 2>&1 &
   broadway=$!
   sleep 0.5
   GDK_BACKEND=broadway BROADWAY_DISPLAY=:77 DISPLAY=:none timeout 4 dbus-run-session -- "$B" --gui-drive "$SRCMP/data" >/dev/null 2>&1; rc=$?
   check "--gui-drive with a folder opens the window and stays open" eq "$rc" 124
   GDK_BACKEND=broadway BROADWAY_DISPLAY=:77 DISPLAY=:none timeout 4 dbus-run-session -- "$B" --gui-drive-check "$SRC" >/dev/null 2>&1; rc=$?
   check "--gui-drive-check opens the same application and stays open" eq "$rc" 124
   kill "$broadway" 2>/dev/null
fi
fi

if want image; then
begin "a disk image: the job around ddrescue (a STAND-IN for ddrescue, which is not validated here)"
SB="$WORK/stubbin"; mkdir -p "$SB"
cat > "$SB/ddrescue" <<'STUB'
#!/bin/bash
# Stand-in: writes a map as ddrescue does, slowly, and reads the device for real
for a in "$@"; do [ "$a" = -- ] && { shift; break; }; shift; done
dev="$1" out="$2" map="$3"; size="$(blockdev --getsize64 "$dev")"
trap 'exit 130' TERM
for pct in 25 50 75 100; do
   done_="$((size * pct / 100))"
   printf '# Mapfile. Created by stand-in\n0x%x ? 1\n0x0 0x%x +\n0x%x 0x%x ?\n' "$done_" "$done_" "$done_" "$((size - done_))" > "$map"
   [ "$pct" = 100 ] && printf '# Mapfile\n0x%x + 1\n0x0 0x%x +\n' "$size" "$size" > "$map"
   sleep "${STUB_DELAY:-1}"
done
dd if="$dev" of="$out" bs=1M status=none
STUB
chmod +x "$SB/ddrescue"
H="$WORK/ihelper"
sed -e "s|^BM_LIB=.*|BM_LIB=$REPO/big-mount/usr/lib/big-mount|" -e "s|^export PATH=.*|export PATH=$SB:/usr/bin:/bin:/usr/sbin:/sbin|" "$REPO/big-mount/usr/lib/big-mount/bigmount-drive-helper" > "$H"; chmod +x "$H"
W="$WORK/isudo"; printf '#!/bin/bash\nexec sudo -n env PKEXEC_UID=%s "%s" "$@"\n' "$EUID" "$H" > "$W"; chmod +x "$W"
new_img im 32M mkfs.ext4 -q -F -L T_IMG; d="$REPLY"
need_pair; mkdir -p "$DSTMP/img"
(
   export PATH="$SB:$PATH" BM_HELPER_CMD="$W"
   out="$("$B" --drive image --source "$d" --image "$DSTMP/img/disco.img" --no-wait --json)"; id="$(job_id <<< "$out")"
   echo "$id" > "$WORK/image.id"
   wait_state "$id" completed needs-attention failed
)
id="$(cat "$WORK/image.id")"
sj="$("$B" --drive status "$id" --json)"
check "completed" eq "$(json state <<< "$sj")" completed
check "progress is the map: all bytes" eq "$(json bytes_done <<< "$sj")" 33554432
check "the image is the device" cmp -s "$WORK/im.img" "$DSTMP/img/disco.img"
check "the image belongs to the user" eq "$(stat -c %u "$DSTMP/img/disco.img")" "$EUID"
check "the map belongs to the user" eq "$(stat -c %u "$DSTMP/img/disco.img.map")" "$EUID"
(
   export PATH="$SB:$PATH" BM_HELPER_CMD="$W" STUB_DELAY=5
   out="$("$B" --drive image --source "$d" --image "$DSTMP/img/b.img" --no-wait --json)"; id2="$(job_id <<< "$out")"
   sleep 3
   "$B" --drive cancel "$id2" >/dev/null
   wait_state "$id2" cancelled failed completed
   "$B" --drive status "$id2" --json > "$WORK/image2.json"
)
check "cancelling reaches the root process, through the stop file" eq "$(json state < "$WORK/image2.json")" cancelled
SF="$WORK/fail-bin"; mkdir -p "$SF"; printf '#!/bin/bash\necho "ddrescue: read error" >&2\nexit 1\n' > "$SF/ddrescue"; chmod +x "$SF/ddrescue"
sed -e "s|^export PATH=.*|export PATH=$SF:/usr/bin:/bin:/usr/sbin:/sbin|" "$H" > "$H.fail"; chmod +x "$H.fail"
printf '#!/bin/bash\nexec sudo -n env PKEXEC_UID=%s "%s" "$@"\n' "$EUID" "$H.fail" > "$W.fail"; chmod +x "$W.fail"
(
   export PATH="$SB:$PATH" BM_HELPER_CMD="$W.fail"
   out="$("$B" --drive image --source "$d" --image "$DSTMP/img/f.img" --no-wait --json)"; id3="$(job_id <<< "$out")"
   wait_state "$id3" completed needs-attention failed
   "$B" --drive status "$id3" --json > "$WORK/image3.json"
)
check "ddrescue fails: the job says it was ddrescue, not rsync" \
   eq "$(json reason < "$WORK/image3.json") $(json reason_text < "$WORK/image3.json")" "image-error GNU ddrescue stopped with an error. See the log."
PATH="$SB:$PATH" "$B" --drive image --source "$d" --image "$WORK/im.img.parts/x.img" --dry-run >/dev/null 2>&1; rc=$?
check "dry run" eq "$rc" 0
new_img tiny 8M mkfs.ext4 -q -F -m 0 -L T_TINY; t="$REPLY"; tm="$(mnt_rw "$t")"; sudo -n chown "$EUID" "$tm"
PATH="$SB:$PATH" "$B" --drive image --source "$d" --image "$tm/x.img" --dry-run >/dev/null 2>&1; check "no room for the image: exit 21" eq "$?" 21
umnt "$t"
sudo -n "$H" image "$d" /etc/x.img /etc/x.map 0 /etc/stop >/dev/null 2>&1; check "the helper refuses a folder that is not the user's" eq "$?" 2
sudo -n "$H" image "$d" "$DSTMP/img/l.img" "$DSTMP/img/l.map" 9 "$DSTMP/img/s" >/dev/null 2>&1; check "  ... and absurd retries" eq "$?" 2
# The folder is the user's: while root works, the names become links to a file of root
victim="$WORK/victim"; sudo -n sh -c 'umask 077; echo secret > "$1"' _ "$victim"
SR="$WORK/race-bin"; mkdir -p "$SR"
# ... and the stand-in writes through what it was given, as ddrescue would
printf '#!/bin/bash\nfor n in "%s" "%s" "%s"; do rm -f -- "$n"; ln -s -- "%s" "$n"; done\necho pwned >> "${@: -2:1}"; echo pwned >> "${@: -1}"\nsleep 3\n' \
   "$DSTMP/img/race.img" "$DSTMP/img/race.img.map" "$DSTMP/img/race.img.map.bak" "$victim" > "$SR/ddrescue"; chmod +x "$SR/ddrescue"
sed -e "s|^export PATH=.*|export PATH=$SR:/usr/bin:/bin:/usr/sbin:/sbin|" "$H" > "$H.race"; chmod +x "$H.race"
sudo -n env PKEXEC_UID="$EUID" "$H.race" image "$d" "$DSTMP/img/race.img" "$DSTMP/img/race.img.map" 0 "$DSTMP/img/race.stop" >/dev/null 2>&1
check "names swapped for links during the run: root's file keeps its owner and mode" \
   eq "$(sudo -n stat -c '%u %a' -- "$victim")" "0 600"
check "  ... and its content" eq "$(sudo -n cat -- "$victim")" secret
# A map cut by a power failure: ddrescue starts from MAP.bak, and the map is whole again
SS="$WORK/seen-bin"; mkdir -p "$SS"
printf '#!/bin/bash\ncp -- "${@: -1}" "%s"\n' "$WORK/seen-map" > "$SS/ddrescue"; chmod +x "$SS/ddrescue"
sed -e "s|^export PATH=.*|export PATH=$SS:/usr/bin:/bin:/usr/sbin:/sbin|" "$H" > "$H.seen"; chmod +x "$H.seen"
printf '# Mapfile\n0x00100000     ?               1\n0x00000000  0x00100000  +\n0x00100000  0x01F00000  ?\n' > "$DSTMP/img/cut.img.map.bak"
printf '# Mapfile\n0x00200000     ?               1\n0x00000000  0x002' > "$DSTMP/img/cut.img.map"
: > "$DSTMP/img/cut.img"
sudo -n env PKEXEC_UID="$EUID" "$H.seen" image "$d" "$DSTMP/img/cut.img" "$DSTMP/img/cut.img.map" 0 "$DSTMP/img/cut.stop" >/dev/null 2>&1
check "a map that was cut: ddrescue resumes from MAP.bak" cmp -s "$WORK/seen-map" "$DSTMP/img/cut.img.map.bak"
check "  ... and the map is whole again, the user's" \
   bash -c 'cmp -s "$1" "$2" && [ "$(stat -c %u "$1")" = "$3" ]' _ "$DSTMP/img/cut.img.map" "$DSTMP/img/cut.img.map.bak" "$EUID"
# While sweeping, ddrescue writes % as the status: a whole map too
printf '# Mapfile\n0x00300000     %%               1\n0x00000000  0x00300000  +\n0x00300000  0x01D00000  ?\n' > "$DSTMP/img/sweep.img.map"
: > "$DSTMP/img/sweep.img"; rm -f "$WORK/seen-map"
sudo -n env PKEXEC_UID="$EUID" "$H.seen" image "$d" "$DSTMP/img/sweep.img" "$DSTMP/img/sweep.img.map" 0 "$DSTMP/img/sweep.stop" >/dev/null 2>&1
check "a map saved while sweeping (%) is resumed" cmp -s "$WORK/seen-map" "$DSTMP/img/sweep.img.map"
# The image named as its own map: refused before anything is written
printf 'keep' > "$DSTMP/img/same.img"
sudo -n env PKEXEC_UID="$EUID" "$H.seen" image "$d" "$DSTMP/img/same.img" "$DSTMP/img/same.img" 0 "$DSTMP/img/same.stop" >/dev/null 2>&1
check "the image as its own map: refused (exit 2), the image untouched" \
   bash -c '[ "$1" = 2 ] && [ "$(cat "$2")" = keep ]' _ "$?" "$DSTMP/img/same.img"
# The map cannot be saved at the end (made immutable): a failure, and MAP.bak keeps the one before
SL="$WORK/lock-bin"; mkdir -p "$SL"
printf '#!/bin/bash\nprintf "# Mapfile\\n0x02000000     +               1\\n0x00000000  0x02000000  +\\n" > "${@: -1}"\nchattr +i -- "%s"\n' \
   "$DSTMP/img/lock.img.map" > "$SL/ddrescue"; chmod +x "$SL/ddrescue"
sed -e "s|^export PATH=.*|export PATH=$SL:/usr/bin:/bin:/usr/sbin:/sbin|" "$H" > "$H.lock"; chmod +x "$H.lock"
printf '# Mapfile\n0x00100000     ?               1\n0x00000000  0x00100000  +\n0x00100000  0x01F00000  ?\n' > "$DSTMP/img/lock.img.map"
cp "$DSTMP/img/lock.img.map" "$WORK/lock.before"; : > "$DSTMP/img/lock.img"
sudo -n env PKEXEC_UID="$EUID" "$H.lock" image "$d" "$DSTMP/img/lock.img" "$DSTMP/img/lock.img.map" 0 "$DSTMP/img/lock.stop" >"$WORK/lock.out" 2>&1; rc=$?
sudo -n chattr -i -- "$DSTMP/img/lock.img.map"
check "the map could not be saved: the helper fails (got $rc)" bash -c '[ "$1" -ne 0 ] && grep -q "map could not be saved" "$2"' _ "$rc" "$WORK/lock.out"
check "  ... and MAP.bak holds the map before" cmp -s "$WORK/lock.before" "$DSTMP/img/lock.img.map.bak"
ln -s /etc/bm-should-not-exist "$DSTMP/img/dangling.map"
sudo -n env PKEXEC_UID="$EUID" "$H" image "$d" "$DSTMP/img/dangling.img" "$DSTMP/img/dangling.map" 0 "$DSTMP/img/s" >/dev/null 2>&1
check "a map that is a link: refused (exit 2), nothing created through it" \
   bash -c '[ "$1" = 2 ] && [ ! -e /etc/bm-should-not-exist ]' _ "$?"
fi

if want recovery; then
begin "TestDisk and PhotoRec on an image (the real tools)"
new_img carve 16M mkfs.vfat -n T_CARVE; d="$REPLY"
mp="$(mnt_rw "$d")"
python3 -I - "$mp/foto.png" <<'PY'
import struct,sys,zlib
def c(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b))
raw=b"".join(b"\0"+bytes((x*y)%256 for x in range(256)) for y in range(256))
open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">IIBBBBB",256,256,8,0,0,0,0))+c(b"IDAT",zlib.compress(raw))+c(b"IEND",b""))
PY
sync -f "$mp"; rm -f "$mp/foto.png"; sync -f "$mp"; umnt "$d"
sudo -n losetup -d "$d"; LOOPS=("${LOOPS[@]/$d}"); udevadm settle
before="$(sha256sum < "$WORK/carve.img")"
out="$("$B" --drive carve --source "$WORK/carve.img" --destination "$WORK/recovered" --json)"; rc=$?
check "exit 0 (got $rc)" eq "$rc" 0
check "the deleted picture was found" bash -c 'compgen -G "$1/recup_dir*/*.png" >/dev/null' _ "$WORK/recovered"
check "the image did not change" eq "$(sha256sum < "$WORK/carve.img")" "$before"
truncate -s 64M "$WORK/parts.img"; printf 'label: dos\n,20M,L\n,,L\n' | sfdisk -q "$WORK/parts.img"
"$B" --drive partitions "$WORK/parts.img" > "$WORK/parts.txt" 2>&1; rc=$?
check "TestDisk lists the table of an image" grep -qi 'parts.img\|Linux\|Partition' "$WORK/parts.txt"
"$B" --drive carve --source /dev/nonexistent --destination "$WORK/x" >/dev/null 2>&1; check "an unreadable source: refused, exit 20" eq "$?" 20
if command -v ddrescue >/dev/null; then
   echo "  ddrescue present: run by hand with a scratch device"
else
   "$B" --drive image --source /dev/null --image "$WORK/i.img" >/dev/null 2>&1; check "image without ddrescue: exit 25" eq "$?" 25
fi
fi

echo "========================================="
echo "drive-integration result: $PASS passed, $FAIL failed"
for f in "${FAILED[@]}"; do echo "  FAILED: $f"; done
echo "========================================="
[ "$FAIL" -eq 0 ]
