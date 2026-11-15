# shellcheck shell=bash
#
# big-mount: read-only access to APFS partitions (disks of a Mac). Loaded by
# cli.sh only for these options, so neither the boot run nor the other
# options read it.
#
# For the person, in their session (bigmount --help):
#   --open-apfs [DEVICE] [--volume N] [--no-open]
#   --close-apfs [DEVICE | FOLDER]
#   --apfs-info [DEVICE]
# As root, run through sudo by the options above, by big-mount.service at
# boot (APFS=readonly in /etc/big-mount.conf), or by another program such as
# Big Storage Rescue (stable interface, docs/apfs-04-read-only-mount.md):
#   --apfs-helper probe DEVICE
#   --apfs-helper mount DEVICE [VOLUME]
#   --apfs-helper unmount DEVICE | FOLDER
#   --apfs-helper boot-mount DEVICE FOLDER UID GID
# As root, run by /usr/bin/mount.apfs, which mount(8) runs for "mount -t
# apfs", as UDisks does when the partition is clicked in the file manager:
#   --apfs-helper fs-mount DEVICE FOLDER OPTIONS
#
# Nothing here ever writes to an APFS partition: both drivers are used
# read-only (apfs-fuse cannot write at all; the kernel driver writes only
# with the option "readwrite", which is never given), and no repair, check
# or format tool is ever run. The drivers are separate packages:
#   apfs-fuse (AUR apfs-fuse-git)            FUSE, also encrypted volumes
#   linux-apfs-rw-dkms (+ apfsprogs), extra  kernel driver, no encryption
#
# Exit codes: 0 done, 1 failed, 2 usage, 3 not a usable APFS partition or
# volume, 4 no APFS driver installed, 5 administrator rights refused,
# 6 encrypted and not unlocked, 7 read error of the device (stop: rescue
# first), 8 still in use (not unmounted).

# Paths, one place (tests/apfs-tests.sh points them into a scratch tree)
APFS_MEDIA=/run/media
APFS_MOUNTS=/proc/mounts
APFS_CONF=/etc/big-mount.conf
APFS_FILESYSTEMS=/proc/filesystems
APFS_KMSG=/dev/kmsg

# GPT partition types that matter to a person holding a Mac disk
apfs_parttype_name() {
   case "${1,,}" in
      7c3457ef-0000-11aa-aa11-00306543ecac) REPLY=$"APFS container" ;;
      48465300-0000-11aa-aa11-00306543ecac) REPLY=$"HFS+ (Mac OS Extended)" ;;
      ebd0a0a2-b9e5-4433-87c0-68b6b72699c7) REPLY=$"Microsoft basic data" ;;
      c12a7328-f81f-11d2-ba4b-00a0c93ec93b) REPLY=$"EFI system partition" ;;
      0fc63daf-8483-4772-8e79-3d69d8477de4) REPLY=$"Linux filesystem" ;;
      52637672-7900-11aa-aa11-00306543ecac) REPLY=$"Apple Recovery HD" ;;
      53746f72-6167-11aa-aa11-00306543ecac) REPLY=$"Apple Core Storage (old FileVault or Fusion Drive)" ;;
      "") REPLY="" ;;
      *) REPLY=$"other" ;;
   esac
}

# Messages for the person: stderr, so that stdout stays data
# shellcheck disable=SC2059  # FORMAT is always a constant, translatable string
apfs_say() { local f="$1"; shift; printf -- "$f"'\n' "$@" >&2; }

# The name of a volume or label as one safe folder name (or nothing)
apfs_safe_name() {
   local s="$1" LC_ALL=C
   s="${s//\//_}"
   s="${s//[[:cntrl:]]/_}"
   case "$s" in . | ..) s="" ;; esac
   [ "${#s}" -gt 200 ] && s=""
   REPLY="$s"
}

