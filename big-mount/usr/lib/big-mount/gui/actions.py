"""What can be done to a drive from anywhere in the window: unmount it, remove it
safely, close what keeps it busy, and the way to erasing it. Every step goes
through the engine, and nothing is forced: a busy volume is never unmounted
behind the back of the programs using it (no forced or lazy unmount). The
person sees who uses it and decides whether those programs are asked to close."""

from gi.repository import Gio, Gtk

from . import widgets as w
from .common import _

BUSY = 3
SERVICES = 9


def unmount(window, target, remove=False, then=None, allow_services=False):
    """Unmount TARGET (a volume, or every volume of a whole drive); with remove,
    also power off a removable drive. Busy and services are asked, never forced."""
    window.notify_text(_("Writing pending data and unmounting…"))

    def done(res):
        window.refresh()
        data = res.data if isinstance(res.data, dict) else {}
        if res.ok:
            if remove and data.get("removable"):
                window.notify_text(_("The drive can be disconnected now."))
            else:
                window.notify_text(_("Unmounted. Everything was written to the device."))
            if then:
                then()
            return
        if res.code == SERVICES and data.get("services"):
            _ask_services(window, target, remove, then, data)
        elif res.code == BUSY:
            busy_dialog(window, data.get("busy_device") or target, lambda: unmount(window, target, remove, then, allow_services),
                        summary=data.get("busy_summary", ""))
        else:
            title = _("Could not remove it") if remove else _("Could not unmount")
            w.alert(window, title, data.get("reason") or res.message or _("The reason could not be determined. Nothing was forced."))
    if remove:
        window.engine.safe_remove(target, done, allow_services=allow_services)
    else:
        window.engine.unmount(target, done, allow_services=allow_services)


def _ask_services(window, target, remove, then, data):
    names = "\n".join(f"• {s.get('name') or s.get('unit')} ({s.get('unit')})" for s in data["services"])
    body = _("Unmounting it stops these services:") + "\n" + names + "\n\n" + data.get("services_back", "")

    def answered(rid):
        if rid == "stop":
            unmount(window, target, remove, then, allow_services=True)
    w.alert(window, _("Services use this device"), body,
            responses=(("cancel", _("Cancel")), ("stop", _("Stop them and unmount"))),
            default="cancel", close="cancel", destructive=("stop",), callback=answered)


def force_unmount(window, target, remove=False):
    """'Force' as it can be done without losing data: see who keeps it busy, ask
    those programs to close (as closing their windows), then unmount."""
    def looked(res):
        data = res.data if isinstance(res.data, dict) else {}
        if not data.get("count"):
            unmount(window, target, remove)
            return
        busy_dialog(window, data.get("device") or target, lambda: unmount(window, target, remove), data=data)
    window.engine.busy(target, looked)


def busy_dialog(window, device, retry, summary="", data=None):
    """Who keeps DEVICE busy, and the offer to ask them to close. Cancel is the
    default: closing a program can lose what was not saved in it."""
    if data is None:
        window.engine.busy(device, lambda res: busy_dialog(window, device, retry, summary,
                                                           res.data if isinstance(res.data, dict) else {}))
        return
    programs = data.get("programs") or []
    closable = [p for p in programs if p.get("closable")]
    lines = []
    for p in programs:
        line = f"• {p.get('app')} ({p.get('comm')}, PID {p.get('pid')}) — {p.get('activity')}"
        if not p.get("closable"):
            line += "\n   " + _("Will not be closed: %s") % p.get("why", "")
        lines.append(line)
    for o in data.get("others") or []:
        lines.append("• " + o.get("text", ""))
    body = (data.get("summary") or summary) + "\n\n" + "\n".join(lines)
    if closable:
        body += "\n\n" + _("Closing asks each program to quit, as when you close its window. Changes not saved in them may be lost: if you can, close them yourself instead.")
    else:
        body += "\n\n" + (data.get("advice") or "")
    responses = [("cancel", _("Cancel")), ("retry", _("Try again"))]
    if closable:
        responses.append(("close", _("Close them and unmount")))

    def answered(rid):
        if rid == "retry":
            retry()
        elif rid == "close":
            _close_then(window, device, retry)
    w.alert(window, _("It is in use"), body.strip(), responses=tuple(responses),
            default="cancel", close="cancel", destructive=("close",) if closable else (), callback=answered)


def _close_then(window, device, retry):
    window.notify_text(_("Asking the programs to close…"))

    def closed(res):
        data = res.data if isinstance(res.data, dict) else {}
        if data.get("still_running"):
            w.alert(window, _("Some programs did not close"),
                    _("They are still running, so nothing was unmounted. Close them yourself, then try again."))
            return
        retry()
    window.engine.close_apps(device, closed)


def erase(window, dev):
    """The way to Erase data permanently: one warning here, then the maintenance
    page, which checks the drive and asks twice more (the second time, its name)."""
    def answered(rid):
        if rid == "continue":
            window.open_maintenance(dev)
    w.alert(window, _("Erase everything on %s?") % dev.name,
            _("This is not recovery: it destroys every file on the whole drive, for good. No program, and no data recovery service, can bring them back.\n\n"
              "Copy what you want to keep first. The next page checks whether this drive can be erased, and asks for confirmation twice more."),
            responses=(("cancel", _("Cancel")), ("continue", _("I understand, continue"))),
            default="cancel", close="cancel", destructive=("continue",), callback=answered)


def drive_target(dev):
    """What 'unmount this drive' means: its one mounted volume, or the whole drive."""
    mounted = dev.mounted_volumes
    return mounted[0].device if len(mounted) == 1 else dev.device


def drive_menu(window, widget, dev):
    """The menu of a drive, wherever it is shown: actions on WIDGET, as 'drive.*'."""
    group = Gio.SimpleActionGroup()
    menu = Gio.Menu()
    view = Gio.Menu()
    can_unmount = bool(dev.mounted_volumes) and not dev.has_system
    entries = [
        (view, "details", _("Open the drive"), lambda: window.show_device(dev.stable_id), True),
        (view, "health", _("Check its health"), lambda: window.show_device(dev.stable_id, "health"), dev.kind != "image"),
        (view, "rescue", _("Recover files…"), lambda: window.open_wizard(dev), dev.kind != "optical"),
    ]
    mount = Gio.Menu()
    entries += [
        (mount, "unmount", _("Unmount"), lambda: unmount(window, drive_target(dev)), can_unmount),
        (mount, "force", _("Force unmount (close the programs using it)…"), lambda: force_unmount(window, drive_target(dev)), can_unmount),
        (mount, "remove", _("Safely remove"), lambda: unmount(window, dev.device, remove=True),
         dev.external and not dev.has_system and dev.kind != "image"),
    ]
    danger = Gio.Menu()
    entries.append((danger, "erase", _("Erase data permanently…"), lambda: erase(window, dev),
                    dev.kind not in ("image", "optical") and not dev.has_system))
    for section, name, text, handler, shown in entries:
        if not shown:
            continue
        action = Gio.SimpleAction.new(name, None)
        action.connect("activate", lambda _a, _p, h=handler: h())
        group.add_action(action)
        section.append(text, f"drive.{name}")
    for section in (view, mount, danger):
        if section.get_n_items():
            menu.append_section(None, section)
    widget.insert_action_group("drive", group)
    widget.drive_actions = group
    button = Gtk.MenuButton(icon_name="view-more-symbolic", menu_model=menu, valign=Gtk.Align.CENTER,
                            tooltip_text=_("More options"), css_classes=["flat"])
    button.update_property([Gtk.AccessibleProperty.LABEL], [_("More options for %s") % dev.name])
    return button
