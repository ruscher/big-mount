# shellcheck shell=bash
# shellcheck disable=SC2034  # DV*, DS_* are read by the other drive modules
#
# big-mount drive manager: what is connected. One lsblk snapshot, parsed once,
# and never a read from the device itself: a failing disk must not be touched
# just to be listed.

# Everything lsblk says about a device, as DV["DEV|KEY"], in lsblk order in
# DV_ORDER. A device that hangs under several parents (LVM on two disks, RAID)
# appears once, under the first one; DV_PARENTS keeps all of them.
declare -gA DV DV_PARENTS
DV_ORDER=() DV_PARTIAL=0 DV_TOP=()
BM_DV_BASE=NAME,KNAME,PKNAME,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTLABEL,PTTYPE,SIZE,RO,RM,HOTPLUG,ROTA,TRAN,VENDOR,MODEL,SERIAL,MOUNTPOINTS
BM_DV_FS=FSUSED,FSAVAIL

bm_dv_scan() {
   local line name out k
   DV=() DV_PARENTS=() DV_ORDER=() DV_PARTIAL=0 DV_TOP=()
   # The FS columns call statvfs: a mount whose driver is stuck on a bad
   # sector would hang the whole list, so they get a limit of their own
   if ! out="$(timeout 6 lsblk -P -b -p -o "$BM_DV_BASE,$BM_DV_FS" 2>/dev/null)"; then
      out="$(timeout 20 lsblk -P -b -p -o "$BM_DV_BASE" 2>/dev/null)" || return 1
      DV_PARTIAL=1
   fi
   while IFS= read -r line; do
      [ -n "$line" ] || continue
      bm_parse_pairs "$line"
      name="${KV[NAME]:-}"
      [ -n "$name" ] || continue
      [ -n "${KV[PKNAME]:-}" ] && DV_PARENTS[$name]+="${KV[PKNAME]} "
      [ -n "${DV[$name|TYPE]+set}" ] && continue
      DV_ORDER+=("$name")
      for k in "${!KV[@]}"; do DV[$name|$k]="${KV[$k]}"; done
      DV[$name|MODEL]="${DV[$name|MODEL]%"${DV[$name|MODEL]##*[! ]}"}"
      DV[$name|VENDOR]="${DV[$name|VENDOR]%"${DV[$name|VENDOR]##*[! ]}"}"
      [ "${DV[$name|VENDOR]}" = ATA ] && DV[$name|VENDOR]=""
      # USB bridges often cut the model in two: "ST1000DM" + "ST1000DM003-1CH162"
      [ -n "${DV[$name|VENDOR]}" ] && [[ ${DV[$name|MODEL]} == "${DV[$name|VENDOR]}"* ]] && DV[$name|VENDOR]=""
      # A partition of a disk that was just unplugged has no parent any more
      bm_dv_is_top "$name" && DV_TOP+=("$name")
   done <<< "$out"
   return 0
}

# Devices shown at the top level: disks, optical drives and attached images.
# Memory devices and empty loop devices (swap backing files) are not storage.
bm_dv_is_top() {
   local d="$1"
   [ -z "${DV[$d|PKNAME]:-}" ] || return 1
   case "${d##*/}" in zram* | ram* | fd[0-9]*) return 1 ;; esac
   case "${DV[$d|TYPE]}" in
      disk | rom) return 0 ;;
      loop) [ -n "${DV[$d|FSTYPE]:-}${DV[$d|PTTYPE]:-}" ] ;;
      *) return 1 ;;
   esac
}

# Children of a device, in lsblk order (DV_KIDS)
bm_dv_children() {
   local d p
   DV_KIDS=()
   for d in "${DV_ORDER[@]}"; do
      [ "$d" = "$1" ] && continue
      for p in ${DV_PARENTS[$d]:-}; do
         [ "$p" = "$1" ] && { DV_KIDS+=("$d"); break; }
      done
   done
}

