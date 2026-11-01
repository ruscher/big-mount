# shellcheck shell=bash
# shellcheck disable=SC2034,SC2015  # CK_*, FI_*, JC, JS are read across functions; A && B || C on purpose
# shellcheck disable=SC2153  # DS_LEVEL comes from drive-diag.sh
#
# big-mount drive manager: copying files off a drive.
#
# A copy is a job: a folder under ~/.local/state/big-mount/jobs with what was
# asked (job.conf) and how far it got (state.env), kept up to date by a
# supervisor process that does not depend on the terminal or window that
# started it. After a power cut the job is still there and resumes.
#
# What a failing disk taught us (docs/12-field-report.md, 16):
#  - one bad sector can hold a read for minutes, and the driver serves one
#    request at a time: everything that touches that mount may hang, so nothing
#    here calls stat on the source without a limit, and the mount table is read
#    from /proc instead of with mountpoint(1);
#  - a file that does not advance must not hold thousands of good ones: it is
#    set aside (deferred) and tried at the end, only if the user asks;
#  - rsync writes to a temporary folder and renames, with fsync: a file with its
#    final name is complete, even after a power cut;
#  - a measured total needs a walk over the source, so a drive at risk goes
#    without one. It then shows what was copied, and no invented percentage.

BM_JOBS="${XDG_STATE_HOME:-$HOME/.local/state}/big-mount/jobs"
BM_MAX_DEFERRED=100
BM_TICK=1

bm_self() {
   REPLY="$(readlink -f -- "$BM_LIB_DIR/../../bin/bigmount")"
   [ -x "$REPLY" ] || REPLY=/usr/bin/bigmount
}

# ---------------------------------------------------------------------------
# Facts about a path, with a limit: the mount may not be answering

