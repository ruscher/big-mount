# shellcheck shell=bash
#
# big-mount entry points other than the boot automount: storage diagnosis,
# "what is using this device", safe removal and the session notifier.
#
# Exit codes: 0 done, 1 error, 2 usage, 3 device busy, 4 refused (holds the
# running system), 5 not authorized, 6 unmounted but still in use by a
# stacked device, 7 unmounted but the drive could not be powered off.

BM_LIB_DIR="${BIGMOUNT_LIB:-/usr/lib/big-mount}"
# shellcheck source=lib.sh
. "$BM_LIB_DIR/lib.sh"
# shellcheck source=ui.sh
. "$BM_LIB_DIR/ui.sh"

bm_usage() {
   printf $"Usage: bigmount [OPTION] [DEVICE|FOLDER]"'\n\n'
   # shellcheck disable=SC2247  # $"(none)" is a translatable string
   printf '  %-28s %s\n' \
      $"(none)" $"mount internal partitions (run at boot by big-mount.service)" \
      "--dry-run" $"show what would be mounted, change nothing" \
      "--diagnose [TARGET]" $"storage overview, or details of one device" \
      "--busy TARGET" $"show what keeps a device busy" \
      "--unmount TARGET" $"unmount one filesystem safely" \
      "--safe-remove TARGET" $"unmount every filesystem of the drive and power it off" \
      "  --close-apps" $"offer to close the programs that keep it busy" \
      "  --assume-yes" $"do not ask before closing them (scripts)" \
      "--gui [TARGET]" $"graphical diagnosis" \
      "--gui-remove TARGET" $"graphical safe removal" \
      "--notifier" $"session service: warn about read-only devices" \
      "-h, --help" $"show this help"
   printf '\n%s\n' $"TARGET is a device (/dev/sdb1) or any folder inside a mounted device."
}

