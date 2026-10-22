#!/bin/bash
# Build every translated resource from locale/*.po:
#   - big-mount/usr/share/locale/<lang>/LC_MESSAGES/big-mount.mo (scripts)
#   - the .desktop files and the polkit policy, merged from locale/templates
# The generated files are committed: the PKGBUILD only copies big-mount/.
# Languages are listed in locale/LINGUAS.
# DEST=DIR writes the results into another tree (used by tests).
set -e
cd "$(dirname "$0")/.."
dest="${DEST:-big-mount}"
for po in locale/*.po; do
    lang="$(basename "$po" .po)"
    dir="$dest/usr/share/locale/$lang/LC_MESSAGES"
    mkdir -p "$dir"
    msgfmt --check -o "$dir/big-mount.mo" "$po"
done

mkdir -p "$dest/usr/share/applications" "$dest/etc/xdg/autostart" "$dest/usr/share/kio/servicemenus" \
    "$dest/usr/share/polkit-1/actions"
desktop() { # TEMPLATE OUTPUT
    msgfmt --desktop -k -kName -kGenericName -kComment -kKeywords -kX-KDE-Submenu \
        --template "locale/templates/$1" -d locale -o "$dest/$2"
}
desktop big-mount.desktop.in usr/share/applications/big-mount.desktop
desktop big-mount-notifier.desktop.in etc/xdg/autostart/big-mount-notifier.desktop
desktop big-mount-servicemenu.desktop.in usr/share/kio/servicemenus/big-mount.desktop
# msgfmt writes BCP 47 tags (pt-BR); polkit matches POSIX locale names
# (pt_BR, then pt), which is also what the policy always used
policy="$dest/usr/share/polkit-1/actions/org.biglinux.big-mount.policy"
# locale/its holds the polkit ITS rules, for systems without polkit (CI)
GETTEXTDATADIRS="$PWD/locale${GETTEXTDATADIRS:+:$GETTEXTDATADIRS}" \
    msgfmt --xml --template locale/templates/org.biglinux.big-mount.policy.in -d locale -o "$policy"
sed -i -E 's/xml:lang="([a-z]{2,3})-([A-Z]{2})"/xml:lang="\1_\2"/g' "$policy"
