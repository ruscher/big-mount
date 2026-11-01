#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329,SC2218,SC2034,SC2209,SC2015,SC2030,SC2031,SC2178,SC2128,SC2153  # helpers called through check(), library functions replaced later
# Unit tests of the drive manager: facts are replaced by fixtures, so these run
# anywhere, as any user, and read nothing from the machine's disks. The real
# scenarios, with real filesystems and real I/O errors, are in
# tests/drive-integration.sh.
#
# Usage: tests/drive-tests.sh
set -u
export LC_ALL=C.UTF-8 LANGUAGE=C

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
BIGMOUNT_LIB="$REPO/big-mount/usr/lib/big-mount"
L="$BIGMOUNT_LIB"
B="$REPO/big-mount/usr/bin/bigmount"
# shellcheck source=../big-mount/usr/lib/big-mount/cli.sh
. "$BIGMOUNT_LIB/cli.sh"
BM_UI=tty
bm_ui_init
bm_load drive.sh
bm_load drive-copy.sh
bm_load drive-recovery.sh
bm_load drive-tui.sh

PASS=0 FAIL=0 FAILED=()
check() {
   local msg="$1"; shift
   if "$@"; then PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$msg"
   else FAIL=$((FAIL + 1)); FAILED+=("$msg"); printf '  \033[31m✗\033[0m %s\n' "$msg"; fi
}
eq() { [ "$1" = "$2" ] || { printf '      got: [%s]\n expected: [%s]\n' "$1" "$2"; return 1; }; }
begin() { echo "— $1"; }
json_ok() { python3 -I -m json.tool >/dev/null; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state" XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$XDG_RUNTIME_DIR"
BM_JOBS="$XDG_STATE_HOME/big-mount/jobs"

echo "========================================="
echo "Drive manager unit tests"
echo "========================================="

# ----- a machine made of fixtures
line() { # NAME PKNAME TYPE [KEY=VALUE]...
   local n="$1" p="$2" t="$3" k out; shift 3
   declare -A v=([FSTYPE]="" [FSVER]="" [LABEL]="" [UUID]="" [PARTLABEL]="" [PTTYPE]="" [SIZE]=1000000 [RO]=0 [RM]=0 [HOTPLUG]=0 [ROTA]=0 [TRAN]="" [VENDOR]="" [MODEL]="" [SERIAL]="" [MOUNTPOINTS]="" [FSUSED]="" [FSAVAIL]="")
   for k in "$@"; do v[${k%%=*}]="${k#*=}"; done
   out="NAME=\"$n\" KNAME=\"$n\" PKNAME=\"$p\" TYPE=\"$t\""
   for k in FSTYPE FSVER LABEL UUID PARTLABEL PTTYPE SIZE RO RM HOTPLUG ROTA TRAN VENDOR MODEL SERIAL MOUNTPOINTS FSUSED FSAVAIL; do out+=" $k=\"${v[$k]}\""; done
   printf '%s\n' "$out"
}
FIXTURE() {
   line /dev/sda "" disk TRAN=sata ROTA=1 MODEL="WDC WD10" VENDOR="ATA     " SERIAL=WD1 SIZE=1000000000000 PTTYPE=gpt
   line /dev/sda1 /dev/sda part FSTYPE=ext4 LABEL=Dados UUID=u-a1 SIZE=500000000000
   line /dev/sda2 /dev/sda part FSTYPE=ntfs LABEL="Win 10" UUID=u-a2 SIZE=400000000000 'MOUNTPOINTS=/run/media/u/Win\x2010' FSUSED=100 FSAVAIL=300
   line /dev/sda3 /dev/sda part FSTYPE=swap UUID=u-a3 SIZE=8000000000
   line /dev/sdb "" disk TRAN=sata ROTA=0 MODEL="KINGSTON SA400" SERIAL=K1 SIZE=480000000000
   line /dev/sdb1 /dev/sdb part FSTYPE=crypto_LUKS UUID=u-b1
   line /dev/sdc "" disk TRAN=usb ROTA=1 VENDOR=ST1000DM MODEL=ST1000DM003-1CH162 SERIAL=S1 HOTPLUG=1 SIZE=1000000000000
   line /dev/sdc1 /dev/sdc part FSTYPE=ntfs LABEL=ARQUIVOS UUID=C830 RO=1
   line /dev/nvme0n1 "" disk TRAN=nvme ROTA=0 MODEL="ADATA LEGEND" SIZE=1000000000000
   line /dev/nvme0n1p1 /dev/nvme0n1 part FSTYPE=vfat 'MOUNTPOINTS=/boot/efi'
   line /dev/nvme0n1p2 /dev/nvme0n1 part FSTYPE=btrfs UUID=root 'MOUNTPOINTS=/var/log\x0a/home\x0a/'
   line /dev/mmcblk0 "" disk TRAN=mmc RM=1 MODEL="SD64G" SIZE=64000000000
   line /dev/mmcblk0p1 /dev/mmcblk0 part FSTYPE=exfat LABEL=FOTOS
   line /dev/sdd "" disk TRAN=usb RM=1 MODEL=Pendrive SIZE=16000000000 FSTYPE=vfat LABEL=SEM_PARTICAO
   line /dev/sde "" disk TRAN=usb MODEL=Vazio SIZE=16000000000
   line /dev/sr0 "" rom TRAN=sata MODEL=DVD
   line /dev/zram0 "" disk SIZE=8000000000
   line /dev/loop0 "" loop SIZE=100
   line /dev/loop1 "" loop SIZE=100 FSTYPE=ext4 LABEL=IMG
   line /dev/sdf "" disk TRAN=sata MODEL=Membro SIZE=2000000000
   line /dev/sdf1 /dev/sdf part FSTYPE=LVM2_member
   line /dev/mapper/vg-lv /dev/sdf1 lvm FSTYPE=ext4 LABEL=LV UUID=u-lv
   line /dev/sdg "" disk TRAN=sata MODEL=RaidA
   line /dev/sdg1 /dev/sdg part FSTYPE=btrfs UUID=multi
   line /dev/sdh "" disk TRAN=sata MODEL=RaidB
   line /dev/sdh1 /dev/sdh part FSTYPE=btrfs UUID=multi
}
timeout() { shift; "$@"; }
lsblk() {
   case " $* " in
      *" -P "*) FIXTURE ;;
      *" -s "*) printf '/dev/sdc1 part\n/dev/sdc disk\n' ;;
      *) command lsblk "$@" ;;
   esac
}
findmnt() { return 1; }
FAKE_HEALTH_FIND=() FAKE_KLOG=1 FAKE_SMART=""
bm_drive_health() {
   DH_FIND=("${FAKE_HEALTH_FIND[@]}") DH_COUNT=() DH_LINES=() DH_KLOG="$FAKE_KLOG" DH_SMART="$FAKE_SMART" DH_BAD="${FAKE_BAD:-0}"
   DH_HOURS="${FAKE_HOURS:-}" DH_TEMP="${FAKE_TEMP:-}" DH_NVME_USED="${FAKE_USED:-}" DH_ATTR_PAST="${FAKE_PAST:-}"
   DH_ATTR_FAIL="${FAKE_FAIL:-}" DH_NVME_WARN="${FAKE_WARN:-}" DH_NVME_MEDIA="" DH_NVME_HOT=""
   local f; for f in "${DH_FIND[@]}"; do DH_COUNT[$f]="${FAKE_COUNT:-5}"; done
}
bm_diskseq() { REPLY=7; }

