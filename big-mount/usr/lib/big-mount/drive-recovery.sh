# shellcheck shell=bash
# shellcheck disable=SC2034  # MP_* are read by callers
#
# big-mount drive manager: what to do when the files cannot be reached.
# Every tool is optional and only ever writes to another place:
#   image       GNU ddrescue: a copy of the whole device, with a map file, so
#               that it resumes and never reads a good area twice
#   partitions  TestDisk /list: partitions that can still be found (changes nothing)
#   carve       PhotoRec: files found by their content, on an image
# Repairing a filesystem or a partition table is not done here, on purpose.

# bm_rec_map_parse FILE: what a ddrescue map says. MP_RESCUED, MP_BAD (sectors
# given up on), MP_TODO (not tried yet or to be retried), all in bytes.
bm_rec_map_parse() {
   local pos size st seen=0 line
   MP_RESCUED=0 MP_BAD=0 MP_TODO=0
   [ -r "$1" ] || return 1
   while read -r pos size st _; do
      case "$pos" in "" | \#*) continue ;; esac
      # The first data line is "current_pos current_status current_pass"
      if [ "$seen" = 0 ]; then seen=1; continue; fi
      [[ $pos =~ ^0x[0-9A-Fa-f]+$ && $size =~ ^0x[0-9A-Fa-f]+$ ]] || continue
      case "$st" in
         +) MP_RESCUED=$((MP_RESCUED + size)) ;;
         -) MP_BAD=$((MP_BAD + size)) ;;
         *) MP_TODO=$((MP_TODO + size)) ;;
      esac
   done < "$1"
   [ "$seen" = 1 ]
}

bm_rec_image_start() {
   local id="$1" dir
   bm_job_dir "$id" || return 1
   dir="$REPLY"
   bm_self
   setsid -f "$REPLY" --drive __run "$id" </dev/null >>"$dir/supervisor.log" 2>&1 || return 1
   return 0
}

# The supervisor of an image: runs the helper, publishes what the map says
bm_rec_image_supervise() {
   local id="$1" dir pid t0 now rc ctl
   bm_job_dir "$id" || return 1
   dir="$REPLY"
   exec 7>"$dir/lock"
   flock -n 7 || return 10
   bm_job_conf_load "$dir"
   : > "$dir/control"
   rm -f -- "$dir/stop"
   JS=([STATE]=running [PID]="$$" [BYTES_TOTAL]="${JC[SIZE]}" [FILES_DONE]=0 [FILES_TOTAL]=0 [TOTAL_ESTIMATE]=0)
   bm_proc_state "$$"; JS[PID_START]="$PROC_START"
   printf -v t0 '%(%s)T' -1
   bm_job_state_save "$dir"
   trap ': > "$dir/stop"; printf "cancel\n" > "$dir/control"' TERM
   # The device name may have changed: the disk is known by its serial or UUID
   bm_rec_image_device
   local dev="$REPLY"
   if [ -z "$dev" ]; then
      JS[STATE]=needs-attention JS[REASON]=source-gone
      bm_job_state_save "$dir"; bm_job_report_write "$dir"
      return 0
   fi
   bm_helper image "$dev" "${JC[DEST]}" "${JC[MAP]}" "${JC[RETRIES]}" "$dir/stop" >> "$dir/ddrescue.out" 2>&1 &
   pid=$!
   while kill -0 "$pid" 2>/dev/null; do
      sleep 2
      printf -v now '%(%s)T' -1
      JS[ELAPSED]=$((now - t0))
      if bm_rec_map_parse "${JC[MAP]}"; then
         JS[RATE_NOW]=$(((MP_RESCUED - ${JS[BYTES_NOW]:-0}) / 2))
         [ "${JS[RATE_NOW]}" -lt 0 ] && JS[RATE_NOW]=0
         JS[BYTES_NOW]="$MP_RESCUED" JS[BAD_BYTES]="$MP_BAD" JS[BYTES_DONE]="$MP_RESCUED"
         [ "${JS[ELAPSED]}" -gt 0 ] && JS[RATE_AVG]=$((MP_RESCUED / JS[ELAPSED]))
         JS[ETA]=""
         [ "${JS[RATE_NOW]}" -gt 0 ] && JS[ETA]=$((MP_TODO / JS[RATE_NOW]))
      fi
      ctl=""
      { read -r ctl < "$dir/control"; } 2>/dev/null
      if [ "$ctl" = cancel ] || [ "$ctl" = pause ]; then
         JS[STATE]=stopping
         : > "$dir/stop"
      fi
      bm_job_state_save "$dir"
   done
   wait "$pid"; rc=$?
   ctl=""
   { read -r ctl < "$dir/control"; } 2>/dev/null
   bm_rec_map_parse "${JC[MAP]}" && JS[BYTES_NOW]="$MP_RESCUED" JS[BYTES_DONE]="$MP_RESCUED" JS[BAD_BYTES]="$MP_BAD"
   printf -v "JS[FINISHED]" '%(%s)T' -1
   case "$rc" in
      126 | 127) JS[STATE]=failed JS[REASON]=not-authorized ;;
      25) JS[STATE]=failed JS[REASON]=no-ddrescue ;;
      *)
         if [ "$ctl" = cancel ]; then JS[STATE]=cancelled
         elif [ "$ctl" = pause ]; then JS[STATE]=paused
         elif [ "$rc" -ne 0 ]; then JS[STATE]=failed JS[REASON]=rsync-error
         elif [ "${MP_BAD:-0}" -gt 0 ] || [ "${MP_TODO:-0}" -gt 0 ]; then JS[STATE]=needs-attention JS[REASON]=image-incomplete
         else JS[STATE]=completed
         fi
         ;;
   esac
   bm_job_state_save "$dir"
   bm_job_report_write "$dir"
}

