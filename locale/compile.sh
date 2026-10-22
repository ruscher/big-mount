#!/bin/bash
# Compile locale/<lang>.po into big-mount/usr/share/locale/<lang>/LC_MESSAGES.
set -e
cd "$(dirname "$0")/.."
for po in locale/*.po; do
    lang="$(basename "$po" .po)"
    dir="big-mount/usr/share/locale/$lang/LC_MESSAGES"
    mkdir -p "$dir"
    msgfmt --check -o "$dir/big-mount.mo" "$po"
done
