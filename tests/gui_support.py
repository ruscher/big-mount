"""What the tests of the application share: a private display (Broadway, so nothing
appears on the screen), a stand-in for `bigmount` that answers with fixtures and
records every call, sample drives, and pictures of the real widgets.

No disk is involved: the window only ever talks to the stand-in.
"""

import atexit
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import warnings

sys.dont_write_bytecode = True
warnings.filterwarnings("ignore", message=".*get_event_loop_policy.*")

# An exception in a callback only prints a line, and the window goes on half done.
# Here it fails the test that caused it.
CALLBACK_ERRORS = []


def _record_callback_error(kind, value, tb):
    import traceback
    CALLBACK_ERRORS.append("".join(traceback.format_exception(kind, value, tb)))
    sys.__excepthook__(kind, value, tb)


sys.excepthook = _record_callback_error

REPO = pathlib.Path(__file__).resolve().parent.parent
LIB = REPO / "big-mount/usr/lib/big-mount"
# Not /tmp: it is often mounted noexec, and the stand-in must run
WORK = pathlib.Path(tempfile.mkdtemp(prefix="bm-gui-", dir=os.environ.get("TMPDIR", "/var/tmp")))
atexit.register(shutil.rmtree, WORK, ignore_errors=True)
STUB = WORK / "bigmount"
CALLS = WORK / "calls"
FIX = WORK / "fix"
FIX.mkdir()
os.environ["XDG_RUNTIME_DIR"] = str(WORK)
# The settings of whoever runs this must not change what the tests see
os.environ["XDG_CONFIG_HOME"] = str(WORK / "config")
os.environ["XDG_STATE_HOME"] = str(WORK / "state")
os.environ["GSK_RENDERER"] = "cairo"
os.environ["GTK_A11Y"] = "none"
os.environ["NO_AT_BRIDGE"] = "1"
os.environ["GSETTINGS_BACKEND"] = "memory"

STUB.write_text(f"""#!/bin/bash
printf '%s\\n' "$*" >> {CALLS}
# The selection is removed once the call ends: keep what was received, and its mode
prev=""
for a in "$@"; do
   [ "$prev" = --items-from ] && cp -- "$a" "{WORK}/last-items" && stat -c %a -- "$a" > "{WORK}/last-items.mode"
   prev="$a"
done
key="$2"
for a in "$@"; do [ "$a" = --dry-run ] && key="$2-dry"; done
d="{FIX}/$key.delay"
[ -f "$d" ] && sleep "$(cat "$d")"
f="{FIX}/$key.json"
[ -f "$f" ] && cat "$f"
t="{FIX}/$key.txt"
[ -f "$t" ] && cat "$t"
rc="{FIX}/$key.rc"
[ -f "$rc" ] && exit "$(cat "$rc")"
exit 0
""")
STUB.chmod(STUB.stat().st_mode | stat.S_IEXEC)
os.environ["BM_GUI_BIN"] = str(STUB)


