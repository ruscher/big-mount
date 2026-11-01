# shellcheck shell=bash
#
# big-mount entry points other than the boot automount: storage diagnosis,
# "what is using this device", safe removal, drive health, Secure Erase
# and the session notifier.
#
# Exit codes: 0 done, 1 error, 2 usage, 3 device busy, 4 refused (holds the
# running system), 5 not authorized or cancelled, 6 unmounted but still in
# use by a stacked device, 7 unmounted, the drive cannot be powered off by
# the computer, 8 unmounted but powering it off failed, 9 not done: services
# depend on the device and the user did not confirm stopping them, 10 not
# done: another operation on the same drive is in progress, 11 not erased:
# the drive stays frozen, 12 the drive did not do what it was told (the
# Secure Erase was ignored, or what was written afterwards was not kept).
# The drive manager adds 20 to 25 (drive.sh).

BM_LIB_DIR="${BIGMOUNT_LIB:-/usr/lib/big-mount}"
# shellcheck source=lib.sh
. "$BM_LIB_DIR/lib.sh"
# shellcheck source=ui.sh
. "$BM_LIB_DIR/ui.sh"

bm_usage() {
   printf $"Usage: bigmount [OPTION] [DEVICE|FOLDER]"'\n\n'
   # shellcheck disable=SC2247  # $"(none)" is a translatable string
   bm_fill $"(none)" 28; printf '  %s %s\n' "$REPLY" $"mount internal partitions (run at boot by big-mount.service)"
   printf '  %-28s %s\n' \
      "--dry-run" $"show what would be mounted, change nothing" \
      "--diagnose [TARGET]" $"storage overview, or details of one device (a whole disk: drive errors)" \
      "--busy TARGET" $"show what keeps a device busy" \
      "--unmount TARGET" $"unmount one filesystem safely" \
      "--safe-remove TARGET" $"unmount every filesystem of the drive and power it off" \
      "  --no-power-off" $"with --safe-remove: unmount everything, do not power it off" \
      "  --close-apps" $"offer to close the programs that keep it busy" \
      "  --assume-yes" $"do not ask before closing them or stopping services (scripts)" \
      "--gui [TARGET]" $"graphical diagnosis" \
      "--gui-remove TARGET" $"graphical safe removal" \
      "--secure-erase DISK" $"erase a whole SATA drive with its own Secure Erase (asks first)" \
      "--drive [COMMAND]" $"drive manager and file rescue in the terminal (bigmount --drive --help)" \
      "--gui-drive [DISK]" $"the application: drives, health and file rescue" \
      "--gui-drive-check [DISK]" $"the same application, opened on the health of the drive" \
      "--notifier" $"session service: warn about read-only devices" \
      "--doctor" $"check the installation and the storage stack (for bug reports)" \
      "-V, --version" $"show the version and the source revision" \
      "-h, --help" $"show this help"
   printf '\n%s\n' $"TARGET is a device (/dev/sdb1) or any folder inside a mounted device."
}

# Parts that only one command needs are loaded by that command
bm_load() {
   # shellcheck source=doctor.sh
   . "$BM_LIB_DIR/$1"
}