# apfs_dev PATH: the canonical block device behind PATH (also a
# /dev/disk/by-* link) in REPLY. Exit 3 with an explanation otherwise.
apfs_dev() {
   local p="$1" r
   if [[ $p != /dev/* ]]; then
      apfs_say $"%s is not a device: give its path, such as /dev/sdb2 (see: lsblk -f)" "$p"
      return 3
   fi
   r="$(readlink -f -- "$p")"
   if [ -z "$r" ] || [ ! -e "$r" ]; then
      apfs_say $"%s does not exist: the disk is not connected, or its name changed (see: lsblk -f)" "$p"
      return 3
   fi
   if [ ! -b "$r" ] || [[ ! $r =~ ^/dev/[A-Za-z0-9._-]+$ ]]; then
      apfs_say $"%s is not a disk partition" "$p"
      return 3
   fi
   REPLY="$r"
}

# The mounts of the system, one entry per line: SOURCE MOUNTPOINT TYPE OPTIONS
# (mount points unescaped from the \040 form of /proc/mounts)
apfs_read_mounts() {
   local src mp typ opts _r
   APFS_M_SRC=() APFS_M_MP=() APFS_M_TYPE=() APFS_M_OPTS=()
   [ -r "$APFS_MOUNTS" ] || return 0
   while read -r src mp typ opts _r; do
      APFS_M_SRC+=("$src")
      printf -v mp '%b' "${mp//\\/\\0}"
      APFS_M_MP+=("$mp")
      APFS_M_TYPE+=("$typ")
      APFS_M_OPTS+=("$opts")
   done < "$APFS_MOUNTS"
}

# An APFS mount: the kernel driver, or apfs-fuse (subtype set by us)
apfs_is_apfs_type() { [ "$1" = apfs ] || [ "$1" = fuse.apfs-fuse ]; }

# apfs_mount_of DEVICE: index (in APFS_M_*) of the first mount of DEVICE, in REPLY
apfs_mount_of() {
   local i
   REPLY=""
   for i in "${!APFS_M_SRC[@]}"; do
      if [ "${APFS_M_SRC[i]}" = "$1" ]; then REPLY="$i"; return 0; fi
   done
   return 1
}

# The folder to show for a mount: apfs-fuse puts the volume under "root"
# (and its private metadata beside it, in "private-dir")
apfs_open_path() {
   if [ "$2" = fuse.apfs-fuse ] && [ -d "$1/root" ]; then REPLY="$1/root"; else REPLY="$1"; fi
}

# Installed drivers, in the order to try them: APFS_BACKENDS (fuse, kernel).
# /etc/big-mount.conf APFS_DRIVER=auto|fuse|kernel; auto prefers apfs-fuse:
# a damaged container can only crash a process, never the kernel, and it
# unlocks encrypted volumes.
apfs_backends() {
   local want=auto line has_fuse="" has_kernel=""
   if [ -r "$APFS_CONF" ]; then
      while IFS= read -r line; do
         line="${line%%#*}"
         line="${line//[[:space:]]/}"
         case "$line" in
            APFS_DRIVER=auto | APFS_DRIVER=fuse | APFS_DRIVER=kernel) want="${line#*=}" ;;
         esac
      done < "$APFS_CONF"
   fi
   command -v apfs-fuse >/dev/null 2>&1 && has_fuse=1
   if grep -qw apfs "$APFS_FILESYSTEMS" 2>/dev/null || modinfo -F filename apfs >/dev/null 2>&1; then
      has_kernel=1
   fi
   APFS_BACKENDS=()
   case "$want" in
      fuse) [ -n "$has_fuse" ] && APFS_BACKENDS=(fuse) ;;
      kernel) [ -n "$has_kernel" ] && APFS_BACKENDS=(kernel) ;;
      *)
         [ -n "$has_fuse" ] && APFS_BACKENDS+=(fuse)
         [ -n "$has_kernel" ] && APFS_BACKENDS+=(kernel)
         ;;
   esac
   APFS_DRIVER_WANTED="$want"
}

apfs_no_driver_help() {
   if [ "${APFS_DRIVER_WANTED:-auto}" != auto ]; then
      apfs_say $"The driver chosen in /etc/big-mount.conf (APFS_DRIVER=%s) is not installed." "$APFS_DRIVER_WANTED"
   fi
   apfs_say $"This partition contains APFS (the filesystem of a Mac), and no APFS driver is installed. Install one to read its files without changing the disk:"
   apfs_say $"  apfs-fuse (recommended, also opens encrypted volumes): pamac build apfs-fuse-git"
   apfs_say $"  or the kernel driver (no encrypted volumes):           sudo pacman -S linux-apfs-rw-dkms apfsprogs"
}

# ---------------------------------------------------------------------------
# Root side

# The person who asked (sudo or pkexec), or root: APFS_USER APFS_UID APFS_GID
apfs_caller() {
   local uid="${SUDO_UID:-${PKEXEC_UID:-0}}" entry
   [[ $uid =~ ^[0-9]+$ ]] || uid=0
   if ! entry="$(getent passwd "$uid")"; then
      apfs_say $"unknown user id %s" "$uid"
      return 1
   fi
   IFS=: read -r APFS_USER _ APFS_UID APFS_GID _ <<< "$entry"
}

# The signature on the partition itself (blkid -p reads the device, not the
# udev cache), the only proof that it is APFS: a GPT type or name is not.
apfs_check_signature() {
   local dev="$1" out rc
   out="$(LC_ALL=C blkid -p -o export -- "$dev" 2>&1)"
   rc=$?
   if [[ $out == *"Input/output error"* ]]; then
      apfs_say $"%s cannot be read (input/output error). Do not insist: copy what can be saved with Big Storage Rescue first." "$dev"
      return 7
   fi
   if [[ $'\n'$out$'\n' == *$'\nTYPE=apfs\n'* ]]; then
      return 0
   fi
   if [ "$rc" -eq 0 ] && [[ $out =~ (^|$'\n')TYPE=([^$'\n']*) ]]; then
      apfs_say $"%s is not APFS: it contains %s" "$dev" "${BASH_REMATCH[2]}"
   else
      apfs_say $"%s has no APFS signature (nor any other known filesystem)" "$dev"
   fi
   return 3
}

# apfs_volumes DEVICE: the volumes of the container, from apfsutil (part of
# apfs-fuse: names, roles, encryption) or apfs-label (apfsprogs: names only).
# APFS_V_IDX/ROLE/ENC/NAME, APFS_LISTER, APFS_RECOMMENDED (the index of the
# volume with the files of the users, -1 if no volume is known).
apfs_volumes() {
   local dev="$1" out rc line idx="" role="" enc="" name="" i
   APFS_V_IDX=() APFS_V_ROLE=() APFS_V_ENC=() APFS_V_NAME=() APFS_LISTER=none APFS_RECOMMENDED=-1
   if command -v apfsutil >/dev/null 2>&1; then
      APFS_LISTER=apfsutil
      out="$(LC_ALL=C timeout 60 apfsutil "$dev" 2>&1)"
      rc=$?
      while IFS= read -r line; do
         if [[ $line =~ ^Volume\ ([0-9]+)\  ]]; then
            [ -n "$idx" ] && APFS_V_IDX+=("$idx") APFS_V_ROLE+=("$role") APFS_V_ENC+=("$enc") APFS_V_NAME+=("$name")
            idx="${BASH_REMATCH[1]}" role="" enc=unknown name=""
         elif [[ $line =~ ^Role:\ +(.*)$ ]]; then
            role="${BASH_REMATCH[1]}"
         elif [[ $line =~ ^Name:\ +(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            name="${name% (Case-insensitive)}"
            name="${name% (Case-sensitive)}"
         elif [[ $line =~ ^FileVault:\ +(Yes|No) ]]; then
            if [ "${BASH_REMATCH[1]}" = Yes ]; then enc=yes; else enc=no; fi
         fi
      done <<< "$out"
      [ -n "$idx" ] && APFS_V_IDX+=("$idx") APFS_V_ROLE+=("$role") APFS_V_ENC+=("$enc") APFS_V_NAME+=("$name")
   elif command -v apfs-label >/dev/null 2>&1; then
      APFS_LISTER=apfs-label
      out="$(LC_ALL=C timeout 60 apfs-label "$dev" 2>&1)"
      rc=$?
      while IFS=$'\t' read -r idx name; do
         [[ $idx =~ ^[0-9]+$ ]] || continue
         APFS_V_IDX+=("$idx") APFS_V_ROLE+=("") APFS_V_ENC+=(unknown) APFS_V_NAME+=("$name")
      done <<< "$out"
   else
      return 0
   fi
   if [ "$rc" -eq 124 ]; then
      apfs_say $"%s: reading the list of volumes took too long; the disk may be failing" "$dev"
      return 7
   fi
   if [[ $out == *"Input/output error"* ]]; then
      apfs_say $"%s cannot be read (input/output error). Do not insist: copy what can be saved with Big Storage Rescue first." "$dev"
      return 7
   fi
   if [ "${#APFS_V_IDX[@]}" -eq 0 ]; then
      apfs_say $"%s has an APFS signature, but its container cannot be read: it is damaged, or uses a format the driver does not know" "$dev"
      return 3
   fi
   for i in "${!APFS_V_NAME[@]}"; do
      APFS_V_NAME[i]="${APFS_V_NAME[i]//[[:cntrl:]]/?}"
      APFS_V_ROLE[i]="${APFS_V_ROLE[i]//[[:cntrl:]]/?}"
   done
   # The files of the users: the Data volume (macOS 10.15 and later), else
   # the first one with no special role (older macOS, external disks), else
   # the first that is not a system helper, else the first one.
   for i in "${!APFS_V_IDX[@]}"; do
      [ "${APFS_V_ROLE[i]}" = Data ] && { APFS_RECOMMENDED="${APFS_V_IDX[i]}"; return 0; }
   done
   # apfs-label gives no roles: the name macOS gives the Data volume
   for i in "${!APFS_V_IDX[@]}"; do
      if [ -z "${APFS_V_ROLE[i]}" ] && [[ ${APFS_V_NAME[i]} == *" - Data" || ${APFS_V_NAME[i]} == Data ]]; then
         APFS_RECOMMENDED="${APFS_V_IDX[i]}"
         return 0
      fi
   done
   for i in "${!APFS_V_IDX[@]}"; do
      case "${APFS_V_ROLE[i]}" in
         "No specific role" | User) APFS_RECOMMENDED="${APFS_V_IDX[i]}"; return 0 ;;
      esac
   done
   for i in "${!APFS_V_IDX[@]}"; do
      case "${APFS_V_ROLE[i]}:${APFS_V_NAME[i]}" in
         *Preboot* | *Recovery* | VM:* | :VM | *Update* | *Hardware* | *Xart* | *Baseband* | System:*) ;;
         *) APFS_RECOMMENDED="${APFS_V_IDX[i]}"; return 0 ;;
      esac
   done
   APFS_RECOMMENDED="${APFS_V_IDX[0]}"
   return 0
}

apfs_cmd_probe() {
   local dev rc i
   apfs_dev "$1" || return
   dev="$REPLY"
   apfs_check_signature "$dev" || return
   apfs_volumes "$dev"
   rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   apfs_backends
   printf '# big-mount apfs probe v1\n'
   printf 'device\t%s\n' "$dev"
   printf 'lister\t%s\n' "$APFS_LISTER"
   printf 'drivers\t%s\n' "${APFS_BACKENDS[*]:-none}"
   local rec
   for i in "${!APFS_V_IDX[@]}"; do
      rec=0
      [ "${APFS_V_IDX[i]}" = "$APFS_RECOMMENDED" ] && rec=1
      printf 'volume\t%s\t%s\t%s\t%s\t%s\n' "${APFS_V_IDX[i]}" "${APFS_V_ROLE[i]:--}" "${APFS_V_ENC[i]}" \
         "$rec" "${APFS_V_NAME[i]:--}"
   done
   return 0
}

# A folder for the person under /run/media/<user>, made like UDisks makes it
# (root's, with read access for that person only, so no other account can
# look at the files), and never through a symlink.
apfs_make_mountpoint() {
   local name="$1" base="$APFS_MEDIA/$APFS_USER" mp n=1
   if [ -L "$APFS_MEDIA" ] || [ -L "$base" ]; then
      apfs_say $"%s is a symbolic link, not using it" "$base"
      return 1
   fi
   if [ ! -d "$base" ]; then
      if ! { mkdir -p -m 0755 -- "$APFS_MEDIA" && mkdir -m 0700 -- "$base"; }; then
         return 1
      fi
      if [ "$APFS_UID" -ne 0 ] && ! { chmod 0750 -- "$base" && setfacl -m "u:$APFS_UID:r-x" -- "$base"; }; then
         # Without an ACL the person could not open the folder: theirs, then
         if ! { chown "$APFS_UID:$APFS_GID" -- "$base" && chmod 0700 -- "$base"; }; then
            return 1
         fi
      fi
   fi
   apfs_safe_name "$name"
   name="${REPLY:-APFS}"
   mp="$base/$name"
   while [ -e "$mp" ] || [ -L "$mp" ]; do
      # An empty folder nothing is mounted on: left behind, use it again
      if [ -d "$mp" ] && [ ! -L "$mp" ] && ! mountpoint -q -- "$mp" && [ -z "$(ls -A -- "$mp" 2>/dev/null)" ]; then
         break
      fi
      mp="$base/$name $n"
      n=$((n + 1))
   done
   if [ ! -d "$mp" ]; then
      mkdir -m 0755 -- "$mp" || return 1
      APFS_CREATED_DIR="$mp"
   fi
   REPLY="$mp"
}

# apfs_mount_fuse DEVICE FOLDER VOLUME UID GID INTERACTIVE
apfs_mount_fuse() {
   local dev="$1" mp="$2" vol="$3" uid="$4" gid="$5" interactive="$6" log rc tries=0
   local opts="ro,nosuid,nodev,allow_other,default_permissions,subtype=apfs-fuse,uid=$uid,gid=$gid,vol=$vol"
   log="$(mktemp)" || return 1
   while :; do
      # apfs-fuse asks for the password itself, on the terminal (with echo
      # off), when the volume is encrypted: it never goes through a command
      # line, a file or this script. Its messages are shown and kept to
      # explain a failure; it then becomes a daemon with no open file of
      # ours. -l (return possibly corrupt data) is never used.
      if [ -n "$interactive" ]; then
         apfs-fuse -o "$opts" "$dev" "$mp" 2>&1 | tee "$log" >&2
         rc="${PIPESTATUS[0]}"
      else
         timeout --foreground 120 apfs-fuse -o "$opts" "$dev" "$mp" < /dev/null > "$log" 2>&1
         rc=$?
      fi
      if [ "$rc" -ne 0 ] && grep -q 'Wrong password' "$log" && [ -n "$interactive" ] && [ "$tries" -lt 2 ]; then
         tries=$((tries + 1))
         apfs_say $"Wrong password, try again (it can be the password of a user of the Mac or the recovery key)."
         continue
      fi
      break
   done
   APFS_FAIL=""
   if [ "$rc" -ne 0 ]; then
      if grep -q 'Wrong password' "$log"; then APFS_FAIL=password
      elif grep -qE 'Input/output error|Error opening device' "$log"; then APFS_FAIL=io
      elif grep -q 'is encrypted' "$log"; then APFS_FAIL=locked
      fi
      [ -n "$interactive" ] || sed 's/^/  apfs-fuse: /' "$log" >&2
   fi
   rm -f -- "$log"
   return "$rc"
}

# apfs_mount_kernel DEVICE FOLDER VOLUME UID GID ENCRYPTED(yes|no|unknown)
# The driver mounts read-only unless given "readwrite", which is never
# given; "ro" is asked for anyway. It mounts encrypted volumes without
# decrypting them, with only a warning in the kernel log, and their files
# would then be garbage: a mark is written to the kernel log first, and the
# volume is unmounted again when that warning follows it.
apfs_mount_kernel() {
   local dev="$1" mp="$2" vol="$3" uid="$4" gid="$5" enc="$6" mark="" rc
   APFS_FAIL=""
   grep -qw apfs "$APFS_FILESYSTEMS" 2>/dev/null || modprobe -q apfs 2>/dev/null
   if [ "$enc" != no ]; then
      mark="big-mount: apfs mount $$ $RANDOM ${dev##*/}"
      if ! printf '<6>%s\n' "$mark" > "$APFS_KMSG" 2>/dev/null; then
         apfs_say $"Whether volume %s is encrypted cannot be checked here: install apfs-fuse-git (it checks it, and reads encrypted volumes)." "$vol"
         APFS_FAIL=locked
         return 1
      fi
   fi
   # -i: the driver itself, never /usr/bin/mount.apfs (which runs this)
   mount -i -t apfs -o "ro,nosuid,nodev,uid=$uid,gid=$gid,vol=$vol" -- "$dev" "$mp"
   rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   if [ -n "$mark" ] && dmesg 2>/dev/null | sed -n "\\|$mark|,\$p" | grep -q 'volume is encrypted'; then
      umount -- "$mp"
      APFS_FAIL=locked
      return 1
   fi
   return 0
}

# apfs_do_mount DEVICE VOLUME FOLDER UID GID MODE (manual | boot)
apfs_do_mount() {
   local dev="$1" vol="$2" mp="$3" uid="$4" gid="$5" mode="$6" enc=unknown i b rc=1 interactive="" tried=()
   for i in "${!APFS_V_IDX[@]}"; do
      [ "${APFS_V_IDX[i]}" = "$vol" ] && enc="${APFS_V_ENC[i]}"
   done
   [ "$mode" = manual ] && [ -t 0 ] && interactive=1
   local backends=("${APFS_BACKENDS[@]}")
   if [ "$enc" = yes ]; then
      backends=()
      for b in "${APFS_BACKENDS[@]}"; do [ "$b" = fuse ] && backends=(fuse); done
      if [ "${#backends[@]}" -eq 0 ]; then
         apfs_say $"Volume %s of %s is encrypted (FileVault). The kernel driver cannot decrypt it: install apfs-fuse (pamac build apfs-fuse-git) and try again." "$vol" "$dev"
         return 6
      fi
      if [ -z "$interactive" ]; then
         apfs_say $"Volume %s of %s is encrypted (FileVault): its password can only be typed in a terminal, run: bigmount --open-apfs %s" "$vol" "$dev" "$dev"
         return 6
      fi
      apfs_say $"Volume %s is encrypted. Type the password of a user of the Mac, or the recovery key (nothing is shown while typing)." "$vol"
   fi
   APFS_BACKEND=""
   for b in "${backends[@]}"; do
      tried+=("$b")
      if [ "$b" = fuse ]; then
         apfs_mount_fuse "$dev" "$mp" "$vol" "$uid" "$gid" "$interactive"
      else
         apfs_mount_kernel "$dev" "$mp" "$vol" "$uid" "$gid" "$enc"
      fi
      rc=$?
      if [ "$rc" -eq 0 ]; then
         APFS_BACKEND="$b"
         break
      fi
      case "$APFS_FAIL" in
         io)
            apfs_say $"%s cannot be read (input/output error). Do not insist: copy what can be saved with Big Storage Rescue first." "$dev"
            return 7
            ;;
         password)
            apfs_say $"Wrong password: volume %s stays locked." "$vol"
            return 6
            ;;
      esac
   done
   if [ -z "$APFS_BACKEND" ]; then
      if [ "$APFS_FAIL" = locked ]; then
         apfs_say $"Volume %s of %s is encrypted, and the installed driver cannot unlock it here." "$vol" "$dev"
         return 6
      fi
      apfs_say $"The APFS driver could not open volume %s of %s (tried: %s). The disk was not changed." "$vol" "$dev" "${tried[*]}"
      [ "${tried[*]}" = kernel ] && apfs_say $"Details: sudo dmesg | grep -i apfs"
      return 1
   fi
   # Read-only, or not at all
   apfs_read_mounts
   for i in "${!APFS_M_MP[@]}"; do
      [ "${APFS_M_MP[i]}" = "$mp" ] || continue
      if [[ ,${APFS_M_OPTS[i]}, != *,ro,* ]]; then
         umount -- "$mp"
         apfs_say $"%s was mounted writable by the driver: unmounted again at once" "$dev"
         return 1
      fi
      APFS_TYPE="${APFS_M_TYPE[i]}"
      return 0
   done
   apfs_say $"The APFS driver reported success, but nothing is mounted on %s" "$mp"
   return 1
}