# The device and everything stacked on it, depth first (DV_TREE)
bm_dv_tree() {
   local q=("$1") d
   local -A seen=()
   DV_TREE=()
   while [ "${#q[@]}" -gt 0 ]; do
      d="${q[0]}"; q=("${q[@]:1}")
      [ -n "${seen[$d]:-}" ] && continue
      seen[$d]=1
      DV_TREE+=("$d")
      bm_dv_children "$d"
      q=("${DV_KIDS[@]}" "${q[@]}")
   done
}

# What kind of storage this is (REPLY). Only what the kernel knows: a USB
# bridge reports every disk as rotational, so USB stays "usb".
#   nvme ssd hdd usb sd emmc optical image unknown
bm_dv_kind() {
   local d="$1" name="${1##*/}" t=""
   case "${DV[$d|TYPE]:-}" in
      rom) REPLY=optical; return ;;
      loop) REPLY=image; return ;;
   esac
   case "${DV[$d|TRAN]:-}" in
      nvme) REPLY=nvme; return ;;
      usb | ieee1394) REPLY=usb; return ;;
   esac
   if [[ $name == mmcblk* ]] || [ "${DV[$d|TRAN]:-}" = mmc ]; then
      { read -r t < "/sys/block/$name/device/type"; } 2>/dev/null
      if [ "$t" = MMC ]; then REPLY=emmc; else REPLY=sd; fi
      return
   fi
   [[ $name == nvme* ]] && { REPLY=nvme; return; }
   case "${DV[$d|ROTA]:-}" in
      0) REPLY=ssd ;;
      1) REPLY=hdd ;;
      *) REPLY=unknown ;;
   esac
}

bm_dv_kind_label() {
   case "$1" in
      nvme) REPLY=$"NVMe SSD" ;;
      ssd) REPLY=$"SSD" ;;
      hdd) REPLY=$"Hard disk" ;;
      usb) REPLY=$"USB storage" ;;
      sd) REPLY=$"SD card" ;;
      emmc) REPLY=$"Built-in flash (eMMC)" ;;
      optical) REPLY=$"Optical drive" ;;
      image) REPLY=$"Disk image" ;;
      *) REPLY=$"Storage" ;;
   esac
}

# Theme icon for a kind (the GUI asks for the same names)
bm_dv_kind_icon() {
   case "$1" in
      nvme | ssd) REPLY=drive-harddisk-solidstate ;;
      hdd) REPLY=drive-harddisk ;;
      usb) REPLY=drive-removable-media-usb ;;
      sd | emmc) REPLY=media-flash-sd-mmc ;;
      optical) REPLY=drive-optical ;;
      image) REPLY=application-x-raw-disk-image ;;
      *) REPLY=drive-harddisk ;;
   esac
}

# Name for people: vendor and model, else the label, else the device name
bm_dv_name() {
   local d="$1"
   REPLY="${DV[$d|VENDOR]:+${DV[$d|VENDOR]} }${DV[$d|MODEL]:-}"
   [ -n "$REPLY" ] || REPLY="${DV[$d|LABEL]:-}"
   [ -n "$REPLY" ] || REPLY="${d##*/}"
}

# Disks a device really lives on, through partitions, LUKS, LVM and RAID
# (DV_DISKS, by stable-enough names for this moment). Comes from the topology
# the kernel reports, not from the device name.
bm_dv_disks_of() {
   local name type
   DV_DISKS=()
   while read -r name type; do
      [ "$type" = disk ] || [ "$type" = loop ] || [ "$type" = rom ] || continue
      [[ " ${DV_DISKS[*]} " == *" $name "* ]] || DV_DISKS+=("$name")
   done < <(lsblk -s -n -p -r -o NAME,TYPE -- "$1" 2>/dev/null)
   [ "${#DV_DISKS[@]}" -gt 0 ]
}

# Other members of a multi-device Btrfs (same UUID on several block devices).
# DV_MULTI: every device with that UUID.
bm_dv_multi_btrfs() {
   local u="${DV[$1|UUID]:-}" d
   DV_MULTI=()
   [ "${DV[$1|FSTYPE]:-}" = btrfs ] && [ -n "$u" ] || return 1
   for d in "${DV_ORDER[@]}"; do
      [ "${DV[$d|FSTYPE]:-}" = btrfs ] && [ "${DV[$d|UUID]:-}" = "$u" ] && DV_MULTI+=("$d")
   done
   [ "${#DV_MULTI[@]}" -gt 1 ]
}