bm_main() {
   local cmd="$1" a args=()
   shift
   # The drive manager has subcommands and resolves paths on its own
   if [ "$cmd" = --drive ]; then
      # shellcheck disable=SC2034  # read by drive.sh
      BM_CWD="$PWD"
      cd / || return 1
      bm_load drive.sh && bm_drive_main "$@"
      return
   fi
   # The application takes a device, a folder or a UUID, which is not a path
   case "$cmd" in
      --gui-drive | --gui-drive-check)
         if [ "$#" -gt 0 ] && [ -z "$1" ]; then
            R_ERR=empty; bm_resolve_fail ""
            return 2
         fi
         # shellcheck disable=SC2034  # read by drive.sh
         BM_CWD="$PWD"
         cd / || return 1
         bm_load drive.sh || return 1
         if [ "$cmd" = --gui-drive-check ]; then bm_gui_drive_main health "$@"; else bm_gui_drive_main "" "$@"; fi
         return
         ;;
   esac
   # Relative paths are resolved now: we leave the current folder below
   for a in "$@"; do
      # An empty target must not silently become the current folder
      if [ -z "$a" ]; then
         R_ERR=empty; bm_resolve_fail ""
         return 2
      fi
      if [[ $a != -* && $a != /* ]]; then a="$PWD/$a"; fi
      args+=("$a")
   done
   # Dolphin may start us inside the very device we must release
   cd / || return 1
   case "$cmd" in
      -h | --help) bm_usage ;;
      -V | --version) bm_load doctor.sh && bm_cmd_version ;;
      --doctor) bm_load doctor.sh && bm_cmd_doctor "${args[@]}" ;;
      --diagnose) BM_UI="tty"; bm_ui_init; bm_cmd_diagnose "${args[@]}" ;;
      --busy) BM_UI="tty"; bm_ui_init; bm_cmd_busy "${args[@]}" ;;
      --unmount) BM_UI="tty"; bm_ui_init; bm_cmd_remove unmount "${args[@]}" ;;
      --safe-remove) BM_UI="tty"; bm_ui_init; bm_cmd_remove remove "${args[@]}" ;;
      --gui) bm_ui_init; bm_gui_diagnose "${args[@]}" ;;
      --gui-remove) bm_ui_init; bm_gui_remove "${args[@]}" ;;
      --secure-erase) BM_UI="tty"; bm_ui_init; bm_cmd_secure_erase "${args[@]}" ;;
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
         C_TITLE=$"Read-only device"
         C_REASON=$"The device itself is write-protected, so no system can write to it."
         C_HELP=($"SD cards and some USB drives have a small lock switch on the side. Remove the device, move the switch to the unlocked position and connect it again."
            $"If there is no switch, the device may have locked itself because of wear. Copy your files to another place as soon as possible.")
         ;;
      unsupported)
         C_TITLE=$"Read-only device"
         C_REASON=$"This kind of filesystem cannot be written on Linux with the driver in use."
         C_HELP=($"CDs, DVDs and disk images (ISO, SquashFS) are read-only by nature."
            $"Drives formatted on a Mac (HFS+ with journaling, APFS) can only be read on Linux."
            $"To write to it, copy the files elsewhere and format the device with a filesystem such as exFAT. Formatting erases everything on it.")
         ;;
      ntfs-unsafe)
         C_TITLE=$"Read-only device"
         C_REASON=$"Windows did not close this NTFS partition properly (hibernation, Fast Startup or an interrupted shutdown). Writing to it now could damage files."
         C_HELP=($"Start Windows and shut it down completely: hold the Shift key while you click Shut down."
            $"To avoid this in the future, disable Fast Startup in Windows: Control Panel > Power Options > Choose what the power buttons do."
            $"If it still happens, check the partition in Windows: open the Command Prompt as administrator and run chkdsk with the /f option for that drive letter."
            $"Big-Mount never repairs NTFS by itself, because the repair tools available on Linux may discard data that Windows still needs.")
         ;;
      fs-errors)
         C_TITLE=$"The filesystem needs attention"
         C_REASON=$"The system found errors in the filesystem and stopped writing to it to protect your files."
         C_HELP=($"First copy your important files to another place."
            $"Then check the filesystem with the device unmounted, for example with KDE Partition Manager (Check)."
            $"Do not write to the device until it has been checked.")
         ;;
      io-errors)
         C_TITLE=$"The device has read or write errors"
         C_REASON=$"The device reported read or write errors. This is usually a bad cable, a weak USB port or a failing drive."
         C_HELP=($"Copy your important files to another place as soon as possible."
            $"Try another cable and connect the device directly to the computer, without a hub."
            $"Check the health of the drive in KDE Partition Manager (SMART status).")
         ;;
      mounted-ro)
         C_TITLE=$"Read-only device"
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
      permission-folder)
         C_TITLE=$"No permission to write"
         printf -v C_REASON $"This folder belongs to %s, and only its owner can create or change files in it." "${D_OWNER:-?}"
         C_HELP=($"Save your files in a folder of your own, for example in your home folder.")
         ;;
      system)
         C_TITLE=$"System partition"
         C_REASON=$"This partition holds the operating system that is running now. Only the system and administrators write here."
         C_HELP=($"Save your files in your home folder.")
         ;;
      swap)
         C_TITLE=$"Swap space"
         C_REASON=$"This partition is used as swap space (virtual memory), not to store files."
         ;;
      permission-other-user)
         C_TITLE=$"No permission to write"
         C_REASON=$"The device was mounted for another user, so only that user can write to it."
         C_HELP=($"Unmount it and open it again from the file manager while you are logged in.")
         if [[ $D_MP == /mnt/* ]]; then
            C_HELP=($"This internal partition is mounted by Big-Mount at boot. An administrator can choose who may write to it with PERMISSIONS in /etc/big-mount.conf.")
         fi
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
      ext4 | ext3 | ext2) REPLY="$1" ;; btrfs) REPLY="Btrfs" ;; xfs) REPLY="XFS" ;;
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
   # Essentials only: the title already says the state, the device path is
   # in the technical details
   bm_display_name; bm_doc_kv $"Device" "$REPLY"
   bm_fs_label "${F[FSTYPE]}"; bm_doc_kv $"Filesystem" "$REPLY"
   mp="$D_MP"
   [ -n "$mp" ] && bm_doc_kv $"Mounted at" "$mp"
   [ -n "${D_PATH:-}" ] && bm_doc_kv $"Folder" "$D_PATH"
   case "$D_CAUSE" in
      permission | permission-other-user) state=$"Writable, but not by your user"; bm_doc_kv $"Status" "$state" ;;
   esac
   bm_doc_p "$C_REASON"
   if [ "${#C_HELP[@]}" -gt 0 ]; then
      bm_doc_p $"How to solve:"
      local s; for s in "${C_HELP[@]}"; do bm_doc_li "$s"; done
   fi
   if [ "${#D_WARN[@]}" -gt 0 ]; then
      bm_doc_p $"Attention: the filesystem has recorded errors. Copy important files elsewhere and check it soon."
   fi
   if [ "$DH_DISK" = "${F[DISK]:-}" ] && [ "${#DH_FIND[@]}" -gt 0 ]; then
      bm_doc_p $"Attention: the drive that holds this device reported errors since the computer was started. Copy important files elsewhere and check the drive."
   fi
}

# Health of the drive of the device in F, for the diagnosis of one of its
# filesystems (loop devices and optical drives have nothing to report)
bm_diag_drive() {
   DH_FIND=() DH_DISK=""
   [ "${F[DISK_TYPE]:-}" = disk ] && bm_drive_health "${F[DISK]}"
   return 0
}

# Technical report for "Details" and for the terminal
bm_tech_report() {
   local dev="$1" i l
   printf '%s\n' "device:      $dev (${F[KNAME]}), disk ${F[DISK]}"
   printf '%s\n' "model:       ${F[VENDOR]:+${F[VENDOR]} }${F[MODEL]}"
   printf '%s\n' "transport:   ${F[TRAN]:-?}  removable=${F[RM]} hotplug=${F[HOTPLUG]} ro(part)=${F[RO]} ro(disk)=${F[DISK_RO]}"
   printf '%s\n' "filesystem:  ${F[FSTYPE]} ${F[FSVER]} label='${F[LABEL]}' uuid=${F[UUID]}"
   bm_mounts "$dev"
   for i in "${!M_TARGET[@]}"; do
      printf '%s\n' "mount:       ${M_TARGET[i]} type=${M_FSTYPE[i]} vfs=${M_VFSOPT[i]} fs=${M_FSOPT[i]}"
   done
   bm_boot_status "$dev" && printf '%s\n' "big-mount:   $REPLY"
   printf '%s\n' "diagnosis:   ${D_CAUSE}${D_DETAIL:+ ($D_DETAIL)}${D_FIX:+ fix=$D_FIX}"
   for l in "${D_WARN[@]}"; do printf '%s\n' "warning:     $l"; done
   [ "$DH_DISK" = "${F[DISK]}" ] && [ "${#DH_FIND[@]}" -gt 0 ] &&
      printf '%s\n' "drive:       ${F[DISK]} reported: ${DH_FIND[*]} (bigmount --diagnose ${F[DISK]})"
   if [ "${#KMSG[@]}" -gt 0 ]; then
      printf '%s\n' "kernel:"
      for l in "${KMSG[@]:$((${#KMSG[@]} > 10 ? ${#KMSG[@]} - 10 : 0))}"; do printf '             %s\n' "$l"; done
   fi
}

# ---------------------------------------------------------------------------
# --diagnose

# Partitions of a whole disk that hold a filesystem (DISK_PARTS)
bm_disk_parts() {
   local line
   DISK_PARTS=()
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      [ "${KV[NAME]}" = "$1" ] && continue
      case "${KV[FSTYPE]}" in "" | crypto_LUKS | LVM2_member | *_member) continue ;; esac
      DISK_PARTS+=("${KV[NAME]}")
   done < <(lsblk -P -p -n -o NAME,FSTYPE -- "$1" 2>/dev/null)
}

bm_cmd_diagnose() {
   local target="${1:-}" part rc=0
   if [ -z "$target" ]; then
      bm_overview
      return
   fi
   bm_resolve "$target" || { bm_resolve_fail "$target"; return 1; }
   bm_facts "$R_DEV" || { R_ERR=unavailable; bm_resolve_fail "$R_DEV"; return 1; }
   # A whole disk: the health of the drive, then each of its filesystems
   if [ "${F[TYPE]}" = disk ] && [ -z "${F[FSTYPE]}" ]; then
      bm_drive_show "$R_DEV" || rc=1
      bm_disk_parts "$R_DEV"
      for part in "${DISK_PARTS[@]}"; do
         printf '\n'
         BM_DRIVE_SHOWN=1 bm_cmd_diagnose "$part" || rc=1
      done
      return "$rc"
   fi
   bm_diagnose_write "$R_DEV" "$R_PATH"
   bm_diag_drive
   bm_diag_doc "$R_DEV"
   bm_ui_show info "$C_TITLE"
   if [ "${#DH_FIND[@]}" -gt 0 ] && [ -z "${BM_DRIVE_SHOWN:-}" ]; then
      printf $"To see the errors of the drive: bigmount --diagnose %s"'\n' "${F[DISK]}"
   fi
   printf '\n%s\n' $"Technical details:"
   bm_tech_report "$R_DEV" | sed 's/^/  /'
   # The running system is used by every program and is never removed:
   # listing its users would only be noise
   if [ -n "$D_MP" ] && ! bm_is_system_mount "$D_MP"; then
      printf '\n'
      bm_busy_doc "$R_DEV" quiet
      if [ "$BUSY_COUNT" -gt 0 ]; then bm_ui_show info ""; fi
   fi
   [ "$D_CAUSE" = ok ] || [ "$D_CAUSE" = not-mounted ]
}

# Overview of every filesystem, plus a quick self-check of the environment
bm_overview() {
   local line dev fstype label size mp state mgr hint=0 rows=() r c out w=() i
   # Header first; column widths come from the longest cell (in characters)
   rows+=($"DEVICE"$'\t'$"LABEL"$'\t'$"SIZE"$'\t'$"FS"$'\t'$"MANAGED BY"$'\t'$"MOUNTED AT"$'\t'$"STATE")
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
      rows+=("$dev"$'\t'"${label:--}"$'\t'"$size"$'\t'"$fstype"$'\t'"$mgr"$'\t'"${mp:--}"$'\t'"$state")
   done < <(lsblk -P -b -p -o NAME,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS 2>/dev/null)
   # Long labels and mount points are shortened (…), never cut mid-character
   local max=(24 20 9 8 16 40 0)
   for r in "${rows[@]}"; do
      IFS=$'\t' read -r -a c <<< "$r"
      for i in 0 1 2 3 4 5; do
         bm_width "${c[i]}"; [ "$REPLY" -gt "${w[i]:-0}" ] && w[i]="$REPLY"
         [ "${w[i]}" -gt "${max[i]}" ] && w[i]="${max[i]}"
      done
   done
   printf '%s\n\n' $"Storage devices"
   for r in "${rows[@]}"; do
      IFS=$'\t' read -r -a c <<< "$r"
      out=" "
      for i in 0 1 2 3 4 5; do
         if [ "$i" -eq 2 ]; then
            # Sizes are right-aligned
            bm_width "${c[i]}"; printf -v line '%*s' $((w[i] - REPLY)) ""; out+=" $line${c[i]}"
         else
            bm_pad "${c[i]}" "${w[i]}"; out+=" $REPLY"
         fi
      done
      printf '%s %s\n' "$out" "${c[6]}"
   done
   [ "$hint" -eq 1 ] && printf '\n%s\n' $"To find out why a device cannot be written to, run: bigmount --diagnose DEVICE"

   printf '\n%s\n' $"Environment"
   local s
   s="$(systemctl is-enabled big-mount.service 2>/dev/null)"; printf '  %-28s %s\n' "big-mount.service" "${s:-?}"
   [ -e /etc/bigmountall-no ] && printf '  %-28s %s\n' "/etc/bigmountall-no" $"present: automount disabled"
   if busctl --system --no-pager status org.freedesktop.UDisks2 >/dev/null 2>&1; then s=$"available"; else s=$"not available"; fi
   printf '  %-28s %s\n' "UDisks2" "$s"
   for s in lsof python3 notify-send; do
      if command -v "$s" >/dev/null; then printf '  %-28s %s\n' "$s" $"installed"; else printf '  %-28s %s\n' "$s" $"missing"; fi
   done
   if journalctl -k -b -n 1 -q >/dev/null 2>&1 && [ -n "$(journalctl -k -b -n 1 -q 2>/dev/null)" ]; then s=$"readable"; else s=$"not readable (fewer details for errors)"; fi
   bm_fill $"kernel log" 28; printf '  %s %s\n' "$REPLY" "$s"
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
      isolated) printf -v REPLY $"Also mounted inside an isolated environment (a container or a sandboxed service): %s" "$2" ;;
      *) REPLY="$2" ;;
   esac
}

# Plain-language summary of a BUSY collection, from the holder that matters
# most to the user: something writing, a terminal, a file manager, an
# indexer, anything else. Sets BUSY_SUMMARY and BUSY_ADVICE.
bm_busy_summary() {
   local i best=0 rank=0 r comm app n="${#BUSY_PIDS[@]}"
   BUSY_SUMMARY="" BUSY_ADVICE=""
   # Priority of a holder: 6 writing, 5 shell/terminal, 4 file manager,
   # 3 indexer, 2 another program whose current folder is on the device, 1 other
   for i in "${!BUSY_PID[@]}"; do
      comm="${BUSY_COMM[i]}" r=1
      case "$comm" in
         dolphin | kioworker* | kioslave* | nautilus | nemo | thunar | pcmanfm* | caja | krusader | doublecmd) r=4 ;;
         baloo_file* | baloorunner | tracker-* | localsearch*) r=3 ;;
      esac
      if [[ $BM_SHELL_COMM == *" $comm "* ]]; then
         r=5
      elif [ "$r" -eq 1 ] && [ "${BUSY_FD[i]}" = cwd ]; then
         r=2
      fi
      if [ "${BUSY_ACCESS[i]}" = w ] || [ "${BUSY_ACCESS[i]}" = u ]; then r=6; fi
      if [ "$r" -gt "$best" ]; then best="$r" rank="$i"; fi
   done
   if [ "$best" -eq 0 ]; then
      if [[ " ${O_KIND[*]} " =~ ^( isolated)+\ $ ]]; then
         BUSY_SUMMARY=$"A container or a sandboxed service has its own mount of this device (see below). Unmounting it here does not release the device while that mount exists."
         BUSY_ADVICE=$"Stop that container or service first. Big-Mount waits for it before saying the device can be disconnected."
      elif [ "${#O_KIND[@]}" -gt 0 ]; then
         BUSY_SUMMARY=$"No program is using it, but the system still is (see below)."
         BUSY_ADVICE=$"Resolve the item listed below, then try again."
      else
         BUSY_SUMMARY=$"None of your programs is using it. A system service or a program of another user may be holding it, or it was released a moment ago."
         BUSY_ADVICE=$"Try again. If it is still busy, show the programs of all users."
      fi
      return 0
   fi
   app="${BUSY_APP[rank]}"
   case "$best" in
      6) printf -v BUSY_SUMMARY $"%s has a file open for writing on this device." "$app"
         BUSY_ADVICE=$"Let it finish, or cancel the operation in that program, then try again." ;;
      5) BUSY_SUMMARY=$"A terminal is open in a folder of this device."
         BUSY_ADVICE=$"Type cd in that terminal, or close it, then try again." ;;
      4) printf -v BUSY_SUMMARY $"%s is showing or reading files of this device." "$app"
         BUSY_ADVICE=$"Close the window or tab that shows the device, then try again." ;;
      3) BUSY_SUMMARY=$"The file indexer is reading this device."
         BUSY_ADVICE=$"It usually finishes in a moment: try again shortly." ;;
      2) printf -v BUSY_SUMMARY $"%s is running inside a folder of this device." "$app"
         BUSY_ADVICE=$"Close that program, then try again." ;;
      *) printf -v BUSY_SUMMARY $"%s is using files on this device." "$app"
         BUSY_ADVICE=$"Close that program, then try again." ;;
   esac
   if [ "$n" -gt 1 ]; then
      bm_nfmt "In total, %d program is using it." "In total, %d programs are using it." "$n" "$n"
      BUSY_SUMMARY+=" $REPLY"
   fi
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
      bm_busy_summary
      bm_short_name
      printf -v key $"%s is still in use" "$REPLY"
      bm_doc_h "$key"
      bm_doc_p "$BUSY_SUMMARY"
      bm_doc_p "$BUSY_ADVICE"
      bm_display_name; bm_doc_kv $"Device" "$REPLY"
      bm_fs_label "${F[FSTYPE]}"; bm_doc_kv $"Filesystem" "$REPLY"
      bm_mounts "$dev"; [ "${#M_TARGET[@]}" -gt 0 ] && bm_doc_kv $"Mounted at" "${M_TARGET[0]}"
      key=""
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
   [ "${#BUSY_PIDS[@]}" -gt 0 ] && bm_doc_p $"An open file does not necessarily mean that something is being copied."
   return 0
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
   bm_resolve "${1:-}" || { bm_resolve_fail "${1:-}"; return 1; }
   bm_busy_doc "$R_DEV"
   if [ "$BUSY_COUNT" -eq 0 ]; then
      # Nothing visible holds it: say so instead of "still in use". A user
      # cannot see the programs of other users, so only root may say "nothing"
      bm_short_name
      bm_doc_new
      if [ "$EUID" -eq 0 ]; then
         printf -v REPLY $"%s is not in use" "$REPLY"
         bm_doc_h "$REPLY"
         bm_doc_p $"No program and nothing in the system is using it. It can be unmounted."
      else
         printf -v REPLY $"None of your programs is using %s" "$REPLY"
         bm_doc_h "$REPLY"
         bm_doc_p $"No program of yours, no other mount and no other device is using it. It can probably be unmounted. Programs of other users and of the system are only visible to an administrator."
      fi
      bm_ui_show info ""
      return 0
   fi
   bm_ui_show info ""
   return 3
}

# ---------------------------------------------------------------------------
# Safe removal

# bm_remove_core MODE DEV: MODE "unmount" (one filesystem), "drive" (every
# filesystem of the drive), "release" (drive, then lock its encrypted
# volumes: nothing of it stays in use, before a Secure Erase) or "remove"
# (release, then power off when it is a removable drive). Returns the exit
# codes documented at the top.
# RM_BUSY_DEV, RM_REASON, RM_POWERED and RM_REMOVABLE describe the outcome;
# RM_GONE=1 when it stopped because the device disappeared (unplugged, or
# replaced by another one under the same name).
#
# Before every step that cannot be undone the disk sequence number is checked
# again (another device may have taken the name), and nothing is reported as
# safe while any filesystem of the drive is still mounted.
bm_remove_core() {
   local mode="$1" dev="$2" d i t targets=() types=() rc seq n
   RM_BUSY_DEV="" RM_REASON="" RM_POWERED=0 RM_REMOVABLE=0 RM_GONE=0 RM_DEP_UNITS=() RM_DEP_NAMES=() RM_DEP_BACK=()
   _bm_gone() {
      RM_GONE=1
      RM_REASON=$"The device was disconnected or replaced during the operation. Nothing else was done."
   }
   bm_facts "$dev" || { _bm_gone; return 1; }
   local disk="${F[DISK]}" disk_type="${F[DISK_TYPE]}"
   bm_is_removable_drive && RM_REMOVABLE=1
   bm_diskseq "$disk"; seq="$REPLY"
   _bm_same_disk() {
      bm_diskseq "$disk"
      # Kernels before 5.15 have no diskseq: then at least the node must exist
      [ "$REPLY" = "$seq" ] && { [ -n "$seq" ] || [ -b "$disk" ]; } && return 0
      _bm_gone
      return 1
   }
   if [ "$mode" != unmount ]; then
      if bm_system_use "$disk"; then RM_REASON="$REPLY"; return 4; fi
      bm_drive_members "$disk"
      targets=("${DRIVE_DEVS[@]}") types=("${DRIVE_FSTYPES[@]}")
   else
      bm_mounts "$dev"
      for t in "${M_TARGET[@]}"; do
         bm_is_system_mount "$t" && { RM_REASON="$dev → $t"; return 4; }
      done
      targets=("$dev")
   fi
   # Services that systemd stops when these mounts go away (e.g. a media or
   # photo server with BindsTo= on the mount): never stop them by surprise.
   # The caller asks the user and sets RM_ALLOW_SERVICES=1 to go on.
   if [ "${RM_ALLOW_SERVICES:-0}" != 1 ]; then
      for d in "${targets[@]}"; do
         bm_mounts "$d"
         for t in "${M_TARGET[@]}"; do
            bm_mount_dependents "$t"
            RM_DEP_UNITS+=("${DEP_UNITS[@]}") RM_DEP_NAMES+=("${DEP_NAMES[@]}") RM_DEP_BACK+=("${DEP_BACK[@]}")
         done
      done
      [ "${#RM_DEP_UNITS[@]}" -gt 0 ] && return 9
   fi

   # Stacked devices (LUKS, LVM) come after their parents in lsblk: go backwards
   for ((i = ${#targets[@]} - 1; i >= 0; i--)); do
      d="${targets[i]}"
      bm_mounts "$d"
      [ "${#M_TARGET[@]}" -eq 0 ] && continue
      _bm_same_disk || return 1
      if ! bm_unmount_all "$d"; then
         case "$UD_ERROR" in
            *DeviceBusy*) RM_BUSY_DEV="$d"; return 3 ;;
            *NotAuthorized*) return 5 ;;
            no-object) _bm_gone; return 1 ;;
            *) RM_REASON="$UD_MESSAGE"; return 1 ;;
         esac
      fi
   done
   [ "$mode" = unmount ] && return 0

   # Nothing may have been mounted again meanwhile (an automounter, a script)
   for d in "${targets[@]}"; do
      bm_mounts "$d"
      if [ "${#M_TARGET[@]}" -gt 0 ]; then
         printf -v RM_REASON $"%s was mounted again at %s" "$d" "${M_TARGET[0]}"
         return 1
      fi
   done
   case "$mode" in remove | release) ;; *) return 0 ;; esac

   # Lock encrypted volumes that are open (their filesystems are unmounted
   # by now), as the Plasma device notifier does before a safe removal
   for i in "${!targets[@]}"; do
      [ "${types[i]}" = crypto_LUKS ] || continue
      d="${targets[i]}"
      bm_has_holders "$d" || continue
      _bm_same_disk || return 1
      if ! bm_udisks lock -b "$d"; then
         [[ $UD_ERROR == *NotAuthorized* ]] && return 5
         [ "$UD_ERROR" = no-object ] && { _bm_gone; return 1; }
         printf -v RM_REASON $"%s: the encrypted volume could not be locked" "$d"
         return 6
      fi
   done

   # Internal disks are unmounted, never powered off
   [ "$mode" = remove ] && [ "$RM_REMOVABLE" = 1 ] || return 0

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
   # A few attempts: right after an unmount, udev and UDisks may still be
   # processing the change and report the drive as in use
   for ((n = 0; n < 3; n++)); do
      _bm_same_disk || return 1
      if bm_udisks power-off -b "$disk"; then
         RM_POWERED=1
         return 0
      fi
      case "$UD_ERROR" in
         *NotAuthorized*) return 5 ;;
         *NotSupported*) RM_REASON="$UD_MESSAGE"; return 7 ;;
         no-object) _bm_gone; return 1 ;;
      esac
      udevadm settle --timeout=5 >/dev/null 2>&1
      sleep 1
   done
   # Unmounted, but the power-off itself failed: say so, with the reason
   RM_REASON="${UD_MESSAGE##*: }"
   return 8
}

# What happens to the services of RM_DEP_* once the device is back (REPLY)
bm_dep_restart_text() {
   if [[ " ${RM_DEP_BACK[*]} " == *" 0 "* ]]; then
      REPLY=$"They do not start again by themselves when the device comes back."
   else
      REPLY=$"They start again by themselves when the device is mounted again."
   fi
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
   local mode="$1" target="" close=0 yes=0 a rc
   shift
   RM_ALLOW_SERVICES=0
   for a in "$@"; do
      case "$a" in
         --close-apps) close=1 ;;
         --assume-yes) yes=1 ;;
         --no-power-off) [ "$mode" = remove ] && mode=drive ;;
         -*) printf $"bigmount: unknown option '%s' (see bigmount --help)"'\n' "$a" >&2; return 2 ;;
         *) target="$a" ;;
      esac
   done
   bm_resolve "$target" || { bm_resolve_fail "$target"; return 1; }
   if bm_facts "$R_DEV" && ! bm_drive_lock "${F[DISK]}"; then
      printf '%s\n' $"Another removal of this drive is in progress. Nothing was done." >&2
      return 10
   fi
   bm_remove_tty "$mode" "$R_DEV" "$close" "$yes"; rc=$?
   bm_drive_unlock
   return "$rc"
}

# The terminal dialogue of bm_cmd_remove, with the drive locked
bm_remove_tty() {
   local mode="$1" dev="$2" close="$3" yes="$4" a rc tries=0
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
         9)
            printf '%s\n' $"These services use the device and will be stopped when it is unmounted:" >&2
            for a in "${!RM_DEP_UNITS[@]}"; do printf '  %s (%s)\n' "${RM_DEP_NAMES[a]}" "${RM_DEP_UNITS[a]}" >&2; done
            bm_dep_restart_text; printf '%s\n' "$REPLY" >&2
            if [ "$yes" -eq 1 ]; then
               RM_ALLOW_SERVICES=1
            elif [ -t 0 ]; then
               bm_doc_new
               bm_ui_confirm "" "" $"Stop them and continue" $"Cancel" || return 9
               RM_ALLOW_SERVICES=1
            else
               printf '%s\n' $"Nothing was done. Run again with --assume-yes to stop them." >&2
               return 9
            fi
            ;;
         8) printf $"Unmounted, but powering the drive off failed (%s). Wait a moment before disconnecting it."'\n' "$RM_REASON" >&2; return 8 ;;
         4) printf $"Refused: this drive holds the running system (%s)."'\n' "$RM_REASON" >&2; return 4 ;;
         5) printf '%s\n' $"Permission to unmount was not granted." >&2; return 5 ;;
         6) printf $"Unmounted, but the drive is still in use (%s), so it was not powered off."'\n' "$RM_REASON" >&2; return 6 ;;
         7) printf '%s\n' $"Unmounted. This drive cannot be powered off by the computer; it can be disconnected now." ; return 7 ;;
         *)
            if [ "$RM_GONE" = 1 ]; then printf '%s\n' "$RM_REASON" >&2
            else printf $"Could not unmount: %s"'\n' "$RM_REASON" >&2
            fi
            return 1
            ;;
      esac
   done
}

# ---------------------------------------------------------------------------
# Drive health and Secure Erase

bm_tran_label() {
   case "$1" in
      sata) REPLY="SATA" ;; ata) REPLY="ATA" ;; nvme) REPLY="NVMe" ;; usb) REPLY="USB" ;;
      mmc) REPLY="SD/MMC" ;; "") REPLY=$"unknown" ;; *) REPLY="$1" ;;
   esac
}

# The drive document (DT_TITLE) for F, the whole disk, after bm_drive_health
bm_drive_doc() {
   local k s
   if [ "${#DH_FIND[@]}" -gt 0 ]; then DT_TITLE=$"The drive reports errors"; else DT_TITLE=$"No drive errors found"; fi
   bm_doc_new
   bm_doc_h "$DT_TITLE"
   bm_display_name; bm_doc_kv $"Drive" "$REPLY"
   bm_tran_label "${F[TRAN]:-}"; bm_doc_kv $"Connection" "$REPLY"
   case "$DH_SMART" in
      ok) s=$"no problem reported" ;;
      failing) s=$"the drive predicts its own failure" ;;
      *) s=$"not available" ;;
   esac
   if [ "$DH_SMART" = ok ] && [ "$DH_BAD" -gt 0 ]; then
      bm_nfmt "no failure predicted (%s damaged sector was replaced by a spare one)" "no failure predicted (%s damaged sectors were replaced by spare ones)" "$DH_BAD" "$DH_BAD"; s="$REPLY"
   fi
   bm_doc_kv $"SMART status" "$s"
   if [ "${#DH_FIND[@]}" -eq 0 ]; then
      if [ "$DH_KLOG" = 1 ]; then
         bm_doc_p $"Since the computer was started, the system recorded no read, write or connection errors for this drive."
      else
         bm_doc_p $"The kernel log cannot be read by your user, so recent errors of this drive cannot be checked."
      fi
      return 0
   fi
   bm_doc_p $"Problems found:"
   for k in "${DH_FIND[@]}"; do
      case "$k" in
         smart-failing) bm_doc_li $"The drive itself reports that it is failing (SMART)." ;;
         timeouts) bm_nfmt "Since the computer was started, it stopped answering and the connection had to be reset (%s kernel message)." "Since the computer was started, it stopped answering and the connection had to be reset (%s kernel messages)." "${DH_COUNT[$k]}" "${DH_COUNT[$k]}"; bm_doc_li "$REPLY" ;;
         io-errors) bm_nfmt "Since the computer was started, reading or writing failed (%s kernel message)." "Since the computer was started, reading or writing failed (%s kernel messages)." "${DH_COUNT[$k]}" "${DH_COUNT[$k]}"; bm_doc_li "$REPLY" ;;
         slow-link) bm_doc_li $"Since the computer was started, the connection was slowed down after errors." ;;
         usb-resets) bm_nfmt "Since the computer was started, the USB connection was reset or lost %s time." "Since the computer was started, the USB connection was reset or lost %s times." "${DH_COUNT[$k]}" "${DH_COUNT[$k]}"; bm_doc_li "$REPLY" ;;
      esac
   done
   bm_doc_p $"How to solve:"
   bm_doc_li $"Copy your important files to another place as soon as possible."
   [ "${F[TRAN]:-}" = sata ] && bm_doc_li $"Check the data and power cables of the drive, or try another SATA port."
   [ "$DH_ATA" = 1 ] && bm_doc_li $"An SSD that fails like this may lock itself in a protection mode: it seems to accept writing, but keeps nothing. Installers then cannot create partitions, and erased partitions come back. The drive's own Secure Erase can bring it back to work, but it erases everything on it."
   bm_doc_li $"If the errors come back, replace the drive."
}

# Technical report of the drive (F, after bm_drive_health)
bm_drive_report() {
   local k l counts=""
   printf '%s\n' "drive:       ${F[DISK]} model='${F[VENDOR]:+${F[VENDOR]} }${F[MODEL]}' transport=${F[TRAN]:-?} port=${DH_PORT:--}"
   printf '%s\n' "smart:       ${DH_SMART:-n/a} bad-sectors=$DH_BAD"
   printf '%s\n' "ata:         ata=$DH_ATA security=${DH_SEC:-unsupported} frozen=$DH_FROZEN erase-minutes=$DH_ERASE_MIN"
   if [ "$DH_KLOG" = 1 ]; then
      for k in timeouts io-errors slow-link usb-resets; do counts+="${counts:+ }$k=${DH_COUNT[$k]:-0}"; done
      printf '%s\n' "kernel log:  $counts"
      for l in "${DH_LINES[@]:$((${#DH_LINES[@]} > 15 ? ${#DH_LINES[@]} - 15 : 0))}"; do printf '             %s\n' "$l"; done
   else
      printf '%s\n' "kernel log:  not readable"
   fi
}

# bigmount --diagnose DISK: the health of the drive. Fails when it reported errors.
bm_drive_show() {
   local disk="$1"
   bm_drive_health "$disk"
   bm_drive_doc
   bm_ui_show info "$DT_TITLE"
   printf '\n%s\n' $"Technical details:"
   bm_drive_report | sed 's/^/  /'
   [ "${#DH_FIND[@]}" -eq 0 ] && return 0
   bm_erase_check "$disk" && printf '\n'$"Secure Erase is available for this drive: bigmount --secure-erase %s"'\n' "$disk"
   return 1
}

# Why a drive cannot be erased (ER_WHY of bm_erase_check), in REPLY
bm_erase_refusal() {
   case "$ER_WHY" in
      not-disk) REPLY=$"Secure Erase works on a whole drive, not on a partition." ;;
      no-seq) REPLY=$"The kernel gives this drive no sequence number, so another drive connected under the same name could not be told apart from it." ;;
      system) REPLY=$"It holds the operating system that is running now. Start the computer from a live USB drive to erase it." ;;
      removable) REPLY=$"Secure Erase is only offered for drives connected inside the computer, not through USB." ;;
      not-ata) REPLY=$"Secure Erase is only available for SATA drives." ;;
      unsupported) REPLY=$"This drive does not support Secure Erase." ;;
      password) REPLY=$"A security password is set on this drive. Remove it first, in the firmware setup (BIOS) or with the tool of the manufacturer." ;;
      *) REPLY=$"This drive cannot be erased." ;;
   esac
}

# What will happen, before anything is done (F is the disk)
bm_erase_intro_doc() {
   local disk="$1" line parts=() s
   bm_doc_new
   bm_doc_h $"Erase the whole drive"
   bm_display_name; bm_doc_kv $"Drive" "$REPLY"
   bm_doc_p $"The drive will erase itself completely, with its own Secure Erase command. Every partition and every file on it will be lost for good. This cannot be undone."
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      [ "${KV[NAME]}" = "$disk" ] && continue
      bm_human_size "${KV[SIZE]}"
      parts+=("${KV[NAME]} — ${KV[LABEL]:+${KV[LABEL]} — }$REPLY${KV[FSTYPE]:+ — ${KV[FSTYPE]}}")
   done < <(lsblk -P -b -p -n -o NAME,FSTYPE,LABEL,SIZE -- "$disk" 2>/dev/null)
   if [ "${#parts[@]}" -gt 0 ]; then
      bm_doc_p $"These partitions will be lost:"
      for s in "${parts[@]}"; do bm_doc_li "$s"; done
   fi
   if [ "$DH_ERASE_MIN" -ge 508 ]; then
      bm_doc_p $"The drive announces that erasing takes more than 8 hours."
   elif [ "$DH_ERASE_MIN" -gt 0 ]; then
      bm_nfmt "The drive announces that erasing takes about %d minute." "The drive announces that erasing takes about %d minutes." "$DH_ERASE_MIN" "$DH_ERASE_MIN"; bm_doc_p "$REPLY"
   fi
   bm_erase_table
   if [ "$REPLY" = gpt ]; then s="GPT"; else s="MBR"; fi
   printf -v s $"Afterwards an empty %s partition table is written and read back, to check that the drive keeps what is written again." "$s"
   bm_doc_p "$s"
   bm_doc_p $"Use it to bring back an SSD that no longer keeps what is written, or before giving a drive away. It is not a repair: if the drive fails again, replace it."
   [ "$DH_FROZEN" = 1 ] && bm_doc_p $"The computer may have to sleep for a moment first."
   bm_doc_p $"The administrator password will be requested."
}

# The drive is frozen: what sleeping does (E_TITLE)
bm_erase_frozen_doc() {
   E_TITLE=$"The drive is locked against erasing"
   bm_doc_new
   bm_doc_h "$E_TITLE"
   bm_doc_p $"When the computer starts, its firmware locks the security commands of the drives (they are frozen). Sleeping once usually unlocks them."
   if [ "$EUID" -eq 0 ] && command -v rtcwake >/dev/null; then
      bm_doc_p $"The computer will sleep and wake up by itself after about 20 seconds."
   else
      bm_doc_p $"The computer will go to sleep. Wake it up with the power button, and unlock the session if asked: the erase continues afterwards."
   fi
}

# Outcome of a Secure Erase (exit code RC, TABLE written) as a document:
# E_TITLE, E_KIND (info|warning|error)
bm_erase_result_doc() {
   local rc="$1" table="$2" s
   E_KIND=error E_TITLE=$"Unable to erase the drive"
   bm_doc_new
   case "$rc" in
      0)
         E_KIND=info E_TITLE=$"Drive erased"
         bm_doc_h "$E_TITLE"
         if [ "$table" = gpt ]; then s="GPT"; else s="MBR"; fi
         printf -v s $"The drive was erased and keeps what is written again. It now has an empty %s partition table: you can install a system or create partitions on it." "$s"
         bm_doc_p "$s"
         bm_doc_p $"It failed once: keep a copy of what you store on it, and replace it if the errors come back."
         ;;
      11)
         E_KIND=warning E_TITLE=$"The drive is still locked"
         bm_doc_h "$E_TITLE"
         bm_doc_p $"The drive is still locked against erasing. Nothing was erased."
         bm_doc_li $"Some computers lock the drives again when they wake up. Try once more, or erase the drive in another computer."
         bm_doc_li $"If the computer supports hot-plugging SATA drives, disconnecting and connecting the drive while the computer is on also unlocks it."
         ;;
      12)
         case "$ER_STAGE" in
            unverified)
               E_KIND=warning E_TITLE=$"Drive erased, not verified"
               bm_doc_h "$E_TITLE"
               printf -v s $"The drive was erased, but writing a new partition table failed (%s), so it could not be checked." "$ER_REASON"
               bm_doc_p "$s"
               bm_doc_p $"Create a partition table with KDE Partition Manager, and check that it is still there after a restart."
               ;;
            erase-ignored)
               E_TITLE=$"The drive is failing"
               bm_doc_h "$E_TITLE"
               bm_doc_p $"The drive accepted the erase command, but its old contents are still there: it no longer does what it is told. Replace it."
               ;;
            *)
               E_TITLE=$"The drive is failing"
               bm_doc_h "$E_TITLE"
               bm_doc_p $"The drive was erased, but it still does not keep what is written. Replace it."
               ;;
         esac
         ;;
      3) bm_doc_h "$E_TITLE"; bm_doc_p $"The drive is still in use. Nothing was erased."; [ -n "$ER_REASON" ] && bm_doc_p "$ER_REASON" ;;
      4) bm_doc_h "$E_TITLE"; bm_doc_p $"It holds the operating system that is running now. Nothing was erased." ;;
      5) bm_doc_h "$E_TITLE"; bm_doc_p $"Permission was not granted. Nothing was erased." ;;
      *)
         bm_doc_h "$E_TITLE"
         if [ -n "$ER_REASON" ]; then bm_doc_p "$ER_REASON"; else bm_doc_p $"The drive could not be erased."; fi
         ;;
   esac
}

# bigmount --secure-erase DISK
bm_cmd_secure_erase() {
   local target="" a disk seq rc
   for a in "$@"; do
      case "$a" in
         -*) printf $"bigmount: unknown option '%s' (see bigmount --help)"'\n' "$a" >&2; return 2 ;;
         *) target="$a" ;;
      esac
   done
   bm_resolve "$target" || { bm_resolve_fail "$target"; return 1; }
   # Read before the facts that are checked and shown: the drive erased is the
   # one they describe, and another one that takes its name has another number
   bm_diskseq "$R_DEV"; seq="$REPLY"
   bm_facts "$R_DEV" || { R_ERR=unavailable; bm_resolve_fail "$R_DEV"; return 1; }
   disk="${F[DISK]}"
   if [ "$R_DEV" != "$disk" ] || [ -n "$R_PATH" ]; then
      printf $"bigmount: Secure Erase works on a whole drive: name the drive itself (%s)"'\n' "$disk" >&2
      return 2
   fi
   bm_drive_health "$disk"
   if ! bm_erase_check "$disk"; then
      bm_erase_refusal; printf 'bigmount: %s\n' "$REPLY" >&2
      [ "$ER_WHY" = system ] && return 4
      return 1
   fi
   if [ ! -t 0 ]; then
      printf '%s\n' $"bigmount: --secure-erase asks for confirmation and needs a terminal" >&2
      return 2
   fi
   if ! bm_drive_lock "$disk"; then
      printf '%s\n' $"Another operation on this drive is in progress. Nothing was done." >&2
      return 10
   fi
   bm_secure_erase_tty "$disk" "$seq"; rc=$?
   bm_drive_unlock
   return "$rc"
}

# The terminal dialogue of bm_cmd_secure_erase, with the drive locked. SEQ is
# the disk sequence number of the drive that was checked
bm_secure_erase_tty() {
   local disk="$1" seq="$2" rc a table
   bm_erase_intro_doc "$disk"
   bm_ui_show info ""
   printf '\n'
   printf -v a $"To confirm, type the name of the drive (%s):" "${disk##*/}"
   if ! bm_ui_input "" "$a" || [ "$REPLY" != "${disk##*/}" ]; then
      printf '%s\n' $"Nothing was erased." >&2
      return 5
   fi
   # Nothing is unmounted on a drive that took the name while the question was open
   bm_diskseq "$disk"
   if [ "$REPLY" != "$seq" ]; then
      ER_REASON=$"The drive was disconnected or replaced. Nothing was erased."
      bm_erase_result_doc 1 ""; bm_ui_show "$E_KIND" "" >&2
      return 1
   fi
   RM_ALLOW_SERVICES=0
   while :; do
      bm_remove_core release "$disk"; rc=$?
      case "$rc" in
         0) break ;;
         3) bm_busy_doc "$RM_BUSY_DEV"; bm_ui_show warning ""; printf '%s\n' $"Nothing was erased." >&2; return 3 ;;
         9)
            printf '%s\n' $"These services use the drive and will be stopped:" >&2
            for a in "${!RM_DEP_UNITS[@]}"; do printf '  %s (%s)\n' "${RM_DEP_NAMES[a]}" "${RM_DEP_UNITS[a]}" >&2; done
            bm_doc_new
            bm_ui_confirm "" "" $"Stop them and continue" $"Cancel" || return 9
            RM_ALLOW_SERVICES=1
            ;;
         *)
            ER_REASON="$RM_REASON"; [ "$rc" -eq 6 ] && rc=3
            bm_erase_result_doc "$rc" ""; bm_ui_show "$E_KIND" "" >&2
            return "$rc"
            ;;
      esac
   done
   bm_udev_props "$disk"
   if [ "${UP[ID_ATA_FEATURE_SET_SECURITY_FROZEN]:-0}" = 1 ]; then
      bm_erase_frozen_doc
      bm_ui_confirm "" "" $"Sleep now" $"Cancel" || return 11
      if ! bm_erase_unfreeze "$disk"; then
         bm_erase_result_doc 11 ""; bm_ui_show warning ""
         return 11
      fi
   fi
   bm_erase_table; table="$REPLY"
   printf $"Erasing %s. Do not turn off the computer or disconnect the drive."'\n' "$disk"
   bm_erase_run "$disk" "$seq" "$table"; rc=$?
   bm_erase_result_doc "$rc" "$table"
   bm_ui_show "$E_KIND" ""
   # Over SSH there is no polkit agent to ask for the password
   if [ "$rc" -eq 5 ] && [ "$EUID" -ne 0 ]; then
      printf '%s\n' $"Without a graphical session, run it as administrator: sudo bigmount --secure-erase DISK" >&2
   fi
   return "$rc"
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
      bm_notify info big-mount $"Storage diagnostics" $"No storage device to diagnose was found."
      return 1
   fi
   bm_ui_menu $"Storage diagnostics" $"Choose a device:" "${items[@]}"
   [ -n "$REPLY" ]
}

