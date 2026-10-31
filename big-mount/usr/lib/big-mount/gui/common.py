"""Words and numbers: translations and the sizes and times people read."""

import gettext
import locale
import os

LIB_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
PREFIX = os.path.normpath(os.path.join(LIB_DIR, "..", ".."))
BIGMOUNT = os.environ.get("BM_GUI_BIN") or os.path.join(PREFIX, "bin", "bigmount")
LOCALE_DIR = os.path.join(PREFIX, "share", "locale")

try:
    locale.setlocale(locale.LC_ALL, "")
except locale.Error:
    pass

_ = gettext.translation("big-mount", LOCALE_DIR, fallback=True).gettext


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