# apfs_pick_volume REQUESTED: the volume to mount in REPLY
apfs_pick_volume() {
   local want="$1" i
   if [ -z "$want" ]; then
      if [ "$APFS_RECOMMENDED" -ge 0 ]; then REPLY="$APFS_RECOMMENDED"; else REPLY=0; fi
      return 0
   fi
   if [[ ! $want =~ ^[0-9]{1,2}$ ]]; then
      apfs_say $"invalid volume number: %s" "$want"
      return 2
   fi
   REPLY="$((10#$want))"
   [ "${#APFS_V_IDX[@]}" -eq 0 ] && return 0
   for i in "${APFS_V_IDX[@]}"; do [ "$i" = "$REPLY" ] && return 0; done
   apfs_say $"this APFS container has no volume %s (it has: %s)" "$REPLY" "${APFS_V_IDX[*]}"
   return 3
}

apfs_volume_name() {
   local i
   REPLY=""
   for i in "${!APFS_V_IDX[@]}"; do
      [ "${APFS_V_IDX[i]}" = "$1" ] && REPLY="${APFS_V_NAME[i]}"
   done
}

apfs_cmd_mount() {
   local dev vol mp rc i
   apfs_caller || return 1
   apfs_dev "$1" || return
   dev="$REPLY"
   # Already open (without a volume asked for: which volume a mount shows is
   # not written anywhere, and two volumes can be open at the same time)
   apfs_read_mounts
   if [ -z "${2:-}" ] && apfs_mount_of "$dev"; then
      i="$REPLY"
      if apfs_is_apfs_type "${APFS_M_TYPE[i]}"; then
         apfs_open_path "${APFS_M_MP[i]}" "${APFS_M_TYPE[i]}"
         printf 'already\t%s\t%s\n' "${APFS_M_MP[i]}" "$REPLY"
         return 0
      fi
      apfs_say $"%s is already mounted on %s" "$dev" "${APFS_M_MP[i]}"
      return 3
   fi
   apfs_check_signature "$dev" || return
   apfs_backends
   if [ "${#APFS_BACKENDS[@]}" -eq 0 ]; then
      apfs_no_driver_help
      return 4
   fi
   apfs_volumes "$dev" || return
   apfs_pick_volume "${2:-}" || return
   vol="$REPLY"
   apfs_volume_name "$vol"
   APFS_CREATED_DIR=""
   apfs_make_mountpoint "${REPLY:-APFS ${dev##*/}}" || { apfs_say $"cannot make a folder for %s under %s" "$dev" "$APFS_MEDIA"; return 1; }
   mp="$REPLY"
   apfs_do_mount "$dev" "$vol" "$mp" "$APFS_UID" "$APFS_GID" manual
   rc=$?
   if [ "$rc" -ne 0 ]; then
      [ -n "$APFS_CREATED_DIR" ] && rmdir -- "$APFS_CREATED_DIR" 2>/dev/null
      return "$rc"
   fi
   apfs_open_path "$mp" "$APFS_TYPE"
   printf 'mounted\t%s\t%s\t%s\t%s\n' "$mp" "$REPLY" "$APFS_BACKEND" "$vol"
}

