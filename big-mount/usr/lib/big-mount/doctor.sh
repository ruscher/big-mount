# shellcheck shell=bash
#
# big-mount self-check: bigmount --version and bigmount --doctor.
#
# Answers "which Big-Mount is installed, which code is it running, and is
# the storage stack around it healthy?" without administrator rights and
# without changing anything: no mount, no unmount, no file written outside
# the terminal. Loaded by cli.sh only for these two commands.
#
# The report is meant to be pasted into a bug report, so it never prints
# volume labels, serial numbers, UUIDs, the user name, the home folder or
# the folders where devices are mounted (they usually carry the label).

BM_VERSION=2.6.0

# ---------------------------------------------------------------------------
# --version

# bm_version_info: V_REVISION, V_DATE, V_SOURCE (where the code came from)
# and V_PKG (the installed package, when this is the packaged copy).
# The PKGBUILD writes $BM_LIB_DIR/version as KEY=value lines; it is read as
# data and every value is checked, never sourced.
bm_version_info() {
   local f="$BM_LIB_DIR/version" key val top
   V_REVISION="" V_DATE="" V_SOURCE="" V_PKG=""
   if [ -r "$f" ]; then
      while IFS='=' read -r key val; do
         case "$key" in
            revision) [[ $val =~ ^[0-9a-f]{7,40}(-dirty)?$ ]] && V_REVISION="$val" ;;
            date) [[ $val =~ ^[0-9T:+-]+Z?$ ]] && V_DATE="$val" ;;
            source) [[ $val =~ ^https://[A-Za-z0-9./_-]+$ ]] && V_SOURCE="$val" ;;
         esac
      done < "$f"
   else
      # A source checkout: ask git, when there is one
      if command -v git >/dev/null && top="$(git -C "$BM_LIB_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
         V_REVISION="$(git -C "$top" describe --always --dirty --tags 2>/dev/null)"
         V_DATE="$(TZ=UTC git -C "$top" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd 2>/dev/null)"
      fi
      V_SOURCE=$"source checkout (not installed by a package)"
   fi
   if [ "$BM_LIB_DIR" = /usr/lib/big-mount ] && command -v pacman >/dev/null; then
      V_PKG="$(pacman -Qqo /usr/bin/bigmount 2>/dev/null | head -n1)"
      [ -n "$V_PKG" ] && V_PKG="$(pacman -Q -- "$V_PKG" 2>/dev/null)"
   fi
}

bm_cmd_version() {
   local l_pkg=$"package:" l_rev=$"revision:" l_src=$"source:" w=0 l
   bm_version_info
   # Labels are aligned by terminal columns (accents, CJK)
   for l in "$l_pkg" "$l_rev" "$l_src"; do bm_width "$l"; [ "$REPLY" -gt "$w" ] && w="$REPLY"; done
   printf 'Big-Mount %s\n' "$BM_VERSION"
   [ -n "$V_PKG" ] && { bm_fill "$l_pkg" "$w"; printf '  %s %s\n' "$REPLY" "$V_PKG"; }
   [ -n "$V_REVISION" ] || V_REVISION=$"unknown"
   bm_fill "$l_rev" "$w"; printf '  %s %s\n' "$REPLY" "$V_REVISION${V_DATE:+ ($V_DATE)}"
   [ -n "$V_SOURCE" ] && { bm_fill "$l_src" "$w"; printf '  %s %s\n' "$REPLY" "$V_SOURCE"; }
   return 0
}

# ---------------------------------------------------------------------------
# --doctor

# Private data never reaches the report: the home folder becomes ~ and the
# folders of the user under /run/media and /media become <user>. The bare
# user name is left alone: it could be part of anything (a URL, a model).
bm_dr_anon() {
   local s="$1"
   [ -n "${HOME:-}" ] && [ "$HOME" != / ] && s="${s//"$HOME"/"~"}"
   if [ -n "${DR_USER:-}" ]; then
      s="${s//"/run/media/$DR_USER"/"/run/media/<user>"}"
      s="${s//"/media/$DR_USER"/"/media/<user>"}"
   fi
   # Control characters from device data, except line breaks
   REPLY="${s//[$'\001'-$'\011'$'\013'-$'\037'$'\177']/?}"
}

# bm_dr LEVEL TEXT [DETAIL]: one line of the report.
# LEVEL: ok | info | warn | fail
bm_dr() {
   local level="$1" text="$2" detail="${3:-}" tag
   case "$level" in
      ok) tag=" OK " ;;
      info) tag="INFO" ;;
      warn) tag="WARN"; DR_WARN=$((DR_WARN + 1)) ;;
      fail) tag="FAIL"; DR_FAIL=$((DR_FAIL + 1)) ;;
   esac
   if [ -n "$DR_COLOR" ]; then
      case "$level" in
         ok) tag=$'\e[32m'"$tag"$'\e[0m' ;;
         warn) tag=$'\e[33m'"$tag"$'\e[0m' ;;
         fail) tag=$'\e[1;31m'"$tag"$'\e[0m' ;;
      esac
   fi
   bm_dr_anon "$text"; text="$REPLY"
   printf '  [%s] %s\n' "$tag" "$text"
   if [ -n "$detail" ]; then
      bm_dr_anon "$detail"
      printf '         %s\n' "${REPLY//$'\n'/$'\n'         }"
   fi
}