bm_main() {
   local cmd="$1" a args=()
   shift
   # Relative paths are resolved now: we leave the current folder below
   for a in "$@"; do
      if [[ $a != -* && $a != /* ]]; then a="$PWD/$a"; fi
      args+=("$a")
   done
   # Dolphin may start us inside the very device we must release
   cd / || return 1
   case "$cmd" in
      -h | --help) bm_usage ;;
      --diagnose) BM_UI="tty"; bm_ui_init; bm_cmd_diagnose "${args[@]}" ;;
      --busy) BM_UI="tty"; bm_ui_init; bm_cmd_busy "${args[@]}" ;;
      --unmount) BM_UI="tty"; bm_ui_init; bm_cmd_remove unmount "${args[@]}" ;;
      --safe-remove) BM_UI="tty"; bm_ui_init; bm_cmd_remove remove "${args[@]}" ;;
      --gui) bm_ui_init; bm_gui_diagnose "${args[@]}" ;;
      --gui-remove) bm_ui_init; bm_gui_remove "${args[@]}" ;;
      --notifier) bm_ui_init; bm_notifier ;;
      *)
         printf $"bigmount: unknown option '%s' (see bigmount --help)"'\n' "$cmd" >&2
         return 2
         ;;
   esac
}

# ---------------------------------------------------------------------------
# Texts for each diagnosis (translatable, no markup)

# bm_cause_text CAUSE: C_TITLE, C_REASON, C_HELP (steps), C_FIX_LABEL, C_FIX_INFO
bm_cause_text() {
   C_TITLE="" C_REASON="" C_HELP=() C_FIX_LABEL="" C_FIX_INFO=""
   case "$1" in
      ok)
         C_TITLE=$"Device ready"
         C_REASON=$"You can read and write files on this device."
         ;;
      not-mounted)
         C_TITLE=$"Device not mounted"
         C_REASON=$"The filesystem is not mounted at the moment."
         C_HELP=($"Open the device in the file manager (Dolphin) to mount it.")
         ;;
      hw-readonly)
         C_TITLE=$"Device mounted read-only"
         C_REASON=$"The device itself is write-protected, so no system can write to it."
         C_HELP=($"SD cards and some USB drives have a small lock switch on the side. Remove the device, move the switch to the unlocked position and connect it again."
            $"If there is no switch, the device may have locked itself because of wear. Copy your files to another place as soon as possible.")
         ;;
      unsupported)
         C_TITLE=$"Device mounted read-only"
         C_REASON=$"This kind of filesystem cannot be written on Linux with the driver in use."
         C_HELP=($"CDs, DVDs and disk images (ISO, SquashFS) are read-only by nature."
            $"Drives formatted on a Mac (HFS+ with journaling, APFS) can only be read on Linux."
            $"To write to it, copy the files elsewhere and format the device with a filesystem such as exFAT. Formatting erases everything on it.")
         ;;
      ntfs-unsafe)
         C_TITLE=$"Device mounted read-only"
         C_REASON=$"Windows did not close this NTFS partition properly (hibernation, Fast Startup or an interrupted shutdown). Writing to it now could damage files."
         C_HELP=($"Start Windows and shut it down completely: hold the Shift key while you click Shut down."
            $"To avoid this in the future, disable Fast Startup in Windows: Control Panel > Power Options > Choose what the power buttons do."
            $"If it still happens, check the partition in Windows: open the Command Prompt as administrator and run chkdsk with the /f option for that drive letter."
            $"Big-Mount never repairs NTFS by itself, because the repair tools available on Linux may discard data that Windows still needs.")
         ;;
      fs-errors)
         C_TITLE=$"Filesystem error"
         C_REASON=$"The system found errors in the filesystem and stopped writing to it to protect your files."
         C_HELP=($"First copy your important files to another place."
            $"Then check the filesystem with the device unmounted, for example with KDE Partition Manager (Check)."
            $"Do not write to the device until it has been checked.")
         ;;
      io-errors)
         C_TITLE=$"Device with read or write errors"
         C_REASON=$"The device reported read or write errors. This is usually a bad cable, a weak USB port or a failing drive."
         C_HELP=($"Copy your important files to another place as soon as possible."
            $"Try another cable and connect the device directly to the computer, without a hub."
            $"Check the health of the drive in KDE Partition Manager (SMART status).")
         ;;
      mounted-ro)
         C_TITLE=$"Device mounted read-only"
         C_REASON=$"The filesystem was mounted read-only, but no problem was found with it."
         C_HELP=($"Mount it again with writing enabled.")
         C_FIX_LABEL=$"Mount again with writing"
         C_FIX_INFO=$"The device will be unmounted and mounted again with writing enabled. Nothing on it is changed. Programs using it must be closed first."
         ;;
      permission)
         C_TITLE=$"No permission to write"
         C_REASON=$"The device accepts writing, but its main folder belongs to another user and you are not allowed to change it."
         C_HELP=($"You can become the owner of the main folder. Only that folder changes: the files and folders inside it keep their owners."
            $"This is the usual fix for drives formatted with a Linux filesystem (ext4, Btrfs, XFS).")
         C_FIX_LABEL=$"Become owner of the main folder"
         C_FIX_INFO=$"The main folder of the device will belong to you (not recursive: the files and folders inside keep their owners). The administrator password may be requested."
         ;;
      permission-os)
         C_TITLE=$"No permission to write"
         C_REASON=$"This partition contains an operating system. Its folders belong to that system and must keep their owners."
         C_HELP=($"Save your files in a folder that belongs to you, for example your home folder on that system.")
         ;;
      permission-other-user)
         C_TITLE=$"No permission to write"
         C_REASON=$"The device was mounted for another user, so only that user can write to it."
         C_HELP=($"Unmount it and open it again from the file manager while you are logged in.")
         C_FIX_LABEL=$"Mount again for my user"
         C_FIX_INFO=$"The device will be unmounted and mounted again for your user. Nothing on it is changed. Programs using it must be closed first."
         ;;
      *)
         C_TITLE=$"Unknown state"
         C_REASON=$"The state of this device could not be determined."
         ;;
   esac
}

bm_fs_label() {
   case "$1" in
      ntfs) REPLY="NTFS" ;; vfat) REPLY="FAT32" ;; exfat) REPLY="exFAT" ;;
      ext4 | ext3 | ext2) REPLY="${1^^}" ;; btrfs) REPLY="Btrfs" ;; xfs) REPLY="XFS" ;;
      f2fs) REPLY="F2FS" ;; iso9660) REPLY="ISO 9660" ;; "") REPLY=$"unknown" ;;
      *) REPLY="$1" ;;
   esac
}

# Turn a diagnosis into the text cause key (permission on an OS partition is
# explained differently)
bm_cause_key() {
   REPLY="$D_CAUSE"
   if [ "$D_CAUSE" = permission ] && [ -z "$D_FIX" ]; then REPLY=permission-os; fi
}

# The mount point that matters among several: a system one if the device
# holds the running system, otherwise the first that is not a leftover of
# os-prober. MOUNTPOINTS from lsblk are separated by newlines.
bm_main_mountpoint() {
   local mp first="" sys=""
   while IFS= read -r mp; do
      [ -n "$mp" ] || continue
      [ "$mp" = "[SWAP]" ] && continue
      bm_is_system_mount "$mp" && { sys="$mp"; break; }
      [[ $mp == /var/lib/os-prober/* ]] && continue
      [ -n "$first" ] || first="$mp"
   done <<< "$1"
   REPLY="${sys:-$first}"
}

# Who mounted it
bm_manager() {
   local dev="$1" mp="$2"
   if [ -z "$mp" ]; then REPLY=""
   elif bm_is_system_mount "$mp"; then REPLY=$"system"
   elif findmnt --fstab --source "$dev" >/dev/null 2>&1; then REPLY="fstab"
   elif bm_boot_status "$dev"; then REPLY="big-mount"
   elif [[ $mp == /run/media/* || $mp == /media/* ]]; then REPLY="UDisks"
   elif [[ $mp == /mnt/* ]]; then REPLY="big-mount"
   else REPLY=$"other"
   fi
}

# Build the diagnosis document for the device in F (after bm_diagnose_write)
bm_diag_doc() {
   local dev="$1" key mp state
   bm_cause_key; key="$REPLY"
   bm_cause_text "$key"
   bm_doc_new
   bm_doc_h "$C_TITLE"
   bm_display_name; bm_doc_kv $"Device" "$REPLY"
   bm_doc_kv $"Path" "$dev"
   bm_fs_label "${F[FSTYPE]}"; bm_doc_kv $"Filesystem" "$REPLY"
   mp="$D_MP"
   if [ -n "$mp" ]; then
      bm_doc_kv $"Mounted at" "$mp"
      case "$D_CAUSE" in
         ok) state=$"Read and write" ;;
         permission*) state=$"Writable, but not by your user" ;;
         *) state=$"Read-only" ;;
      esac
      bm_doc_kv $"Status" "$state"
   else
      bm_doc_kv $"Status" $"Not mounted"
   fi
   bm_doc_p "$C_REASON"
   if [ "${#C_HELP[@]}" -gt 0 ]; then
      bm_doc_p $"How to solve:"
      local s; for s in "${C_HELP[@]}"; do bm_doc_li "$s"; done
   fi
   if [ "${#D_WARN[@]}" -gt 0 ]; then
      bm_doc_p $"Attention: the filesystem has recorded errors. Copy important files elsewhere and check it soon."
   fi
}

# Technical report for "Details" and for the terminal
bm_tech_report() {
   local dev="$1" i l
   printf '%s\n' "device:      $dev (${F[KNAME]}), disk ${F[DISK]}"
   printf '%s\n' "model:       ${F[VENDOR]} ${F[MODEL]}"
   printf '%s\n' "transport:   ${F[TRAN]:-?}  removable=${F[RM]} hotplug=${F[HOTPLUG]} ro(part)=${F[RO]} ro(disk)=${F[DISK_RO]}"
   printf '%s\n' "filesystem:  ${F[FSTYPE]} ${F[FSVER]} label='${F[LABEL]}' uuid=${F[UUID]}"
   bm_mounts "$dev"
   for i in "${!M_TARGET[@]}"; do
      printf '%s\n' "mount:       ${M_TARGET[i]} type=${M_FSTYPE[i]} vfs=${M_VFSOPT[i]} fs=${M_FSOPT[i]}"
   done
   bm_boot_status "$dev" && printf '%s\n' "big-mount:   $REPLY"
   printf '%s\n' "diagnosis:   ${D_CAUSE}${D_DETAIL:+ ($D_DETAIL)}${D_FIX:+ fix=$D_FIX}"
   for l in "${D_WARN[@]}"; do printf '%s\n' "warning:     $l"; done
   if [ "${#KMSG[@]}" -gt 0 ]; then
      printf '%s\n' "kernel:"
      for l in "${KMSG[@]: -10}"; do printf '             %s\n' "$l"; done
   fi
}

# ---------------------------------------------------------------------------
# --diagnose

bm_cmd_diagnose() {
   local target="${1:-}"
   if [ -z "$target" ]; then
      bm_overview
      return
   fi
   bm_resolve "$target" || { printf $"bigmount: '%s' is not a local storage device or a folder on one"'\n' "$target" >&2; return 1; }
   bm_facts "$R_DEV" || { printf $"bigmount: cannot read information about %s"'\n' "$R_DEV" >&2; return 1; }
   bm_diagnose_write "$R_DEV"
   bm_diag_doc "$R_DEV"
   bm_ui_show info "$C_TITLE"
   printf '\n%s\n' $"Technical details:"
   bm_tech_report "$R_DEV" | sed 's/^/  /'
   if [ -n "$D_MP" ]; then
      printf '\n'
      bm_busy_doc "$R_DEV" quiet
      if [ "$BUSY_COUNT" -gt 0 ]; then bm_ui_show info ""; fi
   fi
   [ "$D_CAUSE" = ok ] || [ "$D_CAUSE" = not-mounted ]
}

# Overview of every filesystem, plus a quick self-check of the environment
bm_overview() {
   local line dev fstype label size mp state mgr hint=0
   printf '%s\n\n' $"Storage devices"
   printf '  %-16s %-18s %8s %-7s %-14s %-30s %s\n' \
      $"DEVICE" $"LABEL" $"SIZE" $"FS" $"MANAGED BY" $"MOUNTED AT" $"STATE"
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      dev="${KV[NAME]}" fstype="${KV[FSTYPE]}" label="${KV[LABEL]}"
      bm_main_mountpoint "${KV[MOUNTPOINTS]}"; mp="$REPLY"
      case "$fstype" in "" | swap | squashfs | crypto_LUKS | LVM2_member | *_member) continue ;; esac
      [ "${KV[TYPE]}" = loop ] && [ -z "$mp" ] && continue
      bm_human_size "${KV[SIZE]}"; size="$REPLY"
      bm_manager "$dev" "$mp"; mgr="${REPLY:--}"
      if [ -z "$mp" ]; then
         state=$"not mounted"
      elif bm_is_system_mount "$mp"; then
         state=$"in use by the system"
      elif findmnt -n -o VFS-OPTIONS --mountpoint "$mp" 2>/dev/null | grep -qE '(^|,)ro(,|$)'; then
         state=$"READ-ONLY"; hint=1
      elif [ -w "$mp" ]; then
         state=$"read and write"
      else
         state=$"no write permission"; hint=1
      fi
      label="${label//[[:cntrl:]]/?}" mp="${mp//[[:cntrl:]]/?}"
      printf '  %-16s %-18.18s %8s %-7s %-14s %-30s %s\n' "$dev" "${label:--}" "$size" "$fstype" "$mgr" "${mp:--}" "$state"
   done < <(lsblk -P -b -p -o NAME,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS 2>/dev/null)
   [ "$hint" -eq 1 ] && printf '\n%s\n' $"To find out why a device cannot be written to, run: bigmount --diagnose DEVICE"

   printf '\n%s\n' $"Environment"
   local s
   s="$(systemctl is-enabled big-mount.service 2>/dev/null)"; printf '  %-28s %s\n' "big-mount.service" "${s:-?}"
   [ -e /etc/bigmountall-no ] && printf '  %-28s %s\n' "/etc/bigmountall-no" $"present: automount disabled"
   if busctl --system --no-pager status org.freedesktop.UDisks2 >/dev/null 2>&1; then s=$"available"; else s=$"not available"; fi
   printf '  %-28s %s\n' "UDisks2" "$s"
   for s in lsof kdialog notify-send; do
      if command -v "$s" >/dev/null; then printf '  %-28s %s\n' "$s" $"installed"; else printf '  %-28s %s\n' "$s" $"missing"; fi
   done
   if journalctl -k -b -n 1 -q >/dev/null 2>&1 && [ -n "$(journalctl -k -b -n 1 -q 2>/dev/null)" ]; then s=$"readable"; else s=$"not readable (fewer details for errors)"; fi
   printf '  %-28s %s\n' $"kernel log" "$s"
}

# ---------------------------------------------------------------------------
# What keeps a device busy

# bm_busy_collect DEV [LSOF_FILE]: processes and other users of every mount
# of DEV. Fills the BUSY_* arrays and BUSY_COUNT.
bm_busy_collect() {
   local dev="$1" src="${2:-}" mp i
   BUSY_PID=() BUSY_UID=() BUSY_USER=() BUSY_COMM=() BUSY_APP=() BUSY_FD=() BUSY_ACCESS=() BUSY_PATH=() BUSY_START=() BUSY_STATE=()
   BUSY_PIDS=()
   bm_mounts "$dev"
   local mps=("${M_TARGET[@]}")
   for mp in "${mps[@]}"; do
      bm_holders "$mp" "$src"
      for i in "${!H_PID[@]}"; do
         BUSY_PID+=("${H_PID[i]}") BUSY_UID+=("${H_UID[i]}") BUSY_USER+=("${H_USER[i]}")
         BUSY_COMM+=("${H_COMM[i]}") BUSY_APP+=("${H_APP[i]}") BUSY_FD+=("${H_FD[i]}")
         BUSY_ACCESS+=("${H_ACCESS[i]}") BUSY_PATH+=("${H_PATH[i]}") BUSY_START+=("${H_START[i]}")
         BUSY_STATE+=("${H_STATE[i]}")
      done
      for i in "${H_PIDS[@]}"; do [[ " ${BUSY_PIDS[*]} " == *" $i "* ]] || BUSY_PIDS+=("$i"); done
   done
   bm_other_holders "$dev"
   BUSY_COUNT=$((${#BUSY_PIDS[@]} + ${#O_KIND[@]}))
}

# Present a BUSY collection through the bm_holders arrays (for close checks)
bm_busy_as_holders() {
   H_PID=("${BUSY_PID[@]}") H_UID=("${BUSY_UID[@]}") H_COMM=("${BUSY_COMM[@]}")
   H_ACCESS=("${BUSY_ACCESS[@]}")
}

bm_other_label() {
   case "$1" in
      mount) printf -v REPLY $"Also mounted at %s" "$2" ;;
      nested) printf -v REPLY $"Another device is mounted inside it: %s" "$2" ;;
      swapfile) printf -v REPLY $"A swap file on it is in use: %s" "$2" ;;
      swap) REPLY=$"It is in use as swap space" ;;
      loop) printf -v REPLY $"A disk image stored on it is attached: %s" "$2" ;;
      holder) printf -v REPLY $"It is used by %s (encryption, LVM or RAID)" "$2" ;;
      *) REPLY="$2" ;;
   esac
}

# bm_busy_doc DEV [quiet] [privileged]: document describing what keeps DEV busy
bm_busy_doc() {
   local dev="$1" mode="${2:-}" priv="${3:-}" i key shown=() access
   bm_busy_collect "$dev" "${BM_PRIV_LSOF:-}"
   bm_facts "$dev"
   bm_doc_new
   if [ "$mode" = quiet ]; then
      [ "$BUSY_COUNT" -gt 0 ] || return 0
      bm_doc_h $"In use"
   else
      bm_doc_h $"This device is still in use"
      bm_display_name; bm_doc_kv $"Device" "$REPLY"
      bm_fs_label "${F[FSTYPE]}"; bm_doc_kv $"Filesystem" "$REPLY"
      bm_mounts "$dev"; [ "${#M_TARGET[@]}" -gt 0 ] && bm_doc_kv $"Mounted at" "${M_TARGET[0]}"
   fi
   if [ "${#BUSY_PIDS[@]}" -gt 0 ]; then
      bm_doc_p $"Programs using it:"
      if [ -n "$priv" ]; then
         bm_doc_th $"Application"$'\n'$"process" "PID" $"User" $"Activity"
      else
         bm_doc_th $"Application"$'\n'$"process" "PID" $"Activity"
      fi
      for i in "${!BUSY_PID[@]}"; do
         bm_access_label "${BUSY_FD[i]}" "${BUSY_ACCESS[i]}" ""
         access="$REPLY"
         key="${BUSY_PID[i]}|$access"
         [[ " ${shown[*]} " == *" $key "* ]] && continue
         shown+=("$key")
         if [ -n "$priv" ]; then
            bm_doc_tr "${BUSY_APP[i]}"$'\n'"${BUSY_COMM[i]}" "${BUSY_PID[i]}" "${BUSY_USER[i]:-${BUSY_UID[i]}}" "$access"
         else
            bm_doc_tr "${BUSY_APP[i]}"$'\n'"${BUSY_COMM[i]}" "${BUSY_PID[i]}" "$access"
         fi
      done
   fi
   if [ "${#O_KIND[@]}" -gt 0 ]; then
      bm_doc_p $"Also keeping it busy:"
      for i in "${!O_KIND[@]}"; do bm_other_label "${O_KIND[i]}" "${O_WHAT[i]}"; bm_doc_li "$REPLY"; done
   fi
   [ "$mode" = quiet ] && return 0
   if [ "$BUSY_COUNT" -eq 0 ]; then
      bm_doc_p $"None of your programs is using it. A system service or a program of another user may be holding it, or it was released a moment ago."
   fi
   bm_doc_p $"Close the programs listed, or leave the device's folders in them, then try again. An open file does not necessarily mean that something is being copied."
}

bm_busy_details_file() {
   local f="$1" i
   {
      printf '%s\n' "$(bm_tech_report "$2" 2>/dev/null)"
      printf '\n%s\n' "open files:"
      for i in "${!BUSY_PID[@]}"; do
         printf '  pid=%s user=%s state=%s comm=%s fd=%s access=%s\n      %s\n' \
            "${BUSY_PID[i]}" "${BUSY_USER[i]:-${BUSY_UID[i]}}" "${BUSY_STATE[i]}" "${BUSY_COMM[i]}" \
            "${BUSY_FD[i]}" "${BUSY_ACCESS[i]:--}" "${BUSY_PATH[i]//[[:cntrl:]]/?}"
      done
      for i in "${!O_KIND[@]}"; do printf '  %s: %s\n' "${O_KIND[i]}" "${O_WHAT[i]}"; done
   } > "$f"
}

bm_cmd_busy() {
   bm_resolve "${1:-}" || { printf $"bigmount: '%s' is not a local storage device or a folder on one"'\n' "${1:-}" >&2; return 1; }
   bm_busy_doc "$R_DEV"
   bm_ui_show info ""
   [ "$BUSY_COUNT" -eq 0 ] && return 0
   return 3
}

# ---------------------------------------------------------------------------
# Safe removal

# Drives that are meant to be unplugged (and powered off before that)
bm_is_removable_drive() {
   [ "${F[TRAN]:-}" = usb ] || [ "${F[TRAN]:-}" = ieee1394 ] || [ "${F[HOTPLUG]:-0}" = 1 ] || [ "${F[RM]:-0}" = 1 ]
}

# bm_remove_core MODE DEV: MODE "unmount" (one filesystem), "drive" (every
# filesystem of the drive) or "remove" (drive, then power off when it is a
# removable drive). Returns the exit codes documented at the top.
# RM_BUSY_DEV, RM_REASON, RM_POWERED and RM_REMOVABLE describe the outcome.
bm_remove_core() {
   local mode="$1" dev="$2" d i t targets=() rc
   RM_BUSY_DEV="" RM_REASON="" RM_POWERED=0 RM_REMOVABLE=0
   bm_facts "$dev" || { RM_REASON=$"device not found"; return 1; }
   local disk="${F[DISK]}" disk_type="${F[DISK_TYPE]}"
   bm_is_removable_drive && RM_REMOVABLE=1
   if [ "$mode" != unmount ]; then
      if bm_system_use "$disk"; then RM_REASON="$REPLY"; return 4; fi
      bm_drive_members "$disk"
      targets=("${DRIVE_DEVS[@]}")
   else
      bm_mounts "$dev"
      for t in "${M_TARGET[@]}"; do
         bm_is_system_mount "$t" && { RM_REASON="$dev → $t"; return 4; }
      done
      targets=("$dev")
   fi
   # Stacked devices (LUKS, LVM) come after their parents in lsblk: go backwards
   for ((i = ${#targets[@]} - 1; i >= 0; i--)); do
      d="${targets[i]}"
      bm_mounts "$d"
      [ "${#M_TARGET[@]}" -eq 0 ] && continue
      if ! bm_unmount_all "$d"; then
         case "$UD_ERROR" in
            *DeviceBusy*) RM_BUSY_DEV="$d"; return 3 ;;
            *NotAuthorized*) return 5 ;;
            *) RM_REASON="$UD_MESSAGE"; return 1 ;;
         esac
      fi
   done
   [ "$mode" = remove ] || return 0
   # Internal disks are unmounted, never powered off
   [ "$RM_REMOVABLE" = 1 ] || return 0

   # Nothing may use the drive any more before it is powered off
   for d in "${targets[@]}"; do
      bm_other_holders "$d"
      for i in "${!O_KIND[@]}"; do
         if [ "${O_KIND[i]}" = holder ] || [ "${O_KIND[i]}" = swap ]; then
            bm_other_label "${O_KIND[i]}" "${O_WHAT[i]}"; RM_REASON="$d: $REPLY"; return 6
         fi
      done
   done
   [ "$disk_type" = loop ] && return 7
   if bm_udisks power-off -b "$disk"; then
      RM_POWERED=1
      return 0
   fi
   rc=7
   [[ $UD_ERROR == *NotAuthorized* ]] && rc=5
   RM_REASON="$UD_MESSAGE"
   return "$rc"
}

# Eligible processes to close: CLOSE_PIDS/CLOSE_STARTS/CLOSE_NAMES, others in KEEP_*
bm_close_candidates() {
   local i pid
   local -A seen_pid=()
   CLOSE_PIDS=() CLOSE_STARTS=() CLOSE_NAMES=() KEEP_NAMES=() KEEP_WHY=()
   bm_busy_as_holders
   for i in "${!BUSY_PID[@]}"; do
      pid="${BUSY_PID[i]}"
      [ -n "${seen_pid[$pid]:-}" ] && continue
      seen_pid[$pid]=1
      if bm_close_refusal "$i"; then
         CLOSE_PIDS+=("$pid") CLOSE_STARTS+=("${BUSY_START[i]}") CLOSE_NAMES+=("${BUSY_APP[i]} (${BUSY_COMM[i]}, PID $pid)")
      else
         KEEP_NAMES+=("${BUSY_APP[i]} (${BUSY_COMM[i]}, PID $pid)") KEEP_WHY+=("$REPLY")
      fi
   done
}

bm_close_args() {
   local i
   CLOSE_ARGS=()
   for i in "${!CLOSE_PIDS[@]}"; do CLOSE_ARGS+=("${CLOSE_PIDS[i]}" "${CLOSE_STARTS[i]}"); done
}

bm_cmd_remove() {
   local mode="$1" target="" close=0 yes=0 a rc tries=0
   shift
   for a in "$@"; do
      case "$a" in
         --close-apps) close=1 ;;
         --assume-yes) yes=1 ;;
         --no-power-off) [ "$mode" = remove ] && mode=drive ;;
         -*) printf $"bigmount: unknown option '%s' (see bigmount --help)"'\n' "$a" >&2; return 2 ;;
         *) target="$a" ;;
      esac
   done
   bm_resolve "$target" || { printf $"bigmount: '%s' is not a local storage device or a folder on one"'\n' "$target" >&2; return 1; }
   local dev="$R_DEV"
   while :; do
      bm_remove_core "$mode" "$dev"; rc=$?
      case "$rc" in
         0)
            if [ "$RM_POWERED" = 1 ]; then
               printf '%s\n' $"Device removed safely. It can be disconnected now."
            else
               printf '%s\n' $"Unmounted. Everything was written to the device."
            fi
            return 0
            ;;
         3)
            bm_busy_doc "$RM_BUSY_DEV"
            bm_ui_show warning ""
            [ "$close" -eq 1 ] && [ "$tries" -eq 0 ] || return 3
            tries=1
            bm_close_candidates
            for a in "${!KEEP_NAMES[@]}"; do printf '  %s: %s\n' "${KEEP_NAMES[a]}" "${KEEP_WHY[a]}"; done
            [ "${#CLOSE_PIDS[@]}" -gt 0 ] || return 3
            printf '%s\n' $"These programs can be asked to close (unsaved changes in them may be lost):"
            printf '  %s\n' "${CLOSE_NAMES[@]}"
            if [ "$yes" -eq 0 ]; then
               bm_doc_new
               bm_ui_confirm "" "" $"Close them" $"Cancel" || return 3
            fi
            bm_close_args
            bm_close_processes "${CLOSE_ARGS[@]}" || printf $"Still running: %s"'\n' "${CLOSE_LEFT[*]}"
            ;;
         4) printf $"Refused: this drive holds the running system (%s)."'\n' "$RM_REASON" >&2; return 4 ;;
         5) printf '%s\n' $"Permission to unmount was not granted." >&2; return 5 ;;
         6) printf $"Unmounted, but the drive is still in use (%s), so it was not powered off."'\n' "$RM_REASON" >&2; return 6 ;;
         7) printf '%s\n' $"Unmounted. This drive cannot be powered off by the computer; it can be disconnected now." ; return 7 ;;
         *) printf $"Could not unmount: %s"'\n' "$RM_REASON" >&2; return 1 ;;
      esac
   done
}

# ---------------------------------------------------------------------------
# Graphical diagnosis (bigmount --gui)

bm_pick_device() {
   local line items=() dev label mp
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      dev="${KV[NAME]}" label="${KV[LABEL]}"
      bm_main_mountpoint "${KV[MOUNTPOINTS]}"; mp="$REPLY"
      case "${KV[FSTYPE]}" in "" | swap | squashfs | crypto_LUKS | LVM2_member | *_member) continue ;; esac
      [ -n "$mp" ] && bm_is_system_mount "$mp" && continue
      [ "${KV[TYPE]}" = loop ] && [ -z "$mp" ] && continue
      bm_human_size "${KV[SIZE]}"
      items+=("$dev" "${label:-${dev##*/}} — $REPLY ${KV[FSTYPE]}${mp:+ — $mp}")
   done < <(lsblk -P -b -p -o NAME,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS 2>/dev/null)
   if [ "${#items[@]}" -eq 0 ]; then
      bm_doc_new; bm_doc_p $"No storage device to diagnose was found."
      bm_ui_show info $"Storage diagnostics" drive-harddisk
      return 1
   fi
   bm_ui_menu $"Storage diagnostics" $"Choose a device:" "${items[@]}"
   [ -n "$REPLY" ]
}

