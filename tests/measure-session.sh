#!/bin/bash
# shellcheck disable=SC2016  # bash -c '...$1' snippets
# Reproducible measurements of the session tools (not the boot path, see
# bench.sh): diagnosis time, latency from a mount to the notification, and
# idle cost of the notifier. Uses disposable images attached through UDisks2,
# exactly like tests/integration.sh; never touches a real disk.
#
# Usage: tests/measure-session.sh [BIGMOUNT] [RUNS]

set -u
export LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "$0")" && pwd)"
BM="$(readlink -f "${1:-$HERE/../big-mount/usr/bin/bigmount}")"
RUNS="${2:-5}"
[ "$EUID" -ne 0 ] || { echo "do not run as root" >&2; exit 2; }

IMG="$(mktemp -d "${TMPDIR:-/tmp}/bigmount-measure.XXXXXX")"
NOTE="$(mktemp -d "${TMPDIR:-/tmp}/bigmount-measure-note.XXXXXX")"
LOOPS=() PIDS=()
cleanup() {
    local p d
    for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    for d in "${LOOPS[@]}"; do
        udisksctl unmount --no-user-interaction -b "$d" >/dev/null 2>&1
        udisksctl loop-delete --no-user-interaction -b "$d" >/dev/null 2>&1
    done
    rm -rf -- "${IMG:?}" "${NOTE:?}"
}
trap cleanup EXIT

attach() {
    local out
    out="$(udisksctl loop-setup --no-user-interaction ${2:+-r} -f "$1" 2>&1)" || return 1
    DEV="$(grep -o '/dev/loop[0-9]*' <<< "$out" | head -n1)"
    LOOPS+=("$DEV"); udevadm settle --timeout=5
}
mountdev() { udisksctl mount --no-user-interaction -b "$1" ${2:+-o "$2"} >/dev/null 2>&1; }
ms() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.0f", (b - a) * 1000 }'; }
median() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }

truncate -s 64M "$IMG/rw.img"; mkfs.ext4 -q -F -L MRW -E root_owner="$(id -u):$(id -g)" "$IMG/rw.img"
truncate -s 64M "$IMG/ro.img"; mkfs.ext4 -q -F -L MRO "$IMG/ro.img"
attach "$IMG/rw.img" || { echo "cannot set up loop devices (no active session?)"; exit 77; }
RW="$DEV"; mountdev "$RW"
attach "$IMG/ro.img" ro; RO="$DEV"; mountdev "$RO"

echo "bigmount: $BM"
for dev in "$RW" "$RO"; do
    t=()
    for ((i = 0; i < RUNS; i++)); do
        a=$EPOCHREALTIME; bash "$BM" --diagnose "$dev" >/dev/null 2>&1; b=$EPOCHREALTIME
        t+=("$(ms "$a" "$b")")
    done
    label=writable; [ "$dev" = "$RO" ] && label=read-only
    echo "diagnose ($label) median ms: $(printf '%s\n' "${t[@]}" | median)"
done

# Notifier: idle cost and mount -> notification latency (text fallback)
env -u DBUS_SESSION_BUS_ADDRESS -u WAYLAND_DISPLAY -u DISPLAY \
    XDG_RUNTIME_DIR="$NOTE" XDG_STATE_HOME="$NOTE/state" bash "$BM" --notifier 2> "$NOTE/notes" &
NP=$!; PIDS+=("$NP")
sleep 6
rss=0; for p in $NP $(pgrep -P "$NP"); do r=$(awk '/VmRSS/ { print $2 }' "/proc/$p/status" 2>/dev/null); rss=$((rss + ${r:-0})); done
ticks() { local n=0 p; for p in $NP $(pgrep -P "$NP"); do n=$((n + $(awk '{ print $14 + $15 }' "/proc/$p/stat" 2>/dev/null || echo 0))); done; echo "$n"; }
c0=$(ticks); sleep 10; c1=$(ticks)
echo "notifier idle: processes $((1 + $(pgrep -c -P "$NP"))), RSS ${rss} kB, CPU in 10 s idle: $((c1 - c0)) ticks"
lat=()
for ((i = 0; i < RUNS; i++)); do
    truncate -s 32M "$IMG/n$i.img"; mkfs.ext4 -q -F -L "MNOTE$i" "$IMG/n$i.img"
    attach "$IMG/n$i.img" ro
    a=$EPOCHREALTIME; mountdev "$DEV"
    for ((w = 0; w < 250; w++)); do grep -q "MNOTE$i " "$NOTE/notes" && break; sleep 0.02; done
    b=$EPOCHREALTIME
    grep -q "MNOTE$i " "$NOTE/notes" || { echo "no notification for MNOTE$i: measurement invalid" >&2; exit 1; }
    lat+=("$(ms "$a" "$b")")
done
echo "mount -> notification median ms: $(printf '%s\n' "${lat[@]}" | median) (runs: ${lat[*]})"
