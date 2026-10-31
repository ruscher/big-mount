#!/usr/bin/python3
"""The screenshots of the drive manager in the README, always reproducible.

This is the real window, drawn off screen, in English, with the Breeze style.
Its data comes from a stand-in for `bigmount` that answers with sample drives,
so a picture never shows the disks, labels or files of whoever runs this. No
disk is involved, and nothing appears on the screen.

Usage: python3 tests/readme-screenshots.py [DIR]     (default: docs/images)
"""

import sys
sys.dont_write_bytecode = True
import atexit
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import time

os.environ["QT_QPA_PLATFORM"] = "offscreen"
os.environ["LANGUAGE"] = "C"
os.environ["QT_STYLE_OVERRIDE"] = "Breeze"

REPO = pathlib.Path(__file__).resolve().parent.parent
ARGS = [a for a in sys.argv[1:] if a != "--dark"]
OUT = pathlib.Path(ARGS[0]) if ARGS else REPO / "docs/images"
OUT.mkdir(parents=True, exist_ok=True)

# Not /tmp: it is often mounted noexec, and the stand-in must run
WORK = pathlib.Path(tempfile.mkdtemp(prefix="bm-shots-", dir=os.environ.get("TMPDIR", "/var/tmp")))
atexit.register(shutil.rmtree, WORK, ignore_errors=True)
FIX = WORK / "fix"
FIX.mkdir()
STUB = WORK / "bigmount"
STUB.write_text(f"""#!/bin/bash
f="{FIX}/$2.json"
[ -f "$f" ] && cat "$f"
exit 0
""")
STUB.chmod(STUB.stat().st_mode | stat.S_IEXEC)
os.environ["BM_GUI_BIN"] = str(STUB)

spec = importlib.util.spec_from_file_location("drive_gui", REPO / "big-mount/usr/lib/big-mount/drive-gui.py")
gui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gui)

from PySide6.QtCore import Qt  # noqa: E402
from PySide6.QtGui import QColor, QIcon, QPalette  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

app = QApplication([])
gui.setup_icons()

GB = 1000 ** 3
TB = 1000 ** 4

# The sample source: a folder the file picker can really show
SOURCE = WORK / "OLD-DATA"
for name in ("Documents/Taxes", "Music", "Pictures/2019", "Pictures/2020", "Videos"):
    (SOURCE / name).mkdir(parents=True)
for name in ("Documents/contract.pdf", "Pictures/2020/IMG_1275.JPG", "notes.txt"):
    (SOURCE / name).write_text("sample")


def palette(dark):
    """The colours of Breeze Light and Breeze Dark."""
    window, text, base, button_, mid = (
        ("#232629", "#fcfcfc", "#141618", "#31363b", "#4d5257") if dark else
        ("#eff0f1", "#232629", "#ffffff", "#fcfcfc", "#b4b6b8"))
    pal = QPalette()
    for role, value in ((QPalette.Window, window), (QPalette.WindowText, text), (QPalette.Base, base),
                        (QPalette.AlternateBase, window), (QPalette.Text, text), (QPalette.Button, button_),
                        (QPalette.ButtonText, text), (QPalette.Highlight, "#3daee9"),
                        (QPalette.HighlightedText, "#fcfcfc"), (QPalette.Mid, mid),
                        (QPalette.PlaceholderText, "#8c9094")):
        pal.setColor(role, QColor(value))
    return pal


def fix(key, data):
    (FIX / f"{key}.json").write_text(data if isinstance(data, str) else json.dumps(data))


def vol(device, **kw):
    v = {"device": device, "type": "part", "fstype": "ntfs", "fsver": "", "label": "", "uuid": "ABC", "state": "unmounted",
         "state_label": "Not mounted", "mountpoint": "", "size": TB, "used": None, "avail": None,
         "read_only": False, "device_read_only": False, "fs_supported": True}
    v.update(kw)
    return v


def drive(device, name, kind, kind_label, icon, size, level, label, volumes, reasons=()):
    return {"device": device, "name": name, "kind": kind, "kind_label": kind_label, "icon": icon, "model": name, "vendor": "",
            "serial": "", "transport": kind, "transport_label": kind.upper(),
            "volumes": [vol(device, type="disk", fstype="", size=size, state="container", state_label="Holds other volumes"), *volumes],
            "health": {"level": level, "label": label, "basis": "log", "reasons": [{"key": "r", "text": t} for t in reasons],
                       "smart": {"verdict": ""}}}