bm_gui_diagnose() {
   local target="${1:-}" key icon tmp
   if [ -z "$target" ]; then
      bm_pick_device || return 0
      target="$REPLY"
   fi
   if ! bm_resolve "$target" || ! bm_facts "$R_DEV"; then
      bm_doc_new; bm_doc_p $"This folder is not on a local storage device."
      bm_ui_show info $"Storage diagnostics" drive-harddisk
      return 1
   fi
   local dev="$R_DEV"
   while :; do
      bm_facts "$dev"
      bm_diagnose_write "$dev"
      bm_diag_doc "$dev"
      bm_device_icon; icon="$REPLY"
      [ "$D_CAUSE" = ok ] || icon=dialog-warning
      if [ -n "$D_FIX" ]; then
         bm_ui_choice "$C_TITLE" "$icon" "$C_FIX_LABEL" $"Technical details" $"Close"
      elif bm_is_removable_drive && [ -n "$D_MP" ]; then
         bm_ui_choice "$C_TITLE" "$icon" $"Technical details" $"Safely remove…" $"Close"
         case "$REPLY" in 1) REPLY=2 ;; 2) REPLY=4 ;; esac
      elif bm_ui_confirm "$C_TITLE" "$icon" $"Technical details" $"Close"; then
         REPLY=2
      else
         REPLY=3
      fi
      case "$REPLY" in
         1) bm_gui_fix "$dev" ;;
         2)
            tmp="$(mktemp)"; bm_tech_report "$dev" > "$tmp"
            bm_ui_text $"Technical details" "$tmp"; rm -f -- "$tmp"
            ;;
         4) bm_gui_remove "$dev"; return ;;
         *) return 0 ;;
      esac
   done
}

