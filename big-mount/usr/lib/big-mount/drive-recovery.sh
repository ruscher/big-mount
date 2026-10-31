# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # MP_* are read by callers; JC, JS, PROC_START come from drive-copy.sh and lib.sh
#
# big-mount drive manager: what to do when the files cannot be reached.
# Every tool is optional and only ever writes to another place:
#   image       GNU ddrescue: a copy of the whole device, with a map file, so
#               that it resumes and never reads a good area twice
#   partitions  TestDisk: the partition table, and what its analysis finds (changes nothing)
#   carve       PhotoRec: files found by their content, on an image
#   scan        a list of the files that exist in a mounted folder, by type
# Repairing a filesystem or a partition table is not done here, on purpose.
#
# Three words that must not be mixed up, in the JSON (result_kind) and on screen:
# what a list found EXISTS on the volume; what a search found are CANDIDATES,
# rebuilt from content, without names; only what was copied is RECOVERED.

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

# bm_rec_check_dest FOLDER SOURCE_DEVICE: can results be written there? Sets
# REC_ERR. Same words as the copy: the name of a partition is not enough.
bm_rec_check_dest() {
   local d="$1" src="$2" probe rc
   REC_ERR=""
   if [[ $d == *$'\n'* ]]; then REC_ERR=bad-path; return 1; fi
   probe="$d"
   while [ ! -e "$probe" ] && [ "$probe" != / ]; do probe="${probe%/*}"; probe="${probe:-/}"; done
   bm_cp_fs "$probe"; rc=$?
   [ "$rc" -eq 124 ] && { REC_ERR="dest-stuck"; return 1; }
   [ "$rc" -eq 0 ] || { REC_ERR="dest-missing"; return 1; }
   [ "$FI_RO" = 1 ] && { REC_ERR="dest-ro"; return 1; }
   timeout 10 test -w "$probe" || {
      [ "$?" -eq 124 ] && REC_ERR="dest-stuck" || REC_ERR="dest-denied"
      return 1
   }
   if [[ $src == /dev/* && $FI_SOURCE == /dev/* ]] && bm_cp_disks_share "$src" "$FI_SOURCE"; then
      REC_ERR=same-disk
      return 1
   fi
   return 0
}

# bm_rec_refusal JSON KEY: a refusal, for a person or as data. Returns its code.
bm_rec_refusal() {
   local json="$1" key="$2" text rc
   bm_cp_err_text "$key"; text="$REPLY"
   bm_cp_err_rc "$key"; rc="$REPLY"
   if [ "$json" = 1 ]; then
      printf '{%s,%s,%s,"warnings":[]}\n' "$(bm_jo_inner error "$key" error_text "$text")" "$(bm_jb ok 0)" "$(bm_jn exit "$rc")"
   else
      printf '%s\n' "$text" >&2
   fi
   return "$rc"
}

# bm_rec_preflight KEY...: what a dry run answers (REC_* set by the caller)
bm_rec_warnings_json() {
   local w first=1 out=""
   for w in "$@"; do
      bm_rec_warn_text "$w"
      [ "$first" = 1 ] && first=0 || out+=","
      out+="$(bm_jo key "$w" text "$REPLY")"
   done
   printf '%s' "$out"
}

bm_rec_warn_text() {
   case "$1" in
      image-resume) REPLY=$"This image already exists. It continues where it stopped, reading only what is still missing." ;;
      carve-names) REPLY=$"Files found by content lose their original names and folders." ;;
      source-risk) REPLY=$"This drive reported problems. Reading all of it can make it worse: the disk image is read only once, and only with your consent." ;;
      scan-reads) REPLY=$"Making the list goes through all the folders. On a drive with problems this is extra wear." ;;
      trim) REPLY=$"This SSD erases deleted blocks by itself (TRIM). Files deleted some time ago may be gone for good, however deep the search." ;;
      *) REPLY="$1" ;;
   esac
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
   local src="" img="" map="" retries=0 dry=0 nowait=0 json=0 id dir now expect="" then_carve="" cats=""
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --source) src="${2:-}"; shift ;;
         --image) img="${2:-}"; shift ;;
         --map) map="${2:-}"; shift ;;
         --retries) retries="${2:-}"; shift ;;
         --expect-diskseq) expect="${2:-}"; shift ;;
         --then-carve) then_carve="${2:-}"; shift ;;
         --categories) cats="${2:-}"; shift ;;
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
   [ -z "$cats" ] || bm_rec_categories_valid "$cats" || { bm_drive_badarg "--categories $cats"; return 2; }
   if ! command -v ddrescue >/dev/null; then
      bm_rec_refusal "$json" no-ddrescue
      return
   fi
   bm_resolve "$src" || { bm_resolve_fail "$src"; return 24; }
   src="$R_DEV"
   bm_dv_scan
   local size="${DV[$src|SIZE]:-0}"
   [ "$size" -gt 0 ] 2>/dev/null || { R_ERR=unavailable; bm_resolve_fail "$src"; return 24; }
   local disk="$src"
   bm_dv_disks_of "$src" && disk="${DV_DISKS[0]}"
   # The window names the disk it showed: another one under that name is refused
   if [ -n "$expect" ]; then
      bm_diskseq "$disk"
      [ "$REPLY" = "$expect" ] || { bm_rec_refusal "$json" source-replaced; return; }
   fi
   bm_drive_abs "$img"; img="$(readlink -m -- "$REPLY")"
   [ -n "$map" ] && { bm_drive_abs "$map"; map="$(readlink -m -- "$REPLY")"; }
   [ -n "$map" ] || map="$img.map"
   if [[ $map == *$'\n'* ]]; then bm_rec_refusal "$json" bad-path; return; fi
   # Never on the disk being read. The name of a partition is not enough
   if ! bm_rec_check_dest "$img" "$src"; then
      [ "$REC_ERR" = same-disk ] && REC_ERR=image-same-disk
      bm_rec_refusal "$json" "$REC_ERR"
      return
   fi
   # A map says what was already read of ONE disk. Continuing it from another
   # one would mix two disks in one image, silently
   bm_rec_source_id "$src" "$disk"; local source_id="$REPLY"
   if [ -f "$img.source" ] && [ "$(cat -- "$img.source")" != "$source_id" ]; then
      bm_rec_refusal "$json" image-other-disk
      return
   fi
   bm_cp_avail "${img%/*}"
   [ -d "${img%/*}" ] || { bm_rec_probe "$img"; bm_cp_avail "$REPLY"; }
   local have=0 avail="$REPLY" warns=()
   [ -f "$img" ] && { have="$(stat -c %s -- "$img")"; warns+=(image-resume); }
   if [[ $avail =~ ^[0-9]+$ ]] && [ $((avail + have)) -lt "$size" ]; then
      if [ "$json" = 1 ]; then
         bm_rec_refusal 1 no-space >/dev/null
         bm_cp_err_text no-space
         printf '{%s,%s,%s,"warnings":[]}\n' "$(bm_jo_inner error no-space error_text "$REPLY")" "$(bm_jb ok 0)" "$(bm_jn exit 21 avail "$avail" total_bytes "$size")"
         return 21
      fi
      bm_human_size "$size"; local need="$REPLY"
      printf $"The image needs %s of free space at the destination."'\n' "$need" >&2
      return 21
   fi
   bm_ds_level "$disk"
   case "$DS_LEVEL" in critical | attention) warns+=(source-risk) ;; esac
   if [ "$dry" = 1 ]; then
      if [ "$json" = 1 ]; then
         printf '{%s,%s,%s,"warnings":[%s]}\n' "$(bm_jo_inner error "" error_text "" source "$src" destination "$img" level "$DS_LEVEL")" \
            "$(bm_jb ok 1)" "$(bm_jn exit 0 avail "$avail" total_bytes "$size" total_files 0)" "$(bm_rec_warnings_json "${warns[@]}")"
         return 0
      fi
      printf 'dry-run: pkexec bigmount-drive-helper image %q %q %q %s\n' "$src" "$img" "$map" "$retries"
      return 0
   fi
   mkdir -p -- "${img%/*}" || return 1
   printf '%s\n' "$source_id" > "$img.source"
   bm_job_id; id="$REPLY"
   dir="$BM_JOBS/$id"
   (umask 077; mkdir -p -- "$dir") || return 1
   printf -v now '%(%s)T' -1
   JC=([ID]="$id" [KIND]=image [SOURCE]="$src" [DEVICE]="$src" [DEST]="$img" [MAP]="$map" [RETRIES]="$retries"
      [SIZE]="$size" [SERIAL]="${DV[$disk|SERIAL]:-}" [NAME]="${DV[$src|LABEL]:-${src##*/}}" [CREATED]="$now" [VERIFY]=basic
      [THEN_CARVE]="$then_carve" [CATEGORIES]="$cats")
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

