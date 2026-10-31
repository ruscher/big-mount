# shellcheck shell=bash
# shellcheck disable=SC2034,SC2015  # DS_*, MNT_* are read by the other drive modules; A && B || C on purpose
#
# big-mount drive manager: how a drive is doing, and mounting it without
# changing it. Diagnosis only reads /proc, /sys, udev, UDisks2 and the kernel
# log. It never reads the device: looking at a failing disk must not wear it.

# ---------------------------------------------------------------------------
# SMART details, on request

# The helper asks for the administrator password, and a read through a USB
# bridge can take more than a minute on a failing disk. So it only runs when
# asked, and what it said is kept for this connection of the drive: another
# drive under the same name has another diskseq.
bm_ds_smart_file() {
   local dir="${XDG_RUNTIME_DIR:-/run/user/$EUID}/big-mount"
   bm_diskseq "$1"
   REPLY="$dir/smart-${1##*/}-${REPLY:-0}.txt"
}

# bm_ds_smart_parse FILE: what matters from `smartctl -H -A`. Sets
#   SM_VERDICT     passed | failed | "" (not reported)
#   SM_PENDING SM_OFFLINE SM_REALLOC SM_UNCORR SM_CRC SM_HOURS  raw values or ""
#   SM_NVME_WARN   NVMe critical warning (0x00 is fine)  SM_NVME_MEDIA  media errors
#   SM_NVME_USED   percentage used
#   SM_TEMP        temperature, °C
bm_ds_smart_parse() {
   local line id raw k v head=""
   SM_VERDICT="" SM_PENDING="" SM_OFFLINE="" SM_REALLOC="" SM_UNCORR="" SM_CRC="" SM_HOURS=""
   SM_NVME_WARN="" SM_NVME_MEDIA="" SM_NVME_USED="" SM_TEMP=""
   [ -r "$1" ] || return 1
   while IFS= read -r line; do
      case "$line" in
         *"overall-health self-assessment test result:"*)
            case "$line" in *PASSED*) SM_VERDICT=passed ;; *) SM_VERDICT=failed ;; esac ;;
         "SMART Health Status: OK"*) SM_VERDICT=passed ;;
         "SMART Health Status:"*) SM_VERDICT=failed ;;
         "Critical Warning:"*) v="${line#*:}"; SM_NVME_WARN="${v//[[:space:]]/}" ;;
         "Media and Data Integrity Errors:"*) v="${line#*:}"; SM_NVME_MEDIA="${v//[^0-9]/}" ;;
         "Percentage Used:"*) v="${line#*:}"; SM_NVME_USED="${v//[^0-9]/}" ;;
         "Power On Hours:"*) v="${line#*:}"; SM_HOURS="${v//[^0-9]/}" ;;
         "Temperature:"*Celsius*) v="${line#*:}"; v="${v%%Celsius*}"; SM_TEMP="${v//[^0-9]/}" ;;
         *)
            # ID# ATTRIBUTE_NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
            read -r id k _ _ _ _ _ _ _ raw _ <<< "$line"
            # Some drives count the hours twice, and the power-on counter of a
            # few Seagate models wraps: the head flying hours are a floor
            if [ "$k" = Head_Flying_Hours ] && [[ $raw =~ ^([0-9]+)h ]]; then head="${BASH_REMATCH[1]}"; continue; fi
            [[ $id =~ ^[0-9]+$ ]] && [[ $raw =~ ^[0-9]+$ ]] || continue
            case "$id" in
               5) SM_REALLOC="$raw" ;;
               9) SM_HOURS="$raw" ;;
               187) SM_UNCORR="$raw" ;;
               197) SM_PENDING="$raw" ;;
               198) SM_OFFLINE="$raw" ;;
               199) SM_CRC="$raw" ;;
               194) SM_TEMP="$raw" ;;
               190) SM_TEMP="${SM_TEMP:-$raw}" ;;
            esac
            ;;
      esac
   done < "$1"
   [ -n "$head" ] && [ "$head" -gt "${SM_HOURS:-0}" ] && SM_HOURS="$head"
   return 0
}

