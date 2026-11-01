# shellcheck shell=bash
# shellcheck disable=SC2015,SC2247  # A && B || C on purpose; "1. "$"text" is a number and a translation
#
# big-mount drive manager: the interactive terminal interface (bigmount
# --drive). Only menus: everything it does is done by the commands of the other
# drive modules, the same ones the graphical interface calls. Works in any
# terminal and through SSH: no colours or box characters unless they can be
# shown, and input is line by line.

bm_tui_title() {
   local text="$1" sub="${2:-}" w=46 line="" i pad
   if [ "${BM_TUI_UTF8:-0}" = 1 ]; then
      for ((i = 0; i < w; i++)); do line+="─"; done
      printf '╭%s╮\n' "$line"
      pad=$(((w - ${#text}) / 2)); printf '│%*s%s%*s│\n' "$pad" "" "$text" $((w - pad - ${#text})) ""
      if [ -n "$sub" ]; then pad=$(((w - ${#sub}) / 2)); printf '│%*s%s%*s│\n' "$pad" "" "$sub" $((w - pad - ${#sub})) ""; fi
      printf '╰%s╯\n\n' "$line"
   else
      printf '== %s ==\n' "$text"
      [ -n "$sub" ] && printf '%s\n' "$sub"
      printf '\n'
   fi
}

# bm_tui_ask PROMPT: a line typed by the user (REPLY). Fails at the end of input.
bm_tui_ask() {
   local a
   printf '%s ' "$1"
   read -r a || return 1
   REPLY="$a"
}

bm_tui_pause() {
   local a
   printf '\n%s ' $"Press Enter to continue."
   read -r a || return 1
}

# bm_tui_yes PROMPT: the safe answer is the default
bm_tui_yes() {
   local a
   printf '%s [%s/%s] ' "$1" $"y" $"N"
   read -r a || return 1
   bm_ui_is_yes "$a"
}

bm_tui_main() {
   if [ ! -t 0 ]; then
      printf '%s\n' $"The interactive manager needs a terminal. For scripts, see bigmount --drive --help." >&2
      return 2
   fi
   local n
   while :; do
      bm_dv_scan || return 1
      bm_tui_title "BIG-MOUNT DRIVE MANAGER" $"Safe diagnosis and recovery"
      printf $"Devices found: %s"'\n\n' "${#DV_TOP[@]}"
      bm_dv_list_text numbered
      printf '%s\n' "  j) "$"Copies and images" "  a) "$"Refresh" "  0) "$"Quit"
      bm_tui_ask "$(printf $"Choose a device [1-%s]:" "${#DV_TOP[@]}")" || return 0
      n="$REPLY"
      case "$n" in
         0 | q | Q) return 0 ;;
         j | J) bm_tui_jobs ;;
         a | A | "") ;;
         *)
            if [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#DV_TOP[@]}" ]; then
               bm_tui_device "${DV_TOP[n - 1]}"
            fi
            ;;
      esac
   done
}

# The drive may be gone by the time the user picks something
bm_tui_still_there() {
   bm_dv_scan
   [ -n "${DV[$1|TYPE]:-}" ] && return 0
   printf '%s\n' $"The device was disconnected or replaced. Nothing was done."
   return 1
}

bm_tui_device() {
   local disk="$1" a
   while :; do
      bm_tui_still_there "$disk" || { bm_tui_pause; return 0; }
      bm_dv_name "$disk"
      printf '\n%s: %s\n\n' $"DEVICE" "$(bm_tui_paint none "$REPLY")"
      printf '%s\n' \
         "1. "$"Complete information" \
         "2. "$"Storage diagnosis" \
         "3. "$"Mount safely (read-only)" \
         "4. "$"Explore files" \
         "5. "$"Copy files to another disk" \
         "6. "$"Advanced recovery" \
         "7. "$"Unmount safely" \
         "8. "$"Export report" \
         "0. "$"Back"
      bm_tui_ask $"Choose:" || return 0
      a="$REPLY"
      case "$a" in
         1) bm_drive_inspect_text "$disk"; bm_tui_pause || return 0 ;;
         2) bm_tui_diagnose "$disk" || return 0 ;;
         3) bm_tui_mount "$disk"; bm_tui_pause || return 0 ;;
         4) bm_tui_explore "$disk" || return 0 ;;
         5) bm_tui_copy "$disk" || return 0 ;;
         6) bm_tui_advanced "$disk" || return 0 ;;
         7) bm_tui_unmount "$disk"; bm_tui_pause || return 0 ;;
         8) bm_tui_report "$disk"; bm_tui_pause || return 0 ;;
         0 | q | Q) return 0 ;;
      esac
   done
}