begin "detection: every kind of drive, one scan"
bm_dv_scan
top=" ${DV_TOP[*]} "
check "SATA, USB, NVMe and SD are drives" bash -c '[[ $1 == *" /dev/sda "* && $1 == *" /dev/sdc "* && $1 == *" /dev/nvme0n1 "* && $1 == *" /dev/mmcblk0 "* ]]' _ "$top"
check "a disk without partitions is a drive" bash -c '[[ $1 == *" /dev/sdd "* ]]' _ "$top"
check "an empty disk is a drive" bash -c '[[ $1 == *" /dev/sde "* ]]' _ "$top"
check "an optical drive is a drive" bash -c '[[ $1 == *" /dev/sr0 "* ]]' _ "$top"
check "zram is not storage" bash -c '[[ $1 != *"zram"* ]]' _ "$top"
check "an empty loop device (swap backing) is not storage" bash -c '[[ $1 != *" /dev/loop0 "* ]]' _ "$top"
check "an image with a filesystem is" bash -c '[[ $1 == *" /dev/loop1 "* ]]' _ "$top"
check "partitions are not listed as drives" bash -c '[[ $1 != *" /dev/sda1 "* ]]' _ "$top"
kind() { bm_dv_kind "$1"; eq "$REPLY" "$2"; }
check "SATA rotational: hard disk" kind /dev/sda hdd
check "SATA solid state: SSD" kind /dev/sdb ssd
check "USB stays USB: a bridge says every disk rotates" kind /dev/sdc usb
check "NVMe" kind /dev/nvme0n1 nvme
check "SD card (no /sys entry says otherwise)" kind /dev/mmcblk0 sd
check "optical" kind /dev/sr0 optical
check "image" kind /dev/loop1 image
check "the bus is not a manufacturer" eq "${DV[/dev/sda|VENDOR]}" ""
check "a model cut in two by a USB bridge is not a manufacturer" eq "${DV[/dev/sdc|VENDOR]}" ""
check "escapes in a mount point are decoded" eq "${DV[/dev/sda2|MOUNTPOINTS]}" "/run/media/u/Win 10"
bm_dv_tree /dev/sda; check "tree: disk and its partitions, in order" eq "${DV_TREE[*]}" "/dev/sda /dev/sda1 /dev/sda2 /dev/sda3"
bm_dv_tree /dev/sdf; check "tree: LVM on a partition" eq "${DV_TREE[*]}" "/dev/sdf /dev/sdf1 /dev/mapper/vg-lv"
bm_dv_multi_btrfs /dev/sdg1; check "multi-device Btrfs is seen by its UUID" eq "${DV_MULTI[*]}" "/dev/sdg1 /dev/sdh1"
bm_dv_multi_btrfs /dev/nvme0n1p2; check "single-device Btrfs is not" eq "$?" 1

begin "states: what a volume is, without touching it"
state() { bm_dv_state "$1"; eq "$REPLY" "$2"; }
check "not mounted" state /dev/sda1 unmounted
check "mounted, with a space in the path" state /dev/sda2 mounted-rw
check "the running system" state /dev/nvme0n1p2 system
check "the system mount wins among subvolumes" eq "$DV_MP" /home
check "swap" state /dev/sda3 swap-idle
check "LUKS with nothing on top: locked" state /dev/sdb1 locked
check "an LVM member is not a filesystem" state /dev/sdf1 member
check "no filesystem" state /dev/sde no-fs
check "a disk with partitions holds volumes" state /dev/sda container

begin "health: never healthy just because it was detected"
level() { bm_ds_level "$1"; eq "$DS_LEVEL" "$2"; }
FAKE_HEALTH_FIND=() FAKE_KLOG=0 FAKE_SMART=""
check "no log and no SMART: unknown, not fine" level /dev/sda unknown
check "  ... and that rests on nothing" eq "$DS_BASIS" none
FAKE_KLOG=1
check "no errors in the log: no alerts" level /dev/sda normal
check "  ... but it says SMART was not read" bash -c '[ "$1" = log ]' _ "$DS_BASIS"
bm_ds_level_label; check "  ... in its words" bash -c '[[ $1 == *"SMART not read"* ]]' _ "$REPLY"
FAKE_SMART=ok
check "SMART and log: no alerts" level /dev/sda normal
check "  ... resting on both" eq "$DS_BASIS" smart+log
FAKE_SMART=failing FAKE_HEALTH_FIND=(smart-failing)
check "SMART failing: critical" level /dev/sda critical
FAKE_SMART="" FAKE_HEALTH_FIND=(io-errors) FAKE_COUNT=1
check "one I/O error: attention (a bad cable does that)" level /dev/sda attention
FAKE_COUNT=55
check "many I/O errors: critical" level /dev/sda critical
FAKE_HEALTH_FIND=(timeouts) FAKE_COUNT=2
check "timeouts: attention" level /dev/sda attention
FAKE_HEALTH_FIND=(usb-resets) FAKE_COUNT=48
check "USB resets: attention" level /dev/sdc attention
FAKE_HEALTH_FIND=() FAKE_BAD=3
check "replaced sectors on a hard disk: attention" level /dev/sda attention
check "replaced sectors on an SSD: normal use" level /dev/sdb normal
FAKE_BAD=0
check "a disk image has no health" level /dev/loop1 na

begin "grade: one word, and healthy only on the drive's own report"
grade() { bm_ds_level "$1"; eq "$DS_GRADE:${DS_NOTES[*]}" "$2"; }
FAKE_HEALTH_FIND=() FAKE_KLOG=1 FAKE_SMART=""
check "the system log alone: good, and it says why not healthy" grade /dev/sda "good:smart-unread"
FAKE_SMART=ok
check "SMART and log, nothing found: healthy" grade /dev/sdb "healthy:"
FAKE_HOURS=36000
check "a hard disk after about four years powered on: good" grade /dev/sda "good:old"
check "  ... an SSD that long is still healthy" grade /dev/sdb "healthy:"
bm_ds_level /dev/sda; bm_ds_note_text old; check "  ... in years a person reads" bash -c '[[ $1 == *36000*"4 years"* ]]' _ "$REPLY"
FAKE_HOURS="" FAKE_TEMP=58
check "a hard disk at 58 °C: good" grade /dev/sda "good:hot"
check "  ... normal for an SSD" grade /dev/sdb "healthy:"
FAKE_TEMP="" FAKE_USED=60
check "an SSD past half of its rated life: good" grade /dev/nvme0n1 "good:wear"
FAKE_USED=95
check "  ... past 90 %: poor, without any alert" grade /dev/nvme0n1 "poor:worn-out"
FAKE_USED="" FAKE_PAST=1
check "SMART values below their limit in the past: good" grade /dev/sdb "good:attrs-past"
FAKE_PAST="" FAKE_FAIL=2
check "below their limit now: an alert, poor" grade /dev/sdb "poor:"
check "  ... said in words" bash -c '[[ " $1 " == *" attrs-failing "* ]]' _ "${DS_WHY[*]}"
FAKE_FAIL="" FAKE_WARN="spare"
check "an NVMe critical warning read through UDisks2: critical" grade /dev/nvme0n1 "critical:"
FAKE_WARN="" FAKE_SMART="" FAKE_HEALTH_FIND=(usb-resets) FAKE_COUNT=48
check "an alert: poor" grade /dev/sdc "poor:"
FAKE_HEALTH_FIND=() FAKE_KLOG=0
check "nothing consulted: not assessed" grade /dev/sda "unknown:"
check "a disk image: not applicable" grade /dev/loop1 "na:"
FAKE_KLOG=1 FAKE_SMART=ok FAKE_HOURS=36000
bm_ds_level /dev/sda
out="{$(bm_ds_json)}"; printf '%s' "$out" | json_ok; check "health JSON with the grade: valid" eq "$?" 0
check "  ... grade, its word and why" bash -c 'python3 -I -c "import json,sys; h=json.loads(sys.argv[1])[\"health\"]; assert h[\"grade\"] == \"good\" and h[\"grade_label\"] and h[\"notes\"][0][\"key\"] == \"old\" and h[\"smart\"][\"hours\"] == 36000" "$1"' _ "$out"
FAKE_SMART="" FAKE_HOURS="" FAKE_KLOG=1