# bm_gui_target TARGET TITLE TEXT: resolve TARGET for a graphical command,
# setting R_DEV, R_PATH and F. A folder that is not on a local device is a
# fact, not a failure: a notification (TITLE, TEXT) says so. A device that
# cannot be found (unplugged, not ready yet) gets a dialog that can try
# again and show the technical reason.
bm_gui_target() {
   local target="$1" tmp
   while :; do
      if bm_resolve "$target"; then
         bm_facts "$R_DEV" && return 0
         R_ERR=unavailable
      fi
      if [ "$R_ERR" = not-local ]; then
         bm_notify info big-mount "$2" "$3"
         return 1
      fi
      bm_doc_new
      bm_doc_h $"Unable to access storage device"
      bm_doc_p $"Big-Mount could not identify this storage device. It may have been disconnected or become temporarily unavailable."
      bm_doc_p $"If you disconnected it, connect it again and choose Try again."
      bm_ui_choice $"Unable to access storage device" dialog-warning $"Try again" $"Technical details" $"Close"
      case "$REPLY" in
         1) ;;
         2)
            tmp="$(mktemp)" || return 1
            bm_resolve_message "$target"
            printf '%s\n' "target: $target" "node:   ${R_NODE:--}" "reason: ${R_ERR:-?}" "" "$REPLY" > "$tmp"
            bm_ui_text $"Technical details" "$tmp"; rm -f -- "$tmp"
            ;;
         *) return 1 ;;
      esac
   done
}