bm_dr_section() { printf '\n%s\n' "$1"; }

# Messages with data: a translated FORMAT and its ARGS, into REPLY
# shellcheck disable=SC2059
bm_fmt() { local f="$1"; shift; printf -v REPLY -- "$f" "$@"; }

# Version of a program, first line only, or nothing
bm_dr_ver() {
   REPLY=""
   command -v "$1" >/dev/null || return 1
   REPLY="$(timeout 5 "$@" 2>&1 | head -n1)"
   REPLY="${REPLY//[[:cntrl:]]/}"
}

# The /usr/bin/bigmount of this system (installed, not necessarily the one
# running this check) carries one of the known defects of older versions?
bm_dr_legacy_check() {
   local f="$1"
   [ -r "$f" ] || return 0
   if grep -qF "s|[0-9].*||g" "$f"; then
      bm_fmt $"%s is the legacy script (2025 or earlier): it cuts NVMe and SD card names (nvme0n1p1 becomes nvme)" "$f"
      bm_dr fail "$REPLY" \
         $"Symptoms: 'cat: /sys/block/nvme/removable' and 'Error looking up object for device /dev/nvme'. Update the big-mount package."
   fi
   if grep -qE 'grep \^User= /var/lib/sddm/state.conf' "$f" && ! grep -qF -- '-r /var/lib/sddm/state.conf' "$f"; then
      bm_fmt $"%s reads /var/lib/sddm/state.conf without checking it may: 'Permission denied' when a user runs it" "$f"
      bm_dr fail "$REPLY" \
         $"Update the big-mount package. Never change the permissions of the files of SDDM to work around it."
   fi
   if ! grep -q 'bm_main' "$f"; then
      bm_fmt $"%s has no diagnosis or safe removal: every option is ignored and it tries to mount the internal partitions instead" "$f"
      bm_dr fail "$REPLY" \
         $"Commands such as 'bigmount --diagnose' do not diagnose anything and may print permission errors. Update the big-mount package."
      return 1
   fi
   return 0
}