begin "the session notifier: a drive with problems gets a window, once per boot"
(
   BM_NOTIFIED="$WORK/notified"; : > "$BM_NOTIFIED"; BM_SELF=/bin/true
   bm_ui_confirm() { bm_doc_render_text; printf '%s|%s|%s\n%s\n' "$1" "$3" "$4" "$REPLY" >> "$WORK/window.txt"; return 1; }
   F=([DISK]=/dev/sdc [DISK_TYPE]=disk)
   FAKE_HEALTH_FIND=(usb-resets) FAKE_COUNT=48
   bm_notifier_health /dev/sdc1; wait
   bm_notifier_health /dev/sdc1; wait
   F=([DISK]=/dev/sdb [DISK_TYPE]=disk) FAKE_HEALTH_FIND=()
   bm_notifier_health /dev/sdb1; wait
   F=([DISK]=/dev/loop1 [DISK_TYPE]=loop) FAKE_HEALTH_FIND=(io-errors) FAKE_COUNT=9
   bm_notifier_health /dev/loop1; wait
)
check "one window, for the drive with problems only" eq "$(grep -c '^A drive needs attention|' "$WORK/window.txt")" 1
check "  ... with the way to Big-Mount, or to close it" grep -q '^A drive needs attention|Open Big-Mount|Close$' "$WORK/window.txt"
check "  ... naming the drive, its grade and what was found" bash -c 'grep -q "ST1000DM003-1CH162: Poor" "$1" && grep -q "USB connection was reset" "$1"' _ "$WORK/window.txt"
check "  ... remembered once per boot and drive, not per volume" eq "$(wc -l < "$WORK/notified")" 1

begin "SMART: the field case, PASSED with 1848 unreadable sectors"
SMF="$WORK/smart.txt"
cat > "$SMF" <<'SM'
=== START OF READ SMART DATA SECTION ===
SMART overall-health self-assessment test result: PASSED

ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   099   099   010    Pre-fail  Always       -       912
  9 Power_On_Hours          0x0032   099   075   000    Old_age   Always       -       1552
187 Reported_Uncorrect      0x0032   001   001   000    Old_age   Always       -       30161
194 Temperature_Celsius     0x0022   038   071   000    Old_age   Always       -       38 (0 16 0 0 0)
197 Current_Pending_Sector  0x0012   089   089   000    Old_age   Always       -       1848
198 Offline_Uncorrectable   0x0010   089   089   000    Old_age   Offline      -       1848
199 UDMA_CRC_Error_Count    0x003e   200   108   000    Old_age   Always       -       355
SM
bm_ds_smart_parse "$SMF"
check "verdict" eq "$SM_VERDICT" passed
check "pending" eq "$SM_PENDING" 1848
check "reallocated" eq "$SM_REALLOC" 912
check "uncorrectable" eq "$SM_UNCORR" 30161
check "CRC" eq "$SM_CRC" 355
check "hours" eq "$SM_HOURS" 1552
check "temperature" eq "$SM_TEMP" 38
printf '240 Head_Flying_Hours       0x0000   100   253   000    Old_age   Offline      -       29457h+31m+12.583s\n' >> "$SMF"
bm_ds_smart_parse "$SMF"
check "a wrapped power-on counter: the head flying hours are a floor" eq "$SM_HOURS" 29457
bm_ds_smart_file /dev/sdc; mkdir -p "${REPLY%/*}"; cp "$SMF" "$REPLY"
FAKE_HEALTH_FIND=() FAKE_KLOG=1
check "PASSED does not hide it: critical" level /dev/sdc critical
check "  ... with the reason first" eq "${DS_WHY[0]}" pending-sectors
bm_ds_why_text pending-sectors; check "  ... that names the verdict" bash -c '[[ $1 == *1848*PASSED* ]]' _ "$REPLY"
rm -f "${SMF}" "$XDG_RUNTIME_DIR/big-mount/"*
cat > "$SMF" <<'SM'
SMART/Health Information (NVMe Log 0x02, NSID 0xffffffff)
Critical Warning:                   0x04
Percentage Used:                    12%
Media and Data Integrity Errors:    7
SM
bm_ds_smart_parse "$SMF"
check "NVMe: warning" eq "$SM_NVME_WARN" 0x04
check "NVMe: media errors" eq "$SM_NVME_MEDIA" 7
printf 'garbage\n\n' > "$SMF"; bm_ds_smart_parse "$SMF"; check "garbage gives nothing" eq "$SM_VERDICT$SM_PENDING" ""
bm_ds_smart_parse "$WORK/none"; check "a missing file is not an error of anyone's" eq "$?" 1

begin "the port of a USB disk, and its resets"
(
   unset -f bm_drive_health
   . "$L/lib.sh"
   readlink() { printf '%s\n' /sys/devices/pci0000:00/0000:00:01.3/0000:02:00.0/usb1/1-9/1-9.1/1-9.1:1.0/host11/target11:0:0/11:0:0:0/block/sdb; }
   bm_drive_port /dev/sdb
   [ "$REPLY" = 1-9.1 ] || { echo "      port [$REPLY]"; exit 1; }
   bm_udev_props() { UP=(); }
   bm_udisks_drive() { return 1; }
   bm_drive_kmsg() {
      DKMSG=("usb 1-9.1: reset high-speed USB device number 7 using xhci_hcd"
         "usb 1-9.1: reset high-speed USB device number 7 using xhci_hcd"
         "usb 1-9.1: USB disconnect, device number 5"
         "usb 1-9.1.2: reset high-speed USB device number 8 using xhci_hcd"
         "device offline error, dev sdb, sector 2048 op 0x0:(READ)"
         "I/O error, dev sdb, sector 359807616 op 0x0:(READ)"
         "Buffer I/O error on dev sdb1, logical block 44975696, async page read"
         "I/O error, dev sdba, sector 1 op 0x0:(READ)")
   }
   bm_drive_health /dev/sdb
   [ "${DH_COUNT[usb-resets]}" = 3 ] || { echo "      resets [${DH_COUNT[usb-resets]:-}]"; exit 1; }
   [ "${DH_COUNT[io-errors]}" = 2 ] || { echo "      io [${DH_COUNT[io-errors]:-}]"; exit 1; }
   [ "${DH_COUNT[timeouts]}" = 1 ] || { echo "      offline [${DH_COUNT[timeouts]:-}]"; exit 1; }
   [[ " ${DH_FIND[*]} " == *" usb-resets "* ]]
); check "resets of this port count, of the one behind it do not, sdba is not sdb" eq "$?" 0
(
   . "$L/lib.sh"
   readlink() { printf '%s\n' /sys/devices/x/usb1/1-9/1-9:1.0/host11/target/block/sdb; }
   bm_udev_props() { UP=(); }
   bm_udisks_drive() { return 1; }
   bm_drive_kmsg() { DKMSG=("usb 1-9: reset high-speed USB device number 7 using xhci_hcd" "usb 1-9: reset high-speed USB device number 7 using xhci_hcd"); }
   bm_drive_health /dev/sdb
   [ "${#DH_FIND[@]}" -eq 0 ]
); check "two resets are normal while a disk spins up" eq "$?" 0