# What identifies a source of an image: the disk, or failing that its size
bm_rec_source_id() {
   if [ -n "${DV[$2|SERIAL]:-}" ]; then REPLY="serial:${DV[$2|SERIAL]}:${DV[$1|SIZE]:-0}"
   else REPLY="size:${1##*/}:${DV[$1|SIZE]:-0}"
   fi
}

# The nearest part of a path that exists (REPLY)
bm_rec_probe() {
   REPLY="$1"
   while [ ! -e "$REPLY" ] && [ "$REPLY" != / ]; do REPLY="${REPLY%/*}"; REPLY="${REPLY:-/}"; done
}

# ---------------------------------------------------------------------------
# Types of file. One table for the list and for the results.

BM_REC_CATEGORIES="photos videos documents audio archives"

bm_rec_categories_valid() {
   local c
   [ "$1" = all ] && return 0
   for c in ${1//,/ }; do
      [[ " $BM_REC_CATEGORIES " == *" $c "* ]] || return 1
   done
   [ -n "${1//,/}" ]
}

# PhotoRec does not know "photos": it knows families of signatures. Some are
# wider than the words: riff is AVI, WAV and WebP, zip is also DOCX and ODT, mov
# is also MP4 and M4A. What that means is told before the search starts.
bm_rec_families() {
   case "$1" in
      photos) REPLY="jpg png gif bmp tif orf" ;;
      videos) REPLY="mov mkv mpg riff asf flv" ;;
      audio) REPLY="mp3 flac ogg riff asf" ;;
      documents) REPLY="pdf doc zip txt" ;;
      archives) REPLY="zip rar 7z gz bz2 xz tar" ;;
      *) REPLY="" ;;
   esac
}

bm_rec_category_label() {
   case "$1" in
      photos) REPLY=$"Photos" ;;
      videos) REPLY=$"Videos" ;;
      documents) REPLY=$"Documents" ;;
      audio) REPLY=$"Audio" ;;
      archives) REPLY=$"Compressed files" ;;
      other) REPLY=$"Other files" ;;
      *) REPLY="$1" ;;
   esac
}

# What the search by content can and cannot tell apart, in plain words
bm_rec_category_note() {
   case "$1" in
      photos) REPLY=$"HEIC and WebP photos are found only when searching all types." ;;
      videos) REPLY=$"WAV audio can appear among the results: it has the same signature as AVI." ;;
      audio) REPLY=$"AVI and WMV videos can appear among the results, and M4A audio is found only when searching all types." ;;
      documents) REPLY=$"Word, Excel and LibreOffice files share a signature with ZIP files, so those appear too." ;;
      archives) REPLY=$"Word, Excel and LibreOffice files can appear among the results: they are ZIP files inside." ;;
      *) REPLY="" ;;
   esac
}