# bm_ds_smart_read DISK: ask the helper (password) and keep the answer
bm_ds_smart_read() {
   local disk="$1" f tmp rc
   bm_ds_smart_file "$disk"; f="$REPLY"
   mkdir -p -- "${f%/*}" 2>/dev/null
   tmp="$(mktemp -- "$f.XXXXXX")" || return 1
   bm_helper smart "$disk" > "$tmp" 2>/dev/null; rc=$?
   if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
      mv -f -- "$tmp" "$f"
      return 0
   fi
   rm -f -- "$tmp"
   return "$rc"
}

# ---------------------------------------------------------------------------
# Level of a drive

# bm_ds_level DISK: what can be said about a drive, and how sure it is.
#   DS_LEVEL  normal | attention | critical | unknown | na (a disk image)
#   DS_WHY    reasons, most serious first (bm_ds_why_text)
#   DS_BASIS  smart+log | log | smart | none: what the verdict rests on. "normal"
#             never means healthy: it means no check found anything
bm_ds_level() {
   local disk="$1" w
   DS_LEVEL=unknown DS_WHY=() DS_BASIS=none DS_SMART_AT="" SM_VERDICT="" SM_PENDING="" SM_OFFLINE="" SM_REALLOC="" SM_UNCORR="" SM_CRC="" SM_HOURS=""
   SM_NVME_WARN="" SM_NVME_MEDIA="" SM_NVME_USED="" SM_TEMP="" DS_DISK="$disk" DS_GRADE=unknown DS_NOTES=()
   DH_HOURS="" DH_TEMP="" DH_ATTR_FAIL="" DH_ATTR_PAST="" DH_NVME_WARN="" DH_NVME_USED="" DH_NVME_MEDIA="" DH_NVME_HOT=""
   case "${DV[$disk|TYPE]:-disk}" in
      loop | rom) DS_LEVEL=na DS_GRADE=na; return 0 ;;
   esac
   bm_drive_health "$disk"
   bm_ds_smart_file "$disk"
   local have_smart=0
   DS_SMART_AT=""
   if [ -s "$REPLY" ]; then
      bm_ds_smart_parse "$REPLY"; have_smart=1
      DS_SMART_AT="$(stat -c %Y -- "$REPLY" 2>/dev/null)"
   fi
   # What UDisks2 keeps without a password fills what was not read with it
   SM_HOURS="${SM_HOURS:-$DH_HOURS}" SM_TEMP="${SM_TEMP:-$DH_TEMP}"
   SM_NVME_USED="${SM_NVME_USED:-$DH_NVME_USED}" SM_NVME_MEDIA="${SM_NVME_MEDIA:-$DH_NVME_MEDIA}"
   [ -z "$SM_NVME_WARN" ] && [ -n "$DH_NVME_WARN" ] && SM_NVME_WARN="$DH_NVME_WARN"
   if [ "$DH_KLOG" = 1 ] && { [ "$have_smart" = 1 ] || [ -n "$DH_SMART" ]; }; then DS_BASIS=smart+log
   elif [ "$DH_KLOG" = 1 ]; then DS_BASIS=log
   elif [ "$have_smart" = 1 ] || [ -n "$DH_SMART" ]; then DS_BASIS=smart
   fi

   local crit=() attn=()
   for w in "${DH_FIND[@]}"; do
      case "$w" in
         smart-failing) crit+=(smart-failing) ;;
         io-errors)
            # One error can be a bad cable. Several are not.
            if [ "${DH_COUNT[io-errors]:-0}" -ge 3 ]; then crit+=(io-errors); else attn+=(io-errors); fi
            ;;
         *) attn+=("$w") ;;
      esac
   done
   [ "$SM_VERDICT" = failed ] && [[ " ${crit[*]} " != *" smart-failing "* ]] && crit+=(smart-failing)
   # The verdict of a drive is often PASSED with thousands of unreadable
   # sectors: the raw counters are what tells
   [ "${SM_PENDING:-0}" -gt 0 ] 2>/dev/null && crit+=(pending-sectors)
   [ "${SM_OFFLINE:-0}" -gt 0 ] 2>/dev/null && [ "${SM_PENDING:-0}" = 0 ] && crit+=(pending-sectors)
   if [ -n "$SM_NVME_WARN" ] && [ "$SM_NVME_WARN" != 0x00 ]; then crit+=(nvme-warning); fi
   [ "${SM_NVME_MEDIA:-0}" -gt 0 ] 2>/dev/null && crit+=(nvme-media)
   [ "${SM_REALLOC:-0}" -gt 0 ] 2>/dev/null && attn+=(reallocated)
   [ "${SM_UNCORR:-0}" -gt 0 ] 2>/dev/null && attn+=(uncorrectable)
   [ "${SM_CRC:-0}" -gt 0 ] 2>/dev/null && attn+=(link-errors)
   [ "${DH_ATTR_FAIL:-0}" -gt 0 ] 2>/dev/null && attn+=(attrs-failing)
   # A few replaced sectors are normal on an SSD (see 14), not on a hard disk
   [ "${DV[$disk|ROTA]:-0}" = 1 ] && [ "${DV[$disk|TRAN]:-}" != usb ] && [ "${DH_BAD:-0}" -gt 0 ] && attn+=(reallocated)

   DS_WHY=("${crit[@]}" "${attn[@]}")
   if [ "${#crit[@]}" -gt 0 ]; then DS_LEVEL=critical
   elif [ "${#attn[@]}" -gt 0 ]; then DS_LEVEL=attention
   elif [ "$DS_BASIS" != none ]; then DS_LEVEL=normal
   fi
   bm_ds_grade
   return 0
}

