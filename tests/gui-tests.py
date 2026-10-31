#!/usr/bin/python3
"""Tests of the graphical drive manager, off screen (QT_QPA_PLATFORM=offscreen).

The window talks to a stand-in for `bigmount` (BM_GUI_BIN) that answers with
fixtures and records every call, so these tests are about the window: what it
shows, what it asks the engine for, and what it refuses to pretend. No disk is
involved, and nothing appears on the screen.

Usage: python3 tests/gui-tests.py [-v] [--shots DIR]
"""

import sys
sys.dont_write_bytecode = True
import atexit
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile
import time
import unittest

SHOTS = None
if "--shots" in sys.argv:
    i = sys.argv.index("--shots")
    SHOTS = sys.argv[i + 1]
    del sys.argv[i:i + 2]

os.environ["QT_QPA_PLATFORM"] = "offscreen"
os.environ["LANGUAGE"] = "C"
# Not /tmp: it is often mounted noexec, and the stand-in must run
WORK = pathlib.Path(tempfile.mkdtemp(prefix="bm-gui-", dir=os.environ.get("TMPDIR", "/var/tmp")))
atexit.register(shutil.rmtree, WORK, ignore_errors=True)
STUB = WORK / "bigmount"
CALLS = WORK / "calls"
FIX = WORK / "fix"
FIX.mkdir()
STUB.write_text(f"""#!/bin/bash
printf '%s\\n' "$*" >> {CALLS}
key="$2"
f="{FIX}/$key.json"
[ -f "$f" ] && cat "$f"
rc="{FIX}/$key.rc"
[ -f "$rc" ] && exit "$(cat "$rc")"
exit 0
""")
STUB.chmod(STUB.stat().st_mode | stat.S_IEXEC)
os.environ["BM_GUI_BIN"] = str(STUB)

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "big-mount/usr/lib/big-mount"))

import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("drive_gui", REPO / "big-mount/usr/lib/big-mount/drive-gui.py")
gui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gui)

from PySide6.QtCore import Qt  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication, QCheckBox, QLabel, QPushButton  # noqa: E402

app = QApplication([])
gui.setup_icons()
app.setStyleSheet(gui.app_style(app))


def vol(device, **kw):
    v = {"device": device, "type": "part", "fstype": "ntfs", "fsver": "", "label": "", "uuid": "ABC", "state": "unmounted",
         "state_label": "Not mounted", "mountpoint": "", "size": 1000000000000, "used": None, "avail": None,
         "read_only": False, "device_read_only": False, "fs_supported": True}
    v.update(kw)
    return v


def drive(device, name, level="normal", label="No alerts in the system log (SMART not read)", volumes=None, kind="usb", reasons=()):
    return {"device": device, "name": name, "kind": kind, "kind_label": "USB storage", "icon": "drive-removable-media-usb",
            "model": name, "vendor": "", "serial": "S1", "transport": "usb", "transport_label": "USB",
            "volumes": [vol(device, type="disk", fstype="", state="container", state_label="Holds other volumes"), *(volumes or [])],
            "health": {"level": level, "label": label, "basis": "log", "reasons": list(reasons), "smart": {"verdict": ""}}}


SEAGATE = drive("/dev/sdb", "ST1000DM003-1CH162", "critical", "Critical: high risk for the data",
                [vol("/dev/sdb1", label="ARQUIVOS")], reasons=[{"key": "io-errors", "text": "Reading failed (55 kernel messages)."}])
BACKUP = drive("/dev/sda", "SanDisk Portable SSD", volumes=[vol(
    "/dev/sda1", label="Novo volume", state="mounted-rw", state_label="Mounted", mountpoint=str(WORK), used=800000000000, avail=1200000000000)])


def fix(key, data, rc=None):
    (FIX / f"{key}.json").write_text(json.dumps(data) if not isinstance(data, str) else data)
    rcf = FIX / f"{key}.rc"
    if rc is None:
        rcf.unlink(missing_ok=True)
    else:
        rcf.write_text(str(rc))


def calls():
    return CALLS.read_text().splitlines() if CALLS.exists() else []


def pump(cond=None, timeout=3.0):
    end = time.time() + timeout
    while time.time() < end:
        app.processEvents()
        if cond and cond():
            for _ in range(5):
                app.processEvents()
                QTest.qWait(10)
            return True
        QTest.qWait(15)
    return bool(cond and cond())


def shot(widget, name):
    if SHOTS:
        pump(timeout=0.15)
        os.makedirs(SHOTS, exist_ok=True)
        widget.grab().save(os.path.join(SHOTS, name + ".png"))