bm_tui_diagnose() {
   local disk="$1"
   bm_dg_show "$disk" "$disk"
   if [ "$DS_BASIS" = log ] || [ "$DS_BASIS" = none ]; then
      if [ "${DV[$disk|TYPE]}" = disk ] && command -v smartctl >/dev/null; then
         if bm_tui_yes $"Read SMART now? It asks for the password, and through USB it can take a minute."; then
            bm_ds_smart_read "$disk" && bm_dg_show "$disk" "$disk" || printf '%s\n' $"The drive did not report SMART data. Many USB adapters do not pass it through."
         fi
      fi
   fi
   bm_tui_pause
}

# Volumes of a drive that hold files (TV_LIST); bm_tui_pick_volume asks for one
bm_tui_volumes() {
   local p
   TV_LIST=()
   bm_dv_tree "$1"
   for p in "${DV_TREE[@]}"; do
      bm_dv_state "$p"
      case "$REPLY" in unmounted | mounted-ro | mounted-rw) TV_LIST+=("$p") ;; esac
   done
}

bm_tui_pick_volume() {
   local i=0 p st
   bm_tui_volumes "$1"
   if [ "${#TV_LIST[@]}" -eq 0 ]; then
      printf '%s\n' $"This drive has no volume with files that can be opened. Advanced recovery may help."
      return 1
   fi
   if [ "${#TV_LIST[@]}" -eq 1 ]; then REPLY="${TV_LIST[0]}"; return 0; fi
   for p in "${TV_LIST[@]}"; do
      i=$((i + 1))
      bm_dv_state "$p"; bm_dv_state_label "$REPLY"; st="$REPLY"
      bm_human_size "${DV[$p|SIZE]:-}"
      printf '%2d. %s %s %s — %s %s\n' "$i" "$p" "${DV[$p|LABEL]//[[:cntrl:]]/?}" "$REPLY" "${DV[$p|FSTYPE]:-}" "$st"
   done
   bm_tui_ask $"Choose a volume:" || return 1
   [[ $REPLY =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$i" ] || return 1
   REPLY="${TV_LIST[REPLY - 1]}"
}

# Mount a volume read-only, asking about the device-level protection on a drive
# at risk. REPLY: the mount point.
bm_tui_mount_volume() {
   local v="$1" disk="$2" protect=0 rc
   bm_ds_level "$disk"
   case "$DS_LEVEL" in
      critical | attention)
         bm_ds_level_label; printf '%s\n' "$REPLY"
         bm_tui_yes $"Also block writing on the device itself? It asks for the password. Recommended: then no program can change the disk." && protect=1
         ;;
   esac
   bm_mnt_mount "$v" ro "$protect" 0; rc=$?
   if [ "$rc" -eq 20 ] && [ "$MNT_WHY" = already-rw ]; then
      bm_mnt_why_text already-rw; printf '%s\n' "$REPLY"
      if bm_tui_yes $"Unmount it and mount it again read-only?"; then
         bm_mnt_mount "$v" ro "$protect" 1; rc=$?
      fi
   fi
   bm_mnt_report 0 "$v" "$rc"
   REPLY="$MNT_POINT"
   [ "$rc" -eq 0 ]
}

bm_tui_mount() {
   bm_tui_pick_volume "$1" || return 0
   bm_tui_mount_volume "$REPLY" "$1"
}

bm_tui_unmount() {
   local v
   bm_tui_pick_volume "$1" || return 0
   v="$REPLY"
   bm_drive_unmount "$v"
}

# A simple folder browser (TB_PICKED: the items marked, relative to the root).
# It only lists one folder at a time and never reads file contents.
bm_tui_browse() {
   local root="$1" cwd="" names i n a pick=()
   TB_PICKED=()
   while :; do
      mapfile -d '' -t names < <(cd -- "$root/$cwd" 2>/dev/null && timeout 30 find . -mindepth 1 -maxdepth 1 -printf '%P\0' 2>/dev/null | sort -z)
      printf '\n%s/%s\n' "${root//[[:cntrl:]]/?}" "${cwd//[[:cntrl:]]/?}"
      i=0
      for n in "${names[@]}"; do
         i=$((i + 1))
         a=" "
         [[ " ${pick[*]} " == *" ${cwd:+$cwd/}$n "* ]] && a="*"
         if [ -d "$root/$cwd/$n" ]; then
            printf '%s%3d. %s/\n' "$a" "$i" "${n//[[:cntrl:]]/?}"
         else
            printf '%s%3d. %s\n' "$a" "$i" "${n//[[:cntrl:]]/?}"
         fi
      done
      [ "$i" -gt 0 ] || printf '  %s\n' $"(empty, or it could not be read)"
      printf '%s\n' $"NUMBER: open a folder | m NUMBER: mark or unmark | u: up | d: done | 0: back"
      bm_tui_ask ">" || return 1
      a="$REPLY"
      case "$a" in
         0) TB_PICKED=(); return 1 ;;
         d | D) TB_PICKED=("${pick[@]}"); return 0 ;;
         u | U | ..) [[ $cwd == */* ]] && cwd="${cwd%/*}" || cwd="" ;;
         m\ *)
            n="${a#m }"
            [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || continue
            n="${cwd:+$cwd/}${names[n - 1]}"
            local j found=0 next=()
            for j in "${pick[@]}"; do
               if [ "$j" = "$n" ]; then found=1; else next+=("$j"); fi
            done
            [ "$found" = 1 ] || next+=("$n")
            pick=("${next[@]}")
            ;;
         *)
            [[ $a =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "$i" ] || continue
            n="${names[a - 1]}"
            [ -d "$root/$cwd/$n" ] && cwd="${cwd:+$cwd/}$n"
            ;;
      esac
   done
}

# A volume ready to read (REPLY: its mount point), mounting it when needed
bm_tui_ready() {
   local disk="$1" v
   bm_tui_pick_volume "$disk" || return 1
   v="$REPLY"
   bm_dv_state "$v"
   if [ -n "$DV_MP" ]; then REPLY="$DV_MP"; return 0; fi
   bm_tui_mount_volume "$v" "$disk"
}

bm_tui_explore() {
   local mp
   bm_tui_ready "$1" || { bm_tui_pause; return; }
   mp="$REPLY"
   bm_tui_browse "$mp" || true
   return 0
}

bm_tui_copy() {
   local disk="$1" mp dest a
   bm_tui_ready "$disk" || { bm_tui_pause; return; }
   mp="$REPLY"
   local args=(--source "$mp")
   printf '\n%s\n' "1. "$"Copy everything" "2. "$"Choose files and folders"
   bm_tui_ask $"Choose:" || return 1
   if [ "$REPLY" = 2 ]; then
      bm_tui_browse "$mp" || return 0
      if [ "${#TB_PICKED[@]}" -eq 0 ]; then
         printf '%s\n' $"Nothing was marked."
         bm_tui_pause
         return
      fi
      for a in "${TB_PICKED[@]}"; do args+=(--item "$a"); done
   fi
   printf '\n%s\n' $"Where to? Places marked with * are on another physical disk, with room:"
   bm_cp_destinations --source "$mp"
   bm_tui_ask $"Destination folder:" || return 1
   dest="$REPLY"
   [ -n "$dest" ] || return 0
   args+=(--destination "$dest")
   printf '\n%s\n' $"If a file already exists at the destination:" "1. "$"Keep the existing file (safe)" "2. "$"Replace it, keeping the old one aside" "3. "$"Replace it"
   bm_tui_ask $"Choose:" || return 1
   case "$REPLY" in
      2) args+=(--on-conflict backup) ;;
      3)
         bm_tui_yes $"Replace existing files? This cannot be undone." && args+=(--on-conflict overwrite) || args+=(--on-conflict skip)
         ;;
      *) args+=(--on-conflict skip) ;;
   esac
   printf '\n'
   if ! bm_cp_cmd "${args[@]}" --dry-run; then
      bm_tui_offer_overrides "${args[@]}" || { bm_tui_pause; return; }
      args=("${TO_ARGS[@]}")
   fi
   bm_tui_yes $"Start the copy?" || return 0
   bm_cp_cmd "${args[@]}"
   bm_tui_pause
}

# A refusal that the user may override, each on purpose and with its own words
bm_tui_offer_overrides() {
   TO_ARGS=("$@")
   case "$CK_ERR" in
      same-disk) bm_tui_yes $"Use the same physical disk anyway?" && TO_ARGS+=(--allow-same-disk) || return 1 ;;
      rw-source) bm_tui_yes $"Copy from it while it is mounted with writing enabled?" && TO_ARGS+=(--allow-rw-source) || return 1 ;;
      dest-risky) bm_tui_yes $"Use that drive with critical alerts anyway?" && TO_ARGS+=(--allow-risky-destination) || return 1 ;;
      *) return 1 ;;
   esac
}

bm_tui_advanced() {
   local disk="$1" a v
   printf '\n%s\n' $"These tools do not change the disk." \
      "1. "$"Make a disk image (GNU ddrescue)" \
      "2. "$"Look for lost partitions (TestDisk)" \
      "3. "$"Search for files in an image (PhotoRec)" \
      "4. "$"Block writing on the device" \
      "5. "$"Allow writing on the device" \
      "0. "$"Back"
   bm_tui_ask $"Choose:" || return 1
   a="$REPLY"
   case "$a" in
      1)
         bm_tui_ask $"Image file, on another disk:" || return 1
         [ -n "$REPLY" ] && bm_rec_image_cmd --source "$disk" --image "$REPLY"
         ;;
      2) bm_rec_partitions "$disk" ;;
      3)
         bm_tui_ask $"Image file:" || return 1
         v="$REPLY"
         bm_tui_ask $"Destination folder:" || return 1
         [ -n "$v" ] && [ -n "$REPLY" ] && bm_rec_carve --source "$v" --destination "$REPLY"
         ;;
      4) bm_drive_protect protect "$disk" ;;
      5) bm_drive_protect unprotect "$disk" ;;
      *) return 0 ;;
   esac
   bm_tui_pause
}

bm_tui_report() {
   local a
   bm_tui_ask $"File to write the report to (empty: show it here):" || return 1
   a="$REPLY"
   if [ -n "$a" ]; then
      if bm_tui_yes $"Hide serial numbers, labels and your user name?"; then
         bm_job_cmd_report "$1" --anonymize --output "$a"
      else
         bm_job_cmd_report "$1" --output "$a"
      fi
   else
      bm_job_cmd_report "$1"
   fi
}

bm_tui_jobs() {
   local a dir
   bm_job_list
   printf '\n%s\n' $"To see one, type its name. Empty: back."
   bm_tui_ask ">" || return 0
   a="$REPLY"
   [ -n "$a" ] || return 0
   bm_job_dir "$a" || return 0
   dir="$REPLY"
   bm_job_report_text "$dir"
   bm_job_state_load "$dir"
   case "${JS[STATE]:-}" in
      pending | analyzing | running | verifying | stopping)
         bm_tui_yes $"Follow its progress?" && bm_job_watch "$a" 0
         ;;
      paused | interrupted | needs-attention)
         bm_tui_yes $"Resume it?" && bm_job_cmd_resume "$a"
         ;;
   esac
   bm_tui_pause
}
