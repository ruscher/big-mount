"""One application, one window. A second `bigmount --gui-drive` (or --gui-drive-check)
goes to the window that is already open, at what it asked for."""

import argparse
import os
import signal

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from . import welcome
from .common import BIGMOUNT, PREFIX, _
from .window import MainWindow

APP_ID = "org.biglinux.big-mount"

# The notifier is off unless the person turns it on: its entry in their own
# autostart folder is the switch, and nothing else records it
NOTIFIER_TEMPLATE = os.path.join(PREFIX, "share", "big-mount", "big-mount-notifier.desktop")


def notifier_entry():
    return os.path.join(GLib.get_user_config_dir(), "autostart", "big-mount-notifier.desktop")


def notifier_on():
    """Hidden=true, or GNOME's key, is how desktops turn an autostart entry off."""
    try:
        with open(notifier_entry(), encoding="utf-8") as f:
            lines = f.read().splitlines()
        return "Hidden=true" not in lines and "X-GNOME-Autostart-enabled=false" not in lines
    except FileNotFoundError:
        return False


def notifier_pid():
    """The running notifier of this user, from the lock it holds, or None."""
    try:
        with open(os.path.join(GLib.get_user_runtime_dir(), "big-mount-notifier.lock"), encoding="utf-8") as f:
            pid = int(f.read().strip() or 0)
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            args = f.read().split(b"\0")
        mine = os.stat(f"/proc/{pid}").st_uid == os.getuid()
    except (OSError, ValueError):
        return None
    return pid if pid > 0 and mine and b"--notifier" in args else None


def set_notifier(on):
    """Raises OSError when the autostart entry cannot be written or removed."""
    entry = notifier_entry()
    if on:
        os.makedirs(os.path.dirname(entry), exist_ok=True)
        with open(NOTIFIER_TEMPLATE, "rb") as f:
            data = f.read()
        tmp = f"{entry}.tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, entry)
        # Now, not only at the next login. setsid -f: it outlives the window
        proc = Gio.Subprocess.new(["setsid", "-f", BIGMOUNT, "--notifier"], Gio.SubprocessFlags.NONE)
        proc.wait_async(None, None)
    else:
        try:
            os.unlink(entry)
        except FileNotFoundError:
            pass
        pid = notifier_pid()
        if pid:
            os.kill(pid, signal.SIGTERM)


def load_style():
    display = Gdk.Display.get_default()
    if display is None:
        return
    provider = Gtk.CssProvider()
    provider.load_from_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "style.css"))
    Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def parse(argv):
    # An error is raised, never an exit: a second invocation is parsed inside the
    # window that is already open
    parser = argparse.ArgumentParser(prog="bigmount --gui-drive", add_help=False, exit_on_error=False)
    parser.add_argument("--target", default="")
    parser.add_argument("--section", default="", choices=["", "health"])
    args, _unknown = parser.parse_known_args(argv[1:])
    return args


def welcome_at_start(args):
    """What it can do, when it opens on its home; not over a drive that needs attention."""
    return not args.target and not args.section and welcome.should_show()


class Application(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.window = None
        # The accessible name of the application comes from the program name,
        # which is otherwise the file name of the script
        GLib.set_prgname("big-mount")
        GLib.set_application_name("Big-Mount")
        Gtk.Window.set_default_icon_name("big-mount")

    def do_startup(self):
        Adw.Application.do_startup(self)
        load_style()
        self._action("refresh", ["F5", "<Control>r"], lambda *_a: self.window and self.window.refresh())
        self._action("quit", ["<Control>q"], lambda *_a: self.window and self.window.close())
        self._action("home", ["<Alt>Home"], lambda *_a: self.window and self.window.show_overview())
        self._action("jobs", ["<Control>j"], lambda *_a: self.window and self.window.show_jobs())
        self._action("about", [], lambda *_a: self.window and self.window.show_about())
        self._action("welcome", [], lambda *_a: self.window and self.window.show_welcome())
        notifier = Gio.SimpleAction.new_stateful("notifier", None, GLib.Variant.new_boolean(notifier_on()))
        notifier.connect("change-state", self._notifier_changed)
        self.add_action(notifier)

    def _notifier_changed(self, action, value):
        try:
            set_notifier(value.get_boolean())
        except (OSError, GLib.Error) as exc:
            if self.window:
                self.window.notify_text(_("The notifier could not be changed: %s") % (getattr(exc, "message", "") or str(exc)))
        action.set_state(GLib.Variant.new_boolean(notifier_on()))

    def _action(self, name, accels, handler):
        action = Gio.SimpleAction.new(name, None)
        action.connect("activate", handler)
        self.add_action(action)
        if accels:
            self.set_accels_for_action(f"app.{name}", accels)

    def do_command_line(self, command_line):
        try:
            args = parse(command_line.get_arguments())
        except argparse.ArgumentError as exc:
            command_line.printerr_literal(f"bigmount --gui-drive: {exc}\n")
            return 2
        first = self.window is None
        if first:
            self.window = MainWindow(self)
        self.window.route(args.target, args.section)
        self.window.present()
        if first and welcome_at_start(args):
            GLib.idle_add(lambda: self.window.show_welcome() and False)
        return 0


def run(argv):
    Adw.init()
    app = Application()
    return app.run(argv)