# Sorts NUL-separated "size<TAB>mtime<TAB>path" into the same with a category
# in front of the path, and keeps a count of each. Bytes, not characters: a name
# from an old disk may not be valid in this locale. The output is the index:
#    size<TAB>mtime<TAB>category<TAB>path<NUL>
# shellcheck disable=SC2016  # awk code
BM_REC_AWK='
BEGIN {
   RS = "\0"; ORS = "\0"
   n = split("jpg jpeg jpe png gif bmp tif tiff webp heic heif avif raw cr2 cr3 nef arw dng orf rw2 raf svg", a, " ")
   for (i = 1; i <= n; i++) cat[a[i]] = "photos"
   n = split("mp4 m4v mkv avi mov wmv flv webm mpg mpeg ts m2ts mts 3gp vob ogv", a, " ")
   for (i = 1; i <= n; i++) cat[a[i]] = "videos"
   n = split("mp3 flac ogg oga opus wav m4a aac wma aif aiff", a, " ")
   for (i = 1; i <= n; i++) cat[a[i]] = "audio"
   n = split("pdf doc docx xls xlsx ppt pptx odt ods odp rtf txt md csv epub tex", a, " ")
   for (i = 1; i <= n; i++) cat[a[i]] = "documents"
   n = split("zip rar 7z gz tgz bz2 tbz2 xz txz tar zst iso", a, " ")
   for (i = 1; i <= n; i++) cat[a[i]] = "archives"
   if (filter != "all") {
      n = split(filter, a, ",")
      for (i = 1; i <= n; i++) keep[a[i]] = 1
   }
}
function report(   c) {
   printf "scanned %d\nbytes %d\n", seen, bytes > progress
   for (c in count) printf "%s %d %d\n", c, count[c], size[c] > progress
   close(progress)
}
{
   t1 = index($0, "\t"); if (!t1) next
   s = substr($0, 1, t1 - 1); rest = substr($0, t1 + 1)
   t2 = index(rest, "\t"); if (!t2) next
   m = substr(rest, 1, t2 - 1); p = substr(rest, t2 + 1)
   sub(/\..*$/, "", m)
   if (dates == "no") m = 0
   seen++
   base = p; sub(/^.*\//, "", base)
   ext = ""
   if (match(base, /\.[^.]+$/)) ext = tolower(substr(base, RSTART + 1))
   c = (ext in cat) ? cat[ext] : "other"
   if (filter != "all" && !(c in keep)) {
      if (seen % 2000 == 0) report()
      next
   }
   count[c]++; size[c] += s; bytes += s
   printf "%s\t%s\t%s\t%s", s, m, c, p
   printf "%s", ORS
   if (seen % 2000 == 0) report()
}
END { report() }
'

# Reads what awk last reported: JS[SCANNED], JS[FILES_DONE], JS[BYTES_DONE]
bm_rec_progress_read() {
   local k n _b total=0
   [ -r "$1" ] || return 0
   while read -r k n _b; do
      case "$k" in
         scanned) JS[SCANNED]="$n" ;;
         bytes) JS[BYTES_DONE]="$n" ;;
         "") ;;
         *) total=$((total + n)) ;;
      esac
   done < "$1"
   JS[FILES_DONE]="$total"
}

# ---------------------------------------------------------------------------
# The list of what exists: a walk over the names. It reads folders, never files.

bm_rec_scan_supervise() {
   local id="$1" dir pid ctl rc tick=0 last=-1 still=0 end=finish now t0
   bm_job_dir "$id" || return 1
   dir="$REPLY"
   exec 7>"$dir/lock"
   flock -n 7 || return 10
   bm_job_conf_load "$dir"
   : > "$dir/control"
   JS=([STATE]=analyzing [PID]="$$" [FILES_DONE]=0 [BYTES_DONE]=0 [BYTES_NOW]=0 [SCANNED]=0 [BYTES_TOTAL]=0 [FILES_TOTAL]=0)
   bm_proc_state "$$"; JS[PID_START]="$PROC_START"
   printf -v t0 '%(%s)T' -1
   bm_job_state_save "$dir"
   trap 'printf "cancel\n" > "$dir/control"' TERM
   if ! bm_cp_is_mounted "${JC[SRC_MP]}"; then
      JS[STATE]=needs-attention JS[REASON]=source-gone
      bm_job_state_save "$dir"; bm_job_report_write "$dir"
      return 0
   fi
   rm -f -- "$dir/index" "$dir/index.part"
   : > "$dir/scan.progress"
   {
      ionice -c 2 -n 6 nice -n 5 find "${JC[SOURCE]}" -xdev -type f -printf '%s\t%T@\t%P\0' 2> "$dir/scan.err" |
         LC_ALL=C awk -v filter="${JC[CATEGORIES]:-all}" -v progress="$dir/scan.progress" -v dates=yes "$BM_REC_AWK" > "$dir/index.part"
      exit "${PIPESTATUS[0]}"
   } &
   pid=$!
   while kill -0 "$pid" 2>/dev/null; do
      sleep "$BM_TICK"
      tick=$((tick + 1))
      bm_rec_progress_read "$dir/scan.progress"
      printf -v now '%(%s)T' -1
      JS[ELAPSED]=$((now - t0))
      JS[BYTES_NOW]="${JS[BYTES_DONE]:-0}"
      if [ "${JS[SCANNED]:-0}" = "$last" ]; then still=$((still + BM_TICK)); else still=0; fi
      last="${JS[SCANNED]:-0}"
      JS[STUCK_SECONDS]="$still"
      ctl=""
      { read -r ctl < "$dir/control"; } 2>/dev/null
      if [ "$ctl" = cancel ]; then
         end=cancel
      elif [ $((tick % 5)) -eq 0 ] && ! bm_cp_is_mounted "${JC[SRC_MP]}"; then
         end=source-gone
      fi
      if [ "$end" != finish ]; then
         JS[STATE]=stopping
         bm_job_state_save "$dir"
         pkill -TERM -P "$pid" 2>/dev/null
         kill -TERM "$pid" 2>/dev/null
         break
      fi
      bm_job_state_save "$dir"
   done
   wait "$pid"; rc=$?
   bm_rec_progress_read "$dir/scan.progress"
   JS[BYTES_NOW]="${JS[BYTES_DONE]:-0}" JS[STUCK_SECONDS]=0
   # Whatever was listed until here is real and stays usable
   mv -f -- "$dir/index.part" "$dir/index"
   cp -f -- "$dir/scan.progress" "$dir/index.count"
   printf -v "JS[FINISHED]" '%(%s)T' -1
   JS[READ_FAILS]="$(wc -l < "$dir/scan.err")"
   case "$end" in
      cancel) JS[STATE]=cancelled ;;
      source-gone) JS[STATE]=needs-attention JS[REASON]=source-gone ;;
      *)
         if [ "$rc" -ne 0 ] || [ "${JS[READ_FAILS]:-0}" -gt 0 ]; then JS[STATE]=needs-attention JS[REASON]=read-errors
         else JS[STATE]=completed JS[REASON]=""
         fi
         ;;
   esac
   bm_job_state_save "$dir"
   bm_job_report_write "$dir"
}