# The device of an image job now. Matched by serial, then by the name it had.
bm_rec_image_device() {
   local d
   REPLY=""
   bm_dv_scan
   if [ -n "${JC[SERIAL]:-}" ]; then
      for d in "${DV_ORDER[@]}"; do
         if [ "${DV[$d|SERIAL]:-}" = "${JC[SERIAL]}" ] && [ "${DV[$d|TYPE]}" = disk ]; then REPLY="$d"; return 0; fi
      done
   fi
   [ -b "${JC[DEVICE]}" ] && [ "${DV[${JC[DEVICE]}|SIZE]:-}" = "${JC[SIZE]}" ] && REPLY="${JC[DEVICE]}"
}

bm_rec_image_cmd() {
   local src="" img="" map="" retries=0 dry=0 nowait=0 json=0 id dir now
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --source) src="${2:-}"; shift ;;
         --image) img="${2:-}"; shift ;;
         --map) map="${2:-}"; shift ;;
         --retries) retries="${2:-}"; shift ;;
         --dry-run) dry=1 ;;
         --no-wait) nowait=1 ;;
         --json) json=1 ;;
         *) bm_drive_badarg "$1"; return 2 ;;
      esac
      shift
   done
   if [[ $src != /dev/* ]] || [ -z "$img" ]; then
      printf '%s\n' $"Both --source DEVICE and --image FILE are needed." >&2
      return 2
   fi
   [[ $retries =~ ^[0-5]$ ]] || { bm_drive_badarg "--retries $retries"; return 2; }
   command -v ddrescue >/dev/null || { printf '%s\n' $"GNU ddrescue is not installed (package ddrescue). It makes the disk image." >&2; return 25; }
   bm_resolve "$src" || { bm_resolve_fail "$src"; return 24; }
   src="$R_DEV"
   bm_dv_scan
   local size="${DV[$src|SIZE]:-0}"
   [ "$size" -gt 0 ] 2>/dev/null || { R_ERR=unavailable; bm_resolve_fail "$src"; return 24; }
   bm_drive_abs "$img"; img="$(readlink -m -- "$REPLY")"
   [ -n "$map" ] && { bm_drive_abs "$map"; map="$(readlink -m -- "$REPLY")"; }
   [ -n "$map" ] || map="$img.map"
   if [[ $img == *$'\n'* ]] || [[ $map == *$'\n'* ]]; then
      bm_cp_err_text bad-path; printf '%s\n' "$REPLY" >&2
      return 20
   fi
   mkdir -p -- "${img%/*}" || return 1
   # Never on the disk being read. The name of a partition is not enough
   bm_cp_fs "${img%/*}" || { bm_cp_err_text dest-missing; printf '%s\n' "$REPLY" >&2; return 20; }
   if [[ $FI_SOURCE == /dev/* ]] && bm_cp_disks_share "$src" "$FI_SOURCE"; then
      printf '%s\n' $"The image cannot be stored on the disk being read." >&2
      return 20
   fi
   bm_cp_avail "${img%/*}"
   local have=0
   [ -f "$img" ] && have="$(stat -c %s -- "$img")"
   if [[ $REPLY =~ ^[0-9]+$ ]] && [ $((REPLY + have)) -lt "$size" ]; then
      bm_human_size "$size"; local need="$REPLY"
      printf $"The image needs %s of free space at the destination."'\n' "$need" >&2
      return 21
   fi
   if [ "$dry" = 1 ]; then
      printf 'dry-run: pkexec bigmount-drive-helper image %q %q %q %s\n' "$src" "$img" "$map" "$retries"
      return 0
   fi
   bm_job_id; id="$REPLY"
   dir="$BM_JOBS/$id"
   (umask 077; mkdir -p -- "$dir") || return 1
   printf -v now '%(%s)T' -1
   local disk="$src"
   bm_dv_disks_of "$src" && disk="${DV_DISKS[0]}"
   JC=([ID]="$id" [KIND]=image [SOURCE]="$src" [DEVICE]="$src" [DEST]="$img" [MAP]="$map" [RETRIES]="$retries"
      [SIZE]="$size" [SERIAL]="${DV[$disk|SERIAL]:-}" [NAME]="${DV[$src|LABEL]:-${src##*/}}" [CREATED]="$now" [VERIFY]=basic)
   bm_job_conf_save "$dir"
   JS=([STATE]=pending [PID]="" [BYTES_TOTAL]="$size")
   bm_job_state_save "$dir"
   bm_rec_image_start "$id" || return 1
   if [ "$json" = 1 ]; then bm_jo id "$id" dir "$dir"; printf '\n'; return 0; fi
   printf $"Copy started: %s"'\n' "$id"
   if [ "$nowait" = 1 ]; then
      printf $"To follow it: bigmount --drive status %s --watch"'\n' "$id"
      return 0
   fi
   bm_job_watch "$id" 1
}