# At boot, from bigmount (internal disks, APFS=readonly): the folder is
# chosen by bigmount, the volume is the one with the files of the users,
# nothing is asked, and encrypted volumes are left alone.
apfs_cmd_boot_mount() {
   local dev="$1" mp="$2" uid="$3" gid="$4" vol
   if [[ ! $uid =~ ^[0-9]+$ || ! $gid =~ ^[0-9]+$ ]] || [ ! -d "$mp" ] || [ -L "$mp" ]; then
      apfs_say "apfs-helper boot-mount: invalid arguments"
      return 2
   fi
   apfs_dev "$dev" || return
   dev="$REPLY"
   apfs_check_signature "$dev" || return
   apfs_backends
   if [ "${#APFS_BACKENDS[@]}" -eq 0 ]; then
      apfs_say $"%s: APFS partition, but no APFS driver is installed (apfs-fuse-git or linux-apfs-rw-dkms)" "$dev"
      return 4
   fi
   apfs_volumes "$dev" || return
   apfs_pick_volume "" || return
   vol="$REPLY"
   apfs_do_mount "$dev" "$vol" "$mp" "$uid" "$gid" boot
}

# From /usr/bin/mount.apfs: mount(8) runs it for "mount -t apfs", and UDisks
# does that when the partition is clicked in the file manager, on a folder it
# made under /run/media/<user>. Only the kernel driver is used: UDisks shows a
# mount as the partition's only when it is on the device number of the
# partition, which the kernel driver gives and FUSE (apfs-fuse) never does, so
# the file manager could neither show it open nor close it. The volume is the
# one with the files of the users (vol=N in OPTIONS chooses another), the
# files belong to the person of /run/media/<user>/... (or uid=, gid= in
# OPTIONS), read-only whatever OPTIONS asks for, and encrypted volumes are
# left to bigmount --open-apfs, where their password can be typed. Messages
# go to the journal of udisks2.service, in English.
apfs_cmd_fs_mount() {
   local dev="$1" mp="$2" opts="$3" o list=() uid="" gid="" vol="" user entry pgid="" i enc=unknown
   if [ ! -d "$mp" ] || [ -L "$mp" ]; then
      apfs_say "mount.apfs: %s is not a folder" "$mp"
      return 2
   fi
   IFS=, read -ra list <<< "$opts"
   for o in "${list[@]}"; do
      case "$o" in
         uid=*) uid="${o#uid=}" ;;
         gid=*) gid="${o#gid=}" ;;
         vol=*) vol="${o#vol=}" ;;
      esac
   done
   if [ -z "$uid" ] && [[ $mp == "$APFS_MEDIA"/*/* ]]; then
      user="${mp#"$APFS_MEDIA"/}"
      user="${user%%/*}"
      entry="$(getent passwd "$user")" && IFS=: read -r _ _ uid pgid _ <<< "$entry"
   elif [ -n "$uid" ]; then
      entry="$(getent passwd "$uid")" && IFS=: read -r _ _ _ pgid _ <<< "$entry"
   fi
   uid="${uid:-0}" gid="${gid:-${pgid:-0}}"
   if [[ ! $uid =~ ^[0-9]+$ || ! $gid =~ ^[0-9]+$ ]]; then
      apfs_say "mount.apfs: invalid uid or gid: %s" "$opts"
      return 2
   fi
   apfs_dev "$dev" || return
   dev="$REPLY"
   apfs_check_signature "$dev" || return
   apfs_backends
   if [[ " ${APFS_BACKENDS[*]} " != *" kernel "* ]]; then
      apfs_say "%s: APFS (Mac) partition. The file manager opens it only with the kernel driver (sudo pacman -S linux-apfs-rw-dkms apfsprogs); without it, open it read-only with: bigmount --open-apfs %s" "$dev" "$dev"
      return 4
   fi
   APFS_BACKENDS=(kernel)
   apfs_volumes "$dev" || return
   apfs_pick_volume "$vol" || return
   vol="$REPLY"
   for i in "${!APFS_V_IDX[@]}"; do
      [ "${APFS_V_IDX[i]}" = "$vol" ] && enc="${APFS_V_ENC[i]}"
   done
   if [ "$enc" = yes ]; then
      apfs_say "%s: volume %s is encrypted (FileVault), and the kernel driver cannot decrypt it. Open it with its password in a terminal: bigmount --open-apfs %s" "$dev" "$vol" "$dev"
      return 6
   fi
   apfs_do_mount "$dev" "$vol" "$mp" "$uid" "$gid" boot
}

# apfs_find_open DEVICE|FOLDER: the APFS mount it names (its mount point, or
# the "root" folder apfs-fuse shows): APFS_OPEN_MP and APFS_OPEN_TYPE
apfs_find_open() {
   local target="$1" dev="" i
   APFS_OPEN_MP="" APFS_OPEN_TYPE=""
   apfs_read_mounts
   if [[ $target == /dev/* ]]; then
      apfs_dev "$target" || return
      dev="$REPLY"
   else
      target="$(readlink -f -- "$target" 2>/dev/null)"
   fi
   for i in "${!APFS_M_MP[@]}"; do
      apfs_is_apfs_type "${APFS_M_TYPE[i]}" || continue
      if { [ -n "$dev" ] && [ "${APFS_M_SRC[i]}" = "$dev" ]; } ||
         { [ -z "$dev" ] && { [ "${APFS_M_MP[i]}" = "$target" ] || [ "${APFS_M_MP[i]}/root" = "$target" ]; }; }; then
         APFS_OPEN_MP="${APFS_M_MP[i]}" APFS_OPEN_TYPE="${APFS_M_TYPE[i]}"
      fi
   done
   [ -n "$APFS_OPEN_MP" ]
}

apfs_cmd_unmount() {
   local mp typ rc out
   apfs_find_open "$1"
   rc=$?
   [ "$rc" -eq 3 ] && return 3
   mp="$APFS_OPEN_MP" typ="$APFS_OPEN_TYPE"
   if [ -z "$mp" ]; then
      apfs_say $"%s is not an open APFS volume" "$1"
      return 3
   fi
   # Only what Big-Mount mounts: under /run/media (bigmount --open-apfs) or /mnt (boot)
   if [[ $mp != "$APFS_MEDIA"/*/* && $mp != /mnt/* ]]; then
      apfs_say $"%s was not opened by Big-Mount: unmount it with the program that mounted it" "$mp"
      return 3
   fi
   out="$(LC_ALL=C umount -- "$mp" 2>&1)"
   rc=$?
   if [ "$rc" -ne 0 ]; then
      if [[ $out == *busy* ]]; then
         apfs_say $"%s is still in use: close the files and windows (also terminals) opened in it, then try again. To see which programs: big-storage-rescue --busy %s" "$mp" "$mp"
         return 8
      fi
      apfs_say $"could not unmount %s: %s" "$mp" "$out"
      return 1
   fi
   [[ $mp == "$APFS_MEDIA"/*/* ]] && rmdir -- "$mp" 2>/dev/null
   printf 'unmounted\t%s (%s)\n' "$mp" "$typ"
   return 0
}

