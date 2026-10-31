# shellcheck shell=bash
# shellcheck disable=SC2034  # BM_TUI_* are read by the other drive modules
#
# big-mount drive manager: bigmount --drive (terminal) and the engine behind
# bigmount --gui-drive. The graphical interface only calls these commands with
# --json, so both always do the same thing.
#
# Loaded on demand: the boot path and the other modes never read this file.
#
# Exit codes, besides those of cli.sh: 20 refused by a safety check, 21 not
# enough space, 22 finished but some files were not copied, or the check found
# differences, 23 cancelled or paused, 24 a device went away or did not answer,
# 25 a tool is missing.

bm_load drive-detect.sh
bm_load drive-diag.sh

# ---------------------------------------------------------------------------
# JSON. Device data and file names are untrusted: everything goes through bm_js.

bm_js() {
   local s="$1"
   s="${s//\\/\\\\}"
   s="${s//\"/\\\"}"
   s="${s//$'\n'/\\n}"
   s="${s//$'\t'/\\t}"
   s="${s//$'\r'/\\r}"
   s="${s//[[:cntrl:]]/?}"
   REPLY="\"$s\""
}

# "k":"v","k2":"v2"
bm_jo_inner() {
   local out="" sep=""
   while [ "$#" -ge 2 ]; do
      bm_js "$2"
      out+="$sep\"$1\":$REPLY"
      sep=","
      shift 2
   done
   printf '%s' "$out"
}
bm_jo_open() { printf '{'; bm_jo_inner "$@"; }
bm_jo() { bm_jo_open "$@"; printf '}'; }

# "k":123 or "k":null when the value is not a number
bm_jn() {
   local out="" sep=""
   while [ "$#" -ge 2 ]; do
      if [[ $2 =~ ^-?[0-9]+$ ]]; then out+="$sep\"$1\":$2"; else out+="$sep\"$1\":null"; fi
      sep=","
      shift 2
   done
   printf '%s' "$out"
}

# "k":true for 1, "k":false otherwise
bm_jb() {
   local out="" sep=""
   while [ "$#" -ge 2 ]; do
      if [ "$2" = 1 ]; then out+="$sep\"$1\":true"; else out+="$sep\"$1\":false"; fi
      sep=","
      shift 2
   done
   printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Terminal: colours and box characters only when they can be shown

bm_tui_init() {
   local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
   BM_TUI_COLOR=0 BM_TUI_UTF8=0
   [[ $loc == *[Uu][Tt][Ff]* ]] && BM_TUI_UTF8=1
   if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then BM_TUI_COLOR=1; fi
}

# bm_tui_paint LEVEL TEXT: TEXT in the colour of a health level
bm_tui_paint() {
   local c=""
   if [ "${BM_TUI_COLOR:-0}" = 1 ]; then
      case "$1" in
         critical) c=$'\033[1;31m' ;;
         attention) c=$'\033[1;33m' ;;
         normal) c=$'\033[1;32m' ;;
         *) c=$'\033[1m' ;;
      esac
      printf '%s%s\033[0m' "$c" "${2//[[:cntrl:]]/?}"
   else
      printf '%s' "${2//[[:cntrl:]]/?}"
   fi
}

# ---------------------------------------------------------------------------
# The privileged helper (polkit decides; nothing else here runs as root)

bm_helper() {
   if [ -n "${BM_HELPER_CMD:-}" ]; then
      "$BM_HELPER_CMD" "$@"
   elif [ "$EUID" -eq 0 ]; then
      "$BM_LIB_DIR/bigmount-drive-helper" "$@"
   else
      command -v pkexec >/dev/null || return 127
      pkexec "$BM_LIB_DIR/bigmount-drive-helper" "$@"
   fi
}

# ---------------------------------------------------------------------------
# Usage