# Can this filesystem be mounted here at all? A driver in the running kernel,
# a module on disk or a mount helper. Nothing is loaded by asking.
bm_dv_fs_supported() {
   local fs="$1" l rel
   case "$fs" in "" | swap | crypto_LUKS | BitLocker | *_member) return 1 ;; esac
   [ "$fs" = ntfs ] && [ -x /usr/bin/ntfs-3g ] && return 0
   while read -r l; do
      [ "${l##*[[:space:]]}" = "$fs" ] && return 0
   done < /proc/filesystems
   command -v "mount.$fs" >/dev/null && return 0
   rel="$(uname -r)"
   compgen -G "/lib/modules/$rel/kernel/fs/$fs/*" >/dev/null || compgen -G "/lib/modules/$rel/kernel/fs/$fs.ko*" >/dev/null
}

# A short state for one device (REPLY): role a filesystem plays. Also DV_RO
# (1: a mount of it is read-only) and DV_MP (the mount point that matters).
bm_dv_state() {
   local d="$1" fs opts
   fs="${DV[$d|FSTYPE]:-}"
   DV_MP="" DV_RO=0
   bm_main_mountpoint "${DV[$d|MOUNTPOINTS]:-}"; DV_MP="$REPLY"
   if [ -n "$DV_MP" ]; then
      opts="$(findmnt -n -o VFS-OPTIONS --mountpoint "$DV_MP" 2>/dev/null)"
      bm_has_opt "$opts" ro && DV_RO=1
      if bm_is_system_mount "$DV_MP"; then REPLY=system
      elif [ "$DV_RO" = 1 ]; then REPLY=mounted-ro
      else REPLY=mounted-rw
      fi
      return
   fi
   case "${DV[$d|MOUNTPOINTS]:-}" in *"[SWAP]"*) REPLY=swap; return ;; esac
   case "$fs" in
      crypto_LUKS | BitLocker)
         bm_dv_children "$d"
         if [ "${#DV_KIDS[@]}" -gt 0 ]; then REPLY=unlocked; else REPLY=locked; fi
         ;;
      *_member) REPLY=member ;;
      swap) REPLY=swap-idle ;;
      "")
         bm_dv_children "$d"
         if [ "${#DV_KIDS[@]}" -gt 0 ]; then REPLY=container; else REPLY=no-fs; fi
         ;;
      *) REPLY=unmounted ;;
   esac
}

bm_dv_state_label() {
   case "$1" in
      system) REPLY=$"In use by the running system" ;;
      mounted-rw) REPLY=$"Mounted" ;;
      mounted-ro) REPLY=$"Mounted read-only" ;;
      swap) REPLY=$"In use as swap" ;;
      swap-idle) REPLY=$"Swap space, not in use" ;;
      locked) REPLY=$"Encrypted and locked" ;;
      unlocked) REPLY=$"Encrypted, unlocked" ;;
      member) REPLY=$"Part of a volume (RAID, LVM or similar)" ;;
      container) REPLY=$"Holds other volumes" ;;
      no-fs) REPLY=$"No known filesystem" ;;
      unmounted) REPLY=$"Not mounted" ;;
      *) REPLY=$"Unknown" ;;
   esac
}

# ---------------------------------------------------------------------------
# Output

bm_dv_part_json() {
   local d="$1" out="" st k
   bm_dv_state "$d"; st="$REPLY"
   bm_dv_state_label "$st"
   out="$(bm_jo device "$d" type "${DV[$d|TYPE]}" fstype "${DV[$d|FSTYPE]:-}" fsver "${DV[$d|FSVER]:-}" \
      label "${DV[$d|LABEL]:-}" uuid "${DV[$d|UUID]:-}" state "$st" state_label "$REPLY" mountpoint "$DV_MP")"
   out="${out%\}}"
   k="$(bm_jn size "${DV[$d|SIZE]:-}" used "${DV[$d|FSUSED]:-}" avail "${DV[$d|FSAVAIL]:-}")"
   out+=",$k,$(bm_jb read_only "$DV_RO" device_read_only "${DV[$d|RO]:-0}")"
   bm_dv_fs_supported "${DV[$d|FSTYPE]:-}" && k=1 || k=0
   out+=",$(bm_jb fs_supported "$k")"
   if bm_dv_multi_btrfs "$d"; then out+=",$(bm_jb multi_device 1)"; fi
   printf '%s}' "$out"
}