bm_dr_bigmount() {
   local f p found=() n=0 st mode own altered
   bm_dr_section $"Big-Mount"
   bm_version_info
   bm_dr info "Big-Mount $BM_VERSION, ${V_REVISION:-?}${V_DATE:+ ($V_DATE)}" "$V_PKG"
   if [ "$BM_LIB_DIR" != /usr/lib/big-mount ]; then
      bm_dr info $"This is not the installed copy (a source checkout or an unpacked package); the installed one is checked below."
   fi

   # Every bigmount in PATH: a copy in /usr/local/bin or ~/bin hides the
   # package and is a classic reason for "it works on the other computer"
   mapfile -t found < <(type -ap bigmount 2>/dev/null)
   if [ "${#found[@]}" -eq 0 ]; then
      bm_dr fail $"bigmount is not in PATH" $"Install the big-mount package."
   else
      for p in "${found[@]}"; do
         [ "$(readlink -f -- "$p")" = /usr/bin/bigmount ] || n=$((n + 1))
      done
      if [ "$n" -gt 0 ]; then
         bm_dr warn $"Another copy of bigmount is found in PATH before or besides the package" "${found[*]}"
      fi
   fi

   if [ -e /usr/bin/bigmount ]; then
      bm_dr_legacy_check /usr/bin/bigmount && bm_dr ok $"/usr/bin/bigmount is the current generation (no known defect of older versions)"
   else
      bm_dr fail $"/usr/bin/bigmount is missing" $"Install the big-mount package."
   fi
   # The legacy script is a single file: the others are only expected with
   # the current generation
   if grep -q bm_main /usr/bin/bigmount 2>/dev/null; then
      for f in /usr/lib/big-mount/lib.sh /usr/lib/big-mount/cli.sh /usr/lib/big-mount/ui.sh \
         /usr/lib/big-mount/doctor.sh /usr/lib/big-mount/bigmount-holders \
         /usr/lib/systemd/system/big-mount.service /usr/share/polkit-1/actions/org.biglinux.big-mount.policy \
         /usr/share/kio/servicemenus/big-mount.desktop; do
         [ -e "$f" ] && continue
         if [ "$f" = /usr/lib/big-mount/doctor.sh ]; then
            bm_fmt $"The installed package is older than Big-Mount %s (it has no bigmount --doctor)" "$BM_VERSION"
            bm_dr warn "$REPLY" $"Update the big-mount package."
            continue
         fi
         bm_fmt $"Missing file of the package: %s" "$f"
         bm_dr fail "$REPLY" $"Reinstall the big-mount package."
      done
   fi

   # Code that runs as root (the boot service, the pkexec helper) must not
   # be writable by anyone else
   for f in /usr/bin/bigmount /usr/lib/big-mount /usr/lib/big-mount/*; do
      [ -e "$f" ] || continue
      st="$(stat -c '%U %a' -- "$f" 2>/dev/null)" || continue
      own="${st% *}" mode="${st#* }"
      if [ "$own" != root ] || (( 8#$mode & 8#022 )); then
         bm_fmt $"Unsafe owner or permissions: %s (%s)" "$f" "$st"
         bm_dr fail "$REPLY" $"Reinstall the big-mount package."
      fi
   done

   if command -v pacman >/dev/null && pacman -Q big-mount >/dev/null 2>&1; then
      # Files changed since installation (the configuration may change)
      altered="$(LC_ALL=C pacman -Qkk big-mount 2>&1 | grep -vE '^big-mount: [0-9]+ total files|/etc/big-mount.conf' | grep -E 'warning|error' | sed 's/^warning: //;s/^error: //')"
      if [ -n "$altered" ]; then
         bm_dr warn $"Installed files differ from the package" "$altered"
      else
         bm_dr ok $"Installed files match the package"
      fi
      local url repo
      url="$(LC_ALL=C pacman -Qi big-mount 2>/dev/null | sed -n 's/^URL *: //p')"
      [ -n "$url" ] && { bm_fmt $"Package built from %s" "$url"; bm_dr info "$REPLY"; }
      repo="$(LC_ALL=C pacman -Si big-mount 2>/dev/null | sed -n 's/^Repository *: //p;s/^Version *: //p' | paste -sd' ')"
      if [ -n "$repo" ]; then
         local inst="${V_PKG#* }" rv="${repo#* }"
         command -v vercmp >/dev/null || inst=""
         [ -n "$inst" ] && case "$(vercmp "$inst" "$rv" 2>/dev/null)" in
            -1)
               bm_fmt $"A newer version is in the repository (%s: %s); installed: %s" "${repo% *}" "$rv" "$inst"
               bm_dr warn "$REPLY" $"Update the whole system: sudo pacman -Syu"
               ;;
            1)
               bm_fmt $"The installed version (%s) is newer than the one of the repository (%s: %s)" "$inst" "${repo% *}" "$rv"
               bm_dr info "$REPLY"
               ;;
         esac
      fi
      # pacman -Q NAME also answers for a package that only provides NAME
      pacman -Qq 2>/dev/null | grep -qx big-mount-git && bm_dr warn $"The obsolete package big-mount-git is also installed"
   fi
}

bm_dr_service() {
   local enabled active result frag dropins s line n=0 failed=() warns=()
   bm_dr_section $"Boot service (big-mount.service)"
   if [ -e /etc/bigmountall-no ]; then
      bm_dr info $"/etc/bigmountall-no exists: mounting at boot is disabled on purpose"
   fi
   enabled="$(systemctl is-enabled big-mount.service 2>/dev/null)"
   active="$(systemctl is-active big-mount.service 2>/dev/null)"
   while IFS='=' read -r s line; do
      case "$s" in
         Result) result="$line" ;;
         FragmentPath) frag="$line" ;;
         DropInPaths) dropins="$line" ;;
      esac
   done < <(systemctl show -p Result -p FragmentPath -p DropInPaths big-mount.service 2>/dev/null)
   case "$enabled" in
      enabled) bm_dr ok $"Enabled at boot" ;;
      "") bm_dr fail $"Not found by systemd" $"Reinstall the big-mount package." ;;
      *) bm_fmt $"Not enabled at boot (%s)" "$enabled"; bm_dr warn "$REPLY" $"Enable it: sudo systemctl enable big-mount" ;;
   esac
   if [ "$active" = active ] && [ "${result:-success}" = success ]; then
      bm_dr ok $"Ran in this boot"
   elif [ "$enabled" = enabled ]; then
      bm_fmt $"State in this boot: %s (%s)" "${active:-?}" "${result:-?}"
      bm_dr warn "$REPLY" $"See: journalctl -b -u big-mount"
   fi
   if [ -n "${frag:-}" ] && [[ $frag != /usr/lib/systemd/system/* ]]; then
      bm_fmt $"The unit is replaced by %s" "$frag"
      bm_dr warn "$REPLY" $"A copy in /etc/systemd/system overrides the package: remove it unless it is intended."
   fi
   [ -n "${dropins:-}" ] && { bm_fmt $"Drop-in files change the unit: %s" "$dropins"; bm_dr info "$REPLY"; }

   # What the boot run did, without mount points (they carry the labels)
   if [ -r "$BM_STATUS_FILE" ]; then
      while IFS=$'\t' read -r dev _ _ s line; do
         [[ $dev == /dev/* ]] || continue
         n=$((n + 1))
         [ "$s" = failed ] && failed+=("$dev: $line")
         [ "$s" = ro ] && warns+=("$dev: $line")
      done < "$BM_STATUS_FILE"
      bm_fmt $"Partitions handled by Big-Mount at boot: %d" "$n"; bm_dr info "$REPLY"
      [ "${#failed[@]}" -gt 0 ] && bm_dr warn $"Failed at boot" "$(printf '%s\n' "${failed[@]}")"
      [ "${#warns[@]}" -gt 0 ] && bm_dr warn $"Mounted read-only at boot" "$(printf '%s\n' "${warns[@]}")"
   fi

   if [ -r /etc/big-mount.conf ]; then
      s="$(sed -n 's/^[[:space:]]*PERMISSIONS[[:space:]]*=[[:space:]]*\([^#[:space:]]*\).*/\1/p' /etc/big-mount.conf | tail -n1)"
      case "${s:-shared}" in
         shared | owner | private) bm_fmt $"Configuration: PERMISSIONS=%s" "${s:-shared}"; bm_dr ok "$REPLY" ;;
         *) bm_dr warn $"Configuration: unknown PERMISSIONS value, shared is used" "/etc/big-mount.conf" ;;
      esac
   fi

   if journalctl -b -q -n 1 -u big-mount.service >/dev/null 2>&1; then
      mapfile -t warns < <(journalctl -b -q --no-pager -o cat -p warning -u big-mount.service 2>/dev/null \
         | sed -E 's#/(mnt|media|run/media)/[^ ]*#/\1/…#g' | tail -n 10)
      if [ "${#warns[@]}" -gt 0 ] && [ -n "${warns[0]}" ]; then
         bm_dr warn $"Warnings in the journal of this boot" "$(printf '%s\n' "${warns[@]}")"
      fi
   else
      bm_dr info $"The journal is not readable by this user: boot messages not checked"
   fi
}