NO_ALERTS = "No alerts in the system log (SMART not read)"
FAILING = drive("/dev/sdb", "ST1000DM003-1CH162", "usb", "USB storage", "drive-removable-media-usb", TB, "critical",
                "Critical: high risk for the data",
                [vol("/dev/sdb1", label="OLD-DATA", state="mounted-ro", state_label="Mounted read-only", mountpoint="/run/media/me/OLD-DATA",
                     read_only=True, device_read_only=True, used=620 * GB, avail=380 * GB)],
                ["Since the computer was started, reading or writing failed (55 kernel messages).",
                 "Since the computer was started, it stopped answering and the connection had to be reset (2 kernel messages).",
                 "Since the computer was started, the USB connection was reset or lost 48 times."])
BACKUP = drive("/dev/sda", "SanDisk Portable SSD", "usb", "USB storage", "drive-removable-media-usb", 2 * TB, "normal", NO_ALERTS,
               [vol("/dev/sda1", label="Backup", state="mounted-rw", state_label="Mounted", mountpoint="/run/media/me/Backup",
                    size=2 * TB, used=800 * GB, avail=1200 * GB)])
SYSTEM = drive("/dev/nvme0n1", "NVMe SSD 1 TB", "nvme", "NVMe SSD", "drive-harddisk-solidstate", TB, "normal", NO_ALERTS,
               [vol("/dev/nvme0n1p1", fstype="vfat", state="system", state_label="In use by the running system", mountpoint="/boot/efi", size=314000000),
                vol("/dev/nvme0n1p2", fstype="btrfs", state="system", state_label="In use by the running system", mountpoint="/", size=999 * GB,
                    used=500 * GB, avail=499 * GB)])
ADVICE = ["Copy what matters now, starting with the most important files. Every extra read wears a failing disk.",
          "Do not run repair tools on this disk: they write, and they can destroy what is still readable.",
          "If the data is very important and cannot be replaced, consider a data recovery professional before insisting."]
TOOLS = {"ddrescue": True, "testdisk": True, "photorec": True, "smartctl": True, "rsync": True}
JOB = {"id": "20261030-140000-a1b2", "kind": "copy", "state": "running", "state_label": "Copying", "reason": "", "reason_text": "",
       "source": "/run/media/me/OLD-DATA", "destination": "/run/media/me/Backup/rescue", "current": "Pictures/2020/IMG_1275.JPG",
       "verify": "basic", "verify_result": "", "dir": str(WORK), "files_done": 9240, "files_total": 15464, "bytes_done": 27 * GB,
       "bytes_total": 45 * GB, "rate_now": 31200000, "rate_avg": 28400000, "elapsed": 950, "eta": 634, "deferred": 0, "failed": 0,
       "differ": 0, "conflicts": 0, "read_errors": 0, "stuck": 0, "created": 1793368800, "finished": None, "total_estimate": False}
REPORT = """== Copy report ==
Source:      /run/media/me/OLD-DATA
Destination: /run/media/me/Backup/rescue
Copied:      15461 files, 45.6 GB
Set aside:   1 file (stopped advancing for 90 seconds)
  Pictures/2020/IMG_1275.JPG
Not copied:  2 files (reading failed)
  Videos/trip.mp4
  Videos/old.mov
"""


def pump(cond=None, timeout=4.0):
    end = time.time() + timeout
    while time.time() < end:
        app.processEvents()
        if cond and cond():
            break
        QTest.qWait(15)
    for _ in range(6):
        app.processEvents()
        QTest.qWait(15)


def grab(widget, name):
    pump(timeout=0.25)
    widget.grab().save(str(OUT / f"{name}.png"))
    print(name)


def start(dark=False):
    app.setPalette(palette(dark))
    # Not the theme of whoever runs this: its icons may not fit this palette
    QIcon.setThemeName("breeze-dark" if dark else "breeze")
    app.setStyleSheet(gui.app_style(app))
    fix("list", {"partial": False, "devices": [FAILING, BACKUP, SYSTEM]})
    fix("diagnose", {"device": FAILING, "advice": ADVICE, "kernel": [], "volumes": [], "tools": TOOLS})
    fix("jobs", {"jobs": []})
    win = gui.MainWindow()
    win.show()
    pump(lambda: win.devices.count() == 3 and win.device_page.diag is not None)
    return win


def show_job(win, **kw):
    job = {**JOB, **kw}
    fix("status", job)
    fix("report", REPORT)
    win.open_job(job["id"])
    pump(lambda: win.job_page.state == job["state"])