bm_rec_scan_cmd() {
   local src="" cats=all json=0 dry=0 nowait=0 id dir now hint=""
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --source) src="${2:-}"; shift ;;
         --categories) cats="${2:-}"; shift ;;
         --copy-to) hint="${2:-}"; shift ;;
         --json) json=1 ;;
         --dry-run) dry=1 ;;
         --no-wait) nowait=1 ;;
         *) bm_drive_badarg "$1"; return 2 ;;
      esac
      shift
   done
   [ -n "$src" ] || { printf '%s\n' $"Both --source and --destination are needed." >&2; return 2; }
   bm_rec_categories_valid "$cats" || { bm_drive_badarg "--categories $cats"; return 2; }
   bm_drive_abs "$src"; src="$REPLY"
   src="$(timeout 10 readlink -e -- "$src")"
   if [ -z "$src" ] || ! timeout 10 test -d "$src"; then bm_rec_refusal "$json" source-missing; return; fi
   bm_cp_fs "$src" || { bm_rec_refusal "$json" source-missing; return; }
   local mp="$FI_TARGET" dev="$FI_SOURCE" level=unknown warns=()
   if [[ $dev == /dev/* ]] && bm_dv_scan && bm_dv_disks_of "$dev"; then
      bm_ds_level "${DV_DISKS[0]}"; level="$DS_LEVEL"
   fi
   case "$level" in critical | attention) warns+=(scan-reads) ;; esac
   if [ "$dry" = 1 ]; then
      if [ "$json" = 1 ]; then
         printf '{%s,%s,%s,"warnings":[%s]}\n' "$(bm_jo_inner error "" error_text "" source "$src" destination "" level "$level")" \
            "$(bm_jb ok 1)" "$(bm_jn exit 0)" "$(bm_rec_warnings_json "${warns[@]}")"
      else
         printf 'dry-run: find %q -xdev -type f\n' "$src"
      fi
      return 0
   fi
   bm_job_id; id="$REPLY"
   dir="$BM_JOBS/$id"
   (umask 077; mkdir -p -- "$dir") || return 1
   printf -v now '%(%s)T' -1
   JC=([ID]="$id" [KIND]=scan [SOURCE]="$src" [DEST]="" [SRC_MP]="$mp" [CATEGORIES]="$cats" [CREATED]="$now" [NAME]="${src##*/}" [LEVEL]="$level" [COPY_TO]="$hint")
   bm_job_conf_save "$dir"
   JS=([STATE]=pending [PID]="")
   bm_job_state_save "$dir"
   bm_rec_image_start "$id" || return 1
   if [ "$json" = 1 ]; then bm_jo id "$id" dir "$dir"; printf '\n'; return 0; fi
   printf $"Search started: %s"'\n' "$id"
   [ "$nowait" = 1 ] && return 0
   bm_job_watch "$id" 1
}

# ---------------------------------------------------------------------------
# TestDisk. It writes nothing with /list, and nothing with the analysis as we
# call it: "write" would be a separate word, and it is not in any command here.
# A device needs the administrator; an image file belongs to the user.

# The screen TestDisk draws, as lines: a move to another row is a line break
# shellcheck disable=SC2016  # awk code
BM_REC_SCREEN_AWK='
{
   line = $0; out = ""
   while (match(line, /\033\[[0-9;?]*[A-Za-z]|\033[()][A-Z0-9]|\033[=>]/)) {
      out = out substr(line, 1, RSTART - 1)
      seq = substr(line, RSTART, RLENGTH)
      line = substr(line, RSTART + RLENGTH)
      if (seq ~ /H$/) {
         r = seq; sub(/^\033\[/, "", r); sub(/;.*$/, "", r); sub(/H$/, "", r)
         if (r != row) { out = out "\n"; row = r } else out = out " "
      } else if (seq ~ /d$/) { out = out "\n"; row = "" }
      else if (seq ~ /[GC]$/) out = out " "
   }
   gsub(/\r/, "", line)
   print out line
}
'

# Lines such as "1 P Linux  0 32 33  4 52 48  65536 [LABEL]" (PT_*). The same
# partition is drawn many times by the analysis: once here.
bm_rec_parse_partitions() {
   local re='^[[:space:]]*([0-9]+[[:space:]]+[PLED*][[:space:]]+)?([A-Za-z][^[:cntrl:]]*[^[:space:]])[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)([[:space:]]+\[(.*)\])?[[:space:]]*$'
   local line key
   local -A seen=()
   PT_TYPE=() PT_START=() PT_SECTORS=() PT_LABEL=()
   while IFS= read -r line; do
      [[ $line =~ $re ]] || continue
      key="${BASH_REMATCH[3]}/${BASH_REMATCH[4]}/${BASH_REMATCH[5]}/${BASH_REMATCH[9]}"
      [ -n "${seen[$key]:-}" ] && continue
      seen[$key]=1
      PT_TYPE+=("${BASH_REMATCH[2]}")
      PT_START+=("${BASH_REMATCH[3]}/${BASH_REMATCH[4]}/${BASH_REMATCH[5]}")
      PT_SECTORS+=("${BASH_REMATCH[9]}")
      PT_LABEL+=("${BASH_REMATCH[11]:-}")
   done < <(LC_ALL=C awk "$BM_REC_SCREEN_AWK")
}

bm_rec_partitions() {
   local target="" a out="" rc json=0 search=0 table=i386
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         --search) search=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   if ! command -v testdisk >/dev/null; then
      [ "$json" = 1 ] && { bm_rec_refusal 1 no-testdisk; return; }
      printf '%s\n' $"TestDisk is not installed (package testdisk)." >&2
      return 25
   fi
   bm_drive_abs "$target"; target="$REPLY"
   if [ -f "$target" ]; then
      # An image of a GPT disk starts with its protective table
      if [ "$search" = 1 ]; then
         [ "$(blkid -p -o value -s PTTYPE -- "$target" 2>/dev/null)" = gpt ] && table=gpt
         local here; here="$(mktemp -d)" || return 1
         out="$(cd "$here" && TERM=xterm timeout 3600 testdisk /nolog /cmd "$target" "partition_$table,analyze" 2>&1)"; rc=$?
         rm -rf -- "$here"
      else
         out="$(testdisk /nolog /list "$target" 2>&1)"; rc=$?
      fi
   else
      bm_resolve "$target" || { bm_resolve_fail "$target"; return 24; }
      if [ "$search" = 1 ]; then
         bm_dv_scan
         local disk="$R_DEV"
         bm_dv_disks_of "$R_DEV" && disk="${DV_DISKS[0]}"
         [ "${DV[$disk|PTTYPE]:-}" = gpt ] && table=gpt
         out="$(bm_helper partitions "$R_DEV" search "$table" 2>&1)"; rc=$?
      else
         out="$(bm_helper partitions "$R_DEV" 2>&1)"; rc=$?
      fi
      case "$rc" in
         126 | 127)
            if [ "$json" = 1 ]; then bm_rec_refusal 1 not-authorized; return; fi
            printf '%s\n' $"Permission was not granted." >&2
            return 5
            ;;
      esac
   fi
   if [ "$json" != 1 ]; then
      printf '%s\n' "$out"
      return "$rc"
   fi
   bm_rec_parse_partitions <<< "$out"
   local i rows="" first=1
   for i in "${!PT_TYPE[@]}"; do
      [ "$first" = 1 ] && first=0 || rows+=","
      rows+="{$(bm_jo_inner type "${PT_TYPE[i]}" start "${PT_START[i]}" label "${PT_LABEL[i]}"),$(bm_jn sectors "${PT_SECTORS[i]}" size "$((PT_SECTORS[i] * 512))")}"
   done
   printf '{%s,%s,%s,"found":[%s]}\n' "$(bm_jo_inner target "$target" mode "$([ "$search" = 1 ] && echo search || echo list)")" \
      "$(bm_jb ok "$([ "$rc" -eq 0 ] && echo 1)")" "$(bm_jn exit "$rc")" "$rows"
   return "$rc"
}