# bm_ds_grade: the level in one word for a person, also weighing wear, age
# and heat (called by bm_ds_level).
#   DS_GRADE  critical | poor | good | healthy | unknown | na
#   DS_NOTES  why a drive without alerts is not "healthy" (bm_ds_note_text)
# "healthy" needs the drive's own report: from the system log alone the best
# that can be said is "good". Age alone never makes a drive poor: worn-out
# flash (90 % of its rated life) does.
bm_ds_grade() {
   DS_NOTES=()
   case "$DS_LEVEL" in
      critical) DS_GRADE=critical; return 0 ;;
      attention) DS_GRADE=poor; return 0 ;;
      na) DS_GRADE=na; return 0 ;;
      normal) ;;
      *) DS_GRADE=unknown; return 0 ;;
   esac
   local rota="${DV[$DS_DISK|ROTA]:-0}" old=50000 hot=70
   # Hard disks fail more often after about four years powered on
   [ "$rota" = 1 ] && old=35000 hot=55
   [ -n "$DH_NVME_HOT" ] && hot="$DH_NVME_HOT"
   case "$DS_BASIS" in smart+log | smart) ;; *) DS_NOTES+=(smart-unread) ;; esac
   if [ "${SM_NVME_USED:-0}" -ge 90 ] 2>/dev/null; then DS_NOTES+=(worn-out)
   elif [ "${SM_NVME_USED:-0}" -ge 50 ] 2>/dev/null; then DS_NOTES+=(wear)
   fi
   [ "${DH_ATTR_PAST:-0}" -gt 0 ] 2>/dev/null && DS_NOTES+=(attrs-past)
   [ "${SM_HOURS:-0}" -ge "$old" ] 2>/dev/null && DS_NOTES+=(old)
   [ "${SM_TEMP:-0}" -ge "$hot" ] 2>/dev/null && DS_NOTES+=(hot)
   if [[ " ${DS_NOTES[*]} " == *" worn-out "* ]]; then DS_GRADE=poor
   elif [ "${#DS_NOTES[@]}" -gt 0 ]; then DS_GRADE=good
   else DS_GRADE=healthy
   fi
}

bm_ds_grade_label() {
   case "$DS_GRADE" in
      critical) REPLY=$"Critical" ;;
      poor) REPLY=$"Poor" ;;
      good) REPLY=$"Good" ;;
      healthy) REPLY=$"Healthy" ;;
      na) REPLY=$"Not applicable" ;;
      *) REPLY=$"Not assessed" ;;
   esac
}