# bm_cp_fs PATH: the filesystem that holds PATH (FI_TARGET FI_SOURCE FI_FSTYPE
# FI_RO FI_UUID). Returns 124 when it does not answer, 1 when not found.
bm_cp_fs() {
   local out rc
   FI_TARGET="" FI_SOURCE="" FI_FSTYPE="" FI_RO=0 FI_UUID=""
   out="$(timeout 10 findmnt -P -n -o TARGET,SOURCE,FSTYPE,VFS-OPTIONS -T "$1" 2>/dev/null)"; rc=$?
   [ "$rc" -eq 124 ] && return 124
   [ -n "$out" ] || return 1
   bm_parse_pairs "${out%%$'\n'*}"
   FI_TARGET="${KV[TARGET]}" FI_FSTYPE="${KV[FSTYPE]}"
   FI_SOURCE="${KV[SOURCE]%%\[*}"
   bm_has_opt "${KV[VFS-OPTIONS]}" ro && FI_RO=1
   [[ $FI_SOURCE == /dev/* ]] && FI_UUID="$(lsblk -n -d -o UUID -- "$FI_SOURCE" 2>/dev/null)"
   return 0
}

# Is this exact mount point in the table? Without touching the filesystem.
bm_cp_is_mounted() {
   local t="$1" l f
   while IFS= read -r l; do
      read -r _ _ _ _ f _ <<< "$l"
      printf -v f '%b' "${f//\\/\\0}"
      [ "$f" = "$t" ] && return 0
   done < /proc/self/mountinfo
   return 1
}

# Where a filesystem with this UUID is mounted now (REPLY): a name such as
# /dev/sdb1 and its mount point can change when a drive is connected again.
# PREFERRED wins when it is still there: a Btrfs is mounted many times, one
# per subvolume, and only that one holds the path that was asked for.
bm_cp_mount_of_uuid() {
   local uuid="$1" pref="${2:-}" line mp first=""
   REPLY=""
   [ -n "$uuid" ] || return 1
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      [ "${KV[UUID]:-}" = "$uuid" ] || continue
      while IFS= read -r mp; do
         [ -n "$mp" ] || continue
         [ "$mp" = "[SWAP]" ] && continue
         [ "$mp" = "$pref" ] && { REPLY="$mp"; return 0; }
         [[ $mp == /var/lib/os-prober/* ]] && continue
         [ -n "$first" ] || first="$mp"
      done <<< "${KV[MOUNTPOINTS]:-}"
   done < <(lsblk -P -p -o UUID,MOUNTPOINTS 2>/dev/null)
   REPLY="$first"
   [ -n "$REPLY" ]
}

bm_cp_avail() {
   local out
   out="$(timeout 10 df -B1 --output=avail -- "$1" 2>/dev/null | tail -n 1)"
   REPLY="${out//[[:space:]]/}"
}

# ---------------------------------------------------------------------------
# Checks before anything is written

# bm_cp_err_text KEY: a sentence for a refusal. The exit codes are in bm_cp_err_rc.
bm_cp_err_text() {
   case "$1" in
      no-rsync) REPLY=$"rsync is not installed, and it does the copying. Install the package rsync." ;;
      bad-path) REPLY=$"A path has a line break in its name. It cannot be handled safely." ;;
      source-missing) REPLY=$"The source folder does not exist or cannot be read." ;;
      source-stuck) REPLY=$"The source did not answer in time. The drive may be stuck on a damaged area: wait, or unplug it and try again." ;;
      item-bad) REPLY=$"A selected item is outside the source folder." ;;
      item-missing) REPLY=$"A selected item does not exist in the source folder." ;;
      same-path) REPLY=$"The source and the destination are the same folder." ;;
      dest-inside-source) REPLY=$"The destination is inside the source. The copy would copy itself." ;;
      source-inside-dest) REPLY=$"The source is inside the destination, which could overwrite the source." ;;
      same-fs) REPLY=$"The source and the destination are on the same filesystem. A copy there does not protect the data." ;;
      same-disk) REPLY=$"The destination is on the same physical disk as the source. If that disk fails, both are lost. To accept that, allow it explicitly." ;;
      dest-missing) REPLY=$"The destination folder could not be created." ;;
      dest-ro) REPLY=$"The destination is read-only." ;;
      dest-denied) REPLY=$"You do not have permission to write to the destination." ;;
      dest-stuck) REPLY=$"The destination did not answer in time." ;;
      dest-risky) REPLY=$"The destination is on a drive with critical alerts. To accept that, allow it explicitly." ;;
      rw-source) REPLY=$"This drive is at risk and is mounted with writing enabled. Mount it read-only first, so that nothing changes it during the copy. To accept the risk, allow it explicitly." ;;
      no-space) REPLY=$"There is not enough free space at the destination." ;;
      no-ddrescue) REPLY=$"GNU ddrescue is not installed (package ddrescue). It makes the disk image." ;;
      no-photorec) REPLY=$"PhotoRec is not installed (package testdisk)." ;;
      no-testdisk) REPLY=$"TestDisk is not installed (package testdisk)." ;;
      not-authorized) REPLY=$"Permission was not granted." ;;
      cancelled) REPLY=$"Stopped. Nothing was changed on the disk." ;;
      not-readable) REPLY=$"This device cannot be read by your user. Make a disk image first (bigmount --drive image), and search in the image: it also spares the disk." ;;
      image-same-disk) REPLY=$"The image cannot be stored on the disk being read." ;;
      image-other-disk) REPLY=$"An image of another disk already exists in that place. Continuing it would mix the two: choose another name." ;;
      image-exists) REPLY=$"A file with this name already exists and is not an image started here. Choose another name." ;;
      source-replaced) REPLY=$"The device was disconnected or replaced. Nothing was done." ;;
      no-driver) REPLY=$"This computer has no driver for this filesystem. Installing the right package may solve it." ;;
      locked) REPLY=$"This volume is encrypted. Unlock it first." ;;
      member) REPLY=$"This is a part of a larger volume (RAID, LVM or similar), not a filesystem of its own. Its volume must be assembled first." ;;
      swap) REPLY=$"This is swap space, not a place for files." ;;
      no-filesystem) REPLY=$"No filesystem was recognized on it, so its files cannot be listed." ;;
      pick-volume) REPLY=$"Choose one of the volumes of this drive to see its files." ;;
      image-file) REPLY=$"This is already a disk image." ;;
      *) REPLY=$"The copy was refused." ;;
   esac
}

bm_cp_err_rc() {
   case "$1" in
      no-rsync | no-ddrescue | no-photorec | no-testdisk) REPLY=25 ;;
      no-space) REPLY=21 ;;
      not-authorized) REPLY=5 ;;
      cancelled) REPLY=23 ;;
      source-replaced) REPLY=24 ;;
      source-stuck | dest-stuck) REPLY=24 ;;
      *) REPLY=20 ;;
   esac
}

bm_cp_warn_text() {
   case "$1" in
      source-rw) REPLY=$"The source is mounted with writing enabled. Mounting it read-only is safer." ;;
      source-risk) REPLY=$"The source drive reported problems. Files that do not advance are set aside so the rest is saved first." ;;
      no-total) REPLY=$"The total is not measured on a drive at risk, to avoid extra reads. Progress shows what was copied so far." ;;
      total-estimate) REPLY=$"The total is the used space of the volume: an approximation." ;;
      fat) REPLY=$"The destination is FAT32, which cannot store files of 4 GiB or more. Those files will be listed as failed." ;;
      no-perms) REPLY=$"The destination does not store Linux permissions. Names and dates are kept, permissions are not." ;;
      conflicts) REPLY=$"Some files already exist at the destination with different content. See the option for existing files." ;;
      no-fsync) REPLY=$"This version of rsync cannot sync each file to the disk (it needs 3.2.4 or later). After a power cut, the last files copied should be checked." ;;
      full-verify) REPLY=$"The full check reads every file of the source again. On a drive at risk that is extra wear." ;;
      *) REPLY="$1" ;;
   esac
}

# bm_cp_disks_share A B: do these block devices live on a common physical disk?
bm_cp_disks_share() {
   local a b
   bm_dv_disks_of "$1" || return 1
   local src_disks=("${DV_DISKS[@]}")
   bm_dv_disks_of "$2" || return 1
   for a in "${src_disks[@]}"; do
      for b in "${DV_DISKS[@]}"; do [ "$a" = "$b" ] && return 0; done
   done
   return 1
}

# bm_cp_check: every check that does not write. Reads the CP_* options.
# Sets CK_ERR (empty: ok), CK_WARN, CP_S and CP_D (real paths), CK_SRC_* and
# CK_DST_*, CK_LEVEL (health of the source drive) and CK_SAME_DISK.
bm_cp_check() {
   local i rc s d
   CK_ERR="" CK_WARN=() CK_LEVEL=unknown CK_SAME_DISK=0
   CK_SRC_DEV="" CK_SRC_UUID="" CK_SRC_MP="" CK_SRC_FS="" CK_DST_DEV="" CK_DST_UUID="" CK_DST_MP="" CK_DST_FS=""
   command -v rsync >/dev/null || { CK_ERR="no-rsync"; return 1; }
   if [[ $CP_SOURCE == *$'\n'* || $CP_DEST == *$'\n'* ]]; then CK_ERR="bad-path"; return 1; fi

   s="$(timeout 10 readlink -e -- "$CP_SOURCE")"; rc=$?
   [ "$rc" -eq 124 ] && { CK_ERR="source-stuck"; return 1; }
   [ -n "$s" ] && timeout 10 test -d "$s" || {
      [ "$?" -eq 124 ] && CK_ERR="source-stuck" || CK_ERR="source-missing"
      return 1
   }
   CP_S="$s"
   bm_cp_fs "$s"; rc=$?
   [ "$rc" -eq 124 ] && { CK_ERR="source-stuck"; return 1; }
   [ "$rc" -eq 0 ] || { CK_ERR="source-missing"; return 1; }
   CK_SRC_DEV="$FI_SOURCE" CK_SRC_UUID="$FI_UUID" CK_SRC_MP="$FI_TARGET" CK_SRC_FS="$FI_FSTYPE"
   local src_ro="$FI_RO"

   for i in "${CP_ITEMS[@]}"; do
      case "/$i/" in
         *$'\n'*) CK_ERR="bad-path"; return 1 ;;
         //* | */../*) CK_ERR="item-bad"; return 1 ;;
      esac
   done
   # One process with one limit: a long selection must not start one per item
   if [ "${#CP_ITEMS[@]}" -gt 0 ]; then
      # shellcheck disable=SC2016  # the code of the other bash
      printf '%s\0' "${CP_ITEMS[@]}" | timeout 60 bash -c 'while IFS= read -r -d "" i; do [ -e "$0/$i" ] || [ -L "$0/$i" ] || exit 3; done' "$s"
      rc=$?
      if [ "$rc" -eq 124 ]; then CK_ERR="source-stuck"; return 1; fi
      if [ "$rc" -ne 0 ]; then CK_ERR="item-missing"; return 1; fi
   fi

   # The folder may not exist yet: the real path of what does
   d="$(timeout 10 readlink -m -- "$CP_DEST")"; rc=$?
   [ "$rc" -eq 124 ] && { CK_ERR="dest-stuck"; return 1; }
   CP_D="$d"
   if [ "$s" = "$d" ]; then CK_ERR="same-path"; return 1; fi
   case "$d/" in "$s"/*) CK_ERR="dest-inside-source"; return 1 ;; esac
   case "$s/" in "$d"/*) CK_ERR="source-inside-dest"; return 1 ;; esac

   local probe="$d"
   while [ ! -e "$probe" ] && [ "$probe" != / ]; do probe="${probe%/*}"; probe="${probe:-/}"; done
   bm_cp_fs "$probe"; rc=$?
   [ "$rc" -eq 124 ] && { CK_ERR="dest-stuck"; return 1; }
   [ "$rc" -eq 0 ] || { CK_ERR="dest-missing"; return 1; }
   CK_DST_DEV="$FI_SOURCE" CK_DST_UUID="$FI_UUID" CK_DST_MP="$FI_TARGET" CK_DST_FS="$FI_FSTYPE"
   if [ "$FI_RO" = 1 ]; then CK_ERR="dest-ro"; return 1; fi
   timeout 10 test -w "$probe" || { [ "$?" -eq 124 ] && CK_ERR="dest-stuck" || CK_ERR="dest-denied"; return 1; }

   # A real topology comparison, not one of names: a partition on LVM on the
   # same disk counts as the same disk
   if [ "${CP_ALLOW_SAMEFS:-0}" != 1 ]; then
      if [ "$CK_SRC_DEV" = "$CK_DST_DEV" ]; then CK_ERR="same-fs"; return 1; fi
      if [ -n "$CK_SRC_UUID" ] && [ "$CK_SRC_UUID" = "$CK_DST_UUID" ]; then CK_ERR="same-fs"; return 1; fi
      if [[ $CK_SRC_DEV == /dev/* && $CK_DST_DEV == /dev/* ]] && bm_cp_disks_share "$CK_SRC_DEV" "$CK_DST_DEV"; then
         CK_SAME_DISK=1
         [ "$CP_ALLOW_SAME" = 1 ] || { CK_ERR="same-disk"; return 1; }
      fi
   fi

   # Health of both ends: only from what is already known, never from the disk
   bm_dv_scan
   if [[ $CK_DST_DEV == /dev/* ]] && bm_dv_disks_of "$CK_DST_DEV"; then
      bm_ds_level "${DV_DISKS[0]}"
      [ "$DS_LEVEL" = critical ] && [ "$CP_ALLOW_RISKY" != 1 ] && { CK_ERR="dest-risky"; return 1; }
   fi
   if [[ $CK_SRC_DEV == /dev/* ]] && bm_dv_disks_of "$CK_SRC_DEV"; then
      bm_ds_level "${DV_DISKS[0]}"
      CK_LEVEL="$DS_LEVEL"
   fi
   if [ "$src_ro" = 0 ]; then
      case "$CK_LEVEL" in
         critical | attention)
            [ "$CP_ALLOW_RW" = 1 ] || { CK_ERR="rw-source"; return 1; } ;;
      esac
      CK_WARN+=(source-rw)
   fi
   case "$CK_LEVEL" in critical | attention) CK_WARN+=(source-risk) ;; esac
   case "$CK_DST_FS" in vfat | msdos) CK_WARN+=(fat) ;; esac
   bm_is_posix_fs "$CK_DST_FS" && bm_is_posix_fs "$CK_SRC_FS" || CK_WARN+=(no-perms)
   if [ "$CP_VERIFY" = full ]; then
      case "$CK_LEVEL" in critical | attention) CK_WARN+=(full-verify) ;; esac
   fi
   bm_cp_has_fsync || CK_WARN+=(no-fsync)
   return 0
}

bm_cp_has_fsync() { rsync --help 2>/dev/null | grep -q -- '--fsync'; }

# ---------------------------------------------------------------------------
# rsync

# Options common to every pass (RS). JC holds the job. Never follows a link,
# never crosses into another mounted filesystem, never deletes.
bm_cp_rsync_args() {
   local dir="$1" d="$2"
   # -8: names as they are. Otherwise the log mixes raw bytes with \#ooo escapes
   RS=(-rlt -8 --one-file-system --no-specials --no-devices
      "--log-file=$dir/events.log" '--log-file-format=%i|%l|%n'
      "--temp-dir=$d/.big-mount-tmp-${JC[ID]}"
      '--exclude=/.big-mount-tmp-*' '--exclude=/.big-mount-backup-*'
      "--exclude-from=$dir/excludes.txt")
   [ "${JC[SKIP_LF]:-0}" = 1 ] && RS+=('--exclude=/lost+found')
   bm_cp_has_fsync && RS+=(--fsync)
   if bm_is_posix_fs "${JC[DST_FS]}" && bm_is_posix_fs "${JC[SRC_FS]}"; then RS+=(-p); else RS+=(--no-perms); fi
   case "${JC[DST_FS]}|${JC[SRC_FS]}" in
      vfat* | msdos* | *\|vfat | *\|msdos) RS+=(--modify-window=2) ;;
      exfat* | ntfs* | fuseblk* | *\|exfat | *\|ntfs | *\|fuseblk) RS+=(--modify-window=1) ;;
   esac
   [ -n "${JC[BWLIMIT]:-}" ] && RS+=("--bwlimit=${JC[BWLIMIT]}")
   case "${JC[ON_CONFLICT]}" in
      skip) RS+=(--ignore-existing) ;;
      backup) RS+=(--backup "--backup-dir=$d/.big-mount-backup-${JC[ID]}") ;;
   esac
   return 0
}

# The list of what to copy: selected items, or the whole source
bm_cp_selection() {
   local dir="$1"
   SEL=()
   if [ "${JC[RETRY]:-0}" = 1 ]; then
      SEL=("--files-from=$dir/retry0" --from0)
   elif [ -s "$dir/items0" ]; then
      SEL=("--files-from=$dir/items0" --from0)
   fi
}

# bm_cp_scan S D: what would be copied, measured with a dry run (metadata only).
# CS_FILES CS_BYTES CS_CONFLICTS. Runs under the caller, which may stop it.
bm_cp_scan_cmd() {
   local s="$1" d="$2" skip=0 a args=()
   for a in "${RS[@]}"; do
      case "$a" in
         --log-file=* | --log-file-format=* | --temp-dir=* | --fsync | --ignore-existing) continue ;;
      esac
      args+=("$a")
   done
   [ "${JC[ON_CONFLICT]}" = skip ] && skip=1
   LC_ALL=C rsync -n --out-format='%i|%l' "${args[@]}" "${SEL[@]}" "$s/" "$d/" 2>/dev/null |
      awk -F'|' -v skip="$skip" '
         /^>f\+/ { f++; b += $2; next }
         /^>f/ { c++; if (!skip) { f++; b += $2 } }
         END { printf "%d %d %d\n", f, b, c }'
}

# ---------------------------------------------------------------------------
# Job storage

bm_job_id() {
   local r
   printf -v r '%04x' "$((RANDOM % 65536))"
   printf -v REPLY '%(%Y%m%d-%H%M%S)T-%s' -1 "$r"
}

bm_job_dir() {
   [[ $1 =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]] || return 1
   REPLY="$BM_JOBS/$1"
   [ -f "$REPLY/job.conf" ]
}

declare -gA JC JS
bm_job_conf_load() {
   local k v l
   JC=()
   while IFS= read -r l; do
      k="${l%%=*}" v="${l#*=}"
      [ -n "$k" ] && [ "$k" != "$l" ] && JC[$k]="$v"
   done < "$1/job.conf"
}

# One KEY=value per line: a line break in a value (a volume label, a path)
# would add a line of its own, so such a job is refused
bm_job_conf_save() {
   local dir="$1" k
   for k in "${!JC[@]}"; do
      [[ ${JC[$k]} != *$'\n'* ]] || { printf $"Cannot record a name with a line break: %s"'\n' "${JC[$k]//$'\n'/?}" >&2; return 1; }
   done
   for k in "${!JC[@]}"; do printf '%s=%s\n' "$k" "${JC[$k]}"; done > "$dir/job.conf.tmp"
   mv -f -- "$dir/job.conf.tmp" "$dir/job.conf"
}

# The state is replaced atomically: a reader, or a power cut, never finds half
bm_job_state_save() {
   local dir="$1" k
   for k in "${!JS[@]}"; do printf '%s=%s\n' "$k" "${JS[$k]//$'\n'/ }"; done > "$dir/state.tmp"
   mv -f -- "$dir/state.tmp" "$dir/state.env"
}

# Load the state, and say what is really happening: a job marked as running
# whose supervisor no longer exists (power cut, killed) was interrupted
bm_job_state_load() {
   local dir="$1" k v l
   JS=()
   [ -f "$dir/state.env" ] || return 1
   while IFS= read -r l; do
      k="${l%%=*}" v="${l#*=}"
      [ -n "$k" ] && [ "$k" != "$l" ] && JS[$k]="$v"
   done < "$dir/state.env"
   case "${JS[STATE]:-}" in
      pending | analyzing | running | verifying | stopping)
         # Pending without a supervisor is the moment before it starts
         [ -n "${JS[PID]:-}" ] || return 0
         if ! bm_proc_state "${JS[PID]}" || [ "$PROC_START" != "${JS[PID_START]:-}" ]; then
            JS[STATE]=interrupted
         fi
         ;;
   esac
   return 0
}

# bm_job_state_label STATE [KIND]: the same state reads differently for each kind
bm_job_state_label() {
   case "${2:-copy}:$1" in
      image:running) REPLY=$"Making the disk image"; return ;;
      image:completed) REPLY=$"Disk image complete"; return ;;
      scan:analyzing | scan:running) REPLY=$"Listing the files"; return ;;
      scan:completed) REPLY=$"List of files complete"; return ;;
      carve:analyzing | carve:running) REPLY=$"Searching by content"; return ;;
      carve:completed) REPLY=$"Search complete"; return ;;
   esac
   case "$1" in
      pending) REPLY=$"Waiting to start" ;;
      analyzing) REPLY=$"Measuring what will be copied" ;;
      running) REPLY=$"Copying" ;;
      verifying) REPLY=$"Checking the result" ;;
      stopping) REPLY=$"Stopping: waiting for the disk to answer" ;;
      paused) REPLY=$"Paused" ;;
      completed) REPLY=$"Completed and checked" ;;
      cancelled) REPLY=$"Cancelled" ;;
      failed) REPLY=$"Failed" ;;
      needs-attention) REPLY=$"Finished, needs your attention" ;;
      interrupted) REPLY=$"Interrupted (it can be resumed)" ;;
      *) REPLY="$1" ;;
   esac
}

# File names in a list for the terminal, indented: control characters from a
# name could otherwise move the cursor or retitle the terminal
bm_printable_lines() { LC_ALL=C.UTF-8 sed 's/[[:cntrl:]]//g; s/^/  /'; }

bm_job_reason_text() {
   case "$1" in
      source-gone) REPLY=$"The source drive was disconnected or unmounted. Connect and mount it again, then resume." ;;
      dest-gone) REPLY=$"The destination was disconnected or unmounted. Connect and mount it again, then resume." ;;
      no-space) REPLY=$"The destination ran out of space. Free some space or choose another place, then resume." ;;
      too-many-deferred) printf -v REPLY $"%s files were set aside because they did not advance. The drive may be getting worse, so the copy stopped." "$BM_MAX_DEFERRED" ;;
      files-left) REPLY=$"Some files were not copied. See the list below." ;;
      differences) REPLY=$"The check found differences between source and destination." ;;
      not-verified) REPLY=$"Everything was copied, but the check did not finish: it was cancelled or failed." ;;
      rsync-error) REPLY=$"rsync stopped with an error. See the log." ;;
      not-authorized) REPLY=$"Permission was not granted." ;;
      no-ddrescue) REPLY=$"GNU ddrescue is not installed (package ddrescue). It makes the disk image." ;;
      image-error) REPLY=$"GNU ddrescue stopped with an error. See the log." ;;
      image-incomplete) REPLY=$"Some areas of the disk could not be read. The image holds everything that could be." ;;
      read-errors) REPLY=$"Some folders could not be read, so the list may be incomplete. See the log." ;;
      search-error) REPLY=$"PhotoRec stopped with an error. See the log." ;;
      nothing-found) REPLY=$"No file was recognized by its content. That does not prove there is nothing to recover: another method, or a professional, may find more." ;;
      "") REPLY="" ;;
      *) REPLY="$1" ;;
   esac
}

bm_job_exit() {
   case "${JS[STATE]:-}" in
      completed) return 0 ;;
      needs-attention)
         case "${JS[REASON]:-}" in
            no-space) return 21 ;;
            source-gone | dest-gone) return 24 ;;
         esac
         return 22
         ;;
      cancelled | paused) return 23 ;;
      interrupted) return 24 ;;
      *) return 1 ;;
   esac
}

# ---------------------------------------------------------------------------
# The supervisor

# Two records of what rsync does. The log (--log-file) says what was sent:
#   "2026/10/30 14:37:02 [38219] >f+++++++++|1234|a/b.jpg"
# Its standard error says what went wrong, including everything the receiver
# saw, which the log does not get (disk full, a name the destination refuses).
# A file is logged BEFORE its read errors are known, so a failed attempt is
# taken back when the verdict arrives. A file sent just before rsync was
# stopped is sent again by the next pass: names seen recently count once.
BM_LOG_RE='^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]{8} \[[0-9]+\] (.*)$'
BM_LOG_PART="" BM_OUT_PART=""
declare -gA BM_FAILED BM_RECENT_A BM_RECENT_B
BM_RECENT_MAX=128

# Take one logged attempt of NAME back from the counters
bm_job_uncount() {
   local LC_ALL=C name="$1" size="" l
   if [ -n "${BM_RECENT_A[$name]+set}" ]; then size="${BM_RECENT_A[$name]}"; unset -v 'BM_RECENT_A[$name]'
   elif [ -n "${BM_RECENT_B[$name]+set}" ]; then size="${BM_RECENT_B[$name]}"; unset -v 'BM_RECENT_B[$name]'
   else
      l="$(grep -aF -- "|$name" "$BM_RUN_DIR/events.log" | tail -n 1)"
      l="${l#*|}"
      size="${l%%|*}"
   fi
   [[ $size =~ ^[0-9]+$ ]] || return 0
   JS[FILES_DONE]=$((JS[FILES_DONE] - 1))
   JS[BYTES_DONE]=$((JS[BYTES_DONE] - size))
}

bm_job_log_line() {
   # Bytes: a name from an old disk may not be valid UTF-8, and a regular
   # expression in a UTF-8 locale would then silently not match the line
   local LC_ALL=C line="$1" p size name rest
   [[ $line =~ $BM_LOG_RE ]] || return 0
   p="${BASH_REMATCH[1]}"
   case "$p" in
      ">f"*)
         rest="${p#*|}"; size="${rest%%|*}"; name="${rest#*|}"
         [[ $size =~ ^[0-9]+$ ]] || size=0
         if [ -n "${BM_RECENT_A[$name]+set}" ] || [ -n "${BM_RECENT_B[$name]+set}" ]; then bm_job_uncount "$name"; fi
         JS[FILES_DONE]=$((JS[FILES_DONE] + 1))
         JS[BYTES_DONE]=$((JS[BYTES_DONE] + size))
         JS[CURRENT]="$name"
         BM_RECENT_A[$name]="$size"
         if [ "${#BM_RECENT_A[@]}" -ge "$BM_RECENT_MAX" ]; then
            BM_RECENT_B=()
            for rest in "${!BM_RECENT_A[@]}"; do BM_RECENT_B[$rest]="${BM_RECENT_A[$rest]}"; done
            BM_RECENT_A=()
         fi
         ;;
      "cL"*)
         JS[FILES_DONE]=$((JS[FILES_DONE] + 1))
         ;;
   esac
}

bm_job_out_line() {
   local LC_ALL=C p="$1" name rest
   [[ $p == *"No space left on device"* ]] && BM_NOSPACE=1
   case "$p" in
      "WARNING: "*" failed verification"*)
         name="${p#WARNING: }"; name="${name% failed verification*}"
         bm_job_uncount "$name"
         ;;
      "ERROR: "*" failed verification"*)
         name="${p#ERROR: }"; name="${name% failed verification*}"
         bm_job_uncount "$name"
         BM_FAILED[$name]=$"its content could not be read"
         JS[READ_FAILS]=$((${JS[READ_FAILS]:-0} + 1))
         ;;
      "rsync: "*"read errors mapping"*)
         JS[READ_FAILS]=$((${JS[READ_FAILS]:-0} + 1))
         ;;
      "rsync: "*"failed to open"* | "rsync: "*"link_stat"* | "rsync: "*"readlink"* | "rsync: "*"opendir"* | "rsync: "*"mkstemp"* | "rsync: "*"rename"* | "rsync: "*"recv_generator"* | "rsync: "*"symlink"* | "rsync: "*"mkdir"* | "rsync: "*"write failed"* | "rsync: "*"chown"*)
         if [[ $p =~ \"([^\"]+)\"[^\"]*:\ ([^:]*)\ \([0-9]+\)$ ]]; then
            name="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
            name="${name#"$BM_RUN_S"/}"
            name="${name#"$BM_RUN_D"/}"
            BM_FAILED[$name]="$rest"
         fi
         ;;
   esac
}

# What rsync added to both records since the last look. Errors first: they
# are about attempts already logged, or about to be.
bm_job_read_log() {
   local line
   if [ -n "${BM_OUT_FD:-}" ]; then
      while IFS= read -r -u "$BM_OUT_FD" line; do
         bm_job_out_line "$BM_OUT_PART$line"
         BM_OUT_PART=""
      done
      BM_OUT_PART+="$line"
   fi
   if [ -n "${BM_LOG_FD:-}" ]; then
      while IFS= read -r -u "$BM_LOG_FD" line; do
         bm_job_log_line "$BM_LOG_PART$line"
         BM_LOG_PART=""
      done
      BM_LOG_PART+="$line"
   fi
}

# Which source file rsync has open and where in it (SND_FILE, SND_POS)
bm_job_sender_pos() {
   local pid="$1" fd alvo l flags=""
   SND_FILE="" SND_POS=0
   for fd in /proc/"$pid"/fd/*; do
      alvo="$(readlink "$fd" 2>/dev/null)" || continue
      case "$alvo" in "$BM_RUN_S"/*) ;; *) continue ;; esac
      flags="" l=""
      { while read -r l f; do
           case "$l" in
              pos:) SND_POS="$f" ;;
              flags:) flags="$f" ;;
           esac
        done < "/proc/$pid/fdinfo/${fd##*/}"; } 2>/dev/null
      [ -n "$flags" ] || continue
      # O_DIRECTORY: rsync also keeps the folder it is in open
      [ $((8#$flags & 8#200000)) -eq 0 ] || continue
      SND_FILE="${alvo#"$BM_RUN_S"/}"
      return 0
   done
   SND_POS=0
   return 1
}

# Publish what is known now. ETA only with a total and a measured speed.
bm_job_publish() {
   local dir="$1" pos="$2" now t0 r0 elapsed bytes
   printf -v now '%(%s)T' -1
   bytes=$((JS[BYTES_DONE] + pos))
   elapsed=$((JS[ELAPSED_BASE] + now - BM_RUN_T0))
   JS[ELAPSED]="$elapsed"
   JS[BYTES_NOW]="$bytes"
   JS[DEFERRED]="$BM_DEFERRED_N"
   JS[FAILED]="${#BM_FAILED[@]}"
   BM_RATE_T+=("$now") BM_RATE_B+=("$bytes")
   while [ "${#BM_RATE_T[@]}" -gt 1 ] && [ $((now - BM_RATE_T[0])) -gt 20 ]; do
      BM_RATE_T=("${BM_RATE_T[@]:1}") BM_RATE_B=("${BM_RATE_B[@]:1}")
   done
   t0="${BM_RATE_T[0]}" r0="${BM_RATE_B[0]}"
   if [ "$now" -gt "$t0" ]; then JS[RATE_NOW]=$(((bytes - r0) / (now - t0))); fi
   local copied=$((bytes - JS[BYTES_BASE]))
   [ $((now - BM_RUN_T0)) -gt 0 ] && JS[RATE_AVG]=$((copied / (now - BM_RUN_T0)))
   JS[ETA]=""
   if [ "${JS[BYTES_TOTAL]:-0}" -gt 0 ] && [ "${JS[RATE_NOW]:-0}" -gt 0 ] && [ "$bytes" -lt "${JS[BYTES_TOTAL]}" ]; then
      JS[ETA]=$(((JS[BYTES_TOTAL] - bytes) / JS[RATE_NOW]))
   fi
   bm_job_state_save "$dir"
}

bm_job_write_failed() {
   local dir="$1" k
   for k in "${!BM_FAILED[@]}"; do printf '%s\t%s\n' "${BM_FAILED[$k]}" "$k"; done > "$dir/failed.txt"
}

# Run one rsync pass and watch it. Returns its exit code. Sets BM_PASS_END:
# done | deferred | cancel | pause | source-gone | dest-gone
bm_job_pass() {
   local dir="$1" s="$2" d="$3" stall="$4" last_file="" last_pos=-1 still=0 idle=0 tick=0 ctl
   local wstat="" wnow="" wlast="" wdev
   BM_PASS_END="done"
   # The sectors written to the destination device: while they grow, a file
   # that does not advance waits for the destination (a slow drive syncing
   # the file before it), not for a damaged source
   wdev="$(findmnt -n -o SOURCE -T "$d" 2>/dev/null)"; wdev="${wdev%%\[*}"
   if [ -b "$wdev" ]; then
      wdev="$(readlink -f -- "$wdev")"
      [ -r "/sys/class/block/${wdev##*/}/stat" ] && wstat="/sys/class/block/${wdev##*/}/stat"
   fi
   ionice -c 2 -n 6 nice -n 5 rsync "${RS[@]}" "${SEL[@]}" "$s/" "$d/" >> "$dir/rsync.out" 2>&1 &
   local pid=$!
   while kill -0 "$pid" 2>/dev/null; do
      sleep "$BM_TICK"
      tick=$((tick + 1))
      bm_job_read_log
      SND_FILE="" SND_POS=0
      bm_job_rsync_pid "$pid" && bm_job_sender_pos "$REPLY"
      [ -n "$SND_FILE" ] && JS[CURRENT]="$SND_FILE"
      bm_job_publish "$dir" "$SND_POS"

      ctl=""
      { read -r ctl < "$dir/control"; } 2>/dev/null
      if [ "$ctl" = cancel ] || [ "$ctl" = pause ]; then
         BM_PASS_END="$ctl"
         JS[STATE]=stopping
         bm_job_state_save "$dir"
         break
      fi
      if [ $((tick % 5)) -eq 0 ]; then
         if ! bm_cp_is_mounted "$BM_RUN_SMP"; then
            BM_PASS_END="source-gone"
         elif ! bm_cp_is_mounted "$BM_RUN_DMP"; then
            BM_PASS_END="dest-gone"
         fi
         if [ "$BM_PASS_END" != "done" ]; then
            break
         fi
      fi
      # The file did not advance: set it aside and go on with the others. A
      # destination still writing gets four times the limit: other programs
      # can keep a shared one busy all the time
      wnow=""
      [ -n "$wstat" ] && { read -r _ _ _ _ _ _ wnow _ < "$wstat"; } 2>/dev/null
      if [ "$stall" -gt 0 ] && [ -n "$SND_FILE" ] && [ "$SND_FILE" = "$last_file" ] && [ "$SND_POS" = "$last_pos" ]; then
         still=$((still + BM_TICK))
         [ "$wnow" = "$wlast" ] && idle=$((idle + BM_TICK))
         JS[STUCK_SECONDS]="$still"
         if [ "$idle" -ge "$stall" ] || [ "$still" -ge $((stall * 4)) ]; then
            bm_job_defer "$dir" "$SND_FILE"
            BM_PASS_END="deferred"
            JS[STATE]=running
            bm_job_state_save "$dir"
            break
         fi
      else
         still=0 idle=0
         JS[STUCK_SECONDS]=0
      fi
      last_file="$SND_FILE" last_pos="$SND_POS" wlast="$wnow"
   done
   # Stopped here, never with SIGKILL: rsync removes its temporary file, and
   # exits as soon as a read stuck in the driver comes back. Its helpers end
   # after it; they are listed first, as they get another parent when it exits
   local kids="" k
   if kill -0 "$pid" 2>/dev/null; then
      kids="$(pgrep -P "$pid")"
      kill -TERM "$pid" 2>/dev/null
   fi
   wait "$pid"
   local rc=$?
   for k in $kids; do
      while kill -0 "$k" 2>/dev/null; do sleep 1; done
   done
   bm_job_read_log
   JS[STUCK_SECONDS]=0
   return "$rc"
}

# The rsync that holds source files open is the sender: the one we started
bm_job_rsync_pid() { REPLY="$1"; [ -d "/proc/$1" ]; }

bm_job_defer() {
   local dir="$1" f="$2"
   grep -qxF -- "$f" "$dir/deferred.txt" 2>/dev/null && return 0
   printf '%s\n' "$f" >> "$dir/deferred.txt"
   # An exclude pattern anchored at the source, with its specials escaped
   local p="$f"
   p="${p//\\/\\\\}"; p="${p//\*/\\*}"; p="${p//\?/\\?}"; p="${p//\[/\\[}"
   printf '/%s\n' "$p" >> "$dir/excludes.txt"
   BM_DEFERRED_N=$((BM_DEFERRED_N + 1))
}

# Finds where the source and the destination are now. Needed after the drive
# is connected again, when its name or mount point may have changed.
bm_job_locate() {
   local rel
   BM_RUN_S="${JC[SOURCE]}" BM_RUN_D="${JC[DEST]}" BM_RUN_SMP="${JC[SRC_MP]}" BM_RUN_DMP="${JC[DST_MP]}"
   if [ -n "${JC[SRC_UUID]:-}" ]; then
      bm_cp_mount_of_uuid "${JC[SRC_UUID]}" "${JC[SRC_MP]}" || return 3
      rel="${JC[SOURCE]#"${JC[SRC_MP]}"}"
      BM_RUN_SMP="$REPLY" BM_RUN_S="$REPLY$rel"
   else
      bm_cp_is_mounted "$BM_RUN_SMP" || return 3
   fi
   if [ -n "${JC[DST_UUID]:-}" ]; then
      bm_cp_mount_of_uuid "${JC[DST_UUID]}" "${JC[DST_MP]}" || return 4
      rel="${JC[DEST]#"${JC[DST_MP]}"}"
      BM_RUN_DMP="$REPLY" BM_RUN_D="$REPLY$rel"
   else
      bm_cp_is_mounted "$BM_RUN_DMP" || return 4
   fi
   return 0
}

bm_job_finish() {
   local dir="$1" state="$2" reason="${3:-}" d
   JS[STATE]="$state" JS[REASON]="$reason"
   JS[FAILED]="${#BM_FAILED[@]}" JS[DEFERRED]="$BM_DEFERRED_N"
   JS[BYTES_NOW]="${JS[BYTES_DONE]}"
   printf -v "JS[FINISHED]" '%(%s)T' -1
   bm_job_write_failed "$dir"
   # Only what rsync left in our own folder
   d="$BM_RUN_D/.big-mount-tmp-${JC[ID]}"
   if [ "$state" != paused ] && [ -d "$d" ] && [ ! -L "$d" ]; then
      find "$d" -xdev -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null
      rmdir -- "$d" 2>/dev/null
   fi
   bm_job_state_save "$dir"
   bm_job_report_write "$dir"
}

# The source and destination compared, after the copy. Nothing is changed.
# JS[VERIFY_RESULT]: ok | differences | skipped | failed (cancelled or an error)
bm_job_verify() {
   local dir="$1" s="$2" d="$3" level="${JC[VERIFY]}" a args=() rc
   JS[VERIFY_RESULT]=skipped
   [ "$level" = basic ] && return 0
   JS[STATE]=verifying
   bm_job_state_save "$dir"
   for a in "${RS[@]}"; do
      case "$a" in
         --log-file=* | --log-file-format=* | --temp-dir=* | --fsync | --ignore-existing | --backup | --backup-dir=*) continue ;;
      esac
      args+=("$a")
   done
   [ "$level" = full ] && args+=(--checksum)
   LC_ALL=C rsync -n --out-format='%i|%n' "${args[@]}" "${SEL[@]}" "$s/" "$d/" > "$dir/verify.out" 2>&1 &
   local pid=$! ctl=""
   while kill -0 "$pid" 2>/dev/null; do
      sleep "$BM_TICK"
      { read -r ctl < "$dir/control"; } 2>/dev/null
      if [ "$ctl" = cancel ]; then kill -TERM "$pid" 2>/dev/null; break; fi
   done
   wait "$pid"; rc=$?
   grep -E '^>f|^cL' "$dir/verify.out" | cut -d'|' -f2- > "$dir/differences.txt"
   JS[DIFFER]="$(wc -l < "$dir/differences.txt")"
   if [ "$ctl" = cancel ] || { [ "$rc" -ne 0 ] && [ "$rc" -ne 23 ] && [ "$rc" -ne 24 ]; }; then
      JS[VERIFY_RESULT]=failed
   elif [ "${JS[DIFFER]}" -gt 0 ]; then
      JS[VERIFY_RESULT]=differences
   else
      JS[VERIFY_RESULT]=ok
   fi
}

# bigmount --drive __run ID: the supervisor. Started detached by bm_job_start.
bm_job_supervise() {
   local id="$1" dir s d stall rc end
   bm_job_dir "$id" || return 1
   dir="$REPLY"
   exec 7>"$dir/lock"
   flock -n 7 || return 10
   bm_job_conf_load "$dir"
   bm_job_state_load "$dir" || JS=()
   : > "$dir/control"
   touch "$dir/events.log" "$dir/excludes.txt" "$dir/deferred.txt"

   local k
   for k in FILES_DONE BYTES_DONE BYTES_TOTAL FILES_TOTAL RATE_NOW RATE_AVG ELAPSED BYTES_NOW READ_FAILS DIFFER; do
      JS[$k]="${JS[$k]:-0}"
   done
   # Counted again from the log below, which is the record of what was copied
   JS[FILES_DONE]=0 JS[BYTES_DONE]=0 JS[READ_FAILS]=0 JS[REASON]="" JS[VERIFY_RESULT]=""
   JS[ELAPSED_BASE]="${JS[ELAPSED]:-0}"
   JS[STATE]=pending JS[PID]="$$"
   bm_proc_state "$$"; JS[PID_START]="$PROC_START"
   printf -v "JS[STARTED]" '%(%s)T' -1
   printf -v BM_RUN_T0 '%(%s)T' -1
   BM_RATE_T=() BM_RATE_B=() BM_FAILED=() BM_NOSPACE=0 BM_RECENT_A=() BM_RECENT_B=()
   BM_DEFERRED_N="$(wc -l < "$dir/deferred.txt")"
   bm_job_state_save "$dir"
   trap 'printf "cancel\n" > "$dir/control"' TERM

   bm_job_locate; rc=$?
   if [ "$rc" -ne 0 ]; then
      BM_RUN_D="${JC[DEST]}"
      if [ "$rc" -eq 3 ]; then bm_job_finish "$dir" needs-attention source-gone
      else bm_job_finish "$dir" needs-attention dest-gone
      fi
      return 0
   fi
   s="$BM_RUN_S" d="$BM_RUN_D"
   if ! mkdir -p -- "$d" "$d/.big-mount-tmp-$id" 2>/dev/null; then
      bm_job_finish "$dir" needs-attention dest-gone
      return 0
   fi

   BM_RUN_DIR="$dir"
   # The log is the record of what was copied. Failed attempts of earlier runs
   # are taken back, but the failures themselves start over: everything that
   # failed is tried again in this run, and this run gives the verdict.
   exec {BM_LOG_FD}<"$dir/events.log"
   bm_job_read_log
   touch "$dir/rsync.out" "$dir/rsync.old"
   cat -- "$dir/rsync.out" >> "$dir/rsync.old"
   : > "$dir/rsync.out"
   local old
   while IFS= read -r old; do bm_job_out_line "$old"; done < "$dir/rsync.old"
   BM_FAILED=() BM_NOSPACE=0
   exec {BM_OUT_FD}<"$dir/rsync.out"
   # A folder only the system can read, normally empty: not a failure of the copy
   if [ -e "$s/lost+found" ] && ! timeout 5 test -r "$s/lost+found"; then JC[SKIP_LF]=1; else JC[SKIP_LF]=0; fi
   JS[BYTES_BASE]="${JS[BYTES_DONE]}"
   bm_cp_rsync_args "$dir" "$d"
   bm_cp_selection "$dir"

   # The total: measured when the drive can take it
   if [ "${JC[SCAN]}" = yes ]; then
      JS[STATE]=analyzing
      bm_job_state_save "$dir"
      local out f b c
      bm_cp_scan_cmd "$s" "$d" > "$dir/scan.out" &
      local spid=$! ctl=""
      while kill -0 "$spid" 2>/dev/null; do
         sleep "$BM_TICK"
         { read -r ctl < "$dir/control"; } 2>/dev/null
         # The children first: once the subshell is gone they have another parent
         if [ "$ctl" = cancel ] || [ "$ctl" = pause ]; then pkill -TERM -P "$spid" 2>/dev/null; kill -TERM "$spid" 2>/dev/null; break; fi
      done
      wait "$spid" 2>/dev/null
      case "$ctl" in
         cancel) bm_job_finish "$dir" cancelled; return 0 ;;
         pause) bm_job_finish "$dir" paused; return 0 ;;
      esac
      read -r f b c < "$dir/scan.out" 2>/dev/null
      if [[ ${b:-} =~ ^[0-9]+$ ]] && [ "${JS[FILES_TOTAL]:-0}" -eq 0 ]; then
         JS[FILES_TOTAL]=$((JS[FILES_DONE] + f)) JS[BYTES_TOTAL]=$((JS[BYTES_DONE] + b)) JS[CONFLICTS]="${c:-0}" JS[TOTAL_ESTIMATE]=0
      fi
   fi
   JS[STATE]=running
   bm_job_state_save "$dir"

   stall="${JC[STALL]}"
   [ "${JC[RETRY]:-0}" = 1 ] && stall=600
   while :; do
      bm_job_pass "$dir" "$s" "$d" "$stall"; rc=$?
      end="$BM_PASS_END"
      case "$end" in
         deferred)
            if [ "$BM_DEFERRED_N" -ge "$BM_MAX_DEFERRED" ]; then
               bm_job_finish "$dir" needs-attention too-many-deferred
               return 0
            fi
            continue
            ;;
         cancel) bm_job_finish "$dir" cancelled; return 0 ;;
         pause) bm_job_finish "$dir" paused; return 0 ;;
         source-gone | dest-gone) bm_job_finish "$dir" needs-attention "$end"; return 0 ;;
      esac
      break
   done
   JS[RSYNC_RC]="$rc"
   # A mount that vanished under rsync can end it before the check above runs
   if ! bm_cp_is_mounted "$BM_RUN_SMP"; then bm_job_finish "$dir" needs-attention source-gone; return 0; fi
   if ! bm_cp_is_mounted "$BM_RUN_DMP"; then bm_job_finish "$dir" needs-attention dest-gone; return 0; fi
   if [ "$BM_NOSPACE" = 1 ]; then bm_job_finish "$dir" needs-attention no-space; return 0; fi
   case "$rc" in
      0 | 23 | 24) ;;
      *) bm_job_finish "$dir" failed rsync-error; return 0 ;;
   esac
   if [ "${JC[RETRY]:-0}" = 1 ]; then
      JC[RETRY]=0
      bm_job_conf_save "$dir"
   fi
   bm_job_verify "$dir" "$s" "$d"
   if [ "$BM_DEFERRED_N" -gt 0 ] || [ "${#BM_FAILED[@]}" -gt 0 ] || [ "$rc" -ne 0 ]; then
      bm_job_finish "$dir" needs-attention files-left
   elif [ "${JS[VERIFY_RESULT]}" = differences ]; then
      bm_job_finish "$dir" needs-attention differences
   elif [ "${JS[VERIFY_RESULT]}" = failed ]; then
      bm_job_finish "$dir" needs-attention not-verified
   else
      bm_job_finish "$dir" completed
   fi
   return 0
}

