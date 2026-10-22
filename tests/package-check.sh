#!/bin/bash
# shellcheck disable=SC2016,SC2317  # bash -c '...$1' snippets and helpers called through check()
# Packaging checks: runs the package() function of pkgbuild/PKGBUILD against
# this checkout (instead of the official git source) into a scratch dir and
# verifies what would be installed. No root, nothing is installed.
#
# Usage: tests/package-check.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
cd "$REPO" || exit 2

PASS=0 FAIL=0 FAILED=()
check() {
    local msg="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$msg"
    else FAIL=$((FAIL + 1)); FAILED+=("$msg"); printf '  \033[31m✗\033[0m %s\n' "$msg"; fi
}
begin() { echo "— $1"; }
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT

echo "========================================="
echo "Packaging checks"
echo "========================================="

begin "repository hygiene"
artifacts="$(git ls-files | grep -E '(^|/)(tmp-|\.integ\.|\.bench\.|\.pkg\.)|~$|\.orig$|\.rej$|\.swp$|\.pkg\.tar' || true)"
check "no test scratch files or editor leftovers are versioned" test -z "$artifacts"
[ -n "$artifacts" ] && printf '      %s\n' "$artifacts"
binaries_in_tests() {
    local f
    git ls-files tests | while read -r f; do
        if [ -s "$f" ] && ! grep -Iq . "$f"; then echo "$f"; fi
    done
}
check "no binary file is versioned under tests/" test -z "$(binaries_in_tests)"

begin "package() on this checkout"
mkdir -p "$WORK/src/big-mount" "$WORK/pkg"
git ls-files -z | xargs -0 cp --parents -a -t "$WORK/src/big-mount" 2>/dev/null
# A subshell on purpose: PKGBUILD variables must not leak into this script
# shellcheck disable=SC1091,SC2030
if ! ( srcdir="$WORK/src" pkgdir="$WORK/pkg" pkgname=big-mount; source pkgbuild/PKGBUILD >/dev/null 2>&1; package ); then
    check "package() runs" false
fi
P="$WORK/pkg"
expect=(
    "755 usr/bin/bigmount"
    "755 usr/lib/big-mount/bigmount-holders"
    "644 usr/lib/big-mount/cli.sh"
    "644 usr/lib/big-mount/lib.sh"
    "644 usr/lib/big-mount/ui.sh"
    "644 usr/lib/systemd/system/big-mount.service"
    "644 usr/share/libalpm/hooks/big-mount.hook"
    "644 etc/big-mount.conf"
    "644 etc/xdg/autostart/big-mount-notifier.desktop"
    "644 usr/share/applications/big-mount.desktop"
    "644 usr/share/kio/servicemenus/big-mount.desktop"
    "644 usr/share/polkit-1/actions/org.biglinux.big-mount.policy"
    "644 usr/share/icons/hicolor/scalable/apps/big-mount.svg"
    "644 usr/share/locale/pt_BR/LC_MESSAGES/big-mount.mo"
)
for e in "${expect[@]}"; do
    mode="${e%% *}" f="${e#* }"
    check "$f ($mode)" bash -c '[ -f "$1/$2" ] && [ "$(stat -c %a "$1/$2")" = "$3" ]' _ "$P" "$f" "$mode"
done
installed="$(cd "$P" && find . -type f | sed 's|^\./||' | sort)"
check "nothing else is installed (no docs, tests, templates, scratch files)" \
    test "$installed" = "$(printf '%s\n' "${expect[@]}" | cut -d' ' -f2 | sort)"
check "every translation in locale/LINGUAS is installed" \
    bash -c 'while read -r l; do [ -f "$1/usr/share/locale/$l/LC_MESSAGES/big-mount.mo" ] || exit 1; done < locale/LINGUAS' _ "$P"

begin "metadata"
pkginfo="$(source pkgbuild/PKGBUILD 2>/dev/null; printf 'source=%s\n' "${source[*]}"; printf 'depends=%s\n' "${depends[*]}"; printf 'backup=%s\n' "${backup[*]}")"
check "official source unchanged (biglinux/big-mount)" grep -q "^source=git+https://github.com/biglinux/big-mount.git" <<< "$pkginfo"
check "configuration preserved on upgrades (backup=)" grep -q "^backup=etc/big-mount.conf" <<< "$pkginfo"
for d in udisks2 util-linux ntfs-3g lsof; do check "depends on $d" grep -qw "$d" <<< "$(grep ^depends= <<< "$pkginfo")"; done

begin "installed files are valid"
if command -v desktop-file-validate >/dev/null; then
    check "launcher .desktop" desktop-file-validate "$P/usr/share/applications/big-mount.desktop"
    check "autostart .desktop" desktop-file-validate "$P/etc/xdg/autostart/big-mount-notifier.desktop"
fi
check "service menu: KIO keys present" bash -c 'grep -q "^Type=Service" "$1" && grep -q "^Actions=" "$1" && grep -q "^MimeType=inode/directory;" "$1"' _ "$P/usr/share/kio/servicemenus/big-mount.desktop"
command -v xmllint >/dev/null && check "polkit policy is well-formed XML" xmllint --noout "$P/usr/share/polkit-1/actions/org.biglinux.big-mount.policy"
check "polkit exec.path names the installed helper" grep -q '>/usr/lib/big-mount/bigmount-holders<' "$P/usr/share/polkit-1/actions/org.biglinux.big-mount.policy"
command -v xmllint >/dev/null && check "icon is a well-formed SVG" xmllint --noout "$P/usr/share/icons/hicolor/scalable/apps/big-mount.svg"
check "translation catalog loads" msgunfmt -o /dev/null "$P/usr/share/locale/pt_BR/LC_MESSAGES/big-mount.mo"
if command -v systemd-analyze >/dev/null; then
    check "systemd unit verifies" bash -c 'systemd-analyze verify "$1" 2>&1 | grep -v "/usr/bin/bigmount" | grep -q . && exit 1 || exit 0' _ "$P/usr/lib/systemd/system/big-mount.service"
fi
check "service keeps FUSE daemons alive (KillMode=process)" grep -qx 'KillMode=process' "$P/usr/lib/systemd/system/big-mount.service"
for f in usr/bin/bigmount usr/lib/big-mount/*.sh usr/lib/big-mount/bigmount-holders; do
    for g in "$P"/$f; do check "syntax: ${g#"$P"/}" bash -n "$g"; done
done

echo ""
echo "========================================="
echo "package result: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
echo "========================================="
exit "$FAIL"