begin "JSON: device data cannot break it"
evil=$'a"b\\c\nd\te\x01f'
bm_jo k "$evil" | json_ok; check "quotes, backslashes, controls" eq "${PIPESTATUS[1]}" 0
check "the value survives" eq "$(bm_jo k 'x"y' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["k"])')" 'x"y'
check "a number is a number" eq "$(bm_jn a 12 b nope)" '"a":12,"b":null'
check "booleans" eq "$(bm_jb a 1 b 0 c "")" '"a":true,"b":false,"c":false'
FAKE_HEALTH_FIND=() FAKE_KLOG=1 FAKE_SMART=""
bm_dv_list_json | json_ok; check "the whole list" eq "${PIPESTATUS[1]}" 0
n="$(bm_dv_list_json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(len(d["devices"]))')"
check "every drive" eq "$n" "${#DV_TOP[@]}"
bm_dv_list_text >/dev/null; check "the text list does not fail" eq "$?" 0
check "a label cannot send escape sequences to the terminal" bash -c '! printf %s "$1" | grep -q $'"'"'\033'"'"'' _ "$(BM_TUI_COLOR=0 bm_tui_paint none $'x\033[31my')"

begin "mounting: what cannot be mounted says why"
findmnt() { return 1; }
bm_udisks() { UD_ERROR="" UD_MESSAGE=""; printf '%s\n' "$*" >> "$WORK/udisks.log"; return 0; }
bm_mounts() { M_TARGET=() M_FSTYPE=() M_VFSOPT=() M_FSOPT=(); [ -n "${FAKE_MP:-}" ] && { M_TARGET=("$FAKE_MP"); M_VFSOPT=("$FAKE_OPTS"); M_FSTYPE=(x); M_FSOPT=(x); }; return 0; }
bm_facts() { F=([DISK]=/dev/sdc [FSTYPE]="${DV[$1|FSTYPE]:-}" [NAME]="$1" [KNAME]="${1##*/}"); [ -n "${DV[$1|TYPE]:-}" ]; }
mnt() { # DEV EXPECTED_RC EXPECTED_WHY [MODE] [PROTECT] [REMOUNT]
   bm_mnt_mount "$1" "${4:-ro}" "${5:-0}" "${6:-0}"; local rc=$?
   [ "$rc" = "$2" ] && [ "$MNT_WHY" = "$3" ] || { echo "      rc=$rc why=$MNT_WHY"; return 1; }
}
: > "$WORK/udisks.log"
check "locked LUKS: refused" mnt /dev/sdb1 20 locked
check "LVM member: refused" mnt /dev/sdf1 20 member
check "no filesystem: refused" mnt /dev/sde 20 no-fs
check "swap: refused" mnt /dev/sda3 20 swap
check "gone: exit 24" mnt /dev/sdz9 24 gone
check "  ... UDisks2 was never asked" test ! -s "$WORK/udisks.log"
bm_mnt_options ext4; check "ext4 read-only: no journal replay" eq "$REPLY" "ro,noatime,nosuid,nodev,noexec,noload"
bm_mnt_options ntfs; check "NTFS read-only" eq "$REPLY" "ro,noatime,nosuid,nodev,noexec"
FAKE_MP=/m FAKE_OPTS=rw,noatime
check "the table says rw after asking ro: a failure, whatever mount said" mnt /dev/sdc1 1 unknown
FAKE_OPTS=ro,noatime
check "the table says ro: mounted" mnt /dev/sdc1 0 ""
check "  ... through UDisks2, with the options" grep -q -- '^mount -b /dev/sdc1 -o ro,noatime,nosuid,nodev,noexec$' "$WORK/udisks.log"
FAKE_HEALTH_FIND=(smart-failing) FAKE_SMART=failing
check "writing on a drive at risk: refused" mnt /dev/sdc1 20 refused-rw rw
FAKE_HEALTH_FIND=() FAKE_SMART=""
FAKE_MP=""
check "already rw and ro asked: it does not unmount by surprise" mnt /dev/sda2 20 already-rw
fake_helper() { printf '%s\n' "$*" >> "$WORK/helper.log"; return "${FAKE_HELPER_RC:-0}"; }
BM_HELPER_CMD=fake_helper FAKE_MP=/m FAKE_OPTS=ro,noatime
: > "$WORK/helper.log"
check "btrfs read-only, healthy drive: mounted" mnt /dev/sdg1 0 ""
check "  ... without asking for the password" test ! -s "$WORK/helper.log"
FAKE_HEALTH_FIND=(smart-failing) FAKE_SMART=failing
check "btrfs read-only, drive at risk: mounted" mnt /dev/sdg1 0 ""
check "  ... with writing blocked on the device" grep -qx 'protect /dev/sdg1' "$WORK/helper.log"
: > "$WORK/helper.log"
check "ext4 read-only, drive at risk: no protection" mnt /dev/sda1 0 ""
check "  ... so no password is asked" test ! -s "$WORK/helper.log"
FAKE_HELPER_RC=3; check "btrfs, a sibling volume writing: refused" mnt /dev/sdg1 20 protect-busy
FAKE_HELPER_RC=4; check "btrfs on the system drive: refused" mnt /dev/sdg1 20 protect-system
unset BM_HELPER_CMD FAKE_HELPER_RC; FAKE_MP="" FAKE_HEALTH_FIND=() FAKE_SMART=""
explain() { bm_mnt_explain /dev/sdc1 ntfs "$1"; eq "$MNT_WHY" "$2"; }
bm_kernel_messages() { KMSG=(); }
check "no driver" explain "unknown filesystem type 'apfs'" no-driver
check "hibernated" explain "Windows is hibernated, refused to mount" ntfs-hibernated
check "read error" explain "can't read superblock on /dev/sdc1" io-error
check "bad superblock" explain "wrong fs type, bad option, bad superblock" fs-damaged
check "not authorized" explain "org.freedesktop.UDisks2.Error.NotAuthorized" not-authorized
check "not explainable: says so" explain "something else" unknown
bm_kernel_messages() { KMSG=("XFS (loop3): recovery required on read-only device."); }
check "journal needed: from the kernel" explain "mount failed" needs-recovery

begin "a list shorter than the part of it that is shown"
KMSG=("I/O error, dev sdc, sector 1")
out="$(F=([DISK]=/dev/sdc [KNAME]=sdc [TRAN]=usb [RM]=1 [HOTPLUG]=1 [RO]=0 [DISK_RO]=0 [FSTYPE]=ntfs [FSVER]="" [LABEL]="" [UUID]="" [VENDOR]="" [MODEL]=""); D_CAUSE=io-errors D_DETAIL="" D_FIX="" D_WARN=(); DH_DISK=""; DH_FIND=(); bm_tech_report /dev/sdc1)"
check "one kernel message is shown" bash -c '[[ $1 == *"sector 1"* ]]' _ "$out"