# Only the help text (notification action "How to solve")
bm_gui_help() {
   bm_resolve "${1:-}" && bm_facts "$R_DEV" || return 1
   bm_diagnose_write "$R_DEV"
   bm_cause_key; bm_cause_text "$REPLY"
   bm_doc_new
   bm_doc_h $"How to solve"
   bm_doc_p "$C_REASON"
   local s; for s in "${C_HELP[@]}"; do bm_doc_li "$s"; done
   bm_ui_show info "$C_TITLE" help-about
}

# Apply the safe correction found by the diagnosis, after confirmation
bm_gui_fix() {
   local dev="$1" fix="$D_FIX" mp="$D_MP" ok=0
   bm_cause_text "$D_CAUSE"
   bm_doc_new
   bm_doc_h "$C_FIX_LABEL"
   bm_doc_p "$C_FIX_INFO"
   bm_ui_confirm "$C_FIX_LABEL" dialog-question "$C_FIX_LABEL" $"Cancel" || return 0
   case "$fix" in
      take-ownership)
         bm_take_ownership "$dev"
         [ -w "$mp" ] && ok=1
         ;;
      remount)
         if bm_unmount_all "$dev"; then
            if bm_udisks mount -b "$dev"; then
               bm_diagnose_write "$dev"
               [ "$D_CAUSE" = ok ] && ok=1
            fi
         elif [[ $UD_ERROR == *DeviceBusy* ]]; then
            bm_gui_busy_dialog "$dev"
            return 0
         fi
         ;;
   esac
   bm_doc_new
   if [ "$ok" -eq 1 ]; then
      bm_doc_h $"Done"
      bm_doc_p $"You can now write to this device."
      bm_ui_show info "$C_FIX_LABEL" dialog-ok
   else
      bm_doc_h $"It was not possible to fix it"
      bm_doc_p $"Nothing was changed on the device. See the technical details for more information."
      [ -n "${UD_MESSAGE:-}" ] && bm_doc_pre "$UD_MESSAGE"
      bm_ui_show error "$C_FIX_LABEL" dialog-error
   fi
}