apfs_cmd_helper() {
   local sub="${1:-}"
   shift
   if [ "$EUID" -ne 0 ]; then # root-check
      apfs_say $"bigmount --apfs-helper must run as root (it is used by bigmount --open-apfs through sudo)"
      return 5
   fi
   umask 022
   case "$sub:$#" in
      probe:1) apfs_cmd_probe "$1" ;;
      mount:1 | mount:2) apfs_cmd_mount "$@" ;;
      unmount:1) apfs_cmd_unmount "$1" ;;
      boot-mount:4) apfs_cmd_boot_mount "$@" ;;
      fs-mount:3) apfs_cmd_fs_mount "$@" ;;
      *)
         apfs_say "usage: bigmount --apfs-helper probe DEVICE | mount DEVICE [VOLUME] | unmount DEVICE|FOLDER | boot-mount DEVICE FOLDER UID GID | fs-mount DEVICE FOLDER OPTIONS"
         return 2
         ;;
   esac
}

# ---------------------------------------------------------------------------
# User side

# The partitions udev knows as APFS: APFS_PARTS (paths) and APFS_PARTS_DISK
# (the disk of each), from lsblk
apfs_find_partitions() {
   local line
   APFS_PARTS=() APFS_PARTS_DISK=()
   while IFS= read -r line; do
      if [[ $line =~ NAME=\"([^\"]*)\"\ FSTYPE=\"apfs\"\ PKNAME=\"([^\"]*)\" ]]; then
         APFS_PARTS+=("${BASH_REMATCH[1]}") APFS_PARTS_DISK+=("${BASH_REMATCH[2]}")
      fi
   done < <(lsblk -P -p -o NAME,FSTYPE,PKNAME 2>/dev/null)
}

# lsblk facts of one device: APFS_L[KEY]
apfs_lsblk() {
   local rest pair_re='^[[:space:]]*([A-Z_:-]+)="(([^"\\]|\\.)*)"(.*)$'
   declare -gA APFS_L=()
   rest="$(lsblk -P -p -d -o NAME,TYPE,FSTYPE,SIZE,LABEL,PARTLABEL,PARTTYPE,PKNAME -- "$1" 2>/dev/null)"
   while [[ $rest =~ $pair_re ]]; do
      APFS_L[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[4]}"
   done
}

# Run bigmount --apfs-helper ARGS as root: directly when root, else through
# sudo (in a terminal, so that sudo and apfs-fuse can ask for passwords)
apfs_as_root() {
   local self
   self="$(readlink -f -- "$BM_LIB_DIR/../../bin/bigmount")"
   if [ "$EUID" -eq 0 ]; then # root-check
      "$self" --apfs-helper "$@"
      return
   fi
   if ! command -v sudo >/dev/null 2>&1; then
      apfs_say $"Reading the disk needs administrator rights: run this command as root."
      return 5
   fi
   # No terminal to ask for the password on: only an earlier sudo (or a
   # rule that needs none) can do it
   if [ ! -t 0 ] && ! sudo -n true 2>/dev/null; then
      apfs_say $"Reading the disk needs administrator rights: run this command in a terminal (sudo asks for the password there), or as root."
      return 5
   fi
   sudo -- "$self" --apfs-helper "$@"
}

# A device given by the person, or the only APFS partition connected
apfs_choose_device() {
   local given="$1" i ans
   if [ -n "$given" ]; then
      apfs_dev "$given" || return
      apfs_lsblk "$REPLY"
      # A whole disk: its APFS partition
      if [ "${APFS_L[TYPE]:-}" = disk ] && [ "${APFS_L[FSTYPE]:-}" != apfs ]; then
         apfs_find_partitions
         local mine=()
         for i in "${!APFS_PARTS[@]}"; do [ "${APFS_PARTS_DISK[i]}" = "$REPLY" ] && mine+=("${APFS_PARTS[i]}"); done
         if [ "${#mine[@]}" -eq 1 ]; then
            apfs_say $"%s is a whole disk; using its APFS partition %s" "$REPLY" "${mine[0]}"
            REPLY="${mine[0]}"
            return 0
         fi
         if [ "${#mine[@]}" -eq 0 ]; then
            apfs_say $"%s has no APFS partition (see: lsblk -f %s)" "$REPLY" "$REPLY"
            return 3
         fi
         apfs_say $"%s has several APFS partitions, choose one: %s" "$REPLY" "${mine[*]}"
         return 2
      fi
      return 0
   fi
   apfs_find_partitions
   case "${#APFS_PARTS[@]}" in
      0)
         apfs_say $"No APFS partition is connected. If the disk of the Mac is connected, see what the system found: lsblk -f"
         return 3
         ;;
      1) REPLY="${APFS_PARTS[0]}"; return 0 ;;
   esac
   apfs_say $"APFS partitions connected:"
   for i in "${!APFS_PARTS[@]}"; do
      apfs_lsblk "${APFS_PARTS[i]}"
      apfs_say '  %d) %s  %s  %s' "$((i + 1))" "${APFS_PARTS[i]}" "${APFS_L[SIZE]:-}" "${APFS_L[PARTLABEL]:-}"
   done
   if [ ! -t 0 ]; then
      apfs_say $"Give the one to open: bigmount --open-apfs DEVICE"
      return 2
   fi
   read -r -p $"Partition to open (number): " ans || return 2
   if [[ $ans =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#APFS_PARTS[@]}" ]; then
      REPLY="${APFS_PARTS[ans - 1]}"
      return 0
   fi
   apfs_say $"invalid choice: %s" "$ans"
   return 2
}

# Parse the output of "--apfs-helper probe" (format v1) into APFS_V_*
apfs_parse_probe() {
   local kind a b c d e
   APFS_V_IDX=() APFS_V_ROLE=() APFS_V_ENC=() APFS_V_NAME=() APFS_RECOMMENDED=-1 APFS_LISTER=none APFS_DRIVERS=""
   while IFS=$'\t' read -r kind a b c d e; do
      case "$kind" in
         lister) APFS_LISTER="$a" ;;
         drivers) APFS_DRIVERS="$a" ;;
         volume)
            APFS_V_IDX+=("$a") APFS_V_ROLE+=("$b") APFS_V_ENC+=("$c") APFS_V_NAME+=("$e")
            [ "$d" = 1 ] && APFS_RECOMMENDED="$a"
            ;;
      esac
   done <<< "$1"
}