begin "the map of ddrescue: real numbers"
cat > "$WORK/map" <<'MAP'
# Mapfile. Created by GNU ddrescue version 1.28
# current_pos  current_status  current_pass
0x00120000     ?               1
#      pos        size  status
0x00000000  0x00100000  +
0x00100000  0x00001000  -
0x00101000  0x0001F000  *
0x00120000  0x00EE0000  ?
MAP
bm_rec_map_parse "$WORK/map"
check "rescued" eq "$MP_RESCUED" 1048576
check "given up" eq "$MP_BAD" 4096
check "left to do" eq "$MP_TODO" $((0x1F000 + 0xEE0000))
: > "$WORK/map"; bm_rec_map_parse "$WORK/map"; check "an empty map is not progress" eq "$?" 1

begin "the log of rsync: what counts as copied"
JS=([FILES_DONE]=0 [BYTES_DONE]=0 [READ_FAILS]=0) BM_FAILED=() BM_NOSPACE=0 BM_RECENT_A=() BM_RECENT_B=()
BM_RUN_S=/src BM_RUN_D=/dst BM_RUN_DIR="$WORK"
: > "$WORK/events.log"
ll() { printf '2026/10/30 14:37:02 [1] %s\n' "$1" | tee -a "$WORK/events.log" | while IFS= read -r x; do :; done; bm_job_log_line "2026/10/30 14:37:02 [1] $1"; }
ll '>f+++++++++|100|ok.jpg'
ll 'cd+++++++++|4096|pasta/'
ll 'cL+++++++++|11|link'
ll 'building file list'
check "a file and a link count, a folder does not" eq "${JS[FILES_DONE]}" 2
check "bytes" eq "${JS[BYTES_DONE]}" 100
ll '>f+++++++++|50|nome com | barra.jpg'
check "a | in a name" eq "${JS[CURRENT]}" "nome com | barra.jpg"
ll $'>f+++++++++|5|caf\xe9 antigo.txt'
check "a name that is not valid UTF-8 still counts" eq "${JS[FILES_DONE]}" 4
ll '>f+++++++++|100|ok.jpg'
check "sent again around a restart: counted once" eq "${JS[BYTES_DONE]}" 155
ll '>f+++++++++|1000|ruim.bin'
bm_job_out_line 'rsync: [sender] read errors mapping "/src/ruim.bin": Input/output error (5)'
bm_job_out_line 'WARNING: ruim.bin failed verification -- update discarded (will try again).'
check "a failed attempt is taken back" eq "${JS[BYTES_DONE]}" 155
ll '>f+++++++++|1000|ruim.bin'
bm_job_out_line 'ERROR: ruim.bin failed verification -- update discarded.'
check "the last one too" eq "${JS[BYTES_DONE]}" 155
check "and it is a failure" test -n "${BM_FAILED[ruim.bin]:-}"
bm_job_out_line 'rsync: [receiver] write failed on "/dst/video.mkv": No space left on device (28)'
check "no space is noticed" eq "$BM_NOSPACE" 1
check "the file is named, relative" test -n "${BM_FAILED[video.mkv]:-}"
out="$(printf 'a\033]0;x\007b\xc2\x9bc\n' | bm_printable_lines)"
check "listed names lose control characters" eq "$out" "  a]0;xbc"
bm_job_out_line 'rsync: [sender] send_files failed to open "/src/segredo": Permission denied (13)'
check "no permission" eq "${BM_FAILED[segredo]:-}" "Permission denied"
bm_job_out_line 'rsync error: some files/attrs were not transferred (see previous errors) (code 23)'
check "a summary line is not a file" eq "${#BM_FAILED[@]}" 3
bm_pwned() { : > "$WORK/pwned"; }
ll '>f+++++++++|7|$(bm_pwned)'
bm_job_out_line 'WARNING: $(bm_pwned) failed verification -- update discarded (will try again).'
check "a file name is never run" test ! -e "$WORK/pwned"

begin "job.conf: one KEY=value per line"
JC=([DEST]='/x/backup=' [NAME]=ok); bm_job_conf_save "$WORK"; bm_job_conf_load "$WORK"
check "a trailing = survives" eq "${JC[DEST]}" '/x/backup='
JC=([DEST]=/x [NAME]=$'Fotos\nDEST=/home/victim'); bm_job_conf_save "$WORK" 2>/dev/null
check "a line break is refused" eq "$?" 1
bm_job_conf_load "$WORK"; check "  ... and the saved job is unchanged" eq "${JC[DEST]}" '/x/backup='

begin "an image job finds its source again"
bm_is_block() { :; }
JC=([DEVICE]=/dev/sdz1 [SERIAL]=WD1 [PART]=1 [SIZE]=500000000000); bm_rec_image_device
check "a renamed partition is found again" eq "$REPLY" /dev/sda1
JC=([DEVICE]=/dev/sda [SERIAL]=WD1 [PART]="" [SIZE]=1000000000000); bm_rec_image_device
check "the whole disk" eq "$REPLY" /dev/sda
JC=([DEVICE]=/dev/sda1 [SERIAL]=GONE [PART]=1 [SIZE]=500000000000); bm_rec_image_device
check "a missing serial: no name fallback" eq "$REPLY" ""
bm_is_block() { [ -b "$1" ]; }
out="$(ddrescue() { :; }; bm_resolve() { R_DEV="$1"; }; bm_rec_check_dest() { REC_ERR=""; }
   : > "$WORK/old.img"; bm_rec_image_cmd --source /dev/sda1 --image "$WORK/old.img" --dry-run --json)"
check "an existing file is never imaged over" grep -q '"error":"image-exists"' <<< "$out"