# Start the supervisor, independent of this terminal or window
bm_job_start() {
   local id="$1" dir n
   bm_job_dir "$id" || return 1
   dir="$REPLY"
   # Whatever the last state said is over: a reader must not take it for the result
   bm_job_state_load "$dir" || JS=()
   JS[STATE]=pending JS[PID]=""
   bm_job_state_save "$dir"
   bm_self
   setsid -f "$REPLY" --drive __run "$id" </dev/null >>"$dir/supervisor.log" 2>&1 || return 1
   for ((n = 0; n < 100; n++)); do
      bm_job_state_load "$dir" && [ -n "${JS[PID]:-}" ] && return 0
      sleep 0.1
   done
   JS[STATE]=failed JS[REASON]=rsync-error
   bm_job_state_save "$dir"
   return 1
}

# ---------------------------------------------------------------------------
# Presentation

bm_job_json_of() {
   local dir="$1" id="${1##*/}" label reason
   bm_job_conf_load "$dir"
   bm_job_state_load "$dir" || JS[STATE]=pending
   local kind="${JC[KIND]:-copy}" pausable=0 result
   bm_job_state_label "${JS[STATE]}" "$kind"; label="$REPLY"
   bm_job_reason_text "${JS[REASON]:-}"; reason="$REPLY"
   # What the numbers count: a list of what exists, candidates found by content
   # and files copied are not the same thing and must never read the same
   case "$kind" in
      copy) result=copied-files pausable=1 ;;
      image) result=disk-image pausable=1 ;;
      scan) result=existing-files ;;
      carve) result=carved-candidates ;;
      *) result="" ;;
   esac
   printf '{%s,%s,%s}' \
      "$(bm_jo_inner id "$id" kind "$kind" result_kind "$result" state "${JS[STATE]}" state_label "$label" reason "${JS[REASON]:-}" reason_text "$reason" \
         source "${JC[SOURCE]:-}" destination "${JC[DEST]:-}" name "${JC[NAME]:-}" current "${JS[CURRENT]:-}" verify "${JC[VERIFY]:-}" \
         verify_result "${JS[VERIFY_RESULT]:-}" dir "$dir" categories "${JC[CATEGORIES]:-}" then_carve "${JC[THEN_CARVE]:-}" copy_to "${JC[COPY_TO]:-}" map "${JC[MAP]:-}" level "${JC[LEVEL]:-}")" \
      "$(bm_jn files_done "${JS[FILES_DONE]:-0}" files_total "${JS[FILES_TOTAL]:-0}" bytes_done "${JS[BYTES_NOW]:-0}" bytes_total "${JS[BYTES_TOTAL]:-0}" \
         rate_now "${JS[RATE_NOW]:-0}" rate_avg "${JS[RATE_AVG]:-0}" elapsed "${JS[ELAPSED]:-0}" eta "${JS[ETA]:-}" deferred "${JS[DEFERRED]:-0}" \
         failed "${JS[FAILED]:-0}" differ "${JS[DIFFER]:-0}" conflicts "${JS[CONFLICTS]:-0}" read_errors "${JS[READ_FAILS]:-0}" stuck "${JS[STUCK_SECONDS]:-0}" \
         created "${JC[CREATED]:-0}" finished "${JS[FINISHED]:-}" scanned "${JS[SCANNED]:-0}" pass "${JS[PASS]:-0}" bad_bytes "${JS[BAD_BYTES]:-0}")" \
      "$(bm_jb total_estimate "${JS[TOTAL_ESTIMATE]:-0}" pausable "$pausable")"
}