bm_gui_diagnose() {
   local target="${1:-}" key icon tmp
   if [ -z "$target" ]; then
      bm_pick_device || return 0
      target="$REPLY"
   fi
   bm_gui_target "$target" $"Storage diagnostics" $"This folder is not on a local storage device." || return 1
   local dev="$R_DEV" path="$R_PATH"
   # A whole disk: its only filesystem, or let the user choose one
   if [ "${F[TYPE]}" = disk ] && [ -z "${F[FSTYPE]}" ]; then
      bm_disk_parts "$dev"
      if [ "${#DISK_PARTS[@]}" -eq 1 ]; then
         dev="${DISK_PARTS[0]}"
      elif [ "${#DISK_PARTS[@]}" -gt 1 ]; then
         local items=() p
         for p in "${DISK_PARTS[@]}"; do bm_facts "$p"; bm_display_name; items+=("$p" "$REPLY"); done
         bm_ui_menu $"Storage diagnostics" $"Choose a device:" "${items[@]}"
         [ -n "$REPLY" ] || return 0
         dev="$REPLY"
      fi
   fi
   while :; do
      # The device may have been unplugged while a dialog was open
      if ! bm_facts "$dev"; then
         bm_gui_target "$dev" $"Storage diagnostics" "" || return 1
      fi
      bm_diagnose_write "$dev" "$path"
      bm_diag_drive
      bm_diag_doc "$dev"
      bm_device_icon; icon="$REPLY"
      [ "$D_CAUSE" = ok ] && [ "${#DH_FIND[@]}" -eq 0 ] || icon=dialog-warning
      if [ -n "$D_FIX" ]; then
         bm_ui_choice "$C_TITLE" "$icon" "$C_FIX_LABEL" $"Technical details" $"Close"
      elif [ "${#DH_FIND[@]}" -gt 0 ]; then
         bm_ui_choice "$C_TITLE" "$icon" $"Check the drive…" $"Technical details" $"Close"
         [ "$REPLY" = 1 ] && REPLY=5
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
         5) bm_load drive.sh && bm_gui_drive_main health "${F[DISK]}"; return ;;
         *) return 0 ;;
      esac
   done
}