# bm_ds_note_text KEY: one sentence for a person
bm_ds_note_text() {
   local years
   case "$1" in
      smart-unread) REPLY=$"Only the system log was consulted. Without the drive's own report (SMART) it cannot be called healthy." ;;
      worn-out) printf -v REPLY $"It has used %s%% of the life its maker rates it for: it is near or past its end." "$SM_NVME_USED" ;;
      wear) printf -v REPLY $"It has used %s%% of the life its maker rates it for." "$SM_NVME_USED" ;;
      attrs-past) REPLY=$"Some of its SMART values were below their safe limit in the past." ;;
      old)
         years=$(((SM_HOURS + 4380) / 8760))
         printf -v REPLY $"Powered on for %s hours, about %s years of use: failures become more likely." "$SM_HOURS" "$years"
         ;;
      hot) printf -v REPLY $"It is hot now (%s °C). Heat shortens its life: give it air." "$SM_TEMP" ;;
      *) REPLY="$1" ;;
   esac
}
bm_ds_level_label() {
   case "$DS_LEVEL" in
      critical) REPLY=$"Critical: high risk for the data" ;;
      attention) REPLY=$"Attention: needs a closer look" ;;
      normal)
         case "$DS_BASIS" in
            smart+log) REPLY=$"No alerts (SMART and system log checked)" ;;
            log) REPLY=$"No alerts in the system log (SMART not read)" ;;
            *) REPLY=$"No alerts from SMART (system log not readable)" ;;
         esac
         ;;
      na) REPLY=$"Not applicable (a disk image)" ;;
      *) REPLY=$"Unknown: not enough information" ;;
   esac
}

# bm_ds_why_text KEY: one sentence for a person
bm_ds_why_text() {
   case "$1" in
      smart-failing) REPLY=$"The drive itself reports that it is failing (SMART)." ;;
      pending-sectors) printf -v REPLY $"The drive has sectors it can no longer read (%s pending), even if its overall verdict says PASSED." "${SM_PENDING:-${SM_OFFLINE:-?}}" ;;
      nvme-warning) printf -v REPLY $"The NVMe drive raised a critical warning (%s)." "$SM_NVME_WARN" ;;
      nvme-media) printf -v REPLY $"The NVMe drive recorded %s media or data integrity errors." "$SM_NVME_MEDIA" ;;
      io-errors) printf -v REPLY $"Since the computer was started, reading or writing failed (%s kernel messages)." "${DH_COUNT[io-errors]:-0}" ;;
      timeouts) printf -v REPLY $"Since the computer was started, it stopped answering and the connection had to be reset (%s kernel messages)." "${DH_COUNT[timeouts]:-0}" ;;
      usb-resets) printf -v REPLY $"Since the computer was started, the USB connection was reset or lost %s times." "${DH_COUNT[usb-resets]:-0}" ;;
      slow-link) REPLY=$"Since the computer was started, the connection was slowed down after errors." ;;
      reallocated) REPLY=$"The drive already replaced damaged sectors with spare ones." ;;
      uncorrectable) printf -v REPLY $"The drive reported %s errors it could not correct." "${SM_UNCORR:-?}" ;;
      link-errors) printf -v REPLY $"The cable or adapter corrupted data in transit %s times (CRC errors)." "${SM_CRC:-?}" ;;
      attrs-failing) printf -v REPLY $"%s of its SMART values are below their safe limit now." "${DH_ATTR_FAIL:-?}" ;;
      *) REPLY="$1" ;;
   esac
}

# The health members of a drive object (F is not needed)
bm_ds_json() {
   local w first=1 why=""
   for w in "${DS_WHY[@]}"; do
      bm_ds_why_text "$w"
      [ "$first" = 1 ] && first=0 || why+=","
      why+="$(bm_jo key "$w" text "$REPLY")"
   done
   local notes="" note
   first=1
   for w in "${DS_NOTES[@]}"; do
      bm_ds_note_text "$w"
      [ "$first" = 1 ] && first=0 || notes+=","
      notes+="$(bm_jo key "$w" text "$REPLY")"
   done
   bm_ds_level_label; local label="$REPLY"
   bm_ds_grade_label; note="$REPLY"
   printf '"health":{"level":"%s","label":%s,"grade":"%s","grade_label":%s,"basis":"%s","reasons":[%s],"notes":[%s],"smart":{%s}}' \
      "$DS_LEVEL" "$(bm_js "$label"; printf '%s' "$REPLY")" "$DS_GRADE" "$(bm_js "$note"; printf '%s' "$REPLY")" "$DS_BASIS" "$why" "$notes" \
      "$(bm_jn pending "$SM_PENDING" offline "$SM_OFFLINE" reallocated "$SM_REALLOC" uncorrectable "$SM_UNCORR" crc "$SM_CRC" hours "$SM_HOURS" temperature "$SM_TEMP" read_at "$DS_SMART_AT" nvme_media "$SM_NVME_MEDIA" nvme_used "$SM_NVME_USED"),$(bm_jo_inner verdict "$SM_VERDICT" nvme_warning "$SM_NVME_WARN")"
}

