#!/usr/bin/python3
"""Big-Mount: the dialogs of the commands that run outside the application
(bigmount --gui, --gui-remove and the notifier), drawn with GTK 4 and libadwaita
like the application itself.

The shell builds the content as a small document (bm_doc_* in ui.sh) and sends it
on standard input as NUL-separated pairs of kind and text: h (heading), p
(paragraph), kv (key TAB value), li (list item), th and tr (table cells separated
by TAB, a second line of a cell after \\x1f) and pre (technical text). Labels,
file and program names are data: everything is shown as plain text, never as
markup. The answer goes to standard output: the key of the button, of the item
chosen, or the line typed.

  dialog.py message  --title T
  dialog.py question --title T --button KEY=LABEL... [--default KEY] [--cancel KEY]
                     [--destructive KEY] [--suggested KEY]
  dialog.py menu     --title T --text TEXT --item KEY=LABEL...
  dialog.py input    --title T --text TEXT
  dialog.py text     --title T --file PATH

Exit codes: 0 answered, 1 closed or cancelled, 2 wrong arguments, 5 run as
administrator, 25 GTK 4, libadwaita or a display are not available.
"""

import argparse
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

MIN_ADW = (1, 5)
KINDS = ("h", "p", "kv", "li", "th", "tr", "pre")
# Escape sequences and other control characters from device data; newline, TAB
# and the cell separator have a meaning in the document
CONTROL = re.compile("[\x00-\x08\x0b-\x1e\x7f]")


def read_document(data):
    """NUL-separated kind and text pairs; unknown kinds are left out."""
    parts = data.decode("utf-8", "replace").split("\0")
    doc = []
    for i in range(0, len(parts) - 1, 2):
        kind, text = parts[i], CONTROL.sub("?", parts[i + 1])
        if kind in KINDS:
            doc.append((kind, text))
    return doc


def pairs(values):
    out = []
    for value in values or []:
        key, sep, label = value.partition("=")
        if not sep or not key:
            raise ValueError(value)
        out.append((key, label))
    return out


def parse(argv):
    parser = argparse.ArgumentParser(prog="dialog.py", add_help=False)
    parser.add_argument("mode", choices=["message", "question", "menu", "input", "text"])
    parser.add_argument("--title", default="")
    parser.add_argument("--text", default="")
    parser.add_argument("--button", action="append")
    parser.add_argument("--item", action="append")
    parser.add_argument("--default", default="")
    parser.add_argument("--cancel", default="")
    parser.add_argument("--destructive", default="")
    parser.add_argument("--suggested", default="")
    parser.add_argument("--file", default="")
    args = parser.parse_args(argv)
    args.buttons = pairs(args.button)
    args.items = pairs(args.item)
    if args.mode == "question" and not args.buttons:
        parser.error("a question needs buttons")
    if args.mode == "menu" and not args.items:
        parser.error("a menu needs items")
    if args.mode == "text" and not args.file:
        parser.error("text needs --file")
    return args


def main(argv):
    try:
        args = parse(argv)
    except ValueError as exc:
        print(f"dialog.py: wrong button or item: {exc}", file=sys.stderr)
        return 2
    except SystemExit:
        return 2
    if os.geteuid() == 0:
        print("dialog.py: dialogs do not run as administrator", file=sys.stderr)
        return 5
    doc = []
    if not sys.stdin.isatty():
        doc = read_document(sys.stdin.buffer.read())
    try:
        import gi
        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw, Gdk, GLib, Gtk
    except (ImportError, ValueError) as exc:
        print(f"dialog.py: gtk4, libadwaita and python-gobject are needed ({exc})", file=sys.stderr)
        return 25
    if (Adw.MAJOR_VERSION, Adw.MINOR_VERSION) < MIN_ADW:
        print("dialog.py: libadwaita 1.5 or later is needed", file=sys.stderr)
        return 25
    # The window belongs to Big-Mount: its name and icon in the task bar
    GLib.set_prgname("big-mount")
    GLib.set_application_name("Big-Mount")
    # Gtk.init_check() says yes even when no display could be opened
    if not Gtk.init_check() or Gdk.Display.get_default() is None:
        print("dialog.py: there is no display", file=sys.stderr)
        return 25
    Adw.init()
    Gtk.Window.set_default_icon_name("big-mount")
    from gui.dialogs import run
    return run(args, doc)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
