"""Words and numbers: translations and the sizes and times people read."""

import gettext
import locale
import os
import re

from gi.repository import GLib

LIB_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
PREFIX = os.path.normpath(os.path.join(LIB_DIR, "..", ".."))
BIGMOUNT = os.environ.get("BM_GUI_BIN") or os.path.join(PREFIX, "bin", "bigmount")
LOCALE_DIR = os.path.join(PREFIX, "share", "locale")

try:
    locale.setlocale(locale.LC_ALL, "")
except locale.Error:
    pass

_translation = gettext.translation("big-mount", LOCALE_DIR, fallback=True)
_ = _translation.gettext
ngettext = _translation.ngettext

WEBSITE = "https://github.com/biglinux/big-mount"
ISSUES = "https://github.com/biglinux/big-mount/issues"


def version():
    """The version of Big-Mount, from the one place the engine keeps it."""
    try:
        with open(os.path.join(LIB_DIR, "doctor.sh"), encoding="utf-8") as f:
            found = re.search(r"^BM_VERSION=([0-9][0-9A-Za-z.+-]*)$", f.read(), re.M)
    except OSError:
        return ""
    return found.group(1) if found else ""


def _settings_file():
    return os.path.join(GLib.get_user_config_dir(), "big-mount", "gui.ini")


def setting(group, key, default=""):
    """A preference of the window. Never an error: without it, the default."""
    keys = GLib.KeyFile()
    try:
        keys.load_from_file(_settings_file(), GLib.KeyFileFlags.NONE)
        return keys.get_string(group, key)
    except GLib.Error:
        return default


def save_setting(group, key, value):
    keys = GLib.KeyFile()
    path = _settings_file()
    try:
        keys.load_from_file(path, GLib.KeyFileFlags.KEEP_COMMENTS)
    except GLib.Error:
        pass
    keys.set_string(group, key, value)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        keys.save_to_file(path)
    except (GLib.Error, OSError):
        pass


def _decimal(text):
    point = locale.localeconv().get("decimal_point") or "."
    return text.replace(".", point) if point != "." else text


def human_size(n):
    """Powers of 1000, like Dolphin and the terminal interface."""
    if n is None:
        return "—"
    n = float(n)
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            if unit == "B" or n >= 100:
                return f"{int(n)} {unit}"
            return _decimal(f"{n:.1f}") + f" {unit}"
        n /= 1000
    return ""


def human_time(seconds):
    if seconds is None:
        return "—"
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def human_duration(seconds):
    """For a person: 'about 2 h 10 min', not a clock."""
    seconds = int(seconds)
    if seconds < 60:
        return _("less than a minute")
    minutes = seconds // 60
    if minutes < 60:
        return _("%d min") % minutes
    return _("%(h)d h %(m)d min") % {"h": minutes // 60, "m": minutes % 60}