bm_fmt_time() {
   local s="${1:-0}"
   [[ $s =~ ^[0-9]+$ ]] || { REPLY="—"; return; }
   printf -v REPLY '%02d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
}

# A progress bar with no invented numbers: without a total there is no percent
bm_job_bar() {
   local pct="$1" w=28 fill i out="" f="#" e="-"
   [ "${BM_TUI_UTF8:-0}" = 1 ] && f="█" e="░"
   fill=$((pct * w / 100))
   for ((i = 0; i < w; i++)); do
      if [ "$i" -lt "$fill" ]; then out+="$f"; else out+="$e"; fi
   done
   REPLY="[$out] $pct%"
}

# bm_job_status_text DIR (state already loaded). Prints the progress block.
bm_job_status_text() {
   local dir="$1" kind="${JC[KIND]:-copy}" pct total="${JS[BYTES_TOTAL]:-0}" done_="${JS[BYTES_NOW]:-0}"
   bm_job_state_label "${JS[STATE]}" "$kind"
   printf '%s\n' "$REPLY"
   if [ "$kind" = scan ] || [ "$kind" = carve ]; then
      bm_rec_status_text
      return 0
   fi
   printf '%-22s %s\n' $"Source:" "${JC[SOURCE]//[[:cntrl:]]/?}" $"Destination:" "${JC[DEST]//[[:cntrl:]]/?}"
   if [ "${JS[FILES_TOTAL]:-0}" -gt 0 ]; then
      printf '%-22s %s / %s\n' $"Files:" "${JS[FILES_DONE]:-0}" "${JS[FILES_TOTAL]}"
   else
      printf '%-22s %s\n' $"Files:" "${JS[FILES_DONE]:-0}"
   fi
   if [ "$total" -gt 0 ]; then
      pct=$((done_ * 100 / total))
      [ "$pct" -gt 100 ] && pct=100
      bm_job_bar "$pct"
      if [ "${JS[TOTAL_ESTIMATE]:-0}" = 1 ]; then printf '≈ %s\n' "$REPLY"; else printf '%s\n' "$REPLY"; fi
   fi
   bm_human_size "$done_"; local c="$REPLY"
   bm_human_size "$total"
   if [ "$total" -gt 0 ]; then printf '%-22s %s / %s\n' $"Copied:" "$c" "$REPLY"
   else printf '%-22s %s\n' $"Copied:" "$c"
   fi
   bm_human_size "${JS[RATE_NOW]:-0}"; local rn="$REPLY"
   bm_human_size "${JS[RATE_AVG]:-0}"
   printf '%-22s %s/s (%s %s/s)\n' $"Speed:" "$rn" $"average" "$REPLY"
   bm_fmt_time "${JS[ELAPSED]:-0}"; printf '%-22s %s\n' $"Elapsed:" "$REPLY"
   if [ -n "${JS[ETA]:-}" ]; then bm_fmt_time "${JS[ETA]}"; printf '%-22s %s\n' $"Remaining:" "$REPLY"; fi
   [ "${JS[STUCK_SECONDS]:-0}" -gt 5 ] && printf $"Waiting for the disk to answer, for %s seconds"'\n' "${JS[STUCK_SECONDS]}"
   [ -n "${JS[CURRENT]:-}" ] && printf '%-22s %s\n' $"Current file:" "${JS[CURRENT]//[[:cntrl:]]/?}"
   [ "${JS[DEFERRED]:-0}" -gt 0 ] && printf '%-22s %s\n' $"Set aside:" "${JS[DEFERRED]}"
   [ "${JS[FAILED]:-0}" -gt 0 ] && printf '%-22s %s\n' $"Failed:" "${JS[FAILED]}"
   bm_job_reason_text "${JS[REASON]:-}"
   [ -n "$REPLY" ] && printf '%s\n' "$REPLY"
   return 0
}