# ---------------------------------------------------------------------------
# PhotoRec: a search by content, as a job. It reports the pass, the sector and
# how many files it found. A physical disk is imaged first, because carving
# reads every sector, the last thing a failing disk should go through twice.

# bm_rec_carve_commands LIST: the /cmd of PhotoRec (REPLY). In this order: all
# of it is parsed by PhotoRec, and an unknown name would make it refuse to run.
bm_rec_carve_commands() {
   local c f used=" " out=""
   if [ "$1" = all ] || [ -z "$1" ]; then
      # "dovecot" matches blocks of zeros: an empty area would give thousands of
      # empty candidates. grep: an older PhotoRec does not know the name
      if grep -qa dovecot "$(command -v photorec)"; then
         REPLY="partition_none,fileopt,everything,enable,dovecot,disable,wholespace,search"
      else
         REPLY="partition_none,fileopt,everything,enable,wholespace,search"
      fi
      return 0
   fi
   for c in ${1//,/ }; do
      bm_rec_families "$c"
      for f in $REPLY; do
         [[ $used == *" $f "* ]] && continue
         used+="$f "
         out+="$f,enable,"
      done
   done
   REPLY="partition_none,fileopt,everything,disable,${out}wholespace,search"
}

# Index of what is in the result folders. Dates are those of the recovery, so
# they are not offered as if they were the dates of the files.
bm_rec_carve_index() {
   local dir="$1" dest="$2"
   : > "$dir/index.count"
   find "$dest" -xdev -mindepth 2 -maxdepth 2 -path "$dest/recup_dir.*" -type f ! -name report.xml -printf '%s\t%T@\t%P\0' 2>/dev/null |
      LC_ALL=C awk -v filter=all -v progress="$dir/index.count" -v dates=no "$BM_REC_AWK" > "$dir/index.tmp"
   mv -f -- "$dir/index.tmp" "$dir/index"
   local k n b total=0 bytes=0
   while read -r k n b; do
      case "$k" in
         scanned | bytes | "") ;;
         *) total=$((total + n)); bytes=$((bytes + b)) ;;
      esac
   done < "$dir/index.count"
   JS[FILES_DONE]="$total" JS[BYTES_DONE]="$bytes"
}

bm_rec_carve_supervise() {
   local id="$1" dir pid rc end=finish ctl now t0 tick=0 line pass="" sector="" total="" found=""
   bm_job_dir "$id" || return 1
   dir="$REPLY"
   exec 7>"$dir/lock"
   flock -n 7 || return 10
   bm_job_conf_load "$dir"
   : > "$dir/control"
   JS=([STATE]=running [PID]="$$" [FILES_DONE]=0 [BYTES_DONE]=0 [BYTES_NOW]=0 [BYTES_TOTAL]=0 [PASS]=0 [TOTAL_ESTIMATE]=1)
   bm_proc_state "$$"; JS[PID_START]="$PROC_START"
   printf -v t0 '%(%s)T' -1
   bm_job_state_save "$dir"
   trap 'printf "cancel\n" > "$dir/control"' TERM
   if [ ! -r "${JC[SOURCE]}" ]; then
      JS[STATE]=needs-attention JS[REASON]=source-gone
      bm_job_state_save "$dir"; bm_job_report_write "$dir"
      return 0
   fi
   if ! mkdir -p -- "${JC[DEST]}"; then
      JS[STATE]=needs-attention JS[REASON]=dest-gone
      bm_job_state_save "$dir"; bm_job_report_write "$dir"
      return 0
   fi
   bm_rec_carve_commands "${JC[CATEGORIES]:-all}"
   # >> because the file is emptied below, while PhotoRec is writing to it
   : > "$dir/photorec.out"
   ( cd "$dir" && TERM=xterm LC_ALL=C exec ionice -c 2 -n 6 nice -n 5 photorec /nolog /d "${JC[DEST]}/recup_dir" /cmd "${JC[SOURCE]}" "$REPLY" ) >> "$dir/photorec.out" 2>&1 &
   pid=$!
   local re='Pass ([0-9]+) - Reading sector +([0-9]+)/([0-9]+), +([0-9]+) files? found'
   local eta='Estimated time to completion ([0-9]+)h([0-9]+)m([0-9]+)'
   while kill -0 "$pid" 2>/dev/null; do
      sleep "$BM_TICK"
      tick=$((tick + 1))
      printf -v now '%(%s)T' -1
      JS[ELAPSED]=$((now - t0))
      line="$(LC_ALL=C tail -c 2048 -- "$dir/photorec.out" 2>/dev/null | LC_ALL=C tr -d '\000')"
      if [ -n "$line" ]; then
         # The last report on the screen: the greedy prefix goes to the last one
         if [[ $line =~ .*$re ]]; then
            pass="${BASH_REMATCH[1]}" sector="${BASH_REMATCH[2]}" total="${BASH_REMATCH[3]}" found="${BASH_REMATCH[4]}"
            JS[PASS]="$pass" JS[BYTES_NOW]=$((sector * 512)) JS[BYTES_TOTAL]=$((total * 512)) JS[FILES_DONE]="$found"
         fi
         JS[ETA]=""
         [[ $line =~ .*$eta ]] && JS[ETA]=$((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
         # It redraws its screen for hours: only the end is ever read
         [ $((tick % 30)) -eq 0 ] && : > "$dir/photorec.out"
      fi
      ctl=""
      { read -r ctl < "$dir/control"; } 2>/dev/null
      [ "$ctl" = cancel ] && end=cancel
      # PhotoRec fills the disk and stops without saying why in a way we can read
      if [ $((tick % 10)) -eq 0 ]; then
         bm_cp_avail "${JC[DEST]}"
         [[ $REPLY =~ ^[0-9]+$ ]] && [ "$REPLY" -lt 52428800 ] && end=no-space
      fi
      if [ "$end" != finish ]; then
         JS[STATE]=stopping
         bm_job_state_save "$dir"
         pkill -TERM -P "$pid" 2>/dev/null
         kill -TERM "$pid" 2>/dev/null
         break
      fi
      bm_job_state_save "$dir"
   done
   wait "$pid"; rc=$?
   # It answers 0 to a command it did not understand
   grep -qai 'syntax error' "$dir/photorec.out" && rc=2
   printf -v "JS[FINISHED]" '%(%s)T' -1
   JS[ETA]=""
   bm_rec_carve_index "$dir" "${JC[DEST]}"
   JS[BYTES_NOW]="${JS[BYTES_DONE]:-0}"
   JS[BYTES_TOTAL]=0 JS[TOTAL_ESTIMATE]=0
   case "$end" in
      cancel) JS[STATE]=cancelled ;;
      no-space) JS[STATE]=needs-attention JS[REASON]=no-space ;;
      *)
         if [ "$rc" -ne 0 ]; then JS[STATE]=failed JS[REASON]=search-error
         elif [ "${JS[FILES_DONE]:-0}" -eq 0 ]; then JS[STATE]=needs-attention JS[REASON]=nothing-found
         else JS[STATE]=completed JS[REASON]=""
         fi
         ;;
   esac
   bm_job_state_save "$dir"
   bm_job_report_write "$dir"
}