bm_dr_session() {
   local s rundir="${XDG_RUNTIME_DIR:-/run/user/$EUID}"
   bm_dr_section $"Desktop session"
   bm_fmt $"Session: %s, desktop: %s, language: %s" "${XDG_SESSION_TYPE:-?}" "${XDG_CURRENT_DESKTOP:-?}" "${LC_ALL:-${LC_MESSAGES:-${LANG:-?}}}"
   bm_dr info "$REPLY"
   # Drive manager: only what it offers depends on these
   local dt=0 dt_tools=(rsync smartctl ddrescue testdisk photorec)
   local dt_uses=($"copying files off a drive" $"SMART details" $"disk images" $"lost partitions" $"search by content")
   for dt in "${!dt_tools[@]}"; do
      if command -v "${dt_tools[dt]}" >/dev/null; then bm_fmt $"Drive manager, %s: %s" "${dt_uses[dt]}" "${dt_tools[dt]}"; bm_dr ok "$REPLY"
      else bm_fmt $"Drive manager, %s: %s is not installed" "${dt_uses[dt]}" "${dt_tools[dt]}"; bm_dr info "$REPLY"
      fi
   done
   if command -v python3 >/dev/null && python3 -I -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1"); from gi.repository import Adw; raise SystemExit((Adw.MAJOR_VERSION, Adw.MINOR_VERSION) < (1, 5))' 2>/dev/null; then bm_dr ok $"Application and dialogs: GTK 4 and libadwaita"
   else bm_dr warn $"The application and the dialogs need gtk4, libadwaita 1.5 or later and python-gobject: bigmount --gui-drive cannot open and questions are asked in the terminal. bigmount --drive works without them"
   fi
   if command -v notify-send >/dev/null; then bm_dr ok $"Notifications: notify-send"
   else bm_dr warn $"notify-send (libnotify) is not installed: no notifications" $"Install libnotify."
   fi
   if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
      [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || bm_dr warn $"No session D-Bus: notifications cannot be shown"
      local running=0
      [ -e "$rundir/big-mount-notifier.lock" ] && ! flock -n "$rundir/big-mount-notifier.lock" true 2>/dev/null && running=1
      local entry="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/big-mount-notifier.desktop"
      if [ ! -e "$entry" ] || grep -qx -e 'Hidden=true' -e 'X-GNOME-Autostart-enabled=false' "$entry"; then
         bm_dr info $"The read-only notifier is off (it can be turned on in the menu of the application)"
      elif [ "$running" = 1 ]; then
         bm_dr ok $"The read-only notifier is running"
      else
         bm_dr warn $"The read-only notifier is on but not running" $"It starts at the next login."
      fi
   fi
   if command -v pacman >/dev/null; then
      s="$(pacman -Q plasma-workspace dolphin 2>/dev/null | paste -sd, | sed 's/,/, /g')"
      [ -n "$s" ] && bm_dr info "$s"
   fi
}

bm_dr_storage() {
   local line s name tran rm hp type n v ud_devs=() ns
   bm_dr_section $"Storage stack"
   bm_dr_ver uname -r; v="kernel $REPLY"
   v+=", bash ${BASH_VERSION%%(*}"
   bm_dr_ver lsblk --version; v+=", util-linux ${REPLY##* }"
   s="$(busctl get-property org.freedesktop.UDisks2 /org/freedesktop/UDisks2/Manager org.freedesktop.UDisks2.Manager Version 2>/dev/null)"
   s="${s#s \"}"; v+=", udisks ${s%\"}"
   bm_dr_ver systemctl --version; v+=", ${REPLY%% (*}"
   bm_dr info "$v"

   for s in lsblk findmnt blkid udevadm udisksctl lsof flock setpriv gdbus; do
      command -v "$s" >/dev/null && continue
      bm_fmt $"Missing program: %s" "$s"
      bm_dr fail "$REPLY" $"Install the dependencies of big-mount (util-linux, udisks2, lsof, glib2)."
   done
   if busctl --system --no-pager status org.freedesktop.UDisks2 >/dev/null 2>&1; then
      bm_dr ok $"UDisks2 answers on the system D-Bus"
   else
      bm_dr fail $"UDisks2 does not answer on the system D-Bus" $"Plasma and Big-Mount cannot mount or remove devices. Check: systemctl status udisks2"
   fi
   if command -v pkaction >/dev/null; then
      if pkaction --action-id org.biglinux.big-mount.inspect-processes >/dev/null 2>&1; then
         bm_dr ok $"Polkit knows the action of Big-Mount"
      else
         bm_dr warn $"Polkit does not know org.biglinux.big-mount.inspect-processes" $"'Show programs of all users' will not work. Reinstall the big-mount package."
      fi
   fi
   if journalctl -k -b -q -n 1 >/dev/null 2>&1 && [ -n "$(journalctl -k -b -q -n 1 2>/dev/null)" ]; then
      bm_dr ok $"Kernel log readable (needed to explain read-only devices)"
   else
      bm_dr info $"Kernel log not readable by this user: read-only causes are explained with fewer details"
   fi

   # Every disk the kernel shows must be known to UDisks2 under the same
   # name: that is the lookup that failed with "/dev/nvme" in old versions
   mapfile -t ud_devs < <(LC_ALL=C udisksctl dump 2>/dev/null | sed -n 's/^ *Device: *\(\/dev\/[^ ]*\)$/\1/p')
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      name="${KV[NAME]}" tran="${KV[TRAN]:-}" rm="${KV[RM]}" hp="${KV[HOTPLUG]}" type="${KV[TYPE]}"
      case "${name##*/}" in zram* | ram* | loop*) continue ;; esac
      [ "$type" = disk ] || continue
      bm_human_size "${KV[SIZE]}"
      if [ "$rm" = 1 ] || [ "$hp" = 1 ] || [ "$tran" = usb ]; then
         bm_fmt $"%s: %s, %s, removable" "${name##*/}" "${tran:-?}" "$REPLY"
      else
         bm_fmt $"%s: %s, %s, internal" "${name##*/}" "${tran:-?}" "$REPLY"
      fi
      s="$REPLY"
      if [ ! -e "/sys/block/${name##*/}" ]; then
         bm_dr fail "$s" $"The kernel has no /sys/block entry for it"
      elif [ "${#ud_devs[@]}" -gt 0 ] && [[ " ${ud_devs[*]} " != *" $name "* ]]; then
         bm_dr warn "$s" $"UDisks2 does not know this device: Plasma and Big-Mount cannot manage it"
      else
         bm_dr ok "$s"
      fi
      # SMART failure, timeouts and I/O errors of this boot (read-only, as the user)
      bm_drive_health "$name" </dev/null
      if [ "${#DH_FIND[@]}" -gt 0 ]; then
         bm_fmt $"%s: the drive reports problems (%s)" "${name##*/}" "${DH_FIND[*]}"; s="$REPLY"
         bm_fmt $"For details: bigmount --diagnose %s" "$name"
         bm_dr warn "$s" "$REPLY"
      fi
   done < <(lsblk -P -b -p -d -o NAME,TYPE,TRAN,RM,HOTPLUG,SIZE 2>/dev/null)

   # NVMe: a controller (/dev/nvme0) holds namespaces (/dev/nvme0n1), which
   # hold partitions (/dev/nvme0n1p1). Only namespaces and partitions store data.
   for n in /sys/class/nvme/nvme*; do
      [ -e "$n" ] || continue
      ns=()
      for s in "$n"/nvme*n*; do [ -b "/dev/${s##*/}" ] && ns+=("/dev/${s##*/}"); done
      bm_fmt $"NVMe controller /dev/%s: storage %s" "${n##*/}" "${ns[*]:-?}"; bm_dr info "$REPLY"
   done

   # Filesystems mounted read-only that are not read-only by nature
   local ro=()
   while IFS= read -r line; do
      bm_parse_pairs "$line"
      [[ ${KV[SOURCE]} == /dev/* ]] || continue
      case "${KV[FSTYPE]}" in squashfs | iso9660 | udf | erofs) continue ;; esac
      bm_has_opt "${KV[OPTIONS]}" ro || continue
      [[ " ${ro[*]} " == *" ${KV[SOURCE]%%\[*} "* ]] || ro+=("${KV[SOURCE]%%\[*}")
   done < <(findmnt -P -n -o SOURCE,FSTYPE,OPTIONS 2>/dev/null)
   if [ "${#ro[@]}" -gt 0 ]; then
      bm_fmt $"Mounted read-only: %s" "${ro[*]}"; bm_dr warn "$REPLY" $"To know why: bigmount --diagnose DEVICE"
   fi
}

# Symptoms reported together with storage problems that belong to the
# desktop, not to Big-Mount. Only facts that can be read without risk.
bm_dr_outside() {
   local cfg="${XDG_CONFIG_HOME:-$HOME/.config}" foreign=() f n
   bm_dr_section $"Outside Big-Mount (for reference)"
   if [ -d "$cfg" ]; then
      # Full paths: the report turns the home folder into ~
      while IFS= read -r -d '' f; do foreign+=("$f"); done \
         < <(find "$cfg" -maxdepth 2 ! -user "$EUID" -print0 2>/dev/null | head -z -n 20)
      if [ "${#foreign[@]}" -gt 0 ]; then
         bm_dr warn $"Settings files that do not belong to you (Plasma cannot save them, so settings seem to reset)" \
            "$(printf '%s\n' "${foreign[@]}")"$'\n'$"Usually left by a graphical program run with sudo. An administrator can give them back with chown."
      else
         bm_dr ok $"All your settings files belong to you"
      fi
   fi
   if command -v pacman >/dev/null; then
      n="$(pacman -Qu 2>/dev/null | wc -l)"
      if [ "$n" -gt 0 ]; then
         bm_nfmt "%d package has a newer version in the last synchronized package list" "%d packages have newer versions in the last synchronized package list" "$n" "$n"
         bm_dr info "$REPLY" $"Keep the system consistent: update everything at once (sudo pacman -Syu), never only some packages."
      fi
   fi
}

bm_cmd_doctor() {
   if [ "$#" -gt 0 ]; then
      printf $"bigmount: unknown option '%s' (see bigmount --help)"'\n' "$1" >&2
      return 2
   fi
   DR_WARN=0 DR_FAIL=0 DR_COLOR=""
   DR_USER="$(id -un 2>/dev/null)"
   [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && DR_COLOR=1
   printf '%s\n' $"Big-Mount check (nothing is changed; labels, serial numbers, UUIDs and personal paths are left out)"
   bm_dr_bigmount
   bm_dr_service
   bm_dr_session
   bm_dr_storage
   bm_dr_outside
   printf '\n'
   local problems warnings
   bm_nfmt "%d problem" "%d problems" "$DR_FAIL" "$DR_FAIL"; problems="$REPLY"
   bm_nfmt "%d warning" "%d warnings" "$DR_WARN" "$DR_WARN"; warnings="$REPLY"
   printf $"Result: %s, %s."'\n' "$problems" "$warnings"
   [ "$DR_FAIL" -eq 0 ] && [ "$DR_WARN" -eq 0 ] && printf '%s\n' $"Big-Mount and the storage stack look healthy."
   printf '%s\n' $"To report a problem, attach this output: bigmount --doctor > big-mount-report.txt"
   [ "$DR_FAIL" -eq 0 ]
}