# bm_job_watch ID CANCEL_ON_INT: follow a job until it ends
bm_job_watch() {
   local id="$1" oncancel="${2:-0}" dir lines=0 out asked=0
   bm_job_dir "$id" || return 1
   dir="$REPLY"
   if [ "$oncancel" = 1 ]; then
      # shellcheck disable=SC2064
      trap "asked=1; printf 'cancel\n' > '$dir/control'" INT
   else
      trap 'trap - INT; return 130' INT
   fi
   while :; do
      bm_job_conf_load "$dir"
      bm_job_state_load "$dir"
      out="$(bm_job_status_text "$dir")"
      if [ -t 1 ]; then
         [ "$lines" -gt 0 ] && printf '\033[%dA\033[J' "$lines"
         printf '%s\n' "$out"
         lines="$(printf '%s\n' "$out" | wc -l)"
      else
         # Non-terminal output: a line now and then, not a redraw
         if [ "$((SECONDS % 30))" -eq 0 ]; then
            bm_job_state_label "${JS[STATE]}"; local st="$REPLY"
            bm_human_size "${JS[BYTES_NOW]:-0}"
            printf '%s: %s\n' "$st" "$REPLY"
         fi
      fi
      case "${JS[STATE]}" in
         pending | analyzing | running | verifying | stopping) sleep 1 ;;
         *) break ;;
      esac
   done
   trap - INT
   [ -t 1 ] || printf '%s\n' "$out"
   [ "$asked" = 1 ] && printf '%s\n' $"Cancelled. Files already copied stay at the destination, and the copy can be resumed."
   bm_job_exit
}