# TestDisk lists what it finds and writes nothing with /list. A device needs
# the administrator; an image file belongs to the user.
bm_rec_partitions() {
   local target="" a out rc
   for a in "$@"; do
      case "$a" in
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   command -v testdisk >/dev/null || { printf '%s\n' $"TestDisk is not installed (package testdisk)." >&2; return 25; }
   bm_drive_abs "$target"; target="$REPLY"
   if [ -f "$target" ]; then
      testdisk /nolog /list "$target"
      return
   fi
   bm_resolve "$target" || { bm_resolve_fail "$target"; return 24; }
   bm_helper partitions "$R_DEV"; rc=$?
   case "$rc" in
      126 | 127) printf '%s\n' $"Permission was not granted." >&2; return 5 ;;
   esac
   return "$rc"
}

# PhotoRec on an image, or on a device the user can already read (a loop
# device of theirs). A physical disk is imaged first: carving reads every
# sector, which is the last thing a failing disk should go through twice.
bm_rec_carve() {
   local src="" dest="" json=0
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --source) src="${2:-}"; shift ;;
         --destination) dest="${2:-}"; shift ;;
         --json) json=1 ;;
         *) bm_drive_badarg "$1"; return 2 ;;
      esac
      shift
   done
   if [ -z "$src" ] || [ -z "$dest" ]; then
      printf '%s\n' $"Both --source and --destination are needed." >&2
      return 2
   fi
   command -v photorec >/dev/null || { printf '%s\n' $"PhotoRec is not installed (package testdisk)." >&2; return 25; }
   bm_drive_abs "$src"; src="$(readlink -m -- "$REPLY")"
   bm_drive_abs "$dest"; dest="$(readlink -m -- "$REPLY")"
   if [ ! -r "$src" ]; then
      printf '%s\n' $"This device cannot be read by your user. Make a disk image first (bigmount --drive image), and search in the image: it also spares the disk." >&2
      return 20
   fi
   # Results never go to where they are being searched for
   case "$dest/" in "$src"/*) bm_cp_err_text dest-inside-source; printf '%s\n' "$REPLY" >&2; return 20 ;; esac
   mkdir -p -- "$dest" || return 1
   local before=0 rc n
   before="$(find "$dest" -type f 2>/dev/null | wc -l)"
   if [ -t 0 ] && [ -t 1 ] && [ "$json" = 0 ]; then
      photorec /d "$dest/recup_dir" "$src"; rc=$?
   else
      # No terminal: the whole device, every file type
      LC_ALL=C photorec /nolog /d "$dest/recup_dir" /cmd "$src" partition_none,fileopt,everything,enable,search > "$dest/photorec.out" 2>&1; rc=$?
   fi
   n="$(find "$dest" -type f ! -name photorec.out 2>/dev/null | wc -l)"
   n=$((n - before))
   if [ "$json" = 1 ]; then
      printf '{%s,%s,%s}\n' "$(bm_jo_inner destination "$dest")" "$(bm_jn recovered "$n" exit "$rc")" "$(bm_jb ok "$([ "$rc" -eq 0 ] && echo 1)")"
   else
      printf $"%s files found by content in %s. Their original names and folders could not be kept."'\n' "$n" "$dest"
   fi
   return "$rc"
}

bm_rec_cmd() {
   local cmd="$1"
   shift
   case "$cmd" in
      image) bm_rec_image_cmd "$@" ;;
      partitions) bm_rec_partitions "$@" ;;
      carve) bm_rec_carve "$@" ;;
   esac
}