# The dark picture in a process of its own: changing the palette of a running
# application with a window still around once crashed Qt, and the manager never does it
if "--dark" in sys.argv:
    win = start(dark=True)
    grab(win, "drive-manager-dark")
    win.close()
    sys.exit(0)
subprocess.run([sys.executable, __file__, str(OUT), "--dark"], check=True)

win = start()
grab(win, "drive-manager")

fix("diagnose", {"device": BACKUP, "advice": [], "kernel": [], "volumes": [], "tools": TOOLS})
win.devices.select_device("/dev/sda")
pump(timeout=0.5)
grab(win, "drive-healthy")
win.devices.select_device("/dev/sdb")
pump(timeout=0.5)

dialog = gui.MountDialog(FAILING, FAILING["volumes"][1], win)
dialog.show()
grab(dialog, "drive-mount-dialog")
dialog.close()

dialog = gui.AdvancedDialog(win.engine, FAILING, TOOLS, win)
dialog.show()
grab(dialog, "drive-advanced")
dialog.close()

fix("destinations", {"destinations": [
    {"path": "/run/media/me/Backup", "device": "/dev/sda1", "level": "normal", "why": "", "name": "Backup", "avail": 1200 * GB, "independent": True, "recommended": True},
    {"path": "/mnt/old-backup", "device": "/dev/sdb2", "level": "critical", "why": "risky", "name": "ST1000DM003-1CH162", "avail": 90 * GB, "independent": False, "recommended": False}]})
fix("copy", {"ok": True, "error": "", "source": "/run/media/me/OLD-DATA", "destination": "/run/media/me/Backup/rescue", "scanned": False,
             "total_estimate": False, "avail": 1200 * GB,
             "warnings": [{"key": "no-total", "text": "The total is not measured on a drive at risk: walking the whole disk would wear it. The copy shows what was really copied, without a percentage."}]})
win._open_wizard(str(SOURCE), FAILING)
wizard = win.wizard
# The picker needs a folder that exists; the picture says where it would be
wizard.source_label.setText("Source: /run/media/me/OLD-DATA")
pump(timeout=0.3)
wizard.pick_radio.setChecked(True)
root = wizard.model.index(str(SOURCE))
pump(lambda: wizard.model.rowCount(root) >= 4)
wizard.model.setData(wizard.model.index(str(SOURCE / "Pictures")), Qt.Checked.value, Qt.CheckStateRole)
wizard.model.setData(wizard.model.index(str(SOURCE / "Documents")), Qt.Checked.value, Qt.CheckStateRole)
wizard.tree.expand(wizard.model.index(str(SOURCE / "Pictures")))
pump(timeout=0.4)
grab(win, "drive-wizard-what")
wizard.go_next()
pump(lambda: wizard.dest_edit.text())
grab(win, "drive-wizard-where")
wizard.go_next()
pump(lambda: wizard.next_btn.isEnabled())
grab(win, "drive-wizard-review")

show_job(win)
grab(win, "drive-copy-progress")
show_job(win, bytes_total=0, files_total=0, eta=None, state="analyzing", state_label="Copying")
show_job(win, bytes_total=0, files_total=0, eta=None)
grab(win, "drive-copy-at-risk")
show_job(win, state="needs-attention", state_label="Finished, needs your attention", reason="files-left",
         reason_text="Some files were not copied.", deferred=1, failed=2, bytes_done=int(45.6 * GB), bytes_total=0, files_done=15461,
         files_total=0, current="", rate_now=0, eta=None, elapsed=4410)
pump(lambda: win.job_page.report.isVisibleTo(win.job_page))
grab(win, "drive-copy-attention")

fix("jobs", {"jobs": [
    {**JOB, "id": "20261030-140000-a1b2", "state": "needs-attention", "state_label": "Finished, needs your attention", "deferred": 1, "failed": 2},
    {**JOB, "id": "20261029-091500-c3d4", "state": "completed", "state_label": "Completed and checked", "source": "/run/media/me/PENDRIVE", "created": 1793265300},
    {**JOB, "id": "20261028-180000-e5f6", "state": "interrupted", "state_label": "Interrupted (it can be resumed)", "source": "/run/media/me/SD-CARD", "created": 1793214000}]})
win.show_jobs()
pump(lambda: win.jobs_page.list.count() == 3)
grab(win, "drive-jobs")
win.close()