# ---------------------------------------------------------------------------
# Reports

bm_job_report_text() {
   local dir="$1" f n
   bm_job_conf_load "$dir"
   bm_job_state_load "$dir"
   bm_doc_new
   bm_job_state_label "${JS[STATE]}" "${JC[KIND]:-copy}"
   bm_doc_h "$REPLY"
   bm_job_reason_text "${JS[REASON]:-}"
   [ -n "$REPLY" ] && bm_doc_p "$REPLY"
   bm_doc_kv $"Source" "${JC[SOURCE]}"
   if [ "${JC[KIND]:-copy}" = scan ] || [ "${JC[KIND]:-copy}" = carve ]; then
      bm_rec_report_text "$dir"
      return 0
   fi
   bm_doc_kv $"Destination" "${JC[DEST]}"
   bm_doc_kv $"Files copied" "${JS[FILES_DONE]:-0}"
   bm_human_size "${JS[BYTES_DONE]:-0}"; bm_doc_kv $"Data copied" "$REPLY"
   bm_fmt_time "${JS[ELAPSED]:-0}"; bm_doc_kv $"Elapsed" "$REPLY"
   case "${JS[VERIFY_RESULT]:-}" in
      ok) bm_doc_kv $"Check" $"source and destination match" ;;
      differences) printf -v REPLY $"%s files differ" "${JS[DIFFER]:-?}"; bm_doc_kv $"Check" "$REPLY" ;;
      failed) bm_doc_kv $"Check" $"did not finish" ;;
      *) bm_doc_kv $"Check" $"rsync confirmed each file as it was copied; no second comparison was made" ;;
   esac
   [ "${JS[CONFLICTS]:-0}" -gt 0 ] && bm_doc_kv $"Already at the destination, with different content" "${JS[CONFLICTS]}"
   bm_ui_show info ""
   n="${JS[DEFERRED]:-0}"
   if [ "$n" -gt 0 ]; then
      printf '\n%s\n' $"Set aside because they did not advance (damaged area of the disk):"
      head -n 50 -- "$dir/deferred.txt" | bm_printable_lines
      [ "$n" -gt 50 ] && printf '  … %s\n' "$dir/deferred.txt"
      printf $"To try them again, which puts more strain on the disk: bigmount --drive resume %s --retry-deferred"'\n' "${dir##*/}"
   fi
   n="${JS[FAILED]:-0}"
   if [ "$n" -gt 0 ] && [ -s "$dir/failed.txt" ]; then
      printf '\n%s\n' $"Not copied:"
      head -n 50 -- "$dir/failed.txt" | bm_printable_lines
      [ "$n" -gt 50 ] && printf '  … %s\n' "$dir/failed.txt"
   fi
   if [ "${JS[DIFFER]:-0}" -gt 0 ] && [ -s "$dir/differences.txt" ]; then
      printf '\n%s\n' $"Different at the destination:"
      head -n 50 -- "$dir/differences.txt" | bm_printable_lines
   fi
   printf '\n%s %s\n' $"Log:" "$dir/events.log"
}

bm_job_report_write() {
   local dir="$1"
   bm_job_report_text "$dir" > "$dir/report.tmp" 2>/dev/null
   mv -f -- "$dir/report.tmp" "$dir/report.txt"
   { bm_job_json_of "$dir"; printf '\n'; } > "$dir/report.tmp" 2>/dev/null
   mv -f -- "$dir/report.tmp" "$dir/report.json"
}

# The names of the volumes. lsblk -r writes a space as \x20, and a backslash too,
# so %b can only turn them back into what the name is
bm_anon_labels() {
   local c l
   for c in LABEL PARTLABEL; do
      while IFS= read -r l; do
         [ -n "$l" ] && printf '%b\n' "$l"
      done < <(timeout 10 lsblk -nro "$c" 2>/dev/null)
   done
}

# Personal details out of a report: for a bug report or a public forum
bm_anon_filter() {
   local home="${HOME:-/home/none}" user="${USER:-$(id -un)}" serial=$"Serial number" label=$"Label" line l
   local -a names=()
   # A volume name is also in mount points and titles. As data, never as a
   # pattern: a label can hold anything. One or two letters would hit ordinary words
   while IFS= read -r l; do
      [ "${#l}" -ge 3 ] && names+=("$l")
   done < <(bm_anon_labels)
   while IFS= read -r line || [ -n "$line" ]; do
      for l in "${names[@]}"; do line="${line//"$l"/(hidden)}"; done
      printf '%s\n' "$line"
   done | sed -E -e "s|$home|~|g" -e "s|/run/media/$user/[^/ ()\"]+|/run/media/USER/(hidden)|g" -e "s|/run/media/$user|/run/media/USER|g" \
      -e "s/\"(serial|label|name)\":\"[^\"]*\"/\"\\1\":\"(hidden)\"/g" -e 's/"([a-z_]*uuid)":"[^"]*"/"\1":"(hidden)"/g' \
      -e "s/^(Serial number|Label|UUID|$serial|$label): .*/\\1: (hidden)/" -e 's/“[^”]*”/“(hidden)”/g'
}