apfs_show_volumes() {
   local i role enc mark
   for i in "${!APFS_V_IDX[@]}"; do
      role="${APFS_V_ROLE[i]}"
      [ "$role" = - ] && role=""
      case "${APFS_V_ENC[i]}" in
         yes) enc=$"encrypted" ;;
         no) enc=$"not encrypted" ;;
         *) enc=$"encryption unknown" ;;
      esac
      mark=""
      [ "${APFS_V_IDX[i]}" = "$APFS_RECOMMENDED" ] && mark=$"<- the files of the users are usually here"
      apfs_say '  %2s  %-28s %-16s %-14s %s' "${APFS_V_IDX[i]}" "${APFS_V_NAME[i]}" "${role:+($role)}" "$enc" "$mark"
   done
}

# A row of --apfs-info: label padded by terminal columns (bm_pad, cli.sh)
apfs_row() {
   bm_pad "$1" 36
   printf '  %s %s\n' "$REPLY" "${2//[[:cntrl:]]/?}"
}

apfs_cmd_info() {
   local dev disk probe rc tran="" none=$"none"
   if [ "$#" -gt 1 ]; then
      apfs_say $"bigmount: unknown option '%s' (see bigmount --help)" "$2"
      return 2
   fi
   apfs_choose_device "${1:-}" || return
   dev="$REPLY"
   apfs_lsblk "$dev"
   disk="${APFS_L[PKNAME]:-}"
   [ -n "$disk" ] && tran="$(lsblk -dno TRAN -- "$disk" 2>/dev/null)"
   printf '%s\n' "$dev"
   apfs_row $"size:" "${APFS_L[SIZE]:--}"
   apfs_row $"disk:" "${disk:--}${tran:+ ($tran)}"
   apfs_row $"partition name (GPT, only a name):" "${APFS_L[PARTLABEL]:--}"
   apfs_parttype_name "${APFS_L[PARTTYPE]:-}"
   apfs_row $"partition type (GPT):" "${APFS_L[PARTTYPE]:--}${REPLY:+ ($REPLY)}"
   apfs_row $"filesystem found by udev:" "${APFS_L[FSTYPE]:--}"
   apfs_backends
   apfs_row $"APFS drivers installed:" "${APFS_BACKENDS[*]:-$none}"
   if [ "${APFS_L[FSTYPE]:-}" != apfs ]; then
      apfs_say $"%s is not APFS for udev; the signature on the partition is checked next." "$dev"
   fi
   if [ "${APFS_L[FSTYPE]:-}" = apfs ] && [ "${APFS_L[PARTTYPE],,}" != 7c3457ef-0000-11aa-aa11-00306543ecac ] && [ -n "${APFS_L[PARTTYPE]:-}" ]; then
      apfs_say $"The partition table gives another type, but the signature on the partition is APFS: the signature is what counts. The partition table is left as it is."
   fi
   apfs_say $"Reading the volumes needs administrator rights (nothing is written to the disk)."
   probe="$(apfs_as_root probe "$dev")"
   rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   apfs_parse_probe "$probe"
   if [ "$APFS_LISTER" = none ]; then
      printf '  %s\n' $"Volumes: unknown (install apfs-fuse-git or apfsprogs to list them)"
      return 0
   fi
   printf '  %s\n' $"Volumes:"
   apfs_show_volumes 2>&1
   if [ -z "$APFS_DRIVERS" ] || [ "$APFS_DRIVERS" = none ]; then apfs_no_driver_help; fi
   return 0
}