def start_display():
    """A display of our own. Returns False when this GTK has no Broadway."""
    daemon = shutil.which("gtk4-broadwayd")
    if not daemon:
        return False
    for n in range(40 + os.getpid() % 200, 300):
        proc = subprocess.Popen([daemon, f":{n}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.25)
        if proc.poll() is None:
            atexit.register(proc.kill)
            os.environ["GDK_BACKEND"] = "broadway"
            os.environ["BROADWAY_DISPLAY"] = f":{n}"
            os.environ.pop("WAYLAND_DISPLAY", None)
            os.environ.pop("DISPLAY", None)
            return True
    return False


if not start_display():
    print("gtk4-broadwayd is not available (package gtk4): these tests need a private display", file=sys.stderr)
    sys.exit(77)

sys.path.insert(0, str(LIB))

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gsk", "4.0")
from gi.repository import Adw, Gdk, GLib, Gsk, Gtk  # noqa: E402

GB = 1000 ** 3


def vol(device, **kw):
    v = {"device": device, "type": "part", "fstype": "ntfs", "fsver": "", "label": "", "uuid": "ABC", "state": "unmounted",
         "state_label": "Not mounted", "mountpoint": "", "size": 1000 * GB, "used": None, "avail": None,
         "read_only": False, "device_read_only": False, "fs_supported": True}
    v.update(kw)
    return v


def drive(device, name, level="normal", label="No alerts in the system log (SMART not read)", volumes=None, kind="usb",
          kind_label="USB storage", reasons=(), serial="S1", size=1000 * GB, smart=None, seq=7, basis="log",
          grade=None, notes=(), transport="usb", hotplug=True):
    """grade: what a newer engine adds; without it the window falls back on the level."""
    health = {"level": level, "label": label, "basis": basis, "reasons": list(reasons), "smart": smart or {"verdict": ""}}
    if grade:
        health.update(grade=grade, notes=list(notes))
    return {"device": device, "name": name, "kind": kind, "kind_label": kind_label, "icon": "drive-removable-media-usb",
            "model": name, "vendor": "", "serial": serial, "transport": transport, "transport_label": transport.upper(), "stable_id": f"serial:{serial}",
            "pttype": "gpt", "size": size, "diskseq": seq, "removable": False, "hotplug": hotplug, "rotational": False, "trim": False,
            "volumes": [vol(device, type="disk", fstype="", state="container", state_label="Holds other volumes"), *(volumes or [])],
            "health": health}


def seagate():
    return drive("/dev/sdb", "ST1000DM003-1CH162", "critical", "Critical: high risk for the data",
                 [vol("/dev/sdb1", label="ARQUIVOS")], serial="S1DFL8G9", kind_label="USB storage",
                 reasons=[{"key": "io-errors", "text": "Since the computer was started, reading or writing failed (55 kernel messages)."}])


def backup(mountpoint):
    return drive("/dev/sda", "SanDisk Portable SSD", volumes=[vol(
        "/dev/sda1", label="Backup", state="mounted-rw", state_label="Mounted", mountpoint=str(mountpoint), used=800 * GB, avail=1200 * GB)],
        serial="SD1", size=2000 * GB)


def system_disk():
    return drive("/dev/nvme0n1", "ADATA LEGEND 800", kind="nvme", kind_label="NVMe SSD", serial="ADATA1", transport="nvme", hotplug=False, volumes=[
        vol("/dev/nvme0n1p1", fstype="vfat", size=300 * 1000 * 1000, state="system", state_label="In use by the running system", mountpoint="/boot/efi", used=5 * 1000 * 1000, avail=295 * 1000 * 1000),
        vol("/dev/nvme0n1p2", fstype="btrfs", label="root", size=999 * GB, state="system", state_label="In use by the running system", mountpoint="/", used=420 * GB, avail=579 * GB)],
        label="No alerts (SMART and system log checked)", basis="smart+log", seq=2)


def fix(key, data, rc=None, delay=None):
    """What the stand-in answers to `bigmount --drive KEY` (KEY-dry with --dry-run),
    after `delay` seconds when it should take a while."""
    (FIX / f"{key}.json").write_text(json.dumps(data) if not isinstance(data, str) else data)
    delayf = FIX / f"{key}.delay"
    if delay is None:
        delayf.unlink(missing_ok=True)
    else:
        delayf.write_text(str(delay))
    rcf = FIX / f"{key}.rc"
    if rc is None:
        rcf.unlink(missing_ok=True)
    else:
        rcf.write_text(str(rc))


def unfix(*keys):
    for key in keys:
        for ext in ("json", "txt", "rc", "delay"):
            (FIX / f"{key}.{ext}").unlink(missing_ok=True)


def fix_text(key, text):
    (FIX / f"{key}.txt").write_text(text)


def calls():
    return CALLS.read_text().splitlines() if CALLS.exists() else []


def forget_calls():
    CALLS.unlink(missing_ok=True)


context = GLib.MainContext.default()


def pump(cond=None, timeout=4.0):
    end = time.time() + timeout
    while time.time() < end:
        while context.pending():
            context.iteration(False)
        if cond and cond():
            for _ in range(8):
                while context.pending():
                    context.iteration(False)
                time.sleep(0.01)
            return True
        time.sleep(0.01)
    return bool(cond and cond())


def widgets(root):
    """Every widget under root."""
    stack = [root]
    while stack:
        widget = stack.pop()
        yield widget
        child = widget.get_first_child()
        while child:
            stack.append(child)
            child = child.get_next_sibling()


def texts(root):
    out = []
    for widget in widgets(root):
        if isinstance(widget, Gtk.Label) and widget.get_mapped():
            out.append(widget.get_text())
    return out


def text(root):
    return "\n".join(texts(root))


def find_button(root, wanted):
    for widget in widgets(root):
        if isinstance(widget, Gtk.Button) and widget.get_mapped():
            lab = widget.get_label() or ""
            child = widget.get_child()
            if isinstance(child, Adw.ButtonContent):
                lab = child.get_label()
            if lab.replace("_", "") == wanted:
                return widget
    return None


def click(root, wanted):
    b = find_button(root, wanted)
    assert b is not None, f"no button {wanted!r} in: {text(root)[:600]}"
    assert b.get_sensitive(), f"button {wanted!r} is not sensitive"
    b.emit("clicked")
    pump(timeout=0.05)


def find_row(root, title):
    for widget in widgets(root):
        if isinstance(widget, Adw.ActionRow) and widget.get_title() == title and widget.get_mapped():
            return widget
    return None


def dialogs(window):
    d = window.get_visible_dialog()
    return d


def present_at(window, width, height):
    """On a display nobody looks at there is no window manager to obey a resize."""
    window.set_default_size(width, height)
    window.set_size_request(width, height)
    pump(lambda: window.get_width() == width, 2)
    pump(timeout=0.1)


def shot(widget, path, width=None, height=None):
    """A picture of the real widget, drawn by GTK. Needs no screen."""
    pump(lambda: widget.get_width() > 0, 3)
    width = width or widget.get_width()
    height = height or widget.get_height()
    node = None
    for _ in range(100):
        paintable = Gtk.WidgetPaintable.new(widget)
        snapshot = Gtk.Snapshot()
        paintable.snapshot(snapshot, width, height)
        node = snapshot.to_node()
        if node is not None:
            break
        pump(timeout=0.05)
    assert node is not None, "nothing was drawn"
    renderer = Gsk.CairoRenderer()
    renderer.realize_for_display(Gdk.Display.get_default())
    from gi.repository import Graphene
    texture = renderer.render_texture(node, Graphene.Rect().init(0, 0, width, height))
    renderer.unrealize()
    os.makedirs(os.path.dirname(str(path)), exist_ok=True)
    texture.save_to_png(str(path))


def make_app():
    Adw.init()
    from gui.application import load_style
    load_style()
    # No frame arrives on a display nobody looks at: a transition would never end
    Gtk.Settings.get_default().set_property("gtk-enable-animations", False)
    app = Adw.Application(application_id="org.biglinux.big-mount.tests")
    app.register(None)
    return app