bm_job_cmd_report() {
   local json=0 anon=0 target="" output="" replace=0 a tmp rc
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --json) json=1 ;;
         --anonymize) anon=1 ;;
         --output) output="${2:-}"; shift ;;
         --replace) replace=1 ;;
         -*) bm_drive_badarg "$1"; return 2 ;;
         *) target="$1" ;;
      esac
      shift
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   if [ -n "$output" ]; then
      bm_drive_abs "$output"; output="$REPLY"
      if [ "$replace" = 0 ] && { [ -e "$output" ] || [ -L "$output" ]; }; then
         printf $"'%s' already exists. Nothing was written."'\n' "$output" >&2
         return 20
      fi
   fi
   _bm_report_body() {
      if bm_job_dir "$target"; then
         local dir="$REPLY"
         if [ "$json" = 1 ]; then bm_job_json_of "$dir"; printf '\n'; else bm_job_report_text "$dir"; fi
      else
         bm_drive_disk "$target" || return $?
         if [ "$json" = 1 ]; then
            bm_dg_json "$DD_DISK"
         else
            bm_dg_show "$target" "$DD_DISK"
            bm_drive_inspect_text "$DD_DISK"
            if [ "${#DH_LINES[@]}" -gt 0 ]; then
               printf '\n%s\n' $"Kernel messages:"
               printf '  %s\n' "${DH_LINES[@]:$((${#DH_LINES[@]} > 15 ? ${#DH_LINES[@]} - 15 : 0))}"
            fi
         fi
      fi
   }
   if [ -n "$output" ]; then
      # Written beside it and renamed: a failed report never replaces a good one
      [ ! -d "$output" ] || { printf $"'%s' is a folder. Nothing was written."'\n' "$output" >&2; return 20; }
      tmp="$output.$$.part"
      ( set -o noclobber; : > "$tmp" ) 2>/dev/null || return 20
      if [ "$anon" = 1 ]; then _bm_report_body | bm_anon_filter > "$tmp"; rc="${PIPESTATUS[0]}"; else _bm_report_body > "$tmp"; rc=$?; fi
      if [ "$rc" -ne 0 ] || ! mv -fT -- "$tmp" "$output"; then
         rm -f -- "$tmp"
         return "$((rc ? rc : 20))"
      fi
      printf $"Report written to %s"'\n' "$output"
   elif [ "$anon" = 1 ]; then
      _bm_report_body | bm_anon_filter
   else
      _bm_report_body
   fi
}

# ---------------------------------------------------------------------------
# Commands

bm_cp_destinations() {
   local source="" device="" json=0 need=0 a
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --json) json=1 ;;
         --source) source="${2:-}"; shift ;;
         --device) device="${2:-}"; shift ;;
         --need) need="${2:-0}"; shift ;;
         *) bm_drive_badarg "$1"; return 2 ;;
      esac
      shift
   done
   bm_dv_scan || return 1
   local src_dev=""
   if [ -n "$source" ]; then
      bm_drive_abs "$source"
      bm_cp_fs "$REPLY" && src_dev="$FI_SOURCE"
   fi
   # A source that is not mounted has no folder: named by its device
   if [ -n "$device" ]; then
      bm_resolve "$device" && src_dev="$R_DEV"
   fi
   local rows="" first=1 d p level name
   _bm_dest_row() {
      local path="$1" dev="$2" indep=1 avail why="" ok=1 rec
      bm_cp_avail "$path"; avail="$REPLY"
      [[ $avail =~ ^[0-9]+$ ]] || return 0
      if [ -n "$src_dev" ]; then
         [ "$dev" = "$src_dev" ] && return 0
         bm_cp_disks_share "$src_dev" "$dev" && indep=0
      fi
      bm_dv_disks_of "$dev"
      bm_ds_level "${DV_DISKS[0]}"; level="$DS_LEVEL"
      if [ "$level" = critical ]; then why=risky; ok=0
      elif [ "$indep" = 0 ]; then why=same-disk; ok=0
      elif [ "$need" -gt 0 ] && [ "$avail" -lt "$need" ]; then why=no-space; ok=0
      fi
      if [ "$json" = 1 ]; then
         [ "$first" = 1 ] && first=0 || rows+=","
         rows+="{$(bm_jo_inner path "$path" device "$dev" level "$level" why "$why" name "$3" fstype "${DV[$dev|FSTYPE]:-}"),$(bm_jn avail "$avail"),$(bm_jb independent "$indep" recommended "$ok")}"
      else
         bm_human_size "$avail"; rec="$REPLY"
         if [ "$ok" = 1 ]; then printf '* %s  (%s %s)\n' "${path//[[:cntrl:]]/?}" "$rec" $"free"
         else
            case "$why" in
               risky) a=$"drive with critical alerts" ;;
               same-disk) a=$"same physical disk as the source" ;;
               *) a=$"not enough space" ;;
            esac
            printf '  %s  (%s %s; %s)\n' "${path//[[:cntrl:]]/?}" "$rec" $"free" "$a"
         fi
      fi
   }
   for d in "${DV_ORDER[@]}"; do
      bm_dv_state "$d"
      [ "$REPLY" = mounted-rw ] || continue
      p="$DV_MP"
      [ -w "$p" ] || continue
      name="${DV[$d|LABEL]:-${d##*/}}"
      _bm_dest_row "$p" "$d" "$name"
   done
   # The home folder is always an option, unless it is on the source
   if [ -d "$HOME" ] && bm_cp_fs "$HOME" && [[ $FI_SOURCE == /dev/* ]]; then
      _bm_dest_row "$HOME" "$FI_SOURCE" $"Home folder"
   fi
   if [ "$json" = 1 ]; then printf '{"destinations":[%s]}\n' "$rows"; fi
   return 0
}

# bigmount --drive copy
bm_cp_cmd() {
   local json=0 dry=0 nowait=0 a results_of=""
   CP_SOURCE="" CP_DEST="" CP_ITEMS=() CP_ALLOW_SAME=0 CP_ALLOW_RW=0 CP_ALLOW_RISKY=0 CP_ALLOW_SAMEFS=0
   local conflict=skip verify=basic stall=90 bw="" scan=auto
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --source) CP_SOURCE="${2:-}"; shift ;;
         --destination) CP_DEST="${2:-}"; shift ;;
         --item) CP_ITEMS+=("${2:-}"); shift ;;
         --items-from)
            bm_drive_abs "${2:-}"
            [ -n "${2:-}" ] && [ -r "$REPLY" ] || { bm_drive_badarg "--items-from ${2:-}"; return 2; }
            mapfile -d '' -t -O "${#CP_ITEMS[@]}" CP_ITEMS < "$REPLY"
            shift
            ;;
         --results-of) results_of="${2:-}"; shift ;;
         --on-conflict) conflict="${2:-}"; shift ;;
         --verify) verify="${2:-}"; shift ;;
         --stall-seconds) stall="${2:-}"; shift ;;
         --bwlimit) bw="${2:-}"; shift ;;
         --scan) scan="${2:-}"; shift ;;
         --allow-same-disk) CP_ALLOW_SAME=1 ;;
         --allow-rw-source) CP_ALLOW_RW=1 ;;
         --allow-risky-destination) CP_ALLOW_RISKY=1 ;;
         --dry-run) dry=1 ;;
         --no-wait) nowait=1 ;;
         --json) json=1 ;;
         *) bm_drive_badarg "$1"; return 2 ;;
      esac
      shift
   done
   case "$conflict" in skip | backup | overwrite) ;; *) bm_drive_badarg "--on-conflict $conflict"; return 2 ;; esac
   case "$verify" in basic | metadata | full) ;; *) bm_drive_badarg "--verify $verify"; return 2 ;; esac
   case "$scan" in auto | yes | no) ;; *) bm_drive_badarg "--scan $scan"; return 2 ;; esac
   [[ $stall =~ ^[0-9]+$ ]] || { bm_drive_badarg "--stall-seconds $stall"; return 2; }
   [ -z "$bw" ] || [[ $bw =~ ^[0-9]+$ ]] || { bm_drive_badarg "--bwlimit $bw"; return 2; }
   # Found files are already safe on another disk. Keeping the good ones in a
   # folder beside them protects nothing and risks nothing, so that one case may
   # share a filesystem. Only the folder of a search of ours, never a path given.
   if [ -n "$results_of" ]; then
      bm_job_dir "$results_of" || { printf $"There is no job '%s'."'\n' "$results_of" >&2; return 1; }
      bm_job_conf_load "$REPLY"
      if [ "${JC[KIND]:-}" != carve ]; then
         printf '%s\n' $"Only the results of a search by content can be copied this way." >&2
         return 2
      fi
      CP_SOURCE="${JC[DEST]}"
      CP_ALLOW_SAMEFS=1
   fi
   if [ -z "$CP_SOURCE" ] || [ -z "$CP_DEST" ]; then
      printf '%s\n' $"Both --source and --destination are needed." >&2
      return 2
   fi
   bm_drive_abs "$CP_SOURCE"; CP_SOURCE="$REPLY"
   bm_drive_abs "$CP_DEST"; CP_DEST="$REPLY"
   CP_VERIFY="$verify"

   bm_cp_check
   local total=0 files=0 conflicts=0 estimate=0 avail="" i
   if [ -z "$CK_ERR" ]; then
      bm_cp_avail "${CP_D%/*}"
      [ -d "$CP_D" ] && bm_cp_avail "$CP_D"
      avail="$REPLY"
      # Scan: only with a drive that can take the extra reads
      if [ "$scan" = auto ]; then
         case "$CK_LEVEL" in critical | attention) scan=no ;; *) scan=yes ;; esac
      fi
      if [ "$scan" = yes ]; then
         local dir_tmp
         dir_tmp="$(mktemp -d)" || return 1
         touch "$dir_tmp/excludes.txt"
         JC=([ID]=preflight [DST_FS]="$CK_DST_FS" [SRC_FS]="$CK_SRC_FS" [ON_CONFLICT]="$conflict" [BWLIMIT]="" [RETRY]=0)
         [ "${#CP_ITEMS[@]}" -gt 0 ] && printf '%s\0' "${CP_ITEMS[@]}" > "$dir_tmp/items0"
         bm_cp_rsync_args "$dir_tmp" "$CP_D"
         bm_cp_selection "$dir_tmp"
         read -r files total conflicts < <(bm_cp_scan_cmd "$CP_S" "$CP_D")
         rm -rf -- "$dir_tmp"
         [ "${conflicts:-0}" -gt 0 ] && CK_WARN+=(conflicts)
      else
         CK_WARN+=(no-total)
         if [ "${#CP_ITEMS[@]}" -eq 0 ] && [ "$CP_S" = "$CK_SRC_MP" ]; then
            total="$(timeout 10 df -B1 --output=used -- "$CP_S" 2>/dev/null | tail -n 1)"
            total="${total//[[:space:]]/}"
            [[ $total =~ ^[0-9]+$ ]] || total=0
            [ "$total" -gt 0 ] && { estimate=1; CK_WARN=("${CK_WARN[@]/no-total/total-estimate}"); }
         fi
      fi
      if [[ $avail =~ ^[0-9]+$ ]] && [ "${total:-0}" -gt "$avail" ] && [ "$estimate" = 0 ]; then
         CK_ERR="no-space"
      fi
   fi

   local text="" rc=0 w warns="" first=1
   if [ -n "$CK_ERR" ]; then
      bm_cp_err_text "$CK_ERR"; text="$REPLY"
      bm_cp_err_rc "$CK_ERR"; rc="$REPLY"
   fi
   if [ "$dry" = 1 ] || [ -n "$CK_ERR" ]; then
      if [ "$json" = 1 ]; then
         for w in "${CK_WARN[@]}"; do
            bm_cp_warn_text "$w"
            [ "$first" = 1 ] && first=0 || warns+=","
            warns+="$(bm_jo key "$w" text "$REPLY")"
         done
         printf '{%s,%s,%s,"warnings":[%s]}\n' \
            "$(bm_jo_inner error "$CK_ERR" error_text "$text" source "${CP_S:-}" destination "${CP_D:-}" level "$CK_LEVEL" source_device "$CK_SRC_DEV" destination_device "$CK_DST_DEV")" \
            "$(bm_jn total_bytes "$total" total_files "$files" conflicts "${conflicts:-0}" avail "$avail" exit "$rc")" \
            "$(bm_jb ok "$([ -z "$CK_ERR" ] && echo 1)" total_estimate "$estimate" same_disk "$CK_SAME_DISK" scanned "$([ "$scan" = yes ] && echo 1)")" "$warns"
         return "$rc"
      fi
      if [ -n "$CK_ERR" ]; then
         printf '%s\n' "$text" >&2
         return "$rc"
      fi
      for w in "${CK_WARN[@]}"; do bm_cp_warn_text "$w"; printf '%s\n' "$REPLY"; done
      printf 'dry-run: %s → %s\n' "$CP_S" "$CP_D"
      if [ "$scan" = yes ]; then
         bm_human_size "$total"
         printf $"%s files, %s to copy; %s already exist with different content."'\n' "$files" "$REPLY" "${conflicts:-0}"
      fi
      return 0
   fi

   # The job. From here on it does not depend on this process.
   local id dir
   bm_job_id; id="$REPLY"
   dir="$BM_JOBS/$id"
   (umask 077; mkdir -p -- "$dir") || return 1
   touch "$dir/excludes.txt" "$dir/deferred.txt"
   [ "${#CP_ITEMS[@]}" -gt 0 ] && printf '%s\0' "${CP_ITEMS[@]}" > "$dir/items0"
   local name=""
   [[ $CK_SRC_DEV == /dev/* ]] && { bm_dv_scan; name="${DV[$CK_SRC_DEV|LABEL]:-${CK_SRC_DEV##*/}}"; }
   printf -v i '%(%s)T' -1
   JC=([ID]="$id" [KIND]=copy [SOURCE]="$CP_S" [DEST]="$CP_D" [NAME]="$name" [SRC_UUID]="$CK_SRC_UUID" [DST_UUID]="$CK_DST_UUID"
      [SRC_MP]="$CK_SRC_MP" [DST_MP]="$CK_DST_MP" [SRC_FS]="$CK_SRC_FS" [DST_FS]="$CK_DST_FS" [ON_CONFLICT]="$conflict" [VERIFY]="$verify"
      [STALL]="$stall" [BWLIMIT]="$bw" [SCAN]="$scan" [LEVEL]="$CK_LEVEL" [CREATED]="$i" [RETRY]=0)
   bm_job_conf_save "$dir" || { rm -rf -- "$dir"; return 1; }
   JS=([STATE]=pending [PID]="" [FILES_TOTAL]="${files:-0}" [BYTES_TOTAL]="${total:-0}" [TOTAL_ESTIMATE]="$estimate" [CONFLICTS]="${conflicts:-0}")
   [ "$scan" = yes ] && JC[SCAN]=no
   bm_job_conf_save "$dir"
   bm_job_state_save "$dir"
   bm_job_start "$id" || { printf '%s\n' $"The copy could not be started." >&2; return 1; }
   if [ "$json" = 1 ]; then
      bm_jo id "$id" dir "$dir"; printf '\n'
      return 0
   fi
   printf $"Copy started: %s"'\n' "$id"
   if [ "$nowait" = 1 ] || [ ! -t 1 ]; then
      printf $"To follow it: bigmount --drive status %s --watch"'\n' "$id"
      [ "$nowait" = 1 ] && return 0
   fi
   bm_job_watch "$id" 1
}