# Open the folder in the file manager of the session (Dolphin in Plasma),
# as the person: never as root
apfs_open_folder() {
   local desk fm="" f
   [ "$EUID" -ne 0 ] || return 1 # root-check
   [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] || return 1
   # Not xdg-open: outside Plasma and GNOME it asks the type of the path, a
   # mount point is "inode/mount-point", which no program handles, and it
   # falls back to the web browser. The file manager that opens folders
   # (inode/directory) is started directly, else the first one installed.
   desk="$(xdg-mime query default inode/directory 2>/dev/null)"
   case "${desk,,}" in
      *dolphin*) fm=dolphin ;;
      *thunar*) fm=thunar ;;
      *nautilus*) fm=nautilus ;;
      *nemo*) fm=nemo ;;
      *caja*) fm=caja ;;
      *pcmanfm-qt*) fm=pcmanfm-qt ;;
      *pcmanfm*) fm=pcmanfm ;;
      *spacefm*) fm=spacefm ;;
      *doublecmd*) fm=doublecmd ;;
   esac
   if [ -z "$fm" ] || ! command -v "$fm" >/dev/null 2>&1; then
      fm=""
      for f in dolphin thunar nautilus nemo caja pcmanfm-qt pcmanfm; do
         if command -v "$f" >/dev/null 2>&1; then fm="$f"; break; fi
      done
   fi
   if [ -z "$fm" ]; then
      command -v xdg-open >/dev/null 2>&1 || return 1
      fm=xdg-open
   fi
   setsid -f "$fm" "$1" < /dev/null > /dev/null 2>&1
}