begin "jobs: state on disk"
d="$BM_JOBS/20261030-140000-abcd"; mkdir -p "$d"
JC=([ID]=20261030-140000-abcd [KIND]=copy [SOURCE]="/a b" [DEST]=/c [NAME]=x)
bm_job_conf_save "$d"
JC=(); bm_job_conf_load "$d"
check "paths with spaces survive" eq "${JC[SOURCE]}" "/a b"
bm_job_dir 20261030-140000-abcd; check "a valid id" eq "$?" 0
bm_job_dir ../../etc; check "a path is not an id" eq "$?" 1
bm_job_dir '20261030-140000-abcd/../..'; check "  ... nor this" eq "$?" 1
JS=([STATE]=running [PID]=999999 [PID_START]=1); bm_job_state_save "$d"
bm_job_state_load "$d"; check "running, but its supervisor is gone: interrupted" eq "${JS[STATE]}" interrupted
JS=([STATE]=running [PID]="$$"); bm_proc_state "$$"; JS[PID_START]="$PROC_START"; bm_job_state_save "$d"
bm_job_state_load "$d"; check "running, and alive: running" eq "${JS[STATE]}" running
JS=([STATE]=running [PID]="$$" [PID_START]=1); bm_job_state_save "$d"
bm_job_state_load "$d"; check "a reused PID is not the supervisor" eq "${JS[STATE]}" interrupted
JS=([STATE]=pending [PID]=""); bm_job_state_save "$d"
bm_job_state_load "$d"; check "pending, before the supervisor starts" eq "${JS[STATE]}" pending
JS=([STATE]=completed); bm_job_exit; check "exit: completed 0" eq "$?" 0
JS=([STATE]=needs-attention [REASON]=files-left); bm_job_exit; check "exit: files left 22" eq "$?" 22
JS=([STATE]=needs-attention [REASON]=no-space); bm_job_exit; check "exit: no space 21" eq "$?" 21
JS=([STATE]=needs-attention [REASON]=source-gone); bm_job_exit; check "exit: gone 24" eq "$?" 24
JS=([STATE]=cancelled); bm_job_exit; check "exit: cancelled 23" eq "$?" 23
JS=([STATE]=paused); bm_job_exit; check "exit: paused 23" eq "$?" 23
JS=([STATE]=failed); bm_job_exit; check "exit: failed 1" eq "$?" 1
bm_job_bar 54; check "the bar shows the number it was given" bash -c '[[ $1 == *"54%" ]]' _ "$REPLY"
JS=([STATE]=running [BYTES_NOW]=100 [BYTES_TOTAL]=0 [FILES_DONE]=3); JC=([SOURCE]=/a [DEST]=/b)
bm_job_status_text "$d" >/dev/null; check "a job that could be read: exit 0" eq "$?" 0
out="$(bm_job_status_text "$d")"
check "without a total: no percentage" bash -c '[[ $1 != *"%"* ]]' _ "$out"
check "  ... and no time left" bash -c '[[ $1 != *Remaining* ]]' _ "$out"
JC=([ID]=x [DST_FS]=ext4 [SRC_FS]=ext4 [ON_CONFLICT]=skip [BWLIMIT]=""); touch "$d/excludes.txt"
bm_cp_rsync_args "$d" /dst
args=" ${RS[*]} "
check "rsync: never deletes" bash -c '[[ $1 != *--delete* && $1 != *--remove-source* ]]' _ "$args"
check "rsync: does not follow links" bash -c '[[ $1 != *" -L "* && $1 != *--copy-links* && $1 == *" -rlt "* ]]' _ "$args"
check "rsync: stays on the filesystem" bash -c '[[ $1 == *--one-file-system* ]]' _ "$args"
check "rsync: existing files are kept by default" bash -c '[[ $1 == *--ignore-existing* ]]' _ "$args"
JC[ON_CONFLICT]=overwrite; bm_cp_rsync_args "$d" /dst
check "rsync: overwrite only when asked" bash -c '[[ $1 != *--ignore-existing* ]]' _ " ${RS[*]} "
JC[ON_CONFLICT]=backup; bm_cp_rsync_args "$d" /dst
check "rsync: backup keeps the old ones" bash -c '[[ $1 == *--backup-dir=/dst/.big-mount-backup-x* ]]' _ " ${RS[*]} "
JC=([ID]=x [DST_FS]=vfat [SRC_FS]=ext4 [ON_CONFLICT]=skip); bm_cp_rsync_args "$d" /dst
check "rsync: FAT has no permissions, and 2 s dates" bash -c '[[ $1 == *--no-perms* && $1 == *--modify-window=2* ]]' _ " ${RS[*]} "

begin "anonymizing"
out="$(printf '{"serial":"TESTSERIAL1","label":"Fotos da Maria","name":"x"}\nSerial number: TESTSERIAL1\n%s/segredo /run/media/%s/ARQUIVOS “Fotos”\n' "$HOME" "$(id -un)" | bm_anon_filter)"
check "no serial" bash -c '[[ $1 != *TESTSERIAL1* ]]' _ "$out"
check "no label" bash -c '[[ $1 != *Maria* && $1 != *“Fotos”* ]]' _ "$out"
check "no user" bash -c '[[ $1 != *"$2"* ]]' _ "$out" "/run/media/$(id -un)"
check "no home" bash -c '[[ $1 != *"$2"* ]]' _ "$out" "$HOME"
# A real report: found by running one, where the label was in the title and the mount point
bm_anon_labels() { printf '%s\n' 'OLD DATA' 'x.*' 'ab'; }
out="$(printf '== OLD DATA ==\nUUID: 7044c98d-66a1\nMounted at: /run/media/%s/OLD DATA\n/run/media/%s/7044-ABCD/x\n{"uuid":"7044","source_uuid":"7044"}\nabout a x.* file\n' "$(id -un)" "$(id -un)" | bm_anon_filter)"
check "no volume name, in a title or a mount point" bash -c '[[ $1 != *"OLD DATA"* ]]' _ "$out"
check "no UUID, as text or JSON, or as the name of a mount point" bash -c '[[ $1 != *7044* ]]' _ "$out"
check "a mount point comes out clean" bash -c '[[ $1 == *"/run/media/USER/(hidden)"$'"'"'\n'"'"'* && $1 != *"(hidden))"* ]]' _ "$out"
check "a volume name is data, not a pattern" bash -c '[[ $1 == *"about a (hidden) file"* ]]' _ "$out"
check "a name of two letters does not hit ordinary words" bash -c '[[ $1 == *about* ]]' _ "$out"
unset -f bm_anon_labels
out="$(printf 'plain line' | bm_anon_filter)"; check "the last line stays without a line break of its own" eq "$out" "plain line"

begin "commands: usage and exit codes (a new process each)"
run_b() { env -u BIGMOUNT_LIB "$B" "$@"; }
run_b --drive --help >/dev/null; check "--drive --help" eq "$?" 0
run_b --drive nonsense >/dev/null 2>&1; check "an unknown command: exit 2" eq "$?" 2
run_b --drive list --nope >/dev/null 2>&1; check "an unknown option: exit 2" eq "$?" 2
run_b --drive copy >/dev/null 2>&1; check "copy without paths: exit 2" eq "$?" 2
run_b --drive status nope >/dev/null 2>&1; check "a job that does not exist: exit 1" eq "$?" 1
run_b --drive mount sda1 >/dev/null 2>&1; check "mount of something that is not a device: exit 2" eq "$?" 2
run_b --drive mount /dev/nonexistent >/dev/null 2>&1; check "mount of a device that is not there: exit 24" eq "$?" 24
run_b --drive protect /etc >/dev/null 2>&1; check "protect of a folder: exit 2" eq "$?" 2
r="$WORK/report.txt"; printf 'old\n' > "$r"
run_b --drive report 20261030-140000-abcd --output "$r" >/dev/null 2>&1; check "an existing report is kept" eq "$?:$(cat "$r")" "20:old"
run_b --drive report 20261030-140000-abcd --output "$r" --replace >/dev/null 2>&1; rc=$?
check "  ... replaced with --replace" bash -c '[ "$1" = 0 ] && ! grep -qx old "$2"' _ "$rc" "$r"
mkdir -p "$WORK/rdir"; run_b --drive report 20261030-140000-abcd --output "$WORK/rdir" --replace >/dev/null 2>&1
check "  ... never into a folder" eq "$?:$(find "$WORK/rdir" -mindepth 1 | wc -l)" "20:0"
for c in "unmount --dry-run" "safe-remove --dry-run" busy close-apps; do
   # shellcheck disable=SC2086  # the command and its option
   (cd "$WORK" && run_b --drive $c --json >/dev/null 2>&1); check "${c%% *} without a target: exit 2" eq "$?" 2