# ---------------------------------------------------------------------------
# Graphical safe removal (bigmount --gui-remove, Dolphin action)

# Busy dialog: returns 0 to try again, 1 to give up
bm_gui_busy_dialog() {
   local dev="$1" priv="" tmp self
   BM_PRIV_LSOF=""
   while :; do
      bm_busy_doc "$dev" "" "$priv"
      bm_device_icon
      bm_ui_choice $"Device in use" dialog-warning $"Try again" $"More options…" $"Cancel"
      case "$REPLY" in
         1) BM_PRIV_LSOF=""; return 0 ;;
         3) BM_PRIV_LSOF=""; return 1 ;;
      esac
      local opts=(refresh $"Refresh the list" details $"Show technical details")
      bm_close_candidates
      [ "${#CLOSE_PIDS[@]}" -gt 0 ] && opts+=(close $"Close the listed programs…")
      command -v pkexec >/dev/null && opts+=(admin $"Show programs of all users (administrator)")
      bm_ui_menu $"Device in use" $"What do you want to do?" "${opts[@]}"
      case "$REPLY" in
         details)
            tmp="$(mktemp)"; bm_busy_details_file "$tmp" "$dev"
            bm_ui_text $"Technical details" "$tmp"; rm -f -- "$tmp"
            ;;
         close)
            bm_doc_new
            bm_doc_h $"Close these programs?"
            local n; for n in "${CLOSE_NAMES[@]}"; do bm_doc_li "$n"; done
            bm_doc_p $"They will be asked to close, as when you close their windows. Unsaved changes in them may be lost: if possible, close them yourself instead."
            if [ "${#KEEP_NAMES[@]}" -gt 0 ]; then
               bm_doc_p $"These will not be closed:"
               for n in "${!KEEP_NAMES[@]}"; do bm_doc_li "${KEEP_NAMES[n]}: ${KEEP_WHY[n]}"; done
            fi
            if bm_ui_confirm $"Close programs" dialog-warning $"Close them" $"Cancel"; then
               bm_close_args
               bm_close_processes "${CLOSE_ARGS[@]}"
               return 0
            fi
            ;;
         admin)
            # Only this small helper runs as root (polkit action
            # org.biglinux.big-mount.inspect-processes); the dialogs stay
            # in the user session
            self="$BM_LIB_DIR/bigmount-holders"
            tmp="$(mktemp)"
            bm_mounts "$dev"
            local mp; for mp in "${M_TARGET[@]}"; do
               pkexec "$self" "$mp" >> "$tmp" 2>/dev/null
            done
            if [ -s "$tmp" ]; then BM_PRIV_LSOF="$tmp"; priv=1; fi
            ;;
      esac
   done
}