apfs_cmd_open() {
   local want_vol="" no_open="" given="" dev probe rc kind path backend ans i
   while [ "$#" -gt 0 ]; do
      case "$1" in
         --volume)
            [ "$#" -ge 2 ] || { apfs_say $"--volume needs a number"; return 2; }
            want_vol="$2"
            shift
            ;;
         --volume=*) want_vol="${1#*=}" ;;
         --no-open) no_open=1 ;;
         -*) apfs_say $"bigmount: unknown option '%s' (see bigmount --help)" "$1"; return 2 ;;
         *)
            [ -z "$given" ] || { apfs_say $"bigmount: unknown option '%s' (see bigmount --help)" "$1"; return 2; }
            given="$1"
            ;;
      esac
      shift
   done
   if [ -n "$want_vol" ] && [[ ! $want_vol =~ ^[0-9]{1,2}$ ]]; then
      apfs_say $"invalid volume number: %s" "$want_vol"
      return 2
   fi
   apfs_choose_device "$given" || return
   dev="$REPLY"

   # Already open: show it again (unless another volume is asked for)
   apfs_read_mounts
   if [ -z "$want_vol" ] && apfs_mount_of "$dev" && apfs_is_apfs_type "${APFS_M_TYPE[REPLY]}"; then
      i="$REPLY"
      apfs_open_path "${APFS_M_MP[i]}" "${APFS_M_TYPE[i]}"
      path="$REPLY"
      apfs_say $"%s is already open (read-only): %s" "$dev" "$path"
      [ -z "$no_open" ] && apfs_open_folder "$path"
      printf '%s\n' "$path"
      return 0
   fi

   # Nothing to ask the administrator password for when no driver is installed
   apfs_backends
   if [ "${#APFS_BACKENDS[@]}" -eq 0 ]; then
      apfs_no_driver_help
      return 4
   fi

   apfs_say $"Reading %s needs administrator rights. Nothing will be written to it." "$dev"
   probe="$(apfs_as_root probe "$dev")"
   rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   apfs_parse_probe "$probe"

   if [ -z "$want_vol" ] && [ "${#APFS_V_IDX[@]}" -gt 1 ]; then
      apfs_say $"Volumes of %s:" "$dev"
      apfs_show_volumes
      if [ ! -t 0 ]; then
         apfs_say $"Choose one: bigmount --open-apfs %s --volume N" "$dev"
         return 2
      fi
      read -r -p "$(printf $"Volume to open [%s]: " "$APFS_RECOMMENDED")" ans || return 2
      want_vol="${ans:-$APFS_RECOMMENDED}"
      if [[ ! $want_vol =~ ^[0-9]{1,2}$ ]]; then
         apfs_say $"invalid volume number: %s" "$want_vol"
         return 2
      fi
   elif [ "$APFS_LISTER" = none ] && [ -z "$want_vol" ]; then
      apfs_say $"The volumes of this partition cannot be listed (install apfsprogs or apfs-fuse-git): opening volume 0."
   fi

   probe="$(apfs_as_root mount "$dev" ${want_vol:+"$want_vol"})"
   rc=$?
   [ "$rc" -eq 0 ] || return "$rc"
   IFS=$'\t' read -r kind _ path backend _ <<< "$probe"
   if [ "$kind" != mounted ] && [ "$kind" != already ]; then
      apfs_say $"unexpected answer from the APFS helper"
      return 1
   fi
   if [ ! -r "$path" ] || [ ! -x "$path" ]; then
      apfs_say $"%s is open, but this user cannot read it" "$path"
      return 1
   fi
   if [ -z "$(ls -A -- "$path" 2>/dev/null)" ]; then
      apfs_say $"This volume is empty. Since macOS 10.15 the files of the users are in the volume whose role is Data: bigmount --close-apfs %s, then bigmount --open-apfs %s and choose it." "$dev" "$dev"
   fi
   apfs_say $"Opened read-only (nothing can be changed on the disk): %s" "$path"
   [ "$backend" = fuse ] && apfs_say $"Files that use a compression the driver does not know give a read error instead of wrong content."
   apfs_say $"To close it before unplugging the disk: bigmount --close-apfs %s" "$dev"
   if [ -z "$no_open" ] && ! apfs_open_folder "$path"; then
      [ "$EUID" -eq 0 ] && apfs_say $"Open it in the file manager of your session (it is not opened as root)." # root-check
   fi
   printf '%s\n' "$path"
   return 0
}

apfs_cmd_close() {
   local target="${1:-}" i mine=() out rc
   if [ "$#" -gt 1 ]; then
      apfs_say $"bigmount: unknown option '%s' (see bigmount --help)" "$2"
      return 2
   fi
   if [ -z "$target" ]; then
      apfs_read_mounts
      for i in "${!APFS_M_MP[@]}"; do
         apfs_is_apfs_type "${APFS_M_TYPE[i]}" || continue
         [[ ${APFS_M_MP[i]} == "$APFS_MEDIA"/*/* ]] && mine+=("${APFS_M_MP[i]}")
      done
      case "${#mine[@]}" in
         0) apfs_say $"No APFS volume opened by bigmount --open-apfs is mounted."; return 0 ;;
         1) target="${mine[0]}" ;;
         *)
            apfs_say $"Several APFS volumes are open, give the one to close:"
            for i in "${mine[@]}"; do apfs_say '  %s' "$i"; done
            return 2
            ;;
      esac
   fi
   out="$(apfs_as_root unmount "$target")"
   rc=$?
   # In use: Big Storage Rescue, when installed, says by which programs (as
   # this person: their own programs, nothing is closed)
   if [ "$rc" -eq 8 ] && [ "$EUID" -ne 0 ] && command -v big-storage-rescue >/dev/null 2>&1 && apfs_find_open "$target" 2>/dev/null; then # root-check
      big-storage-rescue --busy "$APFS_OPEN_MP" < /dev/null >&2
   fi
   [ "$rc" -eq 0 ] || return "$rc"
   apfs_say $"Closed: %s. The disk can be unplugged." "${out#unmounted$'\t'}"
   return 0
}

bm_apfs_main() {
   local cmd="$1"
   shift
   case "$cmd" in
      --open-apfs) apfs_cmd_open "$@" ;;
      --close-apfs) apfs_cmd_close "$@" ;;
      --apfs-info) apfs_cmd_info "$@" ;;
      --apfs-helper) apfs_cmd_helper "$@" ;;
   esac
}
