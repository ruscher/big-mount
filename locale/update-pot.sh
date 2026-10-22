#!/bin/bash
# Regenerate locale/big-mount.pot from the $"..." strings of the scripts and
# merge it into every locale/*.po. Run after changing user-visible text.
set -e
cd "$(dirname "$0")/.."
{
    printf 'msgid ""\nmsgstr ""\n"Project-Id-Version: big-mount\\n"\n'
    printf '"Content-Type: text/plain; charset=UTF-8\\n"\n"Content-Transfer-Encoding: 8bit\\n"\n\n'
    for f in big-mount/usr/lib/big-mount/*.sh; do bash --dump-po-strings "$f"; done
} | msguniq --no-wrap -o locale/big-mount.pot -
for po in locale/*.po; do
    msgmerge --quiet --no-wrap --update --backup=none "$po" locale/big-mount.pot
done
