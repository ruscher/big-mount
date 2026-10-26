#!/bin/bash
# shellcheck disable=SC2016,SC2317,SC2329  # bash -c '...$1' snippets and helpers called through check()
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
# Files of this change that are not committed yet are part of the package too
git ls-files -z --others --exclude-standard -- big-mount | xargs -0 -r cp --parents -a -t "$WORK/src/big-mount" 2>/dev/null
# The copy becomes a repository with one commit at a known time, as makepkg
# sees the clone of the git source
(
    cd "$WORK/src/big-mount" && git init -q && git add -A &&
        GIT_AUTHOR_DATE="2026-10-25T13:42:07Z" GIT_COMMITTER_DATE="2026-10-25T13:42:07Z" \
        git -c user.name=test -c user.email=test@invalid commit -q -m test
) || check "test repository for the package created" false
# A subshell on purpose: PKGBUILD variables must not leak into this script
# shellcheck disable=SC1091,SC2030
if ! ( srcdir="$WORK/src" pkgdir="$WORK/pkg" pkgname=big-mount; source pkgbuild/PKGBUILD >/dev/null 2>&1; package ); then
    check "package() runs" false
fi
# shellcheck disable=SC1091,SC2030,SC2031
ver="$( srcdir="$WORK/src" pkgname=big-mount; source pkgbuild/PKGBUILD >/dev/null 2>&1; pkgver )"
check "pkgver() is the UTC date and time of the commit (26.10.25.1342)" test "$ver" = 26.10.25.1342
if command -v vercmp >/dev/null; then
    check "  ... newer than the date versions before it (26.10.22-1342, 25.12.23-2237)" \
        bash -c '[ "$(vercmp "$1-1" 26.10.22-1342)" = 1 ] && [ "$(vercmp "$1-1" 25.12.23-2237)" = 1 ]' _ "$ver"
    check "  ... and a later commit on the same day is newer still" test "$(vercmp 26.10.25.1343-1 "$ver-1")" = 1
fi
rev="$(git -C "$WORK/src/big-mount" rev-parse HEAD)"
check "version file names the exact commit (bigmount --version)" \
    grep -qx "revision=$rev" "$WORK/pkg/usr/lib/big-mount/version"
check "  ... its date and the source URL" bash -c 'grep -qx "date=2026-10-25T13:42:07Z" "$1" && grep -qx "source=https://github.com/ruscher/big-mount" "$1"' _ "$WORK/pkg/usr/lib/big-mount/version"
check "bigmount --version of the package shows that commit" \
    bash -c 'BIGMOUNT_LIB="$1/usr/lib/big-mount" bash "$1/usr/bin/bigmount" --version | grep -q "${2:0:12}"' _ "$WORK/pkg" "$rev"
P="$WORK/pkg"
expect=(
    "755 usr/bin/bigmount"
    "755 usr/lib/big-mount/bigmount-holders"
    "644 usr/lib/big-mount/cli.sh"
    "644 usr/lib/big-mount/lib.sh"
    "644 usr/lib/big-mount/ui.sh"
    "644 usr/lib/big-mount/doctor.sh"
    "644 usr/lib/big-mount/version"
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
pkginfo="$(source pkgbuild/PKGBUILD 2>/dev/null; printf 'source=%s\n' "${source[*]}"; printf 'depends=%s\n' "${depends[*]}"; printf 'backup=%s\n' "${backup[*]}"; printf 'install=%s\n' "${install:-}"; printf 'url=%s\n' "$url")"
check "source is the development repository (ruscher/big-mount)" grep -q "^source=git+https://github.com/ruscher/big-mount.git$" <<< "$pkginfo"
check "url matches the source" grep -q "^url=https://github.com/ruscher/big-mount$" <<< "$pkginfo"
check "install script exists and is valid" bash -c '[ "$1" = "install=big-mount.install" ] && bash -n pkgbuild/big-mount.install' _ "$(grep ^install= <<< "$pkginfo")"
check "install script restarts nothing by itself" bash -c '! grep -vE "^\s*(#|echo)" pkgbuild/big-mount.install | grep -qE "systemctl|kill|mount"' 
check "configuration preserved on upgrades (backup=)" grep -q "^backup=etc/big-mount.conf" <<< "$pkginfo"
check "the obsolete big-mount-git is replaced and cannot be installed beside it" \
    bash -c 'source pkgbuild/PKGBUILD 2>/dev/null; [[ " ${replaces[*]} " == *" big-mount-git "* && " ${conflicts[*]} " == *" big-mount-git "* ]]'
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