def texts(widget):
    return [w.text() for w in widget.findChildren(QLabel) if w.isVisibleTo(widget)]


def button_named(widget, fragment):
    for b in widget.findChildren(QPushButton):
        if fragment in b.text().replace("&", "") and b.isVisibleTo(widget):
            return b
    raise AssertionError(f"no button with {fragment!r}: {[b.text() for b in widget.findChildren(QPushButton)]}")


class Base(unittest.TestCase):
    def setUp(self):
        CALLS.unlink(missing_ok=True)
        for f in FIX.iterdir():
            f.unlink()
        fix("list", {"partial": False, "devices": [SEAGATE, BACKUP]})
        fix("diagnose", {"device": SEAGATE, "advice": ["Copy what matters now."], "kernel": [], "volumes": [],
                         "tools": {"ddrescue": False, "testdisk": True, "photorec": True, "smartctl": True, "rsync": True}})
        fix("jobs", {"jobs": []})
        self.win = gui.MainWindow()
        self.win.show()
        self.assertTrue(pump(lambda: self.win.devices.count() == 2), "the list did not arrive")

    def tearDown(self):
        self.win.close()
        self.win.deleteLater()
        pump(timeout=0.05)


class DeviceListTests(Base):
    def test_the_list_shows_each_drive_and_its_health_in_words(self):
        self.assertEqual(self.win.devices.current_device_name(), "/dev/sdb")
        row = self.win.devices.itemWidget(self.win.devices.item(0))
        all_text = " ".join(texts(row))
        self.assertIn("ST1000DM003-1CH162", all_text)
        self.assertIn("Critical", all_text, "health must be in words, never colour alone")
        shot(self.win, "01-devices")

    def test_the_window_is_not_wider_than_it_needs_to_be(self):
        # Found in the screenshots: buttons a job never shows together made it 1109 wide
        self.assertLess(self.win.minimumSizeHint().width(), 900)
        self.assertEqual(self.win.width(), 1040)

    def test_the_list_has_room_for_a_model_name(self):
        # Found in the screenshots: "ST1000DM003-1CH16" was cut, a label cannot wrap one word
        row = self.win.devices.itemWidget(self.win.devices.item(0))
        title = next(w for w in row.findChildren(QLabel) if "ST1000" in w.text())
        self.assertGreaterEqual(title.width(), title.fontMetrics().horizontalAdvance(title.text()))

    def test_a_refresh_keeps_the_selection(self):
        self.win.devices.setCurrentRow(1)
        self.win.refresh()
        pump(timeout=0.4)
        self.assertEqual(self.win.devices.current_device_name(), "/dev/sda")

    def test_a_drive_that_goes_away_is_said_out_loud(self):
        self.win.devices.setCurrentRow(0)
        fix("list", {"partial": False, "devices": [BACKUP]})
        self.win.refresh()
        self.assertTrue(pump(lambda: "disconnected" in self.win.notice.text()), self.win.notice.text())

    def test_no_drive_at_all(self):
        fix("list", {"partial": False, "devices": []})
        self.win.refresh()
        self.assertTrue(pump(lambda: self.win.pages.currentWidget() is self.win.empty))

    def test_a_list_that_cannot_be_read_does_not_crash(self):
        fix("list", "not json at all")
        self.win.refresh()
        self.assertTrue(pump(lambda: "could not be read" in self.win.notice.text()))

    def test_a_stuck_mount_is_explained(self):
        fix("list", {"partial": True, "devices": [SEAGATE]})
        self.win.refresh()
        self.assertTrue(pump(lambda: "did not answer" in self.win.notice.text()))