bm_drive_usage() {
   printf '%s\n\n' $"Usage: bigmount --drive [COMMAND] [OPTIONS]"
   printf '%s\n\n' $"Without a command: the interactive manager (needs a terminal)."
   printf '  %-36s %s\n' \
      "list" $"storage devices and what is known about their health" \
      "inspect TARGET" $"everything known about one drive" \
      "diagnose TARGET [--smart]" $"explain its state; --smart also reads SMART (asks for a password)" \
      "mount DEV [--read-only]" $"mount a volume without changing it (the default)" \
      "  --protect" $"also block writing on the device itself (asks for a password)" \
      "  --remount" $"unmount first if it is mounted with writing enabled" \
      "  --read-write" $"mount with writing enabled (refused on a drive at risk)" \
      "unmount TARGET" $"unmount one volume safely" \
      "protect DEV | unprotect DEV" $"block or allow writing on the device (asks for a password)" \
      "unlock DEV" $"unlock an encrypted volume" \
      "destinations --source FOLDER" $"where files can be copied to" \
      "copy --source FOLDER --destination FOLDER" $"copy files in the background and follow the progress" \
      "  --item PATH" $"copy only this file or folder of the source (repeatable)" \
      "  --on-conflict skip|backup|overwrite" $"files that already exist: keep them (default), keep them aside, replace them" \
      "  --verify basic|metadata|full" $"how to check the result (full reads the source again)" \
      "  --stall-seconds N" $"set aside a file that does not advance for N seconds (default 90, 0: never)" \
      "  --bwlimit KBPS" $"limit the reading speed" \
      "  --scan auto|yes|no" $"measure the total first (auto: not on a drive at risk)" \
      "  --allow-same-disk" $"accept a destination on the same physical disk" \
      "  --allow-rw-source" $"accept a drive at risk that is mounted with writing enabled" \
      "  --allow-risky-destination" $"accept a destination on a drive with critical alerts" \
      "  --no-wait" $"start and return, the copy continues in the background" \
      "jobs" $"copies and images, running and past" \
      "status ID [--watch]" $"progress of one of them" \
      "pause ID | cancel ID" $"stop it safely (it can be resumed later)" \
      "resume ID [--retry-deferred]" $"continue it, also after a shutdown; optionally try what was set aside" \
      "report TARGET|ID [--anonymize]" $"report of a drive or of a copy (--output FILE)" \
      "image --source DEV --image FILE" $"make a disk image with GNU ddrescue" \
      "partitions TARGET" $"look for partitions with TestDisk, changing nothing" \
      "carve --source DEV|IMAGE --destination FOLDER" $"search for files by content with PhotoRec" \
      "--json" $"machine-readable output" \
      "--dry-run" $"say what would be done, change nothing"
   printf '\n%s\n' $"TARGET is a device (/dev/sdb1) or a folder inside a mounted device."
}

# ---------------------------------------------------------------------------
# Commands