# PhotoRec on an image, or on a device the user can already read (a loop device
# of theirs). In a terminal, without options, its own interface as always.
bm_rec_carve() {
   local src="" dest="" json=0 dry=0 nowait=0 cats=all given=0 id dir now
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --source) src="${2:-}"; shift ;;
         --destination) dest="${2:-}"; shift ;;
         --categories) cats="${2:-}"; given=1; shift ;;
         --json) json=1 ;;
         --dry-run) dry=1 ;;
         --no-wait) nowait=1 ;;
         *) bm_drive_badarg "$1"; return 2 ;;
      esac
      shift
   done
   if [ -z "$src" ] || [ -z "$dest" ]; then
      printf '%s\n' $"Both --source and --destination are needed." >&2
      return 2
   fi
   bm_rec_categories_valid "$cats" || { bm_drive_badarg "--categories $cats"; return 2; }
   if ! command -v photorec >/dev/null; then
      [ "$json" = 1 ] && { bm_rec_refusal 1 no-photorec; return; }
      printf '%s\n' $"PhotoRec is not installed (package testdisk)." >&2
      return 25
   fi
   bm_drive_abs "$src"; src="$(readlink -m -- "$REPLY")"
   bm_drive_abs "$dest"; dest="$(readlink -m -- "$REPLY")"
   if [ ! -r "$src" ]; then
      if [ "$json" = 1 ]; then bm_rec_refusal 1 not-readable; return; fi
      printf '%s\n' $"This device cannot be read by your user. Make a disk image first (bigmount --drive image), and search in the image: it also spares the disk." >&2
      return 20
   fi
   # Results never go to where they are being searched for
   case "$dest/" in "$src"/*) bm_rec_refusal "$json" dest-inside-source; return ;; esac
   bm_dv_scan
   local src_dev=""
   [ -b "$src" ] && src_dev="$src"
   if ! bm_rec_check_dest "$dest" "$src_dev"; then
      bm_rec_refusal "$json" "$REC_ERR"
      return
   fi
   bm_rec_probe "$dest"
   bm_cp_avail "$REPLY"; local avail="$REPLY"
   if [ "$dry" = 1 ]; then
      if [ "$json" = 1 ]; then
         printf '{%s,%s,%s,"warnings":[%s]}\n' "$(bm_jo_inner error "" error_text "" source "$src" destination "$dest" level "")" \
            "$(bm_jb ok 1)" "$(bm_jn exit 0 avail "$avail" total_bytes 0 total_files 0)" "$(bm_rec_warnings_json carve-names)"
         return 0
      fi
      bm_rec_carve_commands "$cats"
      printf 'dry-run: photorec /nolog /d %q /cmd %q %s\n' "$dest/recup_dir" "$src" "$REPLY"
      return 0
   fi
   mkdir -p -- "$dest" || return 1
   if [ -t 0 ] && [ -t 1 ] && [ "$json" = 0 ] && [ "$given" = 0 ] && [ "$nowait" = 0 ]; then
      photorec /d "$dest/recup_dir" "$src"
      local rc=$? n
      n="$(find "$dest" -path "$dest/recup_dir.*" -type f ! -name report.xml 2>/dev/null | wc -l)"
      printf $"%s files found by content in %s. Their original names and folders could not be kept."'\n' "$n" "$dest"
      return "$rc"
   fi
   bm_job_id; id="$REPLY"
   dir="$BM_JOBS/$id"
   (umask 077; mkdir -p -- "$dir") || return 1
   printf -v now '%(%s)T' -1
   JC=([ID]="$id" [KIND]=carve [SOURCE]="$src" [DEST]="$dest" [CATEGORIES]="$cats" [CREATED]="$now" [NAME]="${src##*/}" [VERIFY]=basic)
   bm_job_conf_save "$dir"
   JS=([STATE]=pending [PID]="")
   bm_job_state_save "$dir"
   bm_rec_image_start "$id" || return 1
   if [ "$nowait" = 1 ]; then
      if [ "$json" = 1 ]; then bm_jo id "$id" dir "$dir"; printf '\n'; return 0; fi
      printf $"Search started: %s"'\n' "$id"
      return 0
   fi
   # Scripts wait for the result, as this command always did
   if [ "$json" = 1 ]; then
      while :; do
         bm_job_conf_load "$dir"
         bm_job_state_load "$dir"
         case "${JS[STATE]}" in pending | analyzing | running | stopping) sleep 1 ;; *) break ;; esac
      done
   else
      bm_job_watch "$id" 1 >/dev/null
      bm_job_conf_load "$dir"
      bm_job_state_load "$dir"
   fi
   local ok=0 rc2=0
   case "${JS[STATE]}" in
      completed) ok=1 ;;
      needs-attention) ok=1 ;;
      cancelled) rc2=23 ;;
      *) rc2=1 ;;
   esac
   if [ "$json" = 1 ]; then
      printf '{%s,%s,%s}\n' "$(bm_jo_inner id "$id" destination "$dest" state "${JS[STATE]}")" "$(bm_jn recovered "${JS[FILES_DONE]:-0}" exit "$rc2")" "$(bm_jb ok "$ok")"
   else
      printf $"%s files found by content in %s. Their original names and folders could not be kept."'\n' "${JS[FILES_DONE]:-0}" "$dest"
   fi
   return "$rc2"
}