# ---------------------------------------------------------------------------
# Diagnosis

# Why a mounted volume cannot be written, in the words of bm_cause_text.
# Empty when it can (REPLY)
bm_dg_write_cause() {
   local dev="$1"
   REPLY=""
   bm_facts "$dev" || return 1
   bm_diagnose_write "$dev" ""
   bm_cause_key
   return 0
}

# bm_dg_show TARGET: the diagnosis as text
bm_dg_show() {
   local target="$1" d="$2" w p st
   bm_dv_name "$d"
   bm_doc_new
   bm_doc_h "$REPLY"
   bm_dv_kind "$d"; bm_dv_kind_label "$REPLY"; bm_doc_kv $"Type" "$REPLY"
   bm_human_size "${DV[$d|SIZE]:-}"; bm_doc_kv $"Capacity" "$REPLY"
   bm_tran_label "${DV[$d|TRAN]:-}"; bm_doc_kv $"Connection" "$REPLY"
   bm_doc_kv $"Device" "$d"
   bm_ds_level "$d"
   bm_ds_grade_label; local grade="$REPLY"
   bm_ds_level_label; bm_doc_kv $"Health" "$grade — $REPLY"
   [ -n "$SM_VERDICT" ] && bm_doc_kv $"SMART verdict" "$SM_VERDICT"
   if [ "${#DS_WHY[@]}" -gt 0 ]; then
      bm_doc_p $"What was found:"
      for w in "${DS_WHY[@]}"; do bm_ds_why_text "$w"; bm_doc_li "$REPLY"; done
   fi
   if [ "${#DS_NOTES[@]}" -gt 0 ]; then
      bm_doc_p $"Why it is not called healthy:"
      for w in "${DS_NOTES[@]}"; do bm_ds_note_text "$w"; bm_doc_li "$REPLY"; done
   fi
   bm_ds_advice
   for w in "${DS_ADVICE[@]}"; do bm_doc_li "$w"; done
   bm_doc_p $"Volumes:"
   bm_dv_tree "$d"
   local tree=("${DV_TREE[@]}")
   for p in "${tree[@]}"; do
      [ "$p" = "$d" ] && [ -z "${DV[$p|FSTYPE]:-}" ] && continue
      bm_dv_state "$p"; st="$REPLY"
      bm_dv_state_label "$st"
      local line="$p: ${DV[$p|FSTYPE]:-?} — $REPLY${DV_MP:+ ($DV_MP)}"
      if [ "$st" = unmounted ] && ! bm_dv_fs_supported "${DV[$p|FSTYPE]}"; then
         line+=" — "$"no driver for this filesystem on this computer"
      fi
      [ "${DV[$p|RO]:-0}" = 1 ] && line+=" — "$"writing blocked on the device"
      bm_doc_li "$line"
   done
   bm_ui_show info ""
   if [ "$DS_BASIS" = log ] || [ "$DS_BASIS" = none ]; then
      case "${DV[$d|TYPE]}" in
         disk) printf '%s\n' $"For the SMART details of the drive, which need the administrator password: bigmount --drive diagnose DEVICE --smart" ;;
      esac
   fi
}

# What the level means in practice (DS_ADVICE)
bm_ds_advice() {
   DS_ADVICE=()
   case "$DS_LEVEL" in
      critical)
         DS_ADVICE=($"Copy what matters now, starting with the most important files. Every extra read wears a failing disk."
            $"Do not run repair tools on this disk: they write, and they can destroy what is still readable."
            $"If the data is very important and cannot be replaced, consider a data recovery professional before insisting.")
         ;;
      attention)
         DS_ADVICE=($"Copy your important files to another place."
            $"Try another cable and connect the drive directly to the computer, without a hub.")
         ;;
   esac
}

# ---------------------------------------------------------------------------
# Mounting without changing anything