# One disk with its volumes and what is known about its health
bm_dv_disk_json() {
   local d="$1" kind p first=1 parts=""
   bm_dv_kind "$d"; kind="$REPLY"
   bm_dv_kind_label "$kind"; local label="$REPLY"
   bm_dv_kind_icon "$kind"; local icon="$REPLY"
   bm_dv_name "$d"; local name="$REPLY"
   bm_dv_tree "$d"
   local tree=("${DV_TREE[@]}")
   for p in "${tree[@]}"; do
      if [ "$first" = 1 ]; then first=0; else parts+=","; fi
      parts+="$(bm_dv_part_json "$p")"
   done
   bm_ds_level "$d"
   local tran="${DV[$d|TRAN]:-}"
   bm_tran_label "$tran"; local tlabel="$REPLY"
   printf '%s,"volumes":[%s],%s}' "$(bm_jo_open device "$d" name "$name" kind "$kind" kind_label "$label" icon "$icon" \
      model "${DV[$d|MODEL]:-}" vendor "${DV[$d|VENDOR]:-}" serial "${DV[$d|SERIAL]:-}" transport "$tran" transport_label "$tlabel")" \
      "$parts" "$(bm_ds_json)"
}

bm_dv_list_json() {
   local d first=1 out=""
   for d in "${DV_TOP[@]}"; do
      if [ "$first" = 1 ]; then first=0; else out+=","; fi
      out+="$(bm_dv_disk_json "$d")"
   done
   printf '{"partial":%s,"devices":[%s]}\n' "$([ "$DV_PARTIAL" = 1 ] && echo true || echo false)" "$out"
}

# The text list of the terminal: numbered when ASK is set (menus)
bm_dv_list_text() {
   local numbered="${1:-}" i=0 d kind tag size p st extra
   for d in "${DV_TOP[@]}"; do
      i=$((i + 1))
      bm_dv_kind "$d"; kind="$REPLY"
      bm_dv_kind_label "$kind"; tag="$REPLY"
      bm_dv_name "$d"; local name="$REPLY"
      bm_human_size "${DV[$d|SIZE]:-}"; size="$REPLY"
      bm_ds_level "$d"
      if [ -n "$numbered" ]; then printf '%2d. ' "$i"; else printf '%s' "$d  "; fi
      bm_tui_paint "$DS_LEVEL" "$name"
      printf ' — %s\n' "$size"
      bm_tran_label "${DV[$d|TRAN]:-}"
      if [ "$kind" = usb ] || [ "$kind" = nvme ] || [ -z "${DV[$d|TRAN]:-}" ]; then printf '    %s\n' "$tag"
      else printf '    %s | %s\n' "$tag" "$REPLY"
      fi
      bm_ds_level_label
      printf '    %s: %s\n' $"Health" "$REPLY"
      bm_dv_tree "$d"
      for p in "${DV_TREE[@]}"; do
         [ "$p" = "$d" ] && [ -z "${DV[$p|FSTYPE]:-}" ] && continue
         bm_dv_state "$p"; st="$REPLY"
         bm_dv_state_label "$st"; extra="$REPLY"
         bm_human_size "${DV[$p|SIZE]:-}"
         local line="${p##*/} ${DV[$p|LABEL]:+“${DV[$p|LABEL]//[[:cntrl:]]/?}” }$REPLY ${DV[$p|FSTYPE]:-} — $extra"
         [ -n "$DV_MP" ] && line+=" ${DV_MP//[[:cntrl:]]/?}"
         printf '      %s\n' "$line"
      done
      printf '\n'
   done
   if [ "$DV_PARTIAL" = 1 ]; then
      printf '%s\n' $"A mounted device did not answer in time, so free space is not shown."
   fi
   [ "$i" -gt 0 ] || printf '%s\n' $"No storage device was found."
}
