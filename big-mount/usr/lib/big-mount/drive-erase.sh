# shellcheck shell=bash
# shellcheck disable=SC2034,SC2153  # RM_ALLOW_SERVICES is read by bm_remove_core; RM_REASON and others are set by it
#
# big-mount drive manager: Secure Erase for the application. Loaded on demand.
#
# Nothing new is erased here. bm_erase_check says who may be erased, and
# bm_erase_run does it, exactly as for bigmount --secure-erase. What this file
# adds is the dialogue with a window, which has no terminal:
#
#   erase-check DISK     what would be lost, and whether it is allowed at all
#   erase-prepare DISK   the same, and a ticket bound to this connection of this
#                        drive, kept 0600 in the runtime folder of the user
#   __erase-run TICKET --typed NAME [--allow-services] [--unfreeze]
#                        the erase. Not in the help, not for scripts
#
# There is no option that skips a question. The window asks twice, as the
# terminal does: the explanation with Cancel by default, then the name of the
# drive typed by a person. That name is compared HERE, a ticket works once, for
# ten minutes, and only while the drive is the same one (diskseq and serial).
# And then UDisks2 asks polkit, as always. A program running as this user could
# call UDisks2 directly anyway: polkit is the real barrier, and it stays.

BM_ERASE_TICKET_SECONDS=600

bm_er_dir() { REPLY="${XDG_RUNTIME_DIR:-/run/user/$EUID}/big-mount"; }

# The document built by bm_doc_*, as data. No markup: the window draws it.
bm_er_doc_json() {
   local i first=1 out=""
   for i in "${!DOC_KIND[@]}"; do
      [ "$first" = 1 ] && first=0 || out+=","
      out+="$(bm_jo kind "${DOC_KIND[i]}" text "${DOC_TEXT[i]}")"
   done
   printf '[%s]' "$out"
}

# What is on the drive (mounted or not), as data
bm_er_parts_json() {
   local disk="$1" line first=1 out=""
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      [ "${KV[NAME]}" = "$disk" ] && continue
      [ "$first" = 1 ] && first=0 || out+=","
      bm_main_mountpoint "${KV[MOUNTPOINTS]:-}"
      out+="{$(bm_jo_inner device "${KV[NAME]}" label "${KV[LABEL]:-}" fstype "${KV[FSTYPE]:-}" mountpoint "$REPLY"),$(bm_jn size "${KV[SIZE]:-}")}"
   done < <(lsblk -P -b -p -n -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINTS -- "$disk" 2>/dev/null)
   printf '[%s]' "$out"
}

# bm_er_facts TARGET: F, health and the check. Returns what bm_drive_disk does.
bm_er_facts() {
   local rc
   bm_drive_disk "$1"; rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   if [ "$R_DEV" != "$DD_DISK" ] || [ -n "${R_PATH:-}" ]; then
      printf $"bigmount: Secure Erase works on a whole drive: name the drive itself (%s)"'\n' "$DD_DISK" >&2
      return 2
   fi
   bm_facts "$DD_DISK" || return 24
   bm_drive_health "$DD_DISK"
   return 0
}

bm_er_check_json() {
   local disk="$1" token="${2:-}" eligible=0 why_text="" frozen=0 seq name
   if bm_erase_check "$disk"; then eligible=1; else bm_erase_refusal; why_text="$REPLY"; fi
   bm_udev_props "$disk"
   [ "${UP[ID_ATA_FEATURE_SET_SECURITY_FROZEN]:-0}" = 1 ] && frozen=1
   bm_diskseq "$disk"; seq="$REPLY"
   bm_display_name; name="$REPLY"
   bm_erase_table; local table="$REPLY"
   bm_is_block "$disk" || eligible=0
   printf '{%s,%s,%s,"partitions":%s}\n' \
      "$(bm_jo_inner device "$disk" name "$name" confirm_name "${disk##*/}" serial "$(lsblk -dn -o SERIAL -- "$disk" 2>/dev/null)" why "$ER_WHY" why_text "$why_text" detail "$ER_DETAIL" table "$table" token "$token")" \
      "$(bm_jb eligible "$eligible" frozen "$frozen")" \
      "$(bm_jn diskseq "$seq" erase_minutes "${DH_ERASE_MIN:-0}" size "${F[SIZE]:-}")" \
      "$(bm_er_parts_json "$disk")"
}

bm_er_cmd_check() {
   local target="" a rc
   for a in "$@"; do
      case "$a" in
         --json) ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   bm_er_facts "$target"; rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   bm_er_check_json "$DD_DISK"
}

# Identity of the drive, as it is now: what the ticket is bound to
bm_er_identity() {
   local serial
   bm_diskseq "$1"
   serial="$(lsblk -dn -o SERIAL -- "$1" 2>/dev/null)"
   REPLY="$REPLY|$serial"
}

bm_er_cmd_prepare() {
   local target="" a rc token dir f
   for a in "$@"; do
      case "$a" in
         --json) ;;
         -*) bm_drive_badarg "$a"; return 2 ;;
         *) target="$a" ;;
      esac
   done
   [ -n "$target" ] || { bm_drive_usage >&2; return 2; }
   bm_er_facts "$target"; rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   if ! bm_erase_check "$DD_DISK"; then
      bm_er_check_json "$DD_DISK"
      return 20
   fi
   bm_er_dir; dir="$REPLY"
   (umask 077; mkdir -p -- "$dir") || return 1
   # Tickets nobody used. Only the ones of this name pattern, and only here
   find "$dir" -maxdepth 1 -type f -name 'erase-*' -mmin +10 -delete 2>/dev/null
   token="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
   [[ $token =~ ^[0-9a-f]{32}$ ]] || return 1
   f="$dir/erase-$token"
   bm_er_identity "$DD_DISK"
   local now
   printf -v now '%(%s)T' -1
   (umask 077; printf '%s\n%s\n%s\n' "$DD_DISK" "$REPLY" "$now" > "$f") || return 1
   bm_er_check_json "$DD_DISK" "$token"
}