class DevicePageTests(Base):
    def test_diagnosis_and_advice_appear(self):
        page = self.win.device_page
        self.assertTrue(pump(lambda: page.diag is not None))
        self.assertTrue(pump(lambda: any("Copy what matters" in t for t in texts(page))))
        self.assertTrue(any("Reading failed" in t for t in texts(page)))

    def test_a_volume_offers_only_what_its_state_allows(self):
        page = self.win.device_page
        pump(lambda: page.diag is not None)
        button_named(page, "Recover files")
        button_named(page, "Mount read-only")
        self.assertFalse([b for b in page.findChildren(QPushButton) if "Unmount" in b.text() and b.isVisibleTo(page)])

    def test_locked_and_unsupported_volumes(self):
        locked = drive("/dev/sdc", "Cofre", volumes=[vol("/dev/sdc1", fstype="crypto_LUKS", state="locked", state_label="Encrypted and locked", fs_supported=False)])
        self.win.device_page.show_device(locked)
        pump(timeout=0.2)
        button_named(self.win.device_page, "Unlock")
        weird = drive("/dev/sdd", "Mac", volumes=[vol("/dev/sdd1", fstype="apfs", fs_supported=False)])
        self.win.device_page.show_device(weird)
        pump(timeout=0.2)
        self.assertTrue(any("no driver" in t for t in texts(self.win.device_page)))

    def test_names_are_never_rich_text(self):
        evil = drive("/dev/sdx", "<img src=x>Evil", volumes=[vol("/dev/sdx1", label="<b>bold</b>")])
        self.win.device_page.show_device(evil)
        pump(timeout=0.2)
        for label in self.win.device_page.findChildren(QLabel):
            if "<" in label.text():
                self.assertEqual(label.textFormat(), Qt.PlainText, label.text())


class WizardTests(Base):
    def wizard(self, data=None, rc=None):
        fix("destinations", {"destinations": [
            {"path": "/mnt/backup", "device": "/dev/sda1", "level": "normal", "why": "", "name": "Backup", "avail": 500000000000, "independent": True, "recommended": True},
            {"path": "/mnt/same", "device": "/dev/sdb2", "level": "critical", "why": "risky", "name": "Ruim", "avail": 900000000000, "independent": False, "recommended": False}]})
        if data is not None:
            fix("copy", data, rc)
        self.win._open_wizard(str(WORK), SEAGATE)
        return self.win.wizard

    def test_it_recommends_an_independent_disk(self):
        w = self.wizard()
        w.go_next()
        self.assertTrue(pump(lambda: w.dest_edit.text().startswith("/mnt/backup/")), w.dest_edit.text())
        shot(self.win, "02-destination")

    def test_review_shows_real_numbers(self):
        w = self.wizard({"ok": True, "error": "", "source": "/a", "destination": "/b", "scanned": True, "total_files": 1240,
                         "total_bytes": 126800000000, "avail": 500000000000, "warnings": []})
        w.go_next()
        pump(lambda: w.dest_edit.text())
        w.go_next()
        self.assertTrue(pump(lambda: w.next_btn.isEnabled()))
        joined = " ".join(texts(w))
        self.assertIn("1240 files", joined)
        self.assertIn("126 GB", joined)
        shot(self.win, "03-review")

    def test_a_drive_at_risk_says_the_total_is_not_measured(self):
        w = self.wizard({"ok": True, "error": "", "source": "/a", "destination": "/b", "scanned": False, "total_estimate": False,
                         "avail": 5, "warnings": [{"key": "no-total", "text": "The total is not measured on a drive at risk."}]})
        w.go_next(); pump(lambda: w.dest_edit.text()); w.go_next()
        self.assertTrue(pump(lambda: w.next_btn.isEnabled()))
        joined = " ".join(texts(w))
        self.assertIn("not measured", joined)
        self.assertIn("at risk", joined)

    def test_a_refusal_blocks_the_start(self):
        w = self.wizard({"ok": False, "error": "dest-inside-source", "error_text": "The destination is inside the source.", "warnings": []}, 20)
        w.go_next(); pump(lambda: w.dest_edit.text()); w.go_next()
        self.assertTrue(pump(lambda: any("inside the source" in t for t in texts(w))))
        self.assertFalse(w.next_btn.isEnabled())
        self.assertFalse([c for c in w.findChildren(QCheckBox) if c.isVisibleTo(w)], "that refusal has no override")

    def test_an_override_is_explicit_and_is_passed_on(self):
        w = self.wizard({"ok": False, "error": "same-disk", "error_text": "Same physical disk.", "warnings": []}, 20)
        w.go_next(); pump(lambda: w.dest_edit.text()); w.go_next()
        self.assertTrue(pump(lambda: bool([c for c in w.findChildren(QCheckBox) if c.isVisibleTo(w)])))
        self.assertFalse(w.next_btn.isEnabled(), "nothing starts until the user decides")
        check = next(c for c in w.findChildren(QCheckBox) if c.isVisibleTo(w))
        fix("copy", {"ok": True, "error": "", "warnings": [], "scanned": True, "total_files": 1, "total_bytes": 1})
        check.setChecked(True)
        self.assertTrue(pump(lambda: w.next_btn.isEnabled()))
        self.assertIn("--allow-same-disk", calls()[-1])

    def test_going_back_keeps_the_choices(self):
        w = self.wizard()
        w.go_next(); pump(lambda: w.dest_edit.text())
        w.dest_edit.setText("/mnt/escolhido")
        w.conflict.setCurrentIndex(1)
        w.go_back()
        self.assertEqual(w.stack.currentIndex(), 0)
        w.go_next()
        self.assertEqual(w.dest_edit.text(), "/mnt/escolhido")
        self.assertEqual(w.conflict.currentData(), "backup")

    def test_choosing_items_passes_them_relative_to_the_source(self):
        (WORK / "fotos").mkdir(exist_ok=True)
        (WORK / "fotos" / "a b.jpg").write_text("x")
        (WORK / "doc.txt").write_text("x")
        w = self.wizard({"ok": True, "error": "", "warnings": [], "scanned": True, "total_files": 1, "total_bytes": 1})
        w.pick_radio.setChecked(True)
        self.assertFalse(w.next_btn.isEnabled(), "nothing marked yet")
        model = w.model
        root = model.index(str(WORK))
        self.assertTrue(pump(lambda: model.rowCount(root) >= 2))
        model.setData(model.index(str(WORK / "fotos")), Qt.Checked.value, Qt.CheckStateRole)
        self.assertTrue(w.next_btn.isEnabled())
        self.assertEqual(w.items(), ["fotos"])
        # A folder marked covers what is inside it
        self.assertEqual(Qt.CheckState(model.data(model.index(str(WORK / "fotos" / "a b.jpg")), Qt.CheckStateRole)), Qt.Checked)
        self.assertEqual(Qt.CheckState(model.data(model.index(str(WORK / "doc.txt")), Qt.CheckStateRole)), Qt.Unchecked)
        w.go_next(); pump(lambda: w.dest_edit.text()); w.go_next()
        pump(lambda: w.next_btn.isEnabled())
        last = [c for c in calls() if " copy " in c][-1]
        self.assertIn("--item fotos", last)
        shot(self.win, "04-review-items")

    def test_marking_a_folder_absorbs_what_was_marked_inside(self):
        (WORK / "fotos").mkdir(exist_ok=True)
        (WORK / "fotos" / "a b.jpg").write_text("x")
        w = self.wizard()
        w.pick_radio.setChecked(True)
        m = w.model
        pump(lambda: m.rowCount(m.index(str(WORK))) >= 1)
        m.setData(m.index(str(WORK / "fotos" / "a b.jpg")), Qt.Checked.value, Qt.CheckStateRole)
        m.setData(m.index(str(WORK / "fotos")), Qt.Checked.value, Qt.CheckStateRole)
        self.assertEqual(w.items(), ["fotos"])