done
run_b --drive </dev/null >/dev/null 2>&1; check "the interactive manager without a terminal: exit 2" eq "$?" 2
out="$(NO_COLOR=1 run_b --drive --help | grep -c $'\033')"; check "NO_COLOR: no escape sequences" eq "$out" 0
LC_ALL=C bash -c 'BIGMOUNT_X=1; "$0" --drive list >/dev/null' "$B"; check "a plain terminal locale works" eq "$?" 0
check "the old commands are still in the help" bash -c 'h="$("$1" --help)"; for c in --dry-run --diagnose --busy --unmount --safe-remove --gui --gui-remove --secure-erase --doctor --version; do [[ $h == *"$c"* ]] || exit 1; done' _ "$B"
env -u WAYLAND_DISPLAY -u DISPLAY "$B" --gui-drive >/dev/null 2>"$WORK/nogui"; check "no graphical session: exit 25" eq "$?" 25
check "  ... and it says where the same tools are" grep -q 'bigmount --drive' "$WORK/nogui"
env -u WAYLAND_DISPLAY -u DISPLAY "$B" --gui-drive-check /dev/null >/dev/null 2>&1; check "  ... also for the alias" eq "$?" 25
check "the two flags go to one program, GTK 4 and libadwaita" bash -c '[ "$(grep -c "python3 -I \"\$py\"" "$1/drive.sh")" = 1 ] && grep -q "gi.require_version(\"Adw\", \"1\")" "$1/drive-gui.py" && ! grep -rqE "PySide|PyQt|kdialog|zenity" "$1/drive-gui.py" "$1/gui"' _ "$L"

begin "the boot path knows nothing of this"
check "bigmount loads no drive module by itself" bash -c '! grep -nE "drive[-.]|python|gtk|Gtk" "$1" | grep -v "^[0-9]*:#"' _ "$B"
check "cli.sh does not load them either until asked" bash -c '[ "$(grep -cE "^\. .*drive" "$1/cli.sh")" = 0 ]' _ "$L"

begin "commands that must not exist in the drive manager"
grep -hvE '^[[:space:]]*#' "$L"/drive*.sh "$L"/bigmount-drive-helper "$L"/drive-gui.py "$L"/gui/*.py "$L"/gui/pages/*.py > "$WORK/code.txt"
for bad in 'fsck' 'mkfs' 'wipefs' 'dd if=' 'umount -f' 'umount -l' 'kill -9' 'kill -KILL' 'fuser -k' 'chmod -R' 'chown -R' 'btrfs check' 'ntfsfix' 'shred' 'blkdiscard' 'sgdisk' 'parted' ' eval ' 'rm -rf /'; do
   check "no '$bad'" bash -c '! grep -nF -- "$2" "$1"' _ "$WORK/code.txt" "$bad"
done
check "the helper changes a device only through the read-only flag" bash -c '[ "$(grep -cE "blockdev --set" "$1")" = 2 ] && ! grep -E "of=/dev|[^2&]> */dev/(sd|nvme|loop|mapper|disk|mmc)" "$1"' _ "$L/bigmount-drive-helper"
check "the helper has a fixed library path" grep -q '^BM_LIB="/usr/lib/big-mount"$' "$L/bigmount-drive-helper"
check "the helper resets PATH" grep -q '^export PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "$L/bigmount-drive-helper"
check "rsync is started with fixed options, in one place" eq "$(grep -cE '^ *ionice .*rsync ' "$L/drive-copy.sh")" 1

begin "the application: what the window is told"
. "$L/drive-erase.sh"
bm_dv_scan
bm_dv_stable_id /dev/sdc; check "a drive is known by its serial, not its name" eq "$REPLY" serial:S1
bm_dv_stable_id /dev/sdg; check "  ... without a serial, by its first filesystem" eq "$REPLY" uuid:multi
bm_dv_stable_id /dev/sde; check "  ... without either, by name and size, which says so" eq "$REPLY" device:/dev/sde:16000000000
bm_dv_disk_json /dev/sdc | json_ok; check "the JSON of a drive is valid" eq "$?" 0
bm_dv_part_json /dev/sdg1 | grep -q '"log_replay":true'; check "btrfs: its log replays read-only" eq "$?" 0
bm_dv_part_json /dev/sda1 | grep -q '"log_replay"'; check "  ... ext4 does not say so" eq "$?" 1
bm_dv_disk_json /dev/sdc | grep -q '"stable_id":"serial:S1"'; check "  ... with its identity" eq "$?" 0
bm_dv_disk_json /dev/sdc | grep -q '"diskseq":7'; check "  ... and this connection of it" eq "$?" 0
bm_rec_categories_valid photos,videos; check "types of file: known ones" eq "$?" 0
bm_rec_categories_valid all; check "  ... all" eq "$?" 0
bm_rec_categories_valid "photos,evil;rm"; check "  ... anything else is refused" eq "$?" 1
bm_rec_categories_valid ""; check "  ... nothing is not a choice" eq "$?" 1
bm_rec_carve_commands photos,documents
check "PhotoRec: only the families asked for" eq "$REPLY" "partition_none,fileopt,everything,disable,jpg,enable,png,enable,gif,enable,bmp,enable,tif,enable,orf,enable,pdf,enable,doc,enable,zip,enable,txt,enable,wholespace,search"
bm_rec_carve_commands documents,archives
check "  ... a family asked twice counts once" eq "$(grep -o 'zip,enable' <<< "$REPLY" | wc -l)" 1
bm_rec_carve_commands all
check "  ... all of them, without the one that matches empty blocks where it exists" bash -c '[[ $1 == partition_none,fileopt,everything,enable,*wholespace,search ]]' _ "$REPLY"
screen=$'\033[6;6HPartition\033[6;33HStart\n\033[9;3HLinux\033[9;27H0  32 33\033[9;42H4  52 48\033[9;58H65536 [TEST LOST]\r\n\033[10;3HLinux\033[10;27H0  32 33\033[10;42H4  52 48\033[10;58H65536 [TEST LOST]\n Analyse cylinder     4/8: 51%\n 2 P HPFS - NTFS              1  37 37     2  10  8      14336\n'
bm_rec_parse_partitions <<< "$screen"
check "TestDisk: the analysis screen, each partition once" eq "${#PT_TYPE[@]}" 2
check "  ... its type" eq "${PT_TYPE[0]}" Linux
check "  ... its size in sectors" eq "${PT_SECTORS[0]}" 65536
check "  ... its label, with spaces" eq "${PT_LABEL[0]}" "TEST LOST"
check "  ... the list format too" eq "${PT_TYPE[1]}:${PT_SECTORS[1]}" "HPFS - NTFS:14336"
testdisk() { :; }
stop_helper() { printf '%s\n' "$*" > "$WORK/helper.args"; while [ ! -e "$3" ]; do sleep 0.1; done; return 143; }
rm -f "$WORK/helper.args"
out="$(BM_HELPER_CMD=stop_helper; bm_resolve() { R_DEV="$1"; }; bm_rec_partitions /dev/sda --search --json & p=$!
   until [ -e "$WORK/helper.args" ]; do sleep 0.1; done; kill -TERM "$p"; wait "$p")"
