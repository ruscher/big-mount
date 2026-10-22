#!/bin/bash
# Regenerate locale/big-mount.pot from every user-visible text and merge it
# into locale/*.po. Run it after changing any message, then translate the new
# entries and run locale/compile.sh.
#
# Sources:
#   - $"..." strings of the scripts (bash --dump-po-strings)
#   - .desktop templates (Name, GenericName, Comment, Keywords, X-KDE-Submenu)
#   - the polkit policy template (description, message)
# POT=FILE writes the template elsewhere and merges nothing (used by tests).
set -e
cd "$(dirname "$0")/.."
pot="${POT:-locale/big-mount.pot}"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

{
    printf 'msgid ""\nmsgstr ""\n"Project-Id-Version: big-mount\\n"\n'
    printf '"Content-Type: text/plain; charset=UTF-8\\n"\n"Content-Transfer-Encoding: 8bit\\n"\n\n'
    for f in big-mount/usr/bin/bigmount big-mount/usr/lib/big-mount/*.sh; do
        bash --dump-po-strings "$f"
    done
} | msguniq --no-wrap -o "$tmp/shell.pot" -

xgettext --no-wrap --from-code=UTF-8 -L Desktop -k -kName -kGenericName -kComment -kKeywords -kX-KDE-Submenu \
    -o "$tmp/desktop.pot" locale/templates/*.desktop.in
xgettext --no-wrap --from-code=UTF-8 --its=/usr/share/gettext/its/polkit.its \
    -o "$tmp/polkit.pot" locale/templates/*.policy.in

msgcat --no-wrap --use-first -o "$pot" "$tmp/shell.pot" "$tmp/desktop.pot" "$tmp/polkit.pot"
[ -z "${POT:-}" ] || exit 0
for po in locale/*.po; do
    [ -e "$po" ] || continue
    msgmerge --quiet --no-wrap --update --backup=none "$po" locale/big-mount.pot
done