# bm_rec_status_text: the terminal view of a list or a search (state loaded)
bm_rec_status_text() {
   printf '%-22s %s\n' $"Source:" "${JC[SOURCE]//[[:cntrl:]]/?}"
   if [ "${JC[KIND]}" = scan ]; then
      printf '%-22s %s\n' $"Files listed:" "${JS[FILES_DONE]:-0}"
      printf '%-22s %s\n' $"Files examined:" "${JS[SCANNED]:-0}"
   else
      printf '%-22s %s\n' $"Destination:" "${JC[DEST]//[[:cntrl:]]/?}"
      printf '%-22s %s\n' $"Candidates found:" "${JS[FILES_DONE]:-0}"
      if [ "${JS[BYTES_TOTAL]:-0}" -gt 0 ]; then
         bm_human_size "${JS[BYTES_NOW]:-0}"; local a="$REPLY"
         bm_human_size "${JS[BYTES_TOTAL]}"
         printf '%-22s %s / %s\n' $"Read:" "$a" "$REPLY"
      fi
   fi
   bm_fmt_time "${JS[ELAPSED]:-0}"; printf '%-22s %s\n' $"Elapsed:" "$REPLY"
   bm_job_reason_text "${JS[REASON]:-}"
   [ -n "$REPLY" ] && printf '%s\n' "$REPLY"
   return 0
}

# bm_rec_report_text DIR: the rest of the report of a list or a search
bm_rec_report_text() {
   local dir="$1"
   if [ "${JC[KIND]}" = scan ]; then
      bm_doc_kv $"Files listed" "${JS[FILES_DONE]:-0}"
      bm_doc_kv $"Files examined" "${JS[SCANNED]:-0}"
      bm_doc_p $"These files exist on the volume. Files that were deleted are not on this list."
   else
      bm_doc_kv $"Destination" "${JC[DEST]}"
      bm_doc_kv $"Candidates found" "${JS[FILES_DONE]:-0}"
      bm_doc_p $"Found by content: their original names and folders could not be kept, and some may be incomplete. Open them to check."
   fi
   bm_fmt_time "${JS[ELAPSED]:-0}"; bm_doc_kv $"Elapsed" "$REPLY"
   bm_ui_show info ""
   if [ -s "$dir/scan.err" ]; then
      printf '\n%s\n' $"Could not be read:"
      head -n 50 -- "$dir/scan.err" | sed 's/^/  /'
   fi
}

# bigmount --drive results ID --json: where the list of what was found is, and
# what its columns can be trusted for. The file is NUL-separated records of
#    size<TAB>mtime<TAB>category<TAB>path
bm_rec_results() {
   local id="" json=0 a dir
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) id="$a" ;;
      esac
   done
   bm_job_dir "$id" || { printf $"There is no job '%s'."'\n' "$id" >&2; return 1; }
   dir="$REPLY"
   bm_job_conf_load "$dir"
   bm_job_state_load "$dir"
   local kind="${JC[KIND]:-copy}" root="${JC[SOURCE]:-}" names=1 dates=1 index="" cats="" first=1 k n b
   case "$kind" in
      scan) ;;
      carve) root="${JC[DEST]:-}" names=0 dates=0 ;;
      *) printf '%s\n' $"Only a list or a search has results." >&2; return 2 ;;
   esac
   if [ -f "$dir/index" ]; then index="$dir/index"; fi
   if [ -r "$dir/index.count" ]; then
      while read -r k n b; do
         case "$k" in
            scanned | bytes | "") continue ;;
         esac
         bm_rec_category_label "$k"
         [ "$first" = 1 ] && first=0 || cats+=","
         cats+="{$(bm_jo_inner id "$k" label "$REPLY"),$(bm_jn files "$n" bytes "${b:-0}")}"
      done < "$dir/index.count"
   fi
   if [ "$json" = 1 ]; then
      printf '{%s,%s,%s,"categories":[%s]}\n' \
         "$(bm_jo_inner id "$id" kind "$kind" result_kind "$([ "$kind" = scan ] && echo existing-files || echo carved-candidates)" root "$root" index "$index" state "${JS[STATE]:-}")" \
         "$(bm_jb names_kept "$names" dates_kept "$dates" ready "$([ -n "$index" ] && echo 1)")" \
         "$(bm_jn files "${JS[FILES_DONE]:-0}" level "")" "$cats"
   else
      printf '%s\n' "${index:-$"The list is not ready yet."}"
   fi
}

# ---------------------------------------------------------------------------
# bigmount --drive methods TARGET --json: what can be done with this source and
# what is advised. The window shows this; it does not work it out by itself.

bm_rec_method_json() { # ID AVAILABLE WHY NEEDS_PASSWORD FINDS
   local why_text=""
   if [ -n "$3" ]; then bm_cp_err_text "$3"; why_text="$REPLY"; fi
   printf '{%s,%s}' "$(bm_jo_inner id "$1" why "$3" why_text "$why_text" finds "$5")" "$(bm_jb available "$2" password "$4")"
}