# bm_er_answer STAGE EXIT: the one answer of __erase-run, doc already built
bm_er_answer() {
   local stage="$1" rc="$2"
   printf '{%s,%s,%s,"doc":%s}\n' \
      "$(bm_jo_inner stage "$stage" title "${E_TITLE:-}" kind "${E_KIND:-info}" reason "${ER_REASON:-}" er_stage "${ER_STAGE:-}" busy_summary "${BUSY_SUMMARY:-}" busy_advice "${BUSY_ADVICE:-}")" \
      "$(bm_jb ok "$([ "$rc" -eq 0 ] && echo 1)")" "$(bm_jn exit "$rc")" "$(bm_er_doc_json)"
   return "$rc"
}

bm_er_refuse() { # WHY EXIT TEXT
   ER_REASON="$3" E_TITLE=$"Nothing was erased." E_KIND=error
   bm_doc_new
   bm_doc_p "$3"
   bm_er_answer "$1" "$2"
}

# The erase itself. Everything checked again here: the window may be stale.
bm_er_cmd_run() {
   local token="${1:-}" typed="" services=0 unfreeze=0 f dir disk identity created now rc table seq u
   shift || true
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --typed) typed="${2:-}"; shift ;;
         --allow-services) services=1 ;;
         --unfreeze) unfreeze=1 ;;
         --json) ;;
         *) bm_drive_badarg "$1"; return 2 ;;
      esac
      shift
   done
   ER_REASON="" ER_STAGE="" E_TITLE="" E_KIND=info BUSY_SUMMARY="" BUSY_ADVICE=""
   bm_er_dir; dir="$REPLY"
   f="$dir/erase-$token"
   if ! [[ $token =~ ^[0-9a-f]{32}$ ]] || [ ! -f "$f" ] || [ -L "$f" ]; then
      bm_er_refuse no-ticket 20 $"The confirmation is no longer valid. Nothing was erased. Start again."
      return
   fi
   { read -r disk; read -r identity; read -r created; } < "$f"
   printf -v now '%(%s)T' -1
   if ! [[ $created =~ ^[0-9]+$ ]] || [ $((now - created)) -gt "$BM_ERASE_TICKET_SECONDS" ]; then
      rm -f -- "$f"
      bm_er_refuse expired 20 $"The confirmation is no longer valid. Nothing was erased. Start again."
      return
   fi
   if [ "$typed" != "${disk##*/}" ]; then
      rm -f -- "$f"
      bm_er_refuse name-mismatch 5 $"The name did not match. Nothing was erased."
      return
   fi
   bm_er_identity "$disk"
   if [ "$REPLY" != "$identity" ] || ! bm_is_block "$disk"; then
      rm -f -- "$f"
      bm_er_refuse replaced 24 $"The drive was disconnected or replaced. Nothing was erased."
      return
   fi
   bm_facts "$disk" || { bm_er_refuse replaced 24 $"The drive was disconnected or replaced. Nothing was erased."; return; }
   bm_drive_health "$disk"
   if ! bm_erase_check "$disk"; then
      rm -f -- "$f"
      bm_erase_refusal
      bm_er_refuse refused 20 "$REPLY"
      return
   fi
   if ! bm_drive_lock "$disk"; then
      bm_er_refuse locked 10 $"Another operation on this drive is in progress. Nothing was done."
      return
   fi
   bm_diskseq "$disk"; seq="$REPLY"
   RM_ALLOW_SERVICES="$services"
   bm_remove_core release "$disk"; rc=$?
   case "$rc" in
      0) ;;
      3)
         bm_busy_doc "$RM_BUSY_DEV"; bm_busy_summary
         bm_drive_unlock
         bm_er_answer busy 3
         return
         ;;
      9)
         E_TITLE=$"Services use this device"
         bm_doc_new
         bm_doc_p $"Erasing it will stop these services:"
         for u in "${!RM_DEP_UNITS[@]}"; do bm_doc_li "${RM_DEP_NAMES[u]} (${RM_DEP_UNITS[u]})"; done
         bm_drive_unlock
         bm_er_answer services 9
         return
         ;;
      *)
         ER_REASON="$RM_REASON"
         [ "$rc" -eq 6 ] && rc=3
         bm_erase_result_doc "$rc" ""
         bm_drive_unlock
         bm_er_answer release "$rc"
         return
         ;;
   esac
   bm_udev_props "$disk"
   if [ "${UP[ID_ATA_FEATURE_SET_SECURITY_FROZEN]:-0}" = 1 ]; then
      if [ "$unfreeze" != 1 ]; then
         bm_erase_frozen_doc
         bm_drive_unlock
         bm_er_answer frozen 11
         return
      fi
      if ! bm_erase_unfreeze "$disk"; then
         bm_erase_result_doc 11 ""
         bm_drive_unlock
         bm_er_answer still-frozen 11
         return
      fi
   fi
   # From here on the ticket is spent, whatever happens
   rm -f -- "$f"
   bm_erase_table; table="$REPLY"
   bm_erase_run "$disk" "$seq" "$table"; rc=$?
   bm_drive_unlock
   bm_erase_result_doc "$rc" "$table"
   bm_er_answer finished "$rc"
}

bm_er_cmd() {
   local cmd="$1"
   shift
   case "$cmd" in
      erase-check) bm_er_cmd_check "$@" ;;
      erase-prepare) bm_er_cmd_prepare "$@" ;;
      __erase-run) bm_er_cmd_run "$@" ;;
   esac
}