# Paths are relative to where the user called us: bm_main left that folder
bm_drive_abs() {
   case "$1" in
      /*) REPLY="$1" ;;
      *) REPLY="${BM_CWD:-$PWD}/$1" ;;
   esac
}

# bm_drive_disk TARGET: the drive of a device or folder (R_DEV, DD_DISK)
bm_drive_disk() {
   bm_drive_abs "$1"
   bm_resolve "$REPLY" || { bm_resolve_fail "$1"; return 24; }
   bm_facts "$R_DEV" || { R_ERR=unavailable; bm_resolve_fail "$R_DEV"; return 24; }
   DD_DISK="${F[DISK]}"
   bm_dv_scan || return 1
   [ -n "${DV[$DD_DISK|TYPE]:-}" ] || { R_ERR=unavailable; bm_resolve_fail "$1"; return 24; }
}

bm_drive_list() {
   local json=0 a
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         *) bm_drive_badarg "$a"; return 2 ;;
      esac
   done
   bm_dv_scan || { printf '%s\n' $"The list of devices could not be read." >&2; return 1; }
   if [ "$json" = 1 ]; then bm_dv_list_json; else bm_dv_list_text; fi
}

bm_drive_badarg() {
   printf $"bigmount: unknown option '%s' (see bigmount --help)"'\n' "$1" >&2
}

# Facts of one drive and its volumes, as text
bm_drive_inspect_text() {
   local d="$1" p st
   bm_dv_name "$d"
   bm_doc_new
   bm_doc_h "$REPLY"
   bm_dv_kind "$d"; bm_dv_kind_label "$REPLY"; bm_doc_kv $"Type" "$REPLY"
   [ -n "${DV[$d|VENDOR]:-}" ] && bm_doc_kv $"Manufacturer" "${DV[$d|VENDOR]}"
   [ -n "${DV[$d|MODEL]:-}" ] && bm_doc_kv $"Model" "${DV[$d|MODEL]}"
   [ -n "${DV[$d|SERIAL]:-}" ] && bm_doc_kv $"Serial number" "${DV[$d|SERIAL]}"
   bm_human_size "${DV[$d|SIZE]:-}"; bm_doc_kv $"Capacity" "$REPLY"
   bm_tran_label "${DV[$d|TRAN]:-}"; bm_doc_kv $"Connection" "$REPLY"
   bm_doc_kv $"Device" "$d"
   [ -n "${DV[$d|PTTYPE]:-}" ] && bm_doc_kv $"Partition table" "${DV[$d|PTTYPE]}"
   bm_ds_level "$d"
   bm_ds_level_label; bm_doc_kv $"Health" "$REPLY"
   bm_ui_show info ""
   bm_dv_tree "$d"
   local tree=("${DV_TREE[@]}")
   for p in "${tree[@]}"; do
      [ "$p" = "$d" ] && [ -z "${DV[$p|FSTYPE]:-}" ] && continue
      bm_dv_state "$p"; st="$REPLY"
      bm_dv_state_label "$st"; local state="$REPLY"
      bm_doc_new
      bm_doc_h "$p"
      [ -n "${DV[$p|LABEL]:-}" ] && bm_doc_kv $"Label" "${DV[$p|LABEL]}"
      bm_fs_label "${DV[$p|FSTYPE]:-}"; bm_doc_kv $"Filesystem" "$REPLY${DV[$p|FSVER]:+ ${DV[$p|FSVER]}}"
      bm_human_size "${DV[$p|SIZE]:-}"; bm_doc_kv $"Size" "$REPLY"
      [ -n "${DV[$p|UUID]:-}" ] && bm_doc_kv "UUID" "${DV[$p|UUID]}"
      bm_doc_kv $"Status" "$state"
      [ -n "$DV_MP" ] && bm_doc_kv $"Mounted at" "$DV_MP"
      if [ -n "${DV[$p|FSUSED]:-}" ]; then
         bm_human_size "${DV[$p|FSUSED]}"; local used="$REPLY"
         bm_human_size "${DV[$p|FSAVAIL]:-}"
         bm_doc_kv $"Space" "$used / $REPLY"
      fi
      [ "${DV[$p|RO]:-0}" = 1 ] && bm_doc_kv $"Writing" $"blocked on the device"
      bm_dv_multi_btrfs "$p" && bm_doc_kv "Btrfs" "${DV_MULTI[*]}"
      bm_ui_show info ""
   done
}

bm_drive_inspect() {
   local json=0 target="" a rc
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   bm_drive_disk "$target"; rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   if [ "$json" = 1 ]; then
      bm_dv_disk_json "$DD_DISK"; printf '\n'
   else
      bm_drive_inspect_text "$DD_DISK"
   fi
}

# One volume of a diagnosis: why it cannot be written, in the same words as
# bigmount --diagnose
bm_dg_volume_json() {
   local p="$1" st cause="" title="" reason=""
   bm_dv_state "$p"; st="$REPLY"
   case "$st" in
      mounted-ro | mounted-rw | system)
         if bm_dg_write_cause "$p"; then
            cause="$REPLY"
            bm_cause_text "$cause"
            title="$C_TITLE" reason="$C_REASON"
         fi
         ;;
   esac
   bm_jo volume "$p" cause "$cause" title "$title" reason "$reason"
}

# What may be offered for each volume, read by the GUI
bm_dg_json() {
   local d="$1" p first=1 vols="" l first2=1 lines="" adv="" w
   bm_dv_tree "$d"
   local tree=("${DV_TREE[@]}")
   for p in "${tree[@]}"; do
      [ "$p" = "$d" ] && [ -z "${DV[$p|FSTYPE]:-}" ] && continue
      [ "$first" = 1 ] && first=0 || vols+=","
      vols+="$(bm_dg_volume_json "$p")"
   done
   bm_ds_level "$d"
   bm_ds_advice
   first=1
   for w in "${DS_ADVICE[@]}"; do
      bm_js "$w"
      [ "$first" = 1 ] && first=0 || adv+=","
      adv+="$REPLY"
   done
   for l in "${DH_LINES[@]:$((${#DH_LINES[@]} > 15 ? ${#DH_LINES[@]} - 15 : 0))}"; do
      bm_js "$l"
      [ "$first2" = 1 ] && first2=0 || lines+=","
      lines+="$REPLY"
   done
   printf '{"device":%s,"advice":[%s],"kernel":[%s],"volumes":[%s],"tools":{%s}}\n' \
      "$(bm_dv_disk_json "$d")" "$adv" "$lines" "$vols" \
      "$(bm_jb ddrescue "$(command -v ddrescue >/dev/null && echo 1)" testdisk "$(command -v testdisk >/dev/null && echo 1)" \
         photorec "$(command -v photorec >/dev/null && echo 1)" smartctl "$(command -v smartctl >/dev/null && echo 1)" \
         rsync "$(command -v rsync >/dev/null && echo 1)")"
}

bm_drive_diagnose() {
   local json=0 smart=0 target="" a rc
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         --smart) smart=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   bm_drive_disk "$target"; rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   if [ "$smart" = 1 ]; then
      if ! command -v smartctl >/dev/null; then
         printf '%s\n' $"smartctl is not installed (package smartmontools), so SMART details cannot be read." >&2
      else
         bm_ds_smart_read "$DD_DISK"; rc=$?
         case "$rc" in
            0) ;;
            126 | 127) printf '%s\n' $"Permission to read SMART was not granted." >&2 ;;
            *) printf '%s\n' $"The drive did not report SMART data. Many USB adapters do not pass it through." >&2 ;;
         esac
      fi
   fi
   if [ "$json" = 1 ]; then
      bm_dg_json "$DD_DISK"
   else
      bm_dg_show "$target" "$DD_DISK"
   fi
   bm_ds_level "$DD_DISK"
   [ "$DS_LEVEL" != critical ] && [ "$DS_LEVEL" != attention ]
}

# Result of mount/protect/unlock for a person, or as JSON
bm_mnt_report() {
   local json="$1" dev="$2" rc="$3" text=""
   [ -n "$MNT_WHY" ] && { bm_mnt_why_text "$MNT_WHY"; text="$REPLY"; }
   if [ "$json" = 1 ]; then
      printf '{%s,%s,%s}\n' "$(bm_jo_inner device "$dev" mountpoint "$MNT_POINT" why "$MNT_WHY" text "$text" detail "$MNT_DETAIL")" \
         "$(bm_jb ok "$([ "$rc" -eq 0 ] && echo 1)" read_only "$MNT_RO" protected "$MNT_PROTECTED")" "$(bm_jn exit "$rc")"
      return
   fi
   if [ "$rc" -eq 0 ]; then
      if [ "$MNT_RO" = 1 ]; then printf $"Mounted read-only at %s"'\n' "$MNT_POINT"
      else printf $"Mounted at %s"'\n' "$MNT_POINT"
      fi
      [ "$MNT_PROTECTED" = 1 ] && printf '%s\n' $"Writing is also blocked on the device itself until it is disconnected."
   else
      printf '%s\n' "$text" >&2
      [ -n "$MNT_DETAIL" ] && printf '%s\n' "$MNT_DETAIL" | sed 's/^/  /' >&2
   fi
}

bm_drive_mount() {
   local json=0 mode=ro protect=0 remount=0 dry=0 target="" a rc
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         --read-only) mode=ro ;;
         --read-write) mode=rw ;;
         --protect) protect=1 ;;
         --remount) remount=1 ;;
         --dry-run) dry=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [[ $target == /dev/* ]] || { printf '%s\n' $"Name a device, such as /dev/sdb1." >&2; return 2; }
   bm_resolve "$target" || { bm_resolve_fail "$target"; return 24; }
   if [ "$dry" = 1 ]; then
      bm_dv_scan
      bm_mnt_options "${DV[$R_DEV|FSTYPE]:-}"
      [ "$mode" = rw ] && REPLY=noatime
      printf 'dry-run: udisksctl mount -b %q -o %s\n' "$R_DEV" "$REPLY"
      [ "$protect" = 1 ] && printf 'dry-run: pkexec bigmount-drive-helper protect %q\n' "$R_DEV"
      return 0
   fi
   bm_mnt_mount "$R_DEV" "$mode" "$protect" "$remount"; rc=$?
   bm_mnt_report "$json" "$R_DEV" "$rc"
   return "$rc"
}

bm_drive_unmount() {
   local target="" json=0 a rc dry=0
   for a in "$@"; do
      case "$a" in
         --json) json=1 ;;
         --dry-run) dry=1 ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   bm_drive_abs "$target"
   bm_resolve "$REPLY" || { bm_resolve_fail "$target"; return 24; }
   if [ "$dry" = 1 ]; then printf 'dry-run: udisksctl unmount -b %q\n' "$R_DEV"; return 0; fi
   bm_facts "$R_DEV" && ! bm_drive_lock "${F[DISK]}" && {
      printf '%s\n' $"Another removal of this drive is in progress. Nothing was done." >&2
      return 10
   }
   bm_remove_core unmount "$R_DEV"; rc=$?
   bm_drive_unlock
   if [ "$json" = 1 ]; then
      if [ "$rc" -eq 3 ]; then bm_busy_doc "$RM_BUSY_DEV"; bm_busy_summary; else BUSY_SUMMARY="" BUSY_ADVICE=""; fi
      printf '{%s,%s,%s}\n' "$(bm_jo_inner device "$R_DEV" reason "$RM_REASON" busy_summary "$BUSY_SUMMARY" busy_advice "$BUSY_ADVICE")" \
         "$(bm_jb ok "$([ "$rc" -eq 0 ] && echo 1)")" "$(bm_jn exit "$rc")"
      return "$rc"
   fi
   case "$rc" in
      0) printf '%s\n' $"Unmounted. Everything was written to the device." ;;
      3) bm_busy_doc "$RM_BUSY_DEV"; bm_ui_show warning "" ;;
      4) printf $"Refused: this drive holds the running system (%s)."'\n' "$RM_REASON" >&2 ;;
      5) printf '%s\n' $"Permission to unmount was not granted." >&2 ;;
      9)
         printf '%s\n' $"These services use the device and will be stopped when it is unmounted:" >&2
         for a in "${!RM_DEP_UNITS[@]}"; do printf '  %s (%s)\n' "${RM_DEP_NAMES[a]}" "${RM_DEP_UNITS[a]}" >&2; done
         printf '%s\n' $"Nothing was done. Use bigmount --unmount to confirm stopping them." >&2
         ;;
      *) printf $"Could not unmount: %s"'\n' "$RM_REASON" >&2 ;;
   esac
   return "$rc"
}

# protect/unprotect: on the helper, which refuses the running system
bm_drive_protect() {
   local verb="$1" target="${2:-}" rc
   [[ $target == /dev/* ]] || { printf '%s\n' $"Name a device, such as /dev/sdb1." >&2; return 2; }
   bm_resolve "$target" || { bm_resolve_fail "$target"; return 24; }
   bm_helper "$verb" "$R_DEV"; rc=$?
   case "$rc" in
      0)
         if [ "$verb" = protect ]; then printf '%s\n' $"Writing is now blocked on this device until it is disconnected."
         else printf '%s\n' $"Writing is allowed on this device again."
         fi
         ;;
      3) printf '%s\n' $"Another volume of this drive is mounted with writing enabled. Unmount it first." >&2; return 3 ;;
      4) printf '%s\n' $"Refused: this drive holds the running system." >&2; return 4 ;;
      126 | 127) printf '%s\n' $"Permission was not granted." >&2; return 5 ;;
      *) printf $"The helper failed (exit %s)."'\n' "$rc" >&2; return 1 ;;
   esac
}

# The password goes from udisksctl to UDisks2: it never passes through us
bm_drive_unlock_volume() {
   local target="${1:-}"
   [[ $target == /dev/* ]] || { printf '%s\n' $"Name a device, such as /dev/sdb1." >&2; return 2; }
   bm_resolve "$target" || { bm_resolve_fail "$target"; return 24; }
   [ -t 0 ] || { printf '%s\n' $"Unlocking in the terminal needs an interactive terminal." >&2; return 2; }
   udisksctl unlock -b "$R_DEV"
}

bm_drive_main() {
   local cmd="${1:-}"
   bm_tui_init
   [ "$#" -gt 0 ] && shift
   BM_UI="tty"
   bm_ui_init
   case "$cmd" in
      "")
         bm_load drive-copy.sh
         bm_load drive-recovery.sh
         bm_load drive-tui.sh
         bm_tui_main
         ;;
      -h | --help | help) bm_drive_usage ;;
      list) bm_drive_list "$@" ;;
      inspect) bm_drive_inspect "$@" ;;
      diagnose) bm_drive_diagnose "$@" ;;
      mount) bm_drive_mount "$@" ;;
      unmount) bm_drive_unmount "$@" ;;
      protect | unprotect) bm_drive_protect "$cmd" "$@" ;;
      unlock) bm_drive_unlock_volume "$@" ;;
      destinations | copy | jobs | status | pause | cancel | resume | report | __run)
         bm_load drive-copy.sh
         bm_load drive-recovery.sh
         bm_job_cmd "$cmd" "$@"
         ;;
      image | partitions | carve)
         bm_load drive-copy.sh
         bm_load drive-recovery.sh
         bm_rec_cmd "$cmd" "$@"
         ;;
      *) bm_drive_badarg "$cmd"; return 2 ;;
   esac
}

# bigmount --gui-drive [DISK]: the manager when Qt is available, otherwise the
# drive check in dialogs, which keeps working with KDialog and Zenity alone
bm_gui_drive_main() {
   local py="$BM_LIB_DIR/drive-gui.py" target=()
   # Dolphin hands over a folder: the window selects the drive it is on
   if [ -n "${1:-}" ] && bm_resolve "$1" && bm_facts "$R_DEV"; then target=("${F[DISK]}"); fi
   if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && [ "${BM_UI:-}" != tty ] && [ -z "${BM_NO_QT:-}" ] && [ -r "$py" ] &&
      [ "$EUID" -ne 0 ] && command -v python3 >/dev/null && python3 -I -c 'import PySide6.QtWidgets' 2>/dev/null; then
      exec python3 -I "$py" "${target[@]}"
   fi
   bm_ui_init
   bm_gui_drive "$@"
}