class JobPageTests(Base):
    JOB = {"id": "20261030-140000-abcd", "kind": "copy", "state": "running", "state_label": "Copying", "reason": "", "reason_text": "",
           "source": "/run/media/u/ARQUIVOS", "destination": "/mnt/Backup", "current": "Fotos/IMG_1.jpg", "verify": "basic", "verify_result": "",
           "dir": str(WORK), "files_done": 1240, "files_total": 3800, "bytes_done": 54000000000, "bytes_total": 100000000000, "rate_now": 84200000,
           "rate_avg": 80000000, "elapsed": 1540, "eta": 1313, "deferred": 0, "failed": 0, "differ": 0, "conflicts": 0, "read_errors": 0, "stuck": 0,
           "created": 1, "finished": None, "total_estimate": False}

    def show(self, **kw):
        job = {**self.JOB, **kw}
        fix("status", job)
        fix("report", "== report ==\n")
        self.win.open_job(job["id"])
        pump(lambda: self.win.job_page.state == job["state"])
        return self.win.job_page

    def test_real_progress_with_a_total(self):
        page = self.show()
        self.assertEqual(page.bar.maximum(), 100)
        self.assertEqual(page.bar.value(), 54)
        joined = " ".join(texts(page))
        for expected in ("1240 / 3800", "54.0 GB / 100 GB", "84.2 MB/s", "00:21:53", "Fotos/IMG_1.jpg"):
            self.assertIn(expected, joined)
        shot(self.win, "05-progress")

    def test_without_a_total_there_is_no_percentage_and_no_eta(self):
        page = self.show(bytes_total=0, files_total=0, eta=None)
        self.assertEqual(page.bar.maximum(), 0, "a busy bar, not a made-up number")
        joined = " ".join(texts(page))
        self.assertNotIn("%", joined)
        self.assertFalse(page.values["eta"][1].isVisibleTo(page))
        shot(self.win, "06-progress-unknown")

    def test_an_estimated_total_is_marked_as_such(self):
        page = self.show(total_estimate=True)
        self.assertIn("≈", page.bar.format())
        self.assertIn("≈", page.values["copied"][1].text())

    def test_a_stuck_disk_is_said(self):
        page = self.show(stuck=40)
        self.assertIn("Waiting for the disk", page.values["current"][1].text())

    def test_buttons_follow_the_state(self):
        page = self.show()
        self.assertTrue(page.pause_btn.isVisibleTo(page))
        self.assertTrue(page.cancel_btn.isVisibleTo(page))
        self.assertFalse(page.resume_btn.isVisibleTo(page))
        page = self.show(state="stopping", state_label="Stopping")
        self.assertFalse(page.cancel_btn.isEnabled(), "cancelling twice means nothing")
        page = self.show(state="paused", state_label="Paused")
        self.assertTrue(page.resume_btn.isVisibleTo(page))
        self.assertFalse(page.pause_btn.isVisibleTo(page))

    def test_finished_with_files_left_never_looks_complete(self):
        page = self.show(state="needs-attention", state_label="Finished, needs your attention", reason="files-left",
                         reason_text="Some files were not copied.", deferred=3, failed=2, bytes_total=0)
        self.assertTrue(pump(lambda: page.report.isVisibleTo(page)))
        self.assertNotEqual(page.bar.value(), 100)
        self.assertTrue(page.retry_btn.isVisibleTo(page))
        self.assertEqual(page.values["aside"][1].text(), "3")
        self.assertEqual(page.values["failed"][1].text(), "2")
        shot(self.win, "07-needs-attention")

    def test_resume_and_retry_call_the_engine(self):
        page = self.show(state="needs-attention", state_label="x", deferred=1)
        page.retry_btn.click()
        self.assertTrue(pump(lambda: any("resume" in c and "--retry-deferred" in c for c in calls())))

    def test_an_interrupted_job_can_be_resumed(self):
        page = self.show(state="interrupted", state_label="Interrupted (it can be resumed)")
        self.assertTrue(page.resume_btn.isVisibleTo(page))

    def test_the_poll_stops_when_the_job_ends(self):
        page = self.show(state="completed", state_label="Completed and checked")
        self.assertTrue(pump(lambda: not page.timer.isActive()))