# Options for a read-only mount. UDisks2 only accepts a known list: noload
# (ext3/ext4: do not replay the journal, which writes) is on it. XFS
# norecovery and Btrfs rescue= are not, so those are protected at the device.
bm_mnt_options() {
   REPLY="ro,noatime,nosuid,nodev,noexec"
   case "$1" in ext3 | ext4) REPLY+=",noload" ;; esac
}

# Why a mount failed (MNT_WHY), from the error of mount and the kernel log
bm_mnt_explain() {
   local dev="$1" fs="$2" msg="$3" l
   MNT_WHY=unknown
   case "$msg" in
      *NotAuthorized*) MNT_WHY=not-authorized; return ;;
      *"unknown filesystem type"* | *"no such filesystem"*) MNT_WHY=no-driver; return ;;
      *[Hh]ibernat* | *"Windows is hibernated"* | *"unsafe state"*) MNT_WHY=ntfs-hibernated; return ;;
      *"Input/output error"* | *"I/O error"* | *"can't read superblock"*) MNT_WHY=io-error ;;
      *"bad superblock"* | *"wrong fs type"* | *"Can't find"* | *"NTFS signature is missing"*) MNT_WHY="fs-damaged" ;;
      *"write-protected"* | *"Read-only file system"* | *"read-only"*) MNT_WHY=needs-recovery ;;
   esac
   bm_kernel_messages "${dev##*/}" "${F[DISK]##*/}"
   for l in "${KMSG[@]:$((${#KMSG[@]} > 8 ? ${#KMSG[@]} - 8 : 0))}"; do
      case "$l" in
         *"I/O error"* | *"critical medium error"*) MNT_WHY=io-error; return ;;
         *"recovery required"* | *"write access unavailable"* | *"needs recovery"* | *"log replay required"* | *"cannot replay"*) MNT_WHY="needs-recovery"; return ;;
      esac
   done
   return 0
}

bm_mnt_why_text() {
   case "$1" in
      not-authorized) REPLY=$"Permission to mount was not granted." ;;
      no-driver) REPLY=$"This computer has no driver for this filesystem. Installing the right package may solve it." ;;
      ntfs-hibernated) REPLY=$"Windows left this partition hibernated (Fast Startup). It can be read only after Windows shuts down completely." ;;
      io-error) REPLY=$"The drive could not read the start of this filesystem. This is usually damage on the disk, a bad cable or a weak USB port. Making a disk image with GNU ddrescue is the safest next step." ;;
      fs-damaged) REPLY=$"The structure of this filesystem seems damaged, or this is not the filesystem it claims to be. Nothing was repaired. A disk image or a search for files (PhotoRec) may still recover data." ;;
      needs-recovery) REPLY=$"This filesystem was not closed properly and needs to replay its journal, which writes to the disk. To protect the data that was not done. A disk image, worked on as a copy, is the safe way to read it." ;;
      locked) REPLY=$"This volume is encrypted. Unlock it first." ;;
      member) REPLY=$"This is a part of a larger volume (RAID, LVM or similar), not a filesystem of its own. Its volume must be assembled first." ;;
      no-fs) REPLY=$"No filesystem was recognized on it. If it should have partitions, searching for them with TestDisk does not change the disk." ;;
      swap) REPLY=$"This is swap space, not a place for files." ;;
      gone) REPLY=$"The device was disconnected or replaced. Nothing was done." ;;
      refused-rw) REPLY=$"This drive reported problems, so it is only mounted read-only. Writing to it can destroy what is still readable." ;;
      already-rw) REPLY=$"It is already mounted with writing enabled. Unmount it first to mount it read-only (bigmount --drive mount DEVICE --remount)." ;;
      busy) REPLY=$"It is in use, so it could not be unmounted to be mounted again." ;;
      *) REPLY=$"The reason could not be determined. Nothing was changed on the device. See the technical details." ;;
   esac
}