# Only the help text (notification action "How to solve")
bm_gui_help() {
   bm_resolve "${1:-}" && bm_facts "$R_DEV" || return 1
   bm_diagnose_write "$R_DEV" "$R_PATH"
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
         if ! bm_drive_lock "${F[DISK]:-$dev}"; then
            bm_notify info dialog-information "$C_FIX_LABEL" $"Another operation on this drive is in progress. Try again when it finishes."
            return 0
         fi
         if bm_unmount_all "$dev"; then
            if bm_udisks mount -b "$dev"; then
               bm_diagnose_write "$dev"
               [ "$D_CAUSE" = ok ] && ok=1
            fi
         elif [[ $UD_ERROR == *DeviceBusy* ]]; then
            bm_drive_unlock
            bm_gui_busy_dialog "$dev"
            return 0
         fi
         bm_drive_unlock
         ;;
   esac
   bm_short_name
   if [ "$ok" -eq 1 ]; then
      bm_notify info dialog-ok $"Device ready" "$REPLY"$'\n'$"You can now write to this device."
   else
      bm_notify warning dialog-error $"Unable to fix the device" \
         "$REPLY"$'\n'$"Nothing was changed on the device. See the technical details for more information."
   fi
}

# ---------------------------------------------------------------------------
# Graphical safe removal (bigmount --gui-remove, Dolphin action)