bm_job_list() {
   local json=0 d first=1 rows="" a
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         *) bm_drive_badarg "$a"; return 2 ;;
      esac
   done
   local dirs=()
   [ -d "$BM_JOBS" ] && mapfile -t dirs < <(printf '%s\n' "$BM_JOBS"/*/ | sort -r)
   for d in "${dirs[@]}"; do
      d="${d%/}"
      [ -f "$d/job.conf" ] || continue
      if [ "$json" = 1 ]; then
         [ "$first" = 1 ] && first=0 || rows+=","
         rows+="$(bm_job_json_of "$d")"
      else
         bm_job_conf_load "$d"
         bm_job_state_load "$d" || JS[STATE]=pending
         bm_job_state_label "${JS[STATE]}" "${JC[KIND]:-copy}"
         printf '%s  %s\n    %s → %s\n' "${d##*/}" "$REPLY" "${JC[SOURCE]//[[:cntrl:]]/?}" "${JC[DEST]//[[:cntrl:]]/?}"
         first=0
      fi
   done
   if [ "$json" = 1 ]; then printf '{"jobs":[%s]}\n' "$rows"
   elif [ "$first" = 1 ]; then printf '%s\n' $"No copies or images yet."
   fi
}

bm_job_cmd_status() {
   local id="" json=0 watch=0 a
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         --watch) watch=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) id="$a" ;;
      esac
   done
   bm_job_dir "$id" || { printf $"There is no job '%s'."'\n' "$id" >&2; return 1; }
   local dir="$REPLY"
   if [ "$watch" = 1 ]; then bm_job_watch "$id" 0; return; fi
   if [ "$json" = 1 ]; then bm_job_json_of "$dir"; printf '\n'; return 0; fi
   bm_job_conf_load "$dir"
   bm_job_state_load "$dir"
   bm_job_status_text "$dir"
}

# pause and cancel: the supervisor stops rsync with SIGTERM and records it
bm_job_cmd_stop() {
   local verb="$1" id="${2:-}" dir
   bm_job_dir "$id" || { printf $"There is no job '%s'."'\n' "$id" >&2; return 1; }
   dir="$REPLY"
   bm_job_conf_load "$dir"
   bm_job_state_load "$dir"
   # A search cannot continue where it stopped: PhotoRec keeps no state it can
   # resume from the command line, and a list is quicker to make again
   case "${JC[KIND]:-copy}:$verb" in
      scan:pause | carve:pause)
         printf '%s\n' $"A search cannot be paused, only cancelled. What was found stays." >&2
         return 2
         ;;
   esac
   case "${JS[STATE]}" in
      pending | analyzing | running | verifying | stopping)
         printf '%s\n' "$verb" > "$dir/control"
         [ "${JC[KIND]:-copy}" = image ] && : > "$dir/stop"
         bm_job_state_label stopping
         printf '%s\n' "$REPLY"
         ;;
      paused | interrupted | needs-attention)
         if [ "$verb" = cancel ]; then
            JS[STATE]=cancelled
            bm_job_state_save "$dir"
            bm_job_state_label cancelled
            printf '%s\n' "$REPLY"
         fi
         ;;
      *)
         printf '%s\n' $"It is not running." >&2
         return 1
         ;;
   esac
}

bm_job_cmd_resume() {
   local id="" retry=0 wait=1 json=0 a dir
   for a in "$@"; do
      case "$a" in
         --retry-deferred) retry=1 ;;
         --no-wait) wait=0 ;;
         --json) json=1; wait=0 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) id="$a" ;;
      esac
   done
   bm_job_dir "$id" || { printf $"There is no job '%s'."'\n' "$id" >&2; return 1; }
   dir="$REPLY"
   bm_job_conf_load "$dir"
   bm_job_state_load "$dir"
   case "${JS[STATE]}" in
      pending | analyzing | running | verifying | stopping)
         printf '%s\n' $"It is already running." >&2
         return 10
         ;;
      completed)
         [ "$retry" = 1 ] || { printf '%s\n' $"It is already complete." >&2; return 0; }
         ;;
   esac
   # What did not advance gets one more chance, with more patience
   if [ "$retry" = 1 ] && [ -s "$dir/deferred.txt" ]; then
      tr '\n' '\0' < "$dir/deferred.txt" > "$dir/retry0"
      : > "$dir/deferred.txt"
      : > "$dir/excludes.txt"
      JC[RETRY]=1
      bm_job_conf_save "$dir"
   fi
   rm -f -- "$dir/stop"
   case "${JC[KIND]:-copy}" in
      image | scan | carve) bm_rec_image_start "$id" || return 1 ;;
      *) bm_job_start "$id" || return 1 ;;
   esac
   if [ "$json" = 1 ]; then bm_jo id "$id" dir "$dir"; printf '\n'; return 0; fi
   printf $"Copy started: %s"'\n' "$id"
   [ "$wait" = 1 ] || return 0
   bm_job_watch "$id" 1
}

bm_job_cmd() {
   local cmd="$1"
   shift
   case "$cmd" in
      __run)
         local id="${1:-}"
         bm_job_dir "$id" || return 1
         bm_job_conf_load "$REPLY"
         case "${JC[KIND]:-copy}" in
            image) bm_rec_image_supervise "$id" ;;
            scan) bm_rec_scan_supervise "$id" ;;
            carve) bm_rec_carve_supervise "$id" ;;
            *) bm_job_supervise "$id" ;;
         esac
         ;;
      destinations) bm_cp_destinations "$@" ;;
      copy) bm_cp_cmd "$@" ;;
      jobs) bm_job_list "$@" ;;
      status) bm_job_cmd_status "$@" ;;
      pause | cancel) bm_job_cmd_stop "$cmd" "$@" ;;
      resume) bm_job_cmd_resume "$@" ;;
      report) bm_job_cmd_report "$@" ;;
   esac
}