bm_gui_remove() {
   local target="${1:-}" rc name icon
   if ! bm_resolve "$target" || ! bm_facts "$R_DEV"; then
      bm_doc_new; bm_doc_p $"This folder is not on a removable storage device."
      bm_ui_show info $"Safely remove" drive-harddisk
      return 1
   fi
   local dev="$R_DEV"
   bm_display_name; name="$REPLY"
   bm_device_icon; icon="$REPLY"
   while :; do
      bm_remove_core remove "$dev"; rc=$?
      bm_doc_new
      case "$rc" in
         0)
            if [ "$RM_POWERED" = 1 ]; then
               bm_notify "$icon" $"Device removed safely" \
                  "$name"$'\n'$"All pending data was written. The device can be disconnected now." >/dev/null &
            else
               bm_notify "$icon" $"Device unmounted" \
                  "$name"$'\n'$"All pending data was written and its filesystems were unmounted." >/dev/null &
            fi
            return 0
            ;;
         7)
            bm_notify "$icon" $"Device unmounted" \
               "$name"$'\n'$"All pending data was written. This drive cannot be powered off by the computer, but it can be disconnected now." >/dev/null &
            return 0
            ;;
         3) bm_gui_busy_dialog "$RM_BUSY_DEV" || return 3 ;;
         4)
            bm_doc_h $"This device cannot be removed"
            bm_doc_p $"It holds the operating system that is running now."
            bm_doc_pre "$RM_REASON"
            bm_ui_show error $"Safely remove" dialog-error
            return 4
            ;;
         5)
            bm_doc_h $"Permission not granted"
            bm_doc_p $"The device was not unmounted because the authorization was refused or cancelled. It remains mounted."
            bm_ui_show error $"Safely remove" dialog-error
            return 5
            ;;
         6)
            bm_doc_h $"Device still in use"
            bm_doc_p $"The filesystems were unmounted, but the drive is still in use, so it was not powered off. Lock encrypted volumes in the file manager first."
            bm_doc_pre "$RM_REASON"
            bm_ui_show warning $"Safely remove" dialog-warning
            return 6
            ;;
         *)
            bm_doc_h $"The device could not be unmounted"
            bm_doc_p $"It remains mounted. Nothing was forced."
            bm_doc_pre "$RM_REASON"
            bm_ui_show error $"Safely remove" dialog-error
            return 1
            ;;
      esac
   done
}