# The processes of every user, read with administrator rights, are kept only
# while the busy dialog shows them: never left behind in /tmp
bm_priv_clear() {
   [ -n "${BM_PRIV_LSOF:-}" ] && rm -f -- "$BM_PRIV_LSOF"
   BM_PRIV_LSOF=""
}

# Busy dialog: returns 0 to try again, 1 to give up
bm_gui_busy_dialog() {
   local dev="$1" priv="" tmp self
   bm_priv_clear
   trap 'bm_priv_clear; bm_drive_unlock' EXIT
   trap 'bm_priv_clear; bm_drive_unlock; exit 130' INT TERM HUP
   while :; do
      bm_busy_doc "$dev" "" "$priv"
      bm_device_icon
      bm_ui_choice $"Device is busy" dialog-warning $"Try again" $"More options…" $"Cancel"
      case "$REPLY" in
         1) bm_priv_clear; return 0 ;;
         3) bm_priv_clear; return 1 ;;
      esac
      local opts=(refresh $"Refresh the list" details $"Show technical details")
      bm_close_candidates
      [ "${#CLOSE_PIDS[@]}" -gt 0 ] && opts+=(close $"Close the listed programs…")
      command -v pkexec >/dev/null && opts+=(admin $"Show programs of all users (administrator)")
      bm_ui_menu $"Device is busy" $"What do you want to do?" "${opts[@]}"
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
            if bm_ui_confirm_risky $"Close programs" dialog-warning $"Close them" $"Cancel"; then
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
            bm_priv_clear
            tmp="$(mktemp)" || continue
            BM_PRIV_LSOF="$tmp"
            bm_mounts "$dev"
            local mp; for mp in "${M_TARGET[@]}"; do
               pkexec "$self" "$mp" >> "$tmp" 2>/dev/null
            done
            if [ -s "$tmp" ]; then priv=1; else bm_priv_clear; priv=""; fi
            ;;
      esac
   done
}