# bm_mnt_mount DEV MODE PROTECT REMOUNT: mount one volume. MODE ro|rw. PROTECT=1
# blocks writing on the block device first (administrator password): whatever
# a driver or another program tries afterwards, the disk does not change.
# Sets MNT_POINT, MNT_RO, MNT_PROTECTED, MNT_WHY, MNT_DETAIL. Returns:
# 0 mounted, 20 refused by a check, 5 not authorized, 24 device gone, 1 failed.
bm_mnt_mount() {
   local dev="$1" mode="$2" protect="$3" remount="$4" fs st opts seq disk
   MNT_POINT="" MNT_RO=0 MNT_PROTECTED=0 MNT_WHY="" MNT_DETAIL=""
   bm_dv_scan
   [ -n "${DV[$dev|TYPE]:-}" ] || { MNT_WHY=gone; return 24; }
   bm_facts "$dev" || { MNT_WHY=gone; return 24; }
   disk="${F[DISK]}" fs="${F[FSTYPE]}"
   bm_diskseq "$disk"; seq="$REPLY"
   bm_dv_state "$dev"; st="$REPLY"
   case "$st" in
      locked) MNT_WHY=locked; return 20 ;;
      member) MNT_WHY=member; return 20 ;;
      no-fs | container) MNT_WHY=no-fs; return 20 ;;
      swap | swap-idle) MNT_WHY=swap; return 20 ;;
      unlocked) MNT_WHY=locked; return 20 ;;
   esac
   bm_ds_level "$disk"
   if [ "$mode" = rw ] && [ "$DS_LEVEL" = critical ]; then MNT_WHY=refused-rw; return 20; fi

   if [ -n "$DV_MP" ]; then
      if [ "$st" = system ]; then
         MNT_POINT="$DV_MP" MNT_RO="$DV_RO"
         return 0
      fi
      if [ "$mode" = ro ] && [ "$DV_RO" = 0 ]; then
         if [ "$remount" != 1 ]; then MNT_POINT="$DV_MP"; MNT_WHY=already-rw; return 20; fi
         if ! bm_unmount_all "$dev"; then
            MNT_DETAIL="$UD_MESSAGE"
            case "$UD_ERROR" in
               *DeviceBusy*) MNT_WHY=busy; return 3 ;;
               *NotAuthorized*) MNT_WHY=not-authorized; return 5 ;;
            esac
            MNT_WHY=unknown
            return 1
         fi
      else
         MNT_POINT="$DV_MP" MNT_RO="$DV_RO"
         [ "${DV[$dev|RO]:-0}" = 1 ] && MNT_PROTECTED=1
         return 0
      fi
   fi

   bm_diskseq "$disk"
   [ "$REPLY" = "$seq" ] || { MNT_WHY=gone; return 24; }
   if [ "$protect" = 1 ] && [ "$mode" = ro ]; then
      bm_helper protect "$dev"; local hrc=$?
      case "$hrc" in
         0) MNT_PROTECTED=1 ;;
         126 | 127) MNT_WHY=not-authorized; return 5 ;;
         *) MNT_WHY=unknown; MNT_DETAIL="helper protect: exit $hrc"; return 1 ;;
      esac
   fi

   if [ "$mode" = ro ]; then
      bm_mnt_options "$fs"; opts="$REPLY"
   else
      opts="noatime"
   fi
   if ! bm_udisks mount -b "$dev" -o "$opts"; then
      # A UDisks2 that refuses noload still mounts read-only; only with the
      # device protected is it certain that no journal gets replayed
      if [[ $UD_ERROR == *OptionNotPermitted* ]] && [ "$MNT_PROTECTED" = 1 ]; then
         bm_mnt_options ""; opts="$REPLY"
         bm_udisks mount -b "$dev" -o "$opts"
      fi
   fi
   if [ -n "$UD_ERROR" ]; then
      MNT_DETAIL="$UD_MESSAGE"
      bm_mnt_explain "$dev" "$fs" "$UD_ERROR $UD_MESSAGE"
      [ "$MNT_WHY" = not-authorized ] && return 5
      return 1
   fi
   bm_mounts "$dev"
   MNT_POINT="${M_TARGET[0]:-}"
   if [ -z "$MNT_POINT" ]; then
      MNT_WHY=unknown MNT_DETAIL="$UD_MESSAGE"
      return 1
   fi
   bm_has_opt "${M_VFSOPT[0]}" ro && MNT_RO=1
   # The mount table is the judge: read-only was asked, and read-only it must be
   if [ "$mode" = ro ] && [ "$MNT_RO" != 1 ]; then
      MNT_WHY=unknown MNT_DETAIL="asked for ro, mounted ${M_VFSOPT[0]}"
      return 1
   fi
   return 0
}
