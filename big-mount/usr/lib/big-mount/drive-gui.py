#!/usr/bin/python3
"""Big-Mount: the entry point of the application (bigmount --gui-drive).

It decides nothing about disks. Every fact and every operation comes from
`bigmount --drive ... --json`, the same commands a person can type, so this
window and the terminal cannot disagree. It runs as the logged-in user; what
needs more goes through UDisks2 or the polkit helper of the engine.

Exit codes: 5 run as administrator, 25 GTK 4 or libadwaita are not available.
"""

import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

MIN_ADW = (1, 5)


def main():
    if os.geteuid() == 0:
        print("bigmount: the graphical application does not run as administrator", file=sys.stderr)
        return 5
    try:
        import gi
        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw
    except (ImportError, ValueError) as exc:
        print(f"bigmount: the application needs gtk4, libadwaita and python-gobject ({exc}). "
              "The same tools work in the terminal: bigmount --drive", file=sys.stderr)
        return 25
    if (Adw.MAJOR_VERSION, Adw.MINOR_VERSION) < MIN_ADW:
        print("bigmount: the application needs libadwaita 1.5 or later. "
              "The same tools work in the terminal: bigmount --drive", file=sys.stderr)
        return 25
    from gui.application import run
    return run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