check "TestDisk stops through its stop file" grep -q '"error":"cancelled"' <<< "$out"
check "  ... with the analysis arguments" grep -qE '^partitions /dev/sda /.+/stop search (gpt|i386)$' "$WORK/helper.args"
unset -f testdisk
DV=() bm_drive_is_uuid UUID=ABCD; check "a UUID is a target" eq "$REPLY" ABCD
bm_drive_is_uuid /dev/sda; check "  ... a path is not" eq "$?" 1
bm_drive_uuid_device u-a1; check "UUID of one device: found" eq "$?:$REPLY" 0:/dev/sda1
bm_drive_uuid_device multi; check "  ... of two devices: ambiguous, nothing is guessed" eq "$?" 2
bm_drive_uuid_device nope; check "  ... of none: not found" eq "$?" 1
bm_rec_methods_case() { bm_resolve() { R_DEV="$1"; R_PATH=""; }; bm_rec_methods "$1" --json; }
bm_dv_fs_supported() { return 0; }
bm_ds_level() { DS_LEVEL="${FAKE_LEVEL:-normal}"; DS_WHY=() DS_BASIS=log; }
method() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); m={x["id"]:x for x in d["methods"]}; print(d["recommended"], m[sys.argv[1]]["available"], m[sys.argv[1]]["why"])' "$1"; }
out="$(bm_rec_methods_case /dev/sda1)"; printf '%s' "$out" | json_ok; check "methods: valid JSON" eq "$?" 0
FAKE_LEVEL=normal; check "  ... a healthy volume: list first" eq "$(bm_rec_methods_case /dev/sda1 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["recommended"])')" quick
FAKE_LEVEL=critical; check "  ... a drive at risk with a volume: copy what matters" eq "$(bm_rec_methods_case /dev/sda1 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["recommended"])')" copy
check "  ... a locked volume cannot be listed, and says why" bash -c '[[ $1 == *"False locked" ]]' _ "$(bm_rec_methods_case /dev/sdb1 | method quick)"
FAKE_LEVEL=critical; check "  ... a drive at risk that cannot be opened: an image" eq "$(bm_rec_methods_case /dev/sdb1 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["recommended"])')" image
FAKE_LEVEL=normal; check "  ... a whole disk has no files to list until a volume is chosen" bash -c '[[ $1 == *"False pick-volume" ]]' _ "$(bm_rec_methods_case /dev/sdc | method copy)"
FAKE_LEVEL=attention; check "  ... a whole disk at risk: an image, and never 'its files cannot be opened'" bash -c '[[ $1 == image$'"'"'\t'"'"'* && $1 == *"choose one of its volumes"* && $1 != *"cannot be opened"* ]]' _ \
    "$(LANGUAGE=C bm_rec_methods_case /dev/sdc | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["recommended"] + "\t" + d["recommended_why"])')"
printf 'x' > "$WORK/some.img"; check "  ... an image: search it, it touches no disk" bash -c '[[ $1 == deep* ]]' _ "$(bm_rec_methods_case "$WORK/some.img" | method deep)"
check "  ... an image is not imaged again" bash -c '[[ $1 == *"False image-file" ]]' _ "$(bm_rec_methods_case "$WORK/some.img" | method image)"
unset -f bm_resolve bm_dv_fs_supported bm_ds_level bm_rec_methods_case method
. "$L/lib.sh"; . "$L/drive-diag.sh"

begin "the application: a list of what exists, for real, in a scratch folder"
# /var/tmp: on a filesystem of its own, as the copy below needs
SC="$(mktemp -d -p /var/tmp bm-scan-XXXXXX)"; mkdir -p "$SC/fotos" "$SC/com espaco"
trap 'rm -rf "$WORK" "$SC"' EXIT
printf a > "$SC/fotos/ferias.JPG"; printf bb > "$SC/com espaco/nota.pdf"; printf c > "$SC/musica.mp3"; printf d > "$SC/-traco.txt"; printf e > "$SC/outro.xyz"; printf f > "$SC"/$'tab\taqui.png'; printf g > "$SC"/$'linha\nquebra.jpg'
wait_job() { local i; for ((i = 0; i < 100; i++)); do run_b --drive status "$1" --json | grep -qE '"state":"(pending|analyzing|running|stopping)"' || return 0; sleep 0.1; done; return 1; }
id="$(run_b --drive scan --source "$SC" --categories photos,documents --no-wait --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
check "it starts as a job" bash -c '[[ $1 =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]]' _ "$id"
wait_job "$id"; check "  ... and it ends" eq "$?" 0
st="$(run_b --drive status "$id" --json)"; printf '%s' "$st" | json_ok; check "  ... its status is valid JSON" eq "$?" 0
check "  ... it is called what it is" grep -q '"result_kind":"existing-files"' <<< "$st"
check "  ... 7 examined, 5 of the types asked for" bash -c '[[ $1 == *"\"files_done\":5,"* && $1 == *"\"scanned\":7,"* ]]' _ "$st"
check "  ... it cannot be paused" grep -q '"pausable":false' <<< "$st"
res="$(run_b --drive results "$id" --json)"; printf '%s' "$res" | json_ok; check "results: valid JSON" eq "$?" 0
check "  ... names and dates are real here" bash -c '[[ $1 == *"\"names_kept\":true"* && $1 == *"\"dates_kept\":true"* ]]' _ "$res"
idx="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["index"])' <<< "$res")"
check "  ... every hostile name is there, byte for byte" python3 -I -c 'import sys; names={r.split(b"\t",3)[3] for r in open(sys.argv[1],"rb").read().split(b"\0") if r}; want={b"-traco.txt",b"tab\taqui.png",b"linha\nquebra.jpg",b"com espaco/nota.pdf",b"fotos/ferias.JPG"}; sys.exit(names!=want)' "$idx"
run_b --drive pause "$id" >/dev/null 2>&1; check "pause of a list: refused" eq "$?" 2
run_b --drive scan --source "$WORK/none" --no-wait --json >/dev/null 2>&1; check "a list of what does not exist: refused" eq "$?" 20
run_b --drive scan --source "$SC" --categories evil --no-wait --json >/dev/null 2>&1; check "  ... of a type that does not exist: refused" eq "$?" 2
run_b --drive results 20261031-000000-dead --json >/dev/null 2>&1; check "results of nothing: an error" eq "$?" 1

begin "the application: a selection of many files, with hostile names"
OUTD="/dev/shm/bm-test-$$"
trap 'rm -rf "$WORK" "$SC" "$OUTD"' EXIT
if [ "$(command findmnt -n -o SOURCE -T "$SC")" != "$(command findmnt -n -o SOURCE -T /dev/shm 2>/dev/null)" ] && command -v rsync >/dev/null; then
   mkdir -p "$OUTD"
   printf 'fotos/ferias.JPG\0-traco.txt\0com espaco\0' > "$WORK/items"
   out="$(run_b --drive copy --source "$SC" --destination "$OUTD/d" --items-from "$WORK/items" --dry-run --json)"; rc=$?
   check "--items-from: accepted (exit $rc)" eq "$rc" 0
   check "  ... it measures only what was chosen" grep -q '"total_files":3' <<< "$out"
   printf 'fotos/ferias.JPG\0../../etc/passwd\0' > "$WORK/items2"
   out="$(run_b --drive copy --source "$SC" --destination "$OUTD/d" --items-from "$WORK/items2" --dry-run --json)"; rc=$?
   check "  ... an item outside the source: refused" eq "$rc:$(grep -o '"error":"[a-z-]*"' <<< "$out")" '20:"error":"item-bad"'
   printf 'nao-existe\0' > "$WORK/items3"
   run_b --drive copy --source "$SC" --destination "$OUTD/d" --items-from "$WORK/items3" --dry-run --json >/dev/null; check "  ... an item that is not there: refused" eq "$?" 20
   run_b --drive copy --source "$SC" --destination "$SC/dentro" --dry-run --json >/dev/null; check "the destination inside the source: refused" eq "$?" 20
fi
run_b --drive copy --results-of 20261031-000000-dead --destination "$WORK/x" --dry-run --json >/dev/null 2>&1; check "--results-of nothing: refused" eq "$?" 1
run_b --drive copy --results-of "$id" --destination "$WORK/x" --dry-run --json >/dev/null 2>&1; check "--results-of a list (not a search): refused" eq "$?" 2

echo "========================================="
echo "drive result: $PASS passed, $FAIL failed"
for f in "${FAILED[@]}"; do echo "  FAILED: $f"; done
echo "========================================="
[ "$FAIL" -eq 0 ]