bm_rec_methods() {
   local target="" json=0 a
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   [ "$json" = 1 ] || { printf '%s\n' $"This command only answers with --json." >&2; return 2; }
   bm_drive_abs "$target"; target="$REPLY"
   local kind volume="" dev="" disk="" level=na st="" mp="" size=0 trim=0 fs=""
   if [ -f "$target" ]; then
      kind=image
      size="$(stat -c %s -- "$target")"
   else
      bm_resolve "$target" || { bm_resolve_fail "$target"; return 24; }
      dev="$R_DEV"
      bm_dv_scan || return 1
      disk="$dev"
      bm_dv_disks_of "$dev" && disk="${DV_DISKS[0]}"
      bm_ds_level "$disk"; level="$DS_LEVEL"
      bm_dv_has_trim "$disk" && trim=1
      size="${DV[$dev|SIZE]:-0}"
      if [ "$dev" = "$disk" ] && [ -z "${DV[$dev|FSTYPE]:-}" ]; then
         kind=disk
      else
         kind=volume volume="$dev"
         bm_dv_state "$dev"; st="$REPLY" mp="$DV_MP"
         fs="${DV[$dev|FSTYPE]:-}"
      fi
   fi
   # What each way needs. An answer for everything, in the same words as the refusal
   local has_rsync=0 has_dd=0 has_pr=0 has_td=0 can_read=0
   command -v rsync >/dev/null && has_rsync=1
   command -v ddrescue >/dev/null && has_dd=1
   command -v photorec >/dev/null && has_pr=1
   command -v testdisk >/dev/null && has_td=1
   [ -r "${dev:-$target}" ] && can_read=1
   local fs_ok=0 fs_why=""
   case "$kind" in
      volume)
         case "$st" in
            mounted-rw | mounted-ro | system) fs_ok=1 ;;
            unmounted)
               if bm_dv_fs_supported "$fs"; then fs_ok=1; else fs_why=no-driver; fi
               ;;
            locked | unlocked) fs_why=locked ;;
            member) fs_why=member ;;
            swap | swap-idle) fs_why=swap ;;
            *) fs_why=no-filesystem ;;
         esac
         ;;
      disk) fs_why=pick-volume ;;
      image) fs_why=image-file ;;
   esac
   local rows=() w
   if [ "$fs_ok" = 1 ]; then
      if [ "$has_rsync" = 1 ]; then w=""; else w=no-rsync; fi
      rows+=("$(bm_rec_method_json copy "$([ -z "$w" ] && echo 1)" "$w" 0 existing)")
      rows+=("$(bm_rec_method_json quick "$([ -z "$w" ] && echo 1)" "$w" 0 existing)")
   else
      rows+=("$(bm_rec_method_json copy 0 "$fs_why" 0 existing)")
      rows+=("$(bm_rec_method_json quick 0 "$fs_why" 0 existing)")
   fi
   local deep_image=0
   if [ "$kind" = image ] || [ "$can_read" = 1 ]; then
      if [ "$has_pr" = 1 ]; then w=""; else w=no-photorec; fi
   else
      deep_image=1
      if [ "$has_pr" != 1 ]; then w=no-photorec
      elif [ "$has_dd" != 1 ]; then w=no-ddrescue
      else w=""
      fi
   fi
   rows+=("$(bm_rec_method_json deep "$([ -z "$w" ] && echo 1)" "$w" "$deep_image" carved)")
   if [ "$kind" = image ]; then w=image-file
   elif [ "$has_dd" = 1 ]; then w=""
   else w=no-ddrescue
   fi
   rows+=("$(bm_rec_method_json image "$([ -z "$w" ] && echo 1)" "$w" 1 image)")
   if [ "$has_td" = 1 ]; then w=""; else w=no-testdisk; fi
   rows+=("$(bm_rec_method_json partitions "$([ -z "$w" ] && echo 1)" "$w" "$([ "$kind" != image ] && echo 1)" partitions)")

   # What is advised. Never starts anything: it is the first option on the screen
   local rec why_rec
   case "$kind:$level:$fs_ok" in
      image:*) rec=deep why_rec=$"This is a disk image: searching it does not touch any disk." ;;
      *:critical:1 | *:attention:1)
         rec=copy
         why_rec=$"The drive reported problems: copy what matters first, without going through everything."
         ;;
      *:critical:0 | *:attention:0)
         rec=image
         why_rec=$"The drive reported problems and its files cannot be opened: a disk image reads it only once, and the search is done on the image."
         ;;
      *:*:1)
         rec=quick
         why_rec=$"The files can be read normally: list them, and choose what to copy."
         ;;
      *)
         rec=deep
         why_rec=$"The files cannot be opened normally: search for them by content."
         ;;
   esac
   local notes=() cats="" first=1 c
   [ "$trim" = 1 ] && notes+=(trim)
   for c in $BM_REC_CATEGORIES; do
      bm_rec_category_label "$c"; local l="$REPLY"
      bm_rec_category_note "$c"
      [ "$first" = 1 ] && first=0 || cats+=","
      cats+="$(bm_jo id "$c" label "$l" deep_note "$REPLY")"
   done
   local IFS=,
   printf '{%s,%s,%s,"methods":[%s],"notes":[%s],"categories":[%s]}\n' \
      "$(bm_jo_inner target "$target" source_kind "$kind" device "$dev" volume "$volume" disk "$disk" level "$level" state "$st" mountpoint "$mp" fstype "$fs" recommended "$rec" recommended_why "$why_rec")" \
      "$(bm_jn size "$size")" "$(bm_jb trim "$trim" can_read "$can_read" deep_needs_image "$deep_image")" \
      "${rows[*]}" "$(bm_rec_warnings_json "${notes[@]}")" "$cats"
}

bm_rec_cmd() {
   local cmd="$1"
   shift
   case "$cmd" in
      image) bm_rec_image_cmd "$@" ;;
      partitions) bm_rec_partitions "$@" ;;
      carve) bm_rec_carve "$@" ;;
      scan) bm_rec_scan_cmd "$@" ;;
      results) bm_rec_results "$@" ;;
      methods) bm_rec_methods "$@" ;;
   esac
}