class JobsPageTests(Base):
    def test_history(self):
        fix("jobs", {"jobs": [{**JobPageTests.JOB, "state": "completed", "state_label": "Completed and checked"}]})
        self.win.show_jobs()
        self.assertTrue(pump(lambda: self.win.jobs_page.list.count() == 1))
        shot(self.win, "08-history")

    def test_an_empty_history_says_so(self):
        self.win.show_jobs()
        pump(timeout=0.3)
        self.assertTrue(self.win.jobs_page.empty.isVisibleTo(self.win.jobs_page))


class AccessibilityTests(Base):
    def test_every_button_has_a_name_and_takes_focus(self):
        page = self.win.device_page
        pump(lambda: page.diag is not None)
        for btn in page.findChildren(QPushButton):
            self.assertTrue(btn.text().replace("&", "").strip(), "a button without text")
            self.assertNotEqual(btn.focusPolicy(), Qt.NoFocus)

    def test_lists_are_named_for_screen_readers(self):
        self.assertTrue(self.win.devices.accessibleName())
        self.assertTrue(self.win.wizard.tree.accessibleName())
        self.assertTrue(self.win.job_page.bar.accessibleName())

    def test_long_text_does_not_widen_the_window(self):
        long_name = "M" * 300
        self.win.device_page.show_device(drive("/dev/sdz", long_name, volumes=[vol("/dev/sdz1", label=long_name)]))
        pump(timeout=0.2)
        self.assertLess(self.win.width(), 1400)


class SafetyTests(unittest.TestCase):
    def test_it_contains_no_operation_of_its_own(self):
        source = (REPO / "big-mount/usr/lib/big-mount/drive-gui.py").read_text()
        for word in ("subprocess", "os.system", "fsck", "mkfs", "wipefs", "shell=True", "eval(", "exec(", "sudo"):
            self.assertNotIn(word, source.replace("box.exec()", "").replace("dialog.exec()", "").replace("app.exec()", ""), word)

    def test_it_refuses_to_run_as_root(self):
        source = (REPO / "big-mount/usr/lib/big-mount/drive-gui.py").read_text()
        self.assertIn("os.geteuid() == 0", source)


if __name__ == "__main__":
    unittest.main(verbosity=1)