# Shown when an unmount or power-off is still running after 2 seconds
# Once per removal, however many slow steps it has (unmount, release, power-off)
bm_gui_slow_notice() {
   [ "${BM_GUI_SLOW_SHOWN:-0}" = 1 ] && return 0
   BM_GUI_SLOW_SHOWN=1
   bm_notify info document-save "$BM_GUI_NAME" $"Writing pending data to the device. Do not disconnect it yet." &
}

bm_gui_remove() {
   local target="${1:-}" rc name short icon
   bm_gui_target "$target" $"Safely remove" $"This folder is not on a removable storage device." || return 1
   local dev="$R_DEV"
   bm_display_name; name="$REPLY"
   bm_short_name; short="$REPLY"
   bm_device_icon; icon="$REPLY"
   if ! bm_drive_lock "${F[DISK]}"; then
      bm_notify info "$icon" $"Safely remove" "$name"$'\n'$"The removal of this drive is already in progress." >/dev/null &
      return 10
   fi
   BM_GUI_NAME="$short" BM_SLOW_HOOK=bm_gui_slow_notice BM_GUI_SLOW_SHOWN=0 RM_ALLOW_SERVICES=0
   while :; do
      bm_remove_core remove "$dev"; rc=$?
      case "$rc" in
         0)
            if [ "$RM_POWERED" = 1 ]; then
               bm_notify info "$icon" $"Safe to disconnect" \
                  "$name"$'\n'$"Successfully unmounted and powered off. You can disconnect it now." >/dev/null &
            elif [ "$RM_REMOVABLE" = 1 ]; then
               bm_notify info "$icon" $"Safe to disconnect" \
                  "$name"$'\n'$"Successfully unmounted. You can disconnect it now." >/dev/null &
            else
               bm_notify info "$icon" $"Device unmounted" \
                  "$name"$'\n'$"All pending data was written and its filesystems were unmounted." >/dev/null &
            fi
            break
            ;;
         7)
            bm_notify info "$icon" $"Safe to disconnect" \
               "$name"$'\n'$"Successfully unmounted. This drive cannot be powered off by the computer, but you can disconnect it now." >/dev/null &
            rc=0
            break
            ;;
         3) bm_gui_busy_dialog "$RM_BUSY_DEV" || break ;;
         9)
            bm_doc_new
            bm_doc_h $"Services use this device"
            bm_doc_p $"Removing it will stop these services:"
            local u; for u in "${!RM_DEP_UNITS[@]}"; do bm_doc_li "${RM_DEP_NAMES[u]} (${RM_DEP_UNITS[u]})"; done
            bm_dep_restart_text; bm_doc_p "$REPLY"
            if bm_ui_confirm_risky $"Services use this device" dialog-warning $"Stop them and remove" $"Cancel"; then
               RM_ALLOW_SERVICES=1
            else
               break
            fi
            ;;
         8)
            bm_notify warning dialog-warning $"Unable to power off device" \
               "$name"$'\n'$"It was unmounted, but powering it off failed. Wait a moment before disconnecting it."$'\n'"$RM_REASON" >/dev/null &
            break
            ;;
         4)
            bm_notify warning dialog-error $"Unable to remove device" \
               "$name"$'\n'$"It holds the operating system that is running now." >/dev/null &
            break
            ;;
         5)
            bm_notify warning dialog-error $"Unable to unmount device" \
               "$name"$'\n'$"Permission was not granted. The device remains mounted." >/dev/null &
            break
            ;;
         6)
            bm_notify warning dialog-warning $"Unable to power off device" \
               "$name"$'\n'$"Its filesystems were unmounted, but the drive is still in use, so it was not powered off. Do not disconnect it yet."$'\n'"$RM_REASON" >/dev/null &
            break
            ;;
         *)
            if [ "$RM_GONE" = 1 ]; then
               bm_notify warning dialog-warning $"Device disconnected" \
                  "$name"$'\n'$"The device was disconnected before the removal finished. If files were being written to it, check them when you connect it again." >/dev/null &
            else
               bm_notify warning dialog-error $"Unable to unmount device" \
                  "$name"$'\n'$"It remains mounted. Nothing was forced."$'\n'"${RM_REASON%%$'\n'*}" >/dev/null &
            fi
            break
            ;;
      esac
   done
   BM_SLOW_HOOK=""
   bm_drive_unlock
   return "$rc"
}

