#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets and helpers called through check()
# Reproducible benchmark for the boot path of bigmount.
#
# Usage: tests/bench.sh SCRIPT [ITERATIONS]
#
# Runs SCRIPT against the REAL block devices of this machine (blkid, lsblk,
# udevadm/udisksctl, findmnt and sysfs are the real ones), while `mount` and
# `ntfsfix` are replaced by the logging stubs from tests/stubs and every path
# the script writes to is redirected to a throw-away directory. /proc/mounts
# is replaced by an empty file to simulate the boot situation in which the
# internal partitions are not mounted yet. Nothing on the machine is modified
# and no root privileges are needed.
#
# Reported per run: wall time, user+sys CPU of the script and its children
# (bash `times`), and the number of processes created system-wide during the
# run (/proc/stat "processes" delta; the minimum over all runs filters out
# unrelated background activity).

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_SRC="$(realpath "${1:?usage: $0 SCRIPT [ITERATIONS]}")"
ITER="${2:-20}"
# Work inside the repository: /tmp is often mounted noexec, and a stub that
# cannot be executed makes bash silently fall back to the real /usr/bin/mount.
WORK="$(mktemp -d "$HERE/.bench.XXXXXX")"
trap '[ -n "${BENCH_KEEP:-}" ] || rm -rf "$WORK"' EXIT

mkdir -p "$WORK/shims"
cp "$HERE/stubs/mount" "$HERE/stubs/ntfsfix" "$WORK/shims/"
chmod +x "$WORK/shims/"*
# Safety interlock: refuse to run unless the stubs are what will be executed.
for tool in mount ntfsfix; do
    resolved="$(PATH="$WORK/shims:/usr/bin:/bin" command -v "$tool")"
    if [ "$resolved" != "$WORK/shims/$tool" ] || ! [ -x "$resolved" ]; then
        echo "bench: refusing to run, '$tool' resolves to '$resolved' instead of the stub" >&2
        exit 1
    fi
done

patch_script() {
    local root="$1"
    sed \
        -e "s|/etc/bigmountall-no|$root/etc/bigmountall-no|g" \
        -e "s|/run/media|__RUNMEDIA__|g" \
        -e "s|/run/big-mount|$root/run/big-mount|g" \
        -e "s|/run/lock|$root/run/lock|g" \
        -e "s|/proc/mounts|$root/proc/mounts|g" \
        -e "s|/mnt|$root/mnt|g" \
        -e "s|/media|$root/media|g" \
        -e "s|__RUNMEDIA__|$root/run/media|g" \
        "$SCRIPT_SRC" > "$root/bigmount"
}

forks() { local k v; while read -r k v; do [ "$k" = processes ] && { echo "$v"; return; }; done < /proc/stat; }

walls=() cpus=() procs=()
for ((n = 0; n < ITER; n++)); do
    root="$WORK/r$n"
    mkdir -p "$root/etc" "$root/mnt" "$root/run/media" "$root/run/lock" "$root/proc"
    : > "$root/proc/mounts"; : > "$root/mount.log"; : > "$root/ntfsfix.log"
    patch_script "$root"
    f0=$(forks)
    t0=$EPOCHREALTIME
    out=$(env -i TESTROOT="$root" HOME="$HOME" LANG=C PATH="$WORK/shims:/usr/bin:/bin" \
        bash -c 'bash "$1" >/dev/null 2>&1; times' _ "$root/bigmount")
    t1=$EPOCHREALTIME
    f1=$(forks)
    # `times` prints two lines: shell, then children "XmY.YYYs XmZ.ZZZs"
    child=$(sed -n 2p <<<"$out")
    cpu=$(awk '{ split($1,u,"m"); split($2,s,"m"); sub("s","",u[2]); sub("s","",s[2]);
                 printf "%.0f", (u[1]*60+u[2]+s[1]*60+s[2])*1000 }' <<<"$child")
    walls+=("$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", (b-a)*1000 }')")
    cpus+=("$cpu")
    procs+=("$((f1 - f0 - 1))")   # minus the `env` wrapper itself
    mounts=$(grep -c '^mount' "$root/mount.log")
    fixes=$(grep -c '^ntfsfix' "$root/ntfsfix.log")
done

stats() { sort -n | awk '{ a[NR]=$1; s+=$1 } END { printf "min %s  median %s  mean %.1f  max %s", a[1], a[int((NR+1)/2)], s/NR, a[NR] }'; }

echo "script:     $SCRIPT_SRC"
echo "iterations: $ITER"
echo "wall (ms):  $(printf '%s\n' "${walls[@]}" | stats)"
echo "cpu  (ms):  $(printf '%s\n' "${cpus[@]}" | stats)"
echo "processes:  $(printf '%s\n' "${procs[@]}" | stats)"
echo "last run:   $mounts mount call(s), $fixes ntfsfix call(s)"