# ---------------------------------------------------------------------------
# Session notifier (bigmount --notifier, started by XDG autostart)
#
# Waits for mount events (findmnt --poll: the kernel wakes it up, there is no
# periodic scan) and warns once per boot and device when a removable or
# big-mount device cannot be written to. The GUI never runs as root: the
# boot service only leaves /run/big-mount/status for us to read.

bm_notifier_key() {
   local boot=""
   read -r boot < /proc/sys/kernel/random/boot_id 2>/dev/null
   REPLY="$boot ${F[UUID]:-${1##*/}} $D_CAUSE"
}

bm_notifier_check() {
   local dev="$1" mp="$2" key cause body icon name l_details l_help acts=()
   [[ $dev == /dev/* ]] || return 0
   case "$mp" in
      /run/media/"$USER"/* | /media/* | /mnt/*) ;;
      *) return 0 ;;
   esac
   [ "$mp" = /mnt/user-mount ] && return 0
   bm_facts "$dev" || return 0
   # Optical discs and images are read-only by nature: nothing to explain
   [ "${F[DISK_TYPE]}" = rom ] && return 0
   case "${F[FSTYPE]}" in squashfs | iso9660 | erofs | udf) return 0 ;; esac
   bm_diagnose_write "$dev"
   case "$D_CAUSE" in ok | not-mounted | unsupported) return 0 ;; esac
   bm_notifier_key "$dev"; key="$REPLY"
   grep -qxF -- "$key" "$BM_NOTIFIED" 2>/dev/null && return 0
   printf '%s\n' "$key" >> "$BM_NOTIFIED"

   bm_cause_key; cause="$REPLY"
   bm_cause_text "$cause"
   bm_display_name; name="$REPLY"
   bm_fs_label "${F[FSTYPE]}"
   printf -v body $"Device: %s\nFilesystem: %s\nPossible reason: %s" "$name" "$REPLY" "$C_REASON"
   bm_device_icon; icon="$REPLY"
   l_details=$"View details" l_help=$"How to solve"
   acts=("details=$l_details" "help=$l_help")
   # Offered only when a safe, verifiable correction exists for this cause
   [ -n "$D_FIX" ] && acts+=("fix=$C_FIX_LABEL")
   (
      action="$(bm_notify "$icon" "$C_TITLE" "$body" "${acts[@]}")"
      case "$action" in
         details | fix) "$BM_SELF" --gui "$dev" ;;
         help) bm_gui_help "$dev" ;;
      esac
   ) </dev/null >/dev/null &
}

bm_notifier() {
   local line rundir="${XDG_RUNTIME_DIR:-/run/user/$EUID}" statedir="${XDG_STATE_HOME:-$HOME/.local/state}/big-mount"
   BM_SELF="$(readlink -f "$BM_LIB_DIR/../../bin/bigmount")"
   [ -x /usr/bin/bigmount ] && [ "$BM_LIB_DIR" = /usr/lib/big-mount ] && BM_SELF=/usr/bin/bigmount
   mkdir -p -- "$statedir" || return 1
   BM_NOTIFIED="$statedir/notified"
   # Forget other boots: the list only prevents repeating within one boot
   if [ -f "$BM_NOTIFIED" ]; then
      local boot=""; read -r boot < /proc/sys/kernel/random/boot_id
      grep -F -- "$boot " "$BM_NOTIFIED" > "$BM_NOTIFIED.tmp" 2>/dev/null
      mv -f -- "$BM_NOTIFIED.tmp" "$BM_NOTIFIED"
   fi
   # One notifier per session
   exec 8> "$rundir/big-mount-notifier.lock" || return 1
   flock -n 8 || return 0

   # Devices already mounted at login (big-mount mounts them at boot)
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      bm_notifier_check "${KV[SOURCE]%%\[*}" "${KV[TARGET]}"
   done < <(findmnt -P -n -o SOURCE,TARGET 2>/dev/null)

   # Then react to mounts and remounts (errors=remount-ro shows up as one)
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      case "${KV[ACTION]}" in
         mount | remount)
            # Give UDisks a moment to finish (ownership, mount options)
            sleep 1
            bm_notifier_check "${KV[SOURCE]%%\[*}" "${KV[TARGET]}"
            ;;
      esac
   done < <(LC_ALL=C findmnt --poll=mount,remount -P -o ACTION,SOURCE,TARGET 2>/dev/null)
}