# ---------------------------------------------------------------------------
# Session notifier (bigmount --notifier). Off by default: the application turns
# it on by copying its entry to the person's XDG autostart folder
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

# bm_notifier_health DEV: a drive that reports problems gets a window, once per
# boot and drive (not per volume, not per reconnection), with the way to look
# at it. Only what the diagnosis reads anyway: the kernel log, udev and UDisks2,
# never the disk itself.
bm_notifier_health() {
   local dev="$1" disk boot="" key name grade w
   [ "${F[DISK_TYPE]:-}" = disk ] || return 0
   disk="${F[DISK]}"
   declare -F bm_ds_level >/dev/null || { bm_load drive-detect.sh; bm_load drive-diag.sh; }
   bm_dv_scan 2>/dev/null || return 0
   [ -n "${DV[$disk|TYPE]:-}" ] || return 0
   bm_ds_level "$disk"
   case "$DS_LEVEL" in critical | attention) ;; *) return 0 ;; esac
   read -r boot < /proc/sys/kernel/random/boot_id 2>/dev/null
   bm_dv_stable_id "$disk"; key="$boot health $REPLY"
   grep -qxF -- "$key" "$BM_NOTIFIED" 2>/dev/null && return 0
   printf '%s\n' "$key" >> "$BM_NOTIFIED"
   bm_dv_name "$disk"; name="$REPLY"
   bm_ds_grade_label; grade="$REPLY"
   bm_doc_new
   printf -v REPLY $"%s: %s" "$name" "$grade"
   bm_doc_h "$REPLY"
   if [ "$DS_LEVEL" = critical ]; then
      bm_doc_p $"This drive reported serious problems. Copy your files to another drive before trying any repair."
   else
      bm_doc_p $"This drive reported problems. Copy what matters to another place."
   fi
   for w in "${DS_WHY[@]}"; do bm_ds_why_text "$w"; bm_doc_li "$REPLY"; done
   bm_doc_p $"Big-Mount shows what was found and how to rescue the files without writing to the drive."
   (
      if bm_ui_confirm $"A drive needs attention" dialog-warning $"Open Big-Mount" $"Close"; then
         "$BM_SELF" --gui-drive-check "$disk"
      fi
   ) </dev/null >/dev/null 8>&- &
}

bm_notifier_check() {
   local dev="$1" mp="$2" key cause body icon name l_details l_help acts=()
   [[ $dev == /dev/* ]] || return 0
   case "$mp" in
      /run/media/"${USER:-$BM_USER}"/* | /media/* | /mnt/*) ;;
      *) return 0 ;;
   esac
   [ "$mp" = /mnt/user-mount ] && return 0
   bm_facts "$dev" || return 0
   bm_notifier_health "$dev"
   bm_facts "$dev" || return 0
   # Optical discs and images are read-only by nature: nothing to explain
   [ "${F[DISK_TYPE]}" = rom ] && return 0
   case "${F[FSTYPE]}" in squashfs | iso9660 | erofs | udf) return 0 ;; esac
   bm_diagnose_write "$dev"
   case "$D_CAUSE" in
      ok | not-mounted | unsupported) return 0 ;;
      # Read-only because the person asked for it in Big-Mount
      hw-readonly | mounted-ro) bm_chosen_ro "$dev" && return 0 ;;
   esac
   # Another operating system mounted by big-mount (its folders belong to it):
   # nothing to fix, so no warning at every login. --diagnose still explains it.
   bm_cause_key
   [ "$REPLY" = permission-os ] && return 0
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
      action="$(bm_notify warning "$icon" "$C_TITLE" "$body" "${acts[@]}")"
      case "$action" in
         details | fix) "$BM_SELF" --gui "$dev" ;;
         help) bm_gui_help "$dev" ;;
      esac
   ) </dev/null >/dev/null 8>&- &
}

bm_notifier() {
   local line rundir="${XDG_RUNTIME_DIR:-/run/user/$EUID}" statedir="${XDG_STATE_HOME:-$HOME/.local/state}/big-mount"
   BM_USER="$(id -un)"
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
   # One notifier per session. Children never get fd 8: one that outlived
   # the notifier would keep the lock, and every later notifier would quit.
   # Opened without truncating: the lock holds the PID of the notifier, which
   # the application stops when the person turns it off
   exec 8>> "$rundir/big-mount-notifier.lock" || return 1
   flock -n 8 || return 0
   printf '%s\n' "$$" > "$rundir/big-mount-notifier.lock"

   # Devices already mounted at login (big-mount mounts them at boot)
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      bm_notifier_check "${KV[SOURCE]%%\[*}" "${KV[TARGET]}"
   done < <(findmnt -P -n -o SOURCE,TARGET 2>/dev/null 8>&-)

   # Then react to mounts and remounts (errors=remount-ro shows up as one)
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      case "${KV[ACTION]}" in
         mount | remount)
            bm_notifier_check "${KV[SOURCE]%%\[*}" "${KV[TARGET]}"
            ;;
      esac
   # The kernel ends findmnt with the notifier (it would otherwise live on
   # until the next mount event, writing to a closed pipe)
   done < <(LC_ALL=C setpriv --pdeathsig TERM -- findmnt --poll=mount,remount -P -o ACTION,SOURCE,TARGET 2>/dev/null 8>&-)
}
