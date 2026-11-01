"""One application, one window. A second `bigmount --gui-drive` (or --gui-drive-check)
goes to the window that is already open, at what it asked for."""

import argparse
import os
import sys

from gi.repository import Adw, Gdk, Gio, GLib, Gtk

from . import welcome
from .common import _
from .window import MainWindow

APP_ID = "org.biglinux.big-mount"


def load_style():
    display = Gdk.Display.get_default()
    if display is None:
        return
    provider = Gtk.CssProvider()
    provider.load_from_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "style.css"))
    Gtk.StyleContext.add_provider_for_display(display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def parse(argv):
    parser = argparse.ArgumentParser(prog="bigmount --gui-drive", add_help=False)
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

    def _action(self, name, accels, handler):
        action = Gio.SimpleAction.new(name, None)
        action.connect("activate", handler)
        self.add_action(action)
        if accels:
            self.set_accels_for_action(f"app.{name}", accels)

    def do_command_line(self, command_line):
        args = parse(command_line.get_arguments())
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


__all__ = ["run", "Application", "APP_ID", "load_style", "_", "sys"]
