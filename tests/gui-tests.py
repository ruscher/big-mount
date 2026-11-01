#!/usr/bin/python3
"""Tests of the application, off screen, on a private Broadway display.

The window talks to a stand-in for `bigmount` (BM_GUI_BIN) that answers with
fixtures and records every call, so these tests are about the window: what it
shows, what it asks the engine for, and what it refuses to pretend. No disk is
involved, nothing appears on the screen, and there is no Secure Erase here that
could touch anything: the stand-in only writes down that it was called.

Usage: python3 tests/gui-tests.py [-v] [--shots DIR]
"""

import copy
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
import unittest

os.environ["LANGUAGE"] = "C"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

SHOTS = None
if "--shots" in sys.argv:
    i = sys.argv.index("--shots")
    SHOTS = sys.argv[i + 1]
    del sys.argv[i:i + 2]

from gui_support import (Adw, CALLBACK_ERRORS, FIX, GB, Gtk, LIB, REPO, WORK, backup, calls, click, drive, find_button, find_row, fix, fix_text, forget_calls,  # noqa: E402
                         make_app, present_at, pump, seagate, shot, system_disk, text, texts, vol, widgets)

app = make_app()

import dialog as shell_dialog  # noqa: E402
from gui import dialogs as shell_dialogs  # noqa: E402
from gui.application import parse, welcome_at_start  # noqa: E402
from gui.common import ISSUES, WEBSITE, human_duration, human_size, human_time, save_setting  # noqa: E402
from gui.engine import Engine  # noqa: E402
from gui.models import Device, Job, Methods, UiState, find_device  # noqa: E402
from gui.pages.results import Index, ResultsModel  # noqa: E402
from gui.window import MainWindow  # noqa: E402

DEST = WORK / "dest"
DEST.mkdir()
SOURCE = WORK / "source"
SOURCE.mkdir()
(SOURCE / "a.txt").write_text("a")
(SOURCE / "pasta").mkdir()
(SOURCE / "pasta/b.jpg").write_text("b")

METHOD_ROWS = [{"id": "copy", "available": True, "why": "", "why_text": "", "finds": "existing", "password": False},
               {"id": "quick", "available": True, "why": "", "why_text": "", "finds": "existing", "password": False},
               {"id": "deep", "available": True, "why": "", "why_text": "", "finds": "carved", "password": True},
               {"id": "image", "available": True, "why": "", "why_text": "", "finds": "image", "password": True},
               {"id": "partitions", "available": True, "why": "", "why_text": "", "finds": "partitions", "password": True}]
METHODS = {"target": "/dev/sdb1", "source_kind": "volume", "device": "/dev/sdb1", "volume": "/dev/sdb1", "disk": "/dev/sdb", "level": "critical", "state": "unmounted",
           "mountpoint": "", "fstype": "ntfs", "recommended": "copy", "recommended_why": "Copy what matters first.", "size": 1000 * GB, "trim": False, "can_read": False, "deep_needs_image": True,
           "methods": METHOD_ROWS, "notes": [], "categories": [{"id": "photos", "label": "Photos", "deep_note": "HEIC only when searching all types."},
                                                               {"id": "videos", "label": "Videos", "deep_note": ""}]}
PREFLIGHT_OK = {"error": "", "error_text": "", "source": "s", "destination": "d", "level": "normal", "total_bytes": GB, "total_files": 3, "conflicts": 0,
                "avail": 900 * GB, "ok": True, "total_estimate": False, "same_disk": False, "scanned": True, "warnings": [{"key": "x", "text": "A warning from the engine"}]}
DESTINATIONS = {"destinations": [
    {"path": str(DEST), "device": "/dev/sda1", "level": "normal", "why": "", "name": "Backup", "fstype": "ext4", "avail": 900 * GB, "independent": True, "recommended": True},
    {"path": "/run/media/x/SAME", "device": "/dev/sdb2", "level": "normal", "why": "same-disk", "name": "SAME", "fstype": "ext4", "avail": 500 * GB, "independent": False, "recommended": False}]}


def job_json(**kw):
    base = {"id": "20261031-120000-abcd", "kind": "copy", "result_kind": "copied-files", "state": "running", "state_label": "Copying", "reason": "", "reason_text": "", "source": "/src",
            "destination": str(DEST), "name": "n", "current": "file.txt", "verify": "basic", "verify_result": "", "dir": str(WORK), "categories": "", "then_carve": "", "copy_to": "", "map": "", "level": "",
            "files_done": 3, "files_total": 0, "bytes_done": 500, "bytes_total": 1000, "rate_now": 10, "rate_avg": 10, "elapsed": 5, "eta": 50, "deferred": 0, "failed": 0, "differ": 0, "conflicts": 0,
            "read_errors": 0, "stuck": 0, "created": 1793419273, "finished": None, "scanned": 0, "pass": 0, "bad_bytes": 0, "total_estimate": False, "pausable": True}
    base.update(kw)
    return base


def leftover_items():
    """Selections written for the engine and not removed (the runtime folder is WORK)."""
    return sorted((WORK / "big-mount").glob("items-*"))


def reset():
    for path in FIX.iterdir():
        path.unlink()
    forget_calls()
    (WORK / "config/big-mount/gui.ini").unlink(missing_ok=True)
    fix("list", {"partial": False, "devices": [system_disk(), seagate(), backup(DEST)]})
    fix("jobs", {"jobs": []})
    fix("methods", METHODS)
    fix("destinations", DESTINATIONS)
    fix("copy-dry", PREFLIGHT_OK)
    fix("diagnose", {"device": seagate(), "advice": ["Copy what matters now."], "kernel": ["kernel line"], "volumes": [], "tools": {"smartctl": True}})


def new_window():
    win = MainWindow(app)
    win.present()
    assert pump(lambda: win.loaded, 6), "the list never arrived"
    pump(timeout=0.1)
    return win


class Base(unittest.TestCase):
    def setUp(self):
        reset()
        self.win = new_window()

    def tearDown(self):
        self.win.erase_running = False
        self.win.jobs = []
        dialog = self.win.get_visible_dialog()
        if dialog:
            dialog.force_close()
        self.win.close()
        pump(timeout=0.02)
        errors, CALLBACK_ERRORS[:] = list(CALLBACK_ERRORS), []
        self.assertEqual(errors, [], "exceptions in callbacks")

    def see(self, wanted, root=None, timeout=3):
        root = root or self.win
        ok = pump(lambda: wanted in text(root), timeout)
        self.assertTrue(ok, f"{wanted!r} is not on screen:\n{text(root)[:1500]}")

    def dialog(self, timeout=2):
        pump(lambda: self.win.get_visible_dialog() is not None, timeout)
        return self.win.get_visible_dialog()

    def mount_in_fixture(self, wiz):
        """As if it was mounted read-only: the next list must say the same."""
        dev = seagate()
        dev["volumes"][1].update(state="mounted-ro", state_label="Mounted read-only", mountpoint=str(SOURCE), read_only=True)
        fix("list", {"partial": False, "devices": [system_disk(), dev, backup(DEST)]})
        if wiz.plan.volume:
            wiz.plan.volume.mountpoint = str(SOURCE)
            wiz.plan.volume.state = "mounted-ro"

    def wizard_to(self, step, dev_id="serial:S1DFL8G9", method=None):
        dev = self.win.device_by_id(dev_id)
        self.win.open_wizard(dev)
        wiz = self.win.wizard
        pump(timeout=0.05)
        if step == "source":
            return wiz
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "what", 4))
        if step == "what":
            return wiz
        wiz.go_next()
        self.assertEqual(wiz.step, "how")
        if method:
            wiz.plan.method = method
        if step == "how":
            return wiz
        self.mount_in_fixture(wiz)
        wiz.go_next()
        if step == "pick":
            self.assertTrue(pump(lambda: wiz.step == "pick", 3))
            return wiz
        self.assertTrue(pump(lambda: wiz.step == "where", 3))
        self.assertTrue(pump(lambda: wiz.preflight is not None, 4))
        if step == "where":
            return wiz
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "confirm" and wiz.preflight is not None, 4))
        return wiz


class Words(unittest.TestCase):
    def test_sizes(self):
        self.assertEqual(human_size(None), "—")
        self.assertEqual(human_size(999), "999 B")
        self.assertIn("kB", human_size(1500))
        self.assertEqual(human_size(2 * 10 ** 12)[-2:], "TB")

    def test_times(self):
        self.assertEqual(human_time(3725), "01:02:05")
        self.assertEqual(human_time(None), "—")
        self.assertEqual(human_duration(30), "less than a minute")
        self.assertEqual(human_duration(600), "10 min")
        self.assertEqual(human_duration(7500), "2 h 5 min")

    def test_arguments_of_both_flags(self):
        a = parse(["x", "--target", "/dev/sdb", "--section", "health"])
        self.assertEqual((a.target, a.section), ("/dev/sdb", "health"))
        self.assertEqual(parse(["x"]).target, "")


class Models(unittest.TestCase):
    def test_a_job_says_what_it_counts(self):
        self.assertEqual(Job.from_json(job_json(kind="carve")).count_label, "Candidates found")
        self.assertEqual(Job.from_json(job_json(kind="scan")).count_label, "Files listed")
        self.assertEqual(Job.from_json(job_json(kind="copy")).count_label, "Files copied")

    def test_states(self):
        self.assertEqual(Job.from_json(job_json(state="running")).ui_state, UiState.RUNNING)
        self.assertEqual(Job.from_json(job_json(state="needs-attention")).ui_state, UiState.PARTIAL)
        self.assertEqual(Job.from_json(job_json(state="failed")).ui_state, UiState.ERROR)
        self.assertEqual(Job.from_json(job_json(state="completed")).ui_state, UiState.COMPLETED)

    def test_a_search_never_offers_to_resume_a_list_that_ended(self):
        self.assertFalse(Job.from_json(job_json(kind="carve", state="completed")).can_resume)
        self.assertTrue(Job.from_json(job_json(kind="carve", state="cancelled")).can_resume)
        self.assertTrue(Job.from_json(job_json(kind="copy", state="needs-attention")).can_resume)

    def test_identity_is_not_the_device_name(self):
        a = Device.from_json(seagate())
        moved = copy.deepcopy(seagate())
        moved["device"] = "/dev/sdz"
        b = Device.from_json(moved)
        self.assertEqual(a.stable_id, b.stable_id)
        other = Device.from_json(drive("/dev/sdb", "Another disk", serial="OTHER"))
        self.assertIsNone(find_device([other], stable_id=a.stable_id))

    def test_volumes(self):
        dev = Device.from_json(seagate())
        self.assertEqual([v.device for v in dev.content_volumes], ["/dev/sdb1"])
        self.assertEqual(dev.content_volumes[0].title, "ARQUIVOS")
        self.assertIsNone(dev.space)

    def test_unknown_fields_are_ignored(self):
        data = seagate()
        data["something_new"] = 1
        data["volumes"][0]["other"] = 2
        self.assertEqual(Device.from_json(data).device, "/dev/sdb")
        self.assertEqual(Methods.from_json(METHODS).get("deep").password, True)


class EngineClient(unittest.TestCase):
    def setUp(self):
        reset()

    def run_cmd(self, method, *args, **kw):
        out = {}
        method(*args, lambda r: out.update(r=r), **kw)
        self.assertTrue(pump(lambda: "r" in out, 4))
        return out["r"]

    def test_json_exit_and_stderr(self):
        fix("list", '{"devices": []}', rc=3)
        res = self.run_cmd(Engine().list_devices)
        self.assertEqual(res.code, 3)
        self.assertEqual(res.data, {"devices": []})

    def test_garbage_is_not_data(self):
        fix("list", "not json")
        res = self.run_cmd(Engine().list_devices)
        self.assertIsNone(res.data)
        self.assertEqual(res.code, 0)

    def test_a_program_that_is_not_there(self):
        got = {}
        Engine(program="/nonexistent/bigmount").list_devices(lambda r: got.update(r=r))
        self.assertTrue(pump(lambda: "r" in got, 3))
        self.assertEqual(got["r"].code, 127)

    def test_arguments_are_a_list_never_a_line(self):
        forget_calls()
        hostile = "/tmp/$(touch /tmp/pwned) ; rm -rf *\t'x'"
        out = {}
        Engine().mount(hostile, lambda r: out.update(r=r))
        self.assertTrue(pump(lambda: "r" in out, 3))
        self.assertIn(hostile, calls()[-1])
        self.assertFalse(os.path.exists("/tmp/pwned"))

    def test_invalid_utf8_does_not_break_it(self):
        (FIX / "list.json").write_bytes(b'{"devices": [], "x": "\xff\xfe"}')
        res = self.run_cmd(Engine().list_devices)
        self.assertEqual(res.code, 0)


class Home(Base):
    def test_lists_every_drive(self):
        self.see("Your drives and devices")
        for name in ("ST1000DM003-1CH162", "SanDisk Portable SSD", "ADATA LEGEND 800"):
            self.see(name)

    def test_never_calls_a_drive_healthy_by_itself(self):
        # Without the grade of the engine, "no alerts" is at most "Good"
        all_text = "\n".join(texts(self.win)).lower()
        self.assertNotIn("healthy", all_text)
        self.assertNotIn("saudável", all_text)
        self.see("Good")

    def test_critical_drive_comes_with_the_rescue_action(self):
        self.see("reported serious problems")
        self.assertIsNotNone(find_button(self.win, "Rescue my files"))

    def test_no_drive(self):
        fix("list", {"partial": False, "devices": []})
        self.win.refresh()
        self.see("No storage device was found.")

    def test_partial_list_says_so(self):
        fix("list", {"partial": True, "devices": [seagate()]})
        self.win.refresh()
        self.see("free space is not shown")

    def test_list_that_cannot_be_read_keeps_the_window(self):
        fix("list", "garbage", rc=1)
        self.win.refresh()
        pump(timeout=0.4)
        self.assertTrue(self.win.get_mapped())

    def test_role_stays_on_one_widget(self):
        heads = [x for x in widgets(self.win) if isinstance(x, Gtk.Label) and x.get_mapped() and x.get_text().startswith("On this computer")]
        self.assertTrue(heads)
        self.assertEqual(heads[0].get_accessible_role(), Gtk.AccessibleRole.HEADING)
        self.assertEqual(Gtk.Label().get_accessible_role(), Gtk.AccessibleRole.LABEL)
        self.assertEqual(Gtk.Image().get_accessible_role(), Gtk.AccessibleRole.IMG)

    def test_hostile_label_is_text(self):
        evil = "<b>&amp;<span foreground='red'>x"
        dev = drive("/dev/sdx", evil, volumes=[vol("/dev/sdx1", label=evil)], serial="EVIL")
        fix("list", {"partial": False, "devices": [dev]})
        self.win.refresh()
        self.see(evil)

    def test_many_devices_kinds(self):
        fix("list", {"partial": False, "devices": [
            drive("/dev/sda", "Hard disk", kind="hdd", kind_label="Hard disk", serial="H1"),
            drive("/dev/sdb", "SATA SSD", kind="ssd", kind_label="SSD", serial="H2"),
            drive("/dev/nvme0n1", "NVMe", kind="nvme", kind_label="NVMe SSD", serial="H3"),
            drive("/dev/sdc", "USB", serial="H4"),
            drive("/dev/mmcblk0", "Card", kind="sd", kind_label="SD card", serial="H5"),
            drive("/dev/loop0", "image.img", kind="image", kind_label="Disk image", serial="", level="na", label="Not applicable (a disk image)"),
            drive("/dev/sdd", "Cifrado", volumes=[vol("/dev/sdd1", fstype="crypto_LUKS", state="locked", state_label="Encrypted and locked")], serial="H6"),
        ]})
        self.win.refresh()
        for name in ("Hard disk", "SATA SSD", "NVMe", "Card", "image.img", "Cifrado"):
            self.see(name)


class HomeViews(Base):
    def rows(self):
        from gui.pages.overview import DriveCard, DriveRow
        return [x for x in widgets(self.win.overview) if isinstance(x, (DriveRow, DriveCard)) and x.get_mapped()]

    def test_a_list_by_default_and_the_grid_is_remembered(self):
        from gui.pages.overview import DriveCard, DriveRow, load_view
        self.assertEqual(self.win.overview.view, "list")
        self.assertTrue(pump(lambda: len(self.rows()) == 3, 3))
        self.assertTrue(all(isinstance(r, DriveRow) for r in self.rows()))
        self.win.overview.view_buttons["grid"].set_active(True)
        self.assertTrue(pump(lambda: self.rows() and all(isinstance(r, DriveCard) for r in self.rows()), 3))
        self.assertEqual(load_view(), "grid")
        self.win.overview.set_view("list")
        self.assertEqual(load_view(), "list")

    def test_grouped_by_where_the_drive_is(self):
        self.see("On this computer · 1")
        self.see("External devices · 2")

    def test_search_by_name_label_or_health_without_accents(self):
        ov = self.win.overview
        ov.search.set_text("arquivos")
        self.assertTrue(pump(lambda: [r.dev.name for r in self.rows()] == ["ST1000DM003-1CH162"], 3))
        ov.search.set_text("critical")
        self.assertTrue(pump(lambda: [r.dev.name for r in self.rows()] == ["ST1000DM003-1CH162"], 3))
        ov.search.set_text("nothing-like-this")
        self.see("No drive matches")
        ov.search.set_text("")
        self.assertTrue(pump(lambda: len(self.rows()) == 3, 3))

    def test_search_folds_accents(self):
        from gui.models import fold
        self.assertEqual(fold("Crítico SAÚDE"), fold("critico saude"))

    def test_the_grade_of_the_engine_is_shown_with_why(self):
        sys_disk = system_disk()
        sys_disk["health"].update(grade="healthy", grade_label="Healthy")
        usb = backup(DEST)
        usb["health"].update(grade="good", grade_label="Good", notes=[{"key": "smart-unread", "text": "Only the system log was consulted."}])
        fix("list", {"partial": False, "devices": [sys_disk, seagate(), usb]})
        self.win.refresh()
        self.see("Healthy")
        pill = next(x for x in widgets(self.win.overview) if "grade-good" in x.get_css_classes() and x.get_mapped())
        self.assertIn("Only the system log was consulted.", pill.get_tooltip_text())
        self.win.show_device("serial:SD1", "health")
        self.see("Why it is not called healthy")
        self.see("Only the system log was consulted.")

    def test_each_drive_has_its_actions_and_the_system_none_that_unmounts(self):
        def actions_of(name):
            row = next(r for r in self.rows() if r.dev.name == name)
            return set(row.drive_actions.list_actions())
        self.assertTrue(pump(lambda: len(self.rows()) == 3, 3))
        usb = actions_of("SanDisk Portable SSD")
        self.assertTrue({"unmount", "force", "remove", "erase", "health", "rescue"} <= usb, usb)
        system = actions_of("ADATA LEGEND 800")
        self.assertFalse({"unmount", "force", "remove", "erase"} & system, system)
        self.assertIn("health", system)

    def test_safe_removal_is_one_click_on_an_external_drive(self):
        self.assertTrue(pump(lambda: len(self.rows()) == 3, 3))
        row = next(r for r in self.rows() if r.dev.name == "SanDisk Portable SSD")
        fix("safe-remove", {"ok": True, "removable": True, "powered_off": True})
        forget_calls()
        button = next(b for b in widgets(row) if isinstance(b, Gtk.Button) and b.get_tooltip_text() == "Safely remove")
        button.emit("clicked")
        self.assertTrue(pump(lambda: any(c.startswith("--drive safe-remove /dev/sda") for c in calls()), 3))


class DriveActions(Base):
    BUSY = {"device": "/dev/sda1", "mountpoint": "/run/media/x/Backup", "summary": "Dolphin is showing files of this device.", "advice": "Close it.",
            "programs": [{"app": "Dolphin", "comm": "dolphin", "activity": "Current folder is on the device", "why": "", "pid": 4242, "closable": True},
                         {"app": "Terminal", "comm": "bash", "activity": "Current folder is on the device", "why": "a terminal: type 'cd' in it", "pid": 77, "closable": False}],
            "others": [], "count": 2}

    def setUp(self):
        super().setUp()
        from gui import actions
        self.actions = actions

    def test_busy_offers_to_close_the_programs_and_never_forces(self):
        fix("unmount", {"ok": False, "busy_device": "/dev/sda1", "busy_summary": "Dolphin is showing files.", "reason": ""}, rc=3)
        fix("busy", self.BUSY)
        forget_calls()
        self.actions.unmount(self.win, "/dev/sda1")
        dialog = self.dialog()
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "Dolphin" in self.win.get_visible_dialog().get_body(), 3))
        dialog = self.win.get_visible_dialog()
        self.assertEqual(dialog.get_default_response(), "cancel")
        self.assertEqual(dialog.get_close_response(), "cancel")
        self.assertIn("Will not be closed", dialog.get_body())
        self.assertTrue(dialog.has_response("close"))
        fix("close-apps", {"device": "/dev/sda1", "asked": ["Dolphin"], "kept": [], "still_running": 0, "ok": True})
        fix("unmount", {"ok": True}, rc=0)
        forget_calls()
        dialog.emit("response", "close")
        self.assertTrue(pump(lambda: "--drive close-apps /dev/sda1 --json" in calls() and calls()[-1].startswith("--drive unmount /dev/sda1"), 4), calls())
        self.assertFalse(any("-f" in c.split() or "--force" in c or "-l" in c.split() for c in calls()))

    def test_nothing_closable_offers_no_closing(self):
        busy = dict(self.BUSY, programs=[self.BUSY["programs"][1]])
        fix("unmount", {"ok": False, "busy_device": "/dev/sda1", "reason": ""}, rc=3)
        fix("busy", busy)
        self.actions.unmount(self.win, "/dev/sda1")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "Terminal" in self.win.get_visible_dialog().get_body(), 3))
        self.assertFalse(self.win.get_visible_dialog().has_response("close"))

    def test_programs_that_did_not_close_stop_everything(self):
        fix("busy", self.BUSY)
        fix("close-apps", {"device": "/dev/sda1", "asked": ["Dolphin"], "kept": [], "still_running": 1, "ok": False}, rc=1)
        self.actions.force_unmount(self.win, "/dev/sda1")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() is not None, 3))
        forget_calls()
        self.win.get_visible_dialog().emit("response", "close")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "did not close" in self.win.get_visible_dialog().get_heading(), 3))
        self.assertFalse(any(c.startswith("--drive unmount") for c in calls()))

    def test_force_without_holders_simply_unmounts(self):
        fix("busy", dict(self.BUSY, programs=[], count=0))
        fix("unmount", {"ok": True})
        forget_calls()
        self.actions.force_unmount(self.win, "/dev/sda1")
        self.assertTrue(pump(lambda: any(c.startswith("--drive unmount /dev/sda1") for c in calls()), 3))
        self.assertFalse(any("close-apps" in c for c in calls()))

    def test_services_are_asked_before_they_are_stopped(self):
        fix("unmount", {"ok": False, "services": [{"unit": "jellyfin.service", "name": "Jellyfin"}], "services_back": "They start again by themselves."}, rc=9)
        self.actions.unmount(self.win, "/dev/sda1")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "Jellyfin" in self.win.get_visible_dialog().get_body(), 3))
        dialog = self.win.get_visible_dialog()
        self.assertEqual(dialog.get_default_response(), "cancel")
        fix("unmount", {"ok": True})
        forget_calls()
        dialog.emit("response", "stop")
        self.assertTrue(pump(lambda: "--drive unmount /dev/sda1 --allow-services --json" in calls(), 3), calls())

    def test_erasing_warns_first_and_cancel_is_the_default(self):
        dev = self.win.device_by_id("serial:SD1")
        self.actions.erase(self.win, dev)
        dialog = self.dialog()
        self.assertIn("not recovery", dialog.get_body())
        self.assertEqual(dialog.get_default_response(), "cancel")
        self.assertEqual(dialog.get_close_response(), "cancel")
        self.assertEqual(dialog.get_response_appearance("continue"), Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.emit("response", "cancel")
        pump(timeout=0.1)
        self.assertNotEqual(type(self.win.nav.get_visible_page()).__name__, "MaintenancePage")
        self.actions.erase(self.win, dev)
        fix("erase-check", {"device": "/dev/sda", "eligible": False, "why": "removable", "why_text": "Not through USB.", "partitions": []})
        self.dialog().emit("response", "continue")
        self.assertTrue(pump(lambda: type(self.win.nav.get_visible_page()).__name__ == "MaintenancePage", 3))


class Sidebar(Base):
    JOB = {"id": "20261031-1", "kind": "copy", "state": "running", "state_label": "Copying", "source": "/run/media/x/ARQUIVOS", "name": "ARQUIVOS",
           "destination": "/run/media/x/Backup", "bytes_done": 25 * GB, "bytes_total": 100 * GB, "total_estimate": False, "pausable": True}

    def side_rows(self, kind):
        out, i = [], 0
        while (row := self.win.side_list.get_row_at_index(i)) is not None:
            if row.kind == kind:
                out.append(row)
            i += 1
        return out

    def test_count_and_running_jobs_with_their_progress(self):
        done = dict(self.JOB, id="old", state="completed", state_label="Completed")
        search = dict(self.JOB, id="20261031-2", kind="carve", state_label="Searching", name="disk.img", bytes_total=0)
        fix("jobs", {"jobs": [self.JOB, search, done]})
        fix("status", self.JOB)
        self.win.refresh_jobs()
        self.assertTrue(pump(lambda: len(self.side_rows("job")) == 2, 3))
        jobs_row = self.side_rows("jobs")[0]
        self.assertIn("3", text(jobs_row))
        self.assertIn("2 running", text(jobs_row))
        first = self.side_rows("job")[0]
        self.assertIn("25%", text(first))
        bar = next(x for x in widgets(first) if isinstance(x, Gtk.ProgressBar))
        self.assertAlmostEqual(bar.get_fraction(), 0.25)
        # Without a measured total: no percentage at all
        self.assertNotIn("%", text(self.side_rows("job")[1]))
        self.win.side_list.emit("row-activated", first)
        self.assertTrue(pump(lambda: type(self.win.nav.get_visible_page()).__name__ == "JobPage", 3))
        self.assertEqual(self.win.nav.get_visible_page().job_id, "20261031-1")
        self.assertEqual(self.win.side_list.get_selected_row().value, "20261031-1")

    def test_no_job_shows_zero_and_nothing_below(self):
        self.assertTrue(pump(lambda: self.side_rows("jobs"), 3))
        self.assertIn("0", text(self.side_rows("jobs")[0]))
        self.assertEqual(self.side_rows("job"), [])


class Routing(Base):
    def go(self, target, section, answer):
        fix("resolve", answer, rc=0 if answer.get("ok") else 24)
        self.win.route(target, section)

    def test_the_alias_opens_the_same_window_on_health(self):
        self.go("/dev/sdb", "health", {"ok": True, "disk": "/dev/sdb", "device": "/dev/sdb"})
        self.assertTrue(pump(lambda: self.win.nav.get_visible_page() is self.win.device_page, 3))
        self.assertEqual(self.win.device_page.stack.get_visible_child_name(), "health")

    def test_a_partition_or_folder_selects_its_drive(self):
        self.go("/run/media/x/ARQUIVOS", "", {"ok": True, "disk": "/dev/sdb", "device": "/dev/sdb1"})
        self.assertTrue(pump(lambda: self.win.nav.get_visible_page() is self.win.device_page, 3))
        self.assertEqual(self.win.device_page.stack.get_visible_child_name(), "overview")
        self.assertEqual(self.win.selected_id, "serial:S1DFL8G9")

    def test_uuid_and_by_id_go_through_the_engine(self):
        forget_calls()
        self.go("UUID=ABCD-1234", "", {"ok": True, "disk": "/dev/sdb"})
        self.assertTrue(pump(lambda: any("resolve UUID=ABCD-1234" in c for c in calls()), 3))

    def test_ambiguous_or_missing_target_is_said_and_goes_home(self):
        self.go("UUID=SAME", "health", {"ok": False, "error_text": "more than one device has this UUID"})
        self.assertTrue(pump(lambda: "more than one" in " ".join(w.get_title() for w in widgets(self.win) if isinstance(w, Adw.Toast)) or self.win.nav.get_visible_page() is self.win.overview, 3))
        self.assertIs(self.win.nav.get_visible_page(), self.win.overview)

    def test_second_invocation_reuses_the_window(self):
        self.go("/dev/sda", "", {"ok": True, "disk": "/dev/sda"})
        pump(lambda: self.win.selected_id == "serial:SD1", 3)
        self.go("/dev/sdb", "health", {"ok": True, "disk": "/dev/sdb"})
        self.assertTrue(pump(lambda: self.win.selected_id == "serial:S1DFL8G9", 3))
        self.assertEqual(self.win.device_page.stack.get_visible_child_name(), "health")

    def test_only_one_toolkit_in_the_code(self):
        code = "".join(p.read_text() for p in (LIB / "gui").rglob("*.py")) + (LIB / "drive-gui.py").read_text()
        for bad in ("PySide", "PyQt", "QtWidgets", "QML", "WebKit", "shell=True", "os.system", "Electron"):
            self.assertNotIn(bad, code)


class Hotplug(Base):
    def test_a_new_drive_appears(self):
        fix("list", {"partial": False, "devices": [seagate(), drive("/dev/sde", "New one", serial="NEW")]})
        self.win.monitor.poke()
        self.see("New one", timeout=3)

    def test_selection_follows_the_drive_not_the_name(self):
        self.win.show_device("serial:S1DFL8G9")
        moved = seagate()
        moved["device"] = "/dev/sdz"
        fix("list", {"partial": False, "devices": [moved]})
        self.win.refresh()
        self.assertTrue(pump(lambda: self.win.device_page.dev and self.win.device_page.dev.device == "/dev/sdz", 3))
        self.assertEqual(self.win.device_page.content.get_visible_child_name(), "drive")

    def test_another_disk_under_the_same_name_is_not_the_same_disk(self):
        self.win.show_device("serial:S1DFL8G9")
        fix("list", {"partial": False, "devices": [drive("/dev/sdb", "Other disk", serial="OTHER")]})
        self.win.refresh()
        self.assertTrue(pump(lambda: self.win.device_page.content.get_visible_child_name() == "gone", 3))
        self.see("The drive was disconnected")

    def test_comes_back(self):
        self.win.show_device("serial:S1DFL8G9")
        fix("list", {"partial": False, "devices": []})
        self.win.refresh()
        pump(lambda: self.win.device_page.content.get_visible_child_name() == "gone", 3)
        fix("list", {"partial": False, "devices": [seagate()]})
        self.win.refresh()
        self.assertTrue(pump(lambda: self.win.device_page.content.get_visible_child_name() == "drive", 3))

    def test_wizard_never_continues_with_a_drive_that_left(self):
        wiz = self.wizard_to("how")
        fix("list", {"partial": False, "devices": [drive("/dev/sdb", "Other disk", serial="OTHER")]})
        self.win.refresh()
        self.assertTrue(pump(lambda: wiz.step == "source", 3))
        self.assertIsNone(wiz.plan.device)
        self.assertFalse(wiz.next_btn.get_sensitive())


class Health(Base):
    def open(self):
        self.win.show_device("serial:S1DFL8G9", "health")
        pump(timeout=0.2)

    def test_critical_says_copy_first_and_offers_rescue(self):
        self.open()
        self.see("Copy your files to another drive before trying any repair")
        self.assertIn("suggested-action", find_button(self.win, "Rescue my files").get_css_classes())

    def test_not_read_is_not_no_alert(self):
        dev = drive("/dev/sdf", "Fresh", level="unknown", label="Unknown: not enough information", basis="none", serial="F1")
        fix("list", {"partial": False, "devices": [dev]})
        self.win.refresh()
        pump(lambda: self.win.device_by_id("serial:F1"), 3)
        self.win.show_device("serial:F1", "health")
        self.see("Not examined yet")
        self.see("Not read")

    def test_normal_never_means_healthy(self):
        dev = drive("/dev/sdf", "Calm", serial="F2")
        fix("list", {"partial": False, "devices": [dev]})
        self.win.refresh()
        pump(lambda: self.win.device_by_id("serial:F2"), 3)
        self.win.show_device("serial:F2", "health")
        self.see("No alert was found in the information consulted")
        self.see("was not read")

    def test_smart_values_with_their_origin(self):
        dev = drive("/dev/sdf", "Read", level="critical", label="Critical", serial="F3", basis="smart+log",
                    smart={"verdict": "passed", "pending": 12, "hours": 900, "read_at": 1793419273})
        fix("list", {"partial": False, "devices": [dev]})
        self.win.refresh()
        pump(lambda: self.win.device_by_id("serial:F3"), 3)
        self.win.show_device("serial:F3", "health")
        self.see("Read at")
        self.assertIsNotNone(pump(lambda: find_row(self.win, "Sectors waiting to be replaced"), 2))

    def test_serial_hidden_by_default(self):
        self.open()
        pump(timeout=0.3)
        self.assertNotIn("S1DFL8G9", text(self.win))

    def test_smart_only_on_request(self):
        forget_calls()
        self.open()
        pump(timeout=0.4)
        self.assertFalse(any("--smart" in c for c in calls()))
        click(self.win, "Read SMART…")
        self.assertTrue(pump(lambda: any("--smart" in c for c in calls()), 3))

    def test_smart_stays_with_its_drive(self):
        self.open()
        health = self.win.device_page.health
        self.assertTrue(pump(lambda: health.diag is not None, 3))
        fix("diagnose", {"device": seagate(), "advice": ["Advice for the Seagate"], "kernel": [], "volumes": [], "tools": {"smartctl": True}}, delay=0.5)
        click(self.win, "Read SMART…")
        self.win.show_device("serial:SD1", "health")
        self.assertTrue(pump(lambda: not health.smart_busy, 4))
        pump(timeout=0.3)
        self.assertIsNone(health.diag)
        self.assertNotIn("Advice for the Seagate", text(self.win))

    def test_missing_smartctl_is_explained(self):
        fix("diagnose", {"device": seagate(), "advice": [], "kernel": [], "volumes": [], "tools": {"smartctl": False}})
        self.open()
        self.see("smartctl is not installed")

    def test_maintenance_is_far_from_the_first_level(self):
        self.win.show_device("serial:S1DFL8G9")
        pump(timeout=0.2)
        self.assertNotIn("Erase", text(self.win).replace("Erase data permanently", ""))
        self.assertIsNone(find_button(self.win, "Erase the whole drive"))


class Volumes(Base):
    def test_mount_is_read_only_and_names_the_disk_it_saw(self):
        self.win.show_device("serial:S1DFL8G9")
        pump(timeout=0.2)
        click(self.win, "Mount read-only")
        dialog = self.dialog()
        self.assertIsNotNone(dialog)
        forget_calls()
        fix("mount", {"ok": True, "mountpoint": "/run/media/x/A", "read_only": True})
        dialog.emit("response", "mount")
        self.assertTrue(pump(lambda: any(c.startswith("--drive mount") for c in calls()), 3))
        call = next(c for c in calls() if c.startswith("--drive mount"))
        self.assertIn("--read-only", call)
        self.assertIn("--expect-diskseq 7", call)
        self.assertIn("--protect", call, "at risk: writing blocked at the device, on by default")

    def test_mount_on_a_healthy_drive_does_not_ask_for_the_password_by_default(self):
        dev = drive("/dev/sdf", "Calm", serial="F2", volumes=[vol("/dev/sdf1", label="V")])
        fix("list", {"partial": False, "devices": [dev]})
        self.win.refresh()
        pump(lambda: self.win.device_by_id("serial:F2"), 3)
        self.win.show_device("serial:F2")
        pump(timeout=0.2)
        click(self.win, "Mount read-only")
        dialog = self.dialog()
        forget_calls()
        fix("mount", {"ok": True, "mountpoint": "/run/media/x/A", "read_only": True})
        dialog.emit("response", "mount")
        self.assertTrue(pump(lambda: any(c.startswith("--drive mount") for c in calls()), 3))
        self.assertNotIn("--protect", next(c for c in calls() if c.startswith("--drive mount")))

    def test_failed_mount_is_explained_in_plain_words(self):
        self.win.show_device("serial:S1DFL8G9")
        pump(timeout=0.2)
        click(self.win, "Mount read-only")
        fix("mount", {"ok": False, "why": "io-error", "text": "The drive could not read the start of this filesystem.", "detail": "tech"}, rc=1)
        self.dialog().emit("response", "mount")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "could not read" in self.win.get_visible_dialog().get_body(), 3))

    def test_busy_unmount_says_who(self):
        dev = backup(DEST)
        fix("list", {"partial": False, "devices": [dev]})
        self.win.refresh()
        pump(lambda: self.win.device_by_id("serial:SD1"), 3)
        self.win.show_device("serial:SD1")
        pump(timeout=0.2)
        fix("unmount", {"ok": False, "busy_summary": "Dolphin is showing files.", "busy_advice": "Close it.", "reason": ""}, rc=3)
        click(self.win, "Unmount")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "Dolphin" in self.win.get_visible_dialog().get_body(), 3))

    def test_locked_volume_offers_unlock_and_keeps_the_passphrase_out_of_arguments(self):
        dev = drive("/dev/sdf", "Crypt", serial="F9", volumes=[vol("/dev/sdf1", fstype="crypto_LUKS", state="locked", state_label="Encrypted and locked")])
        fix("list", {"partial": False, "devices": [dev]})
        self.win.refresh()
        pump(lambda: self.win.device_by_id("serial:F9"), 3)
        self.win.show_device("serial:F9")
        pump(timeout=0.2)
        forget_calls()
        click(self.win, "Unlock…")
        dialog = self.dialog()
        self.assertIsNotNone(dialog)
        entry = dialog.get_extra_child()
        self.assertIsInstance(entry, Gtk.PasswordEntry)
        entry.set_text("segredo")
        dialog.emit("response", "cancel")
        pump(timeout=0.2)
        self.assertFalse(any("segredo" in c for c in calls()))
        self.assertEqual(entry.get_text(), "")


class Wizard(Base):
    def test_starts_on_the_only_volume_of_the_drive(self):
        wiz = self.wizard_to("source")
        self.assertEqual(wiz.plan.volume.device, "/dev/sdb1")
        self.assertTrue(wiz.next_btn.get_sensitive())

    def test_engine_decides_the_methods(self):
        forget_calls()
        wiz = self.wizard_to("how")
        self.assertTrue(any("methods /dev/sdb1" in c for c in calls()))
        self.assertEqual(wiz.plan.method, "copy")
        self.see("Recommended")
        self.see("Copy what matters first.")

    def test_unavailable_method_says_why_and_cannot_go_on(self):
        rows = copy.deepcopy(METHOD_ROWS)
        rows[2].update(available=False, why="no-ddrescue", why_text="GNU ddrescue is not installed (package ddrescue).")
        fix("methods", {**METHODS, "methods": rows})
        wiz = self.wizard_to("how", method="deep")
        wiz._enter("how")
        self.see("GNU ddrescue is not installed")
        self.assertFalse(wiz.next_btn.get_sensitive())

    def test_nothing_recommended_available_falls_to_what_is(self):
        rows = copy.deepcopy(METHOD_ROWS)
        rows[0].update(available=False, why="no-rsync", why_text="rsync is not installed")
        fix("methods", {**METHODS, "methods": rows})
        wiz = self.wizard_to("how")
        self.assertEqual(wiz.plan.method, "quick")

    def test_going_back_loses_nothing(self):
        wiz = self.wizard_to("what")
        wiz.plan.categories = {"photos"}
        wiz.go_next()
        wiz.plan.method = "quick"
        wiz.go_back()
        self.assertEqual(wiz.step, "what")
        self.assertEqual(wiz.plan.categories, {"photos"})
        self.assertTrue(wiz._choice["photos"].get_active())
        wiz.go_next()
        self.assertEqual(wiz.plan.method, "quick")

    def test_all_excludes_the_types(self):
        wiz = self.wizard_to("what")
        wiz._choice["photos"].set_active(True)
        self.assertEqual(wiz.plan.categories, {"photos"})
        self.assertFalse(wiz._choice["all"].get_active())
        wiz._choice["all"].set_active(True)
        self.assertEqual(wiz.plan.categories, {"all"})
        self.assertFalse(wiz._choice["photos"].get_active())
        wiz._choice["all"].set_active(False)
        self.assertTrue(wiz._choice["all"].get_active(), "there is always a choice")

    def test_what_a_type_cannot_find_is_said_before(self):
        wiz = self.wizard_to("what")
        wiz._choice["photos"].set_active(True)
        self.see("HEIC only when searching all types.")

    def test_same_disk_has_no_button_at_all(self):
        wiz = self.wizard_to("where")
        row = find_row(self.win, "SAME")
        self.assertIsNotNone(row)
        self.assertFalse(row.get_sensitive())
        self.see("same physical disk as the source")
        self.assertFalse(any(isinstance(x, Gtk.CheckButton) and x.get_sensitive() and x.get_mapped() and x.is_ancestor(row) for x in widgets(row)))
        self.assertEqual(wiz.plan.dest_base, str(DEST))

    def test_refusal_of_a_folder_blocks_next_and_shows_the_reason(self):
        wiz = self.wizard_to("where")
        fix("copy-dry", {"ok": False, "error": "same-disk", "error_text": "The destination is on the same physical disk as the source.", "warnings": []}, rc=20)
        wiz._set_dest("/run/media/x/SAME/pasta", True)
        self.see("same physical disk")
        self.assertFalse(wiz.next_btn.get_sensitive())
        self.assertIsNone(find_button(self.win, "Use the same physical disk anyway"))

    def test_no_override_is_ever_passed(self):
        forget_calls()
        wiz = self.wizard_to("confirm")
        self.assertTrue(wiz.next_btn.get_sensitive())
        for c in calls():
            self.assertNotIn("--allow-same-disk", c)
            self.assertNotIn("--allow-rw-source", c)
            self.assertNotIn("--allow-risky-destination", c)

    def test_rw_source_on_a_risky_drive_offers_the_safe_way(self):
        wiz = self.wizard_to("where")
        fix("copy-dry", {"ok": False, "error": "rw-source", "error_text": "This drive is at risk and is mounted with writing enabled.", "warnings": []}, rc=20)
        wiz._set_dest(str(DEST), False)
        self.assertTrue(pump(lambda: find_button(self.win, "Unmount and mount read-only") is not None, 3))
        self.assertFalse(wiz.next_btn.get_sensitive())

    def test_summary_shows_engine_numbers_and_warnings(self):
        self.wizard_to("confirm")
        self.see("A warning from the engine")
        self.see("Nothing is written to the source")
        self.see("Free at the destination", timeout=1)

    def test_start_copy_only_with_consent_and_exact_arguments(self):
        forget_calls()
        wiz = self.wizard_to("confirm")
        self.assertFalse(any(c.startswith("--drive copy") and "--dry-run" not in c for c in calls()), "nothing before Start")
        fix("copy", {"id": "20261031-120000-abcd"})
        fix("status", job_json())
        wiz.go_next()
        self.assertTrue(pump(lambda: any(c.startswith("--drive copy") and "--no-wait" in c for c in calls()), 3))
        call = next(c for c in calls() if "--no-wait" in c and c.startswith("--drive copy"))
        self.assertIn(f"--source {SOURCE}", call)
        self.assertIn(f"--destination {DEST}/Recovered files", call)
        self.assertTrue(pump(lambda: type(self.win.nav.get_visible_page()).__name__ == "JobPage", 3))

    def test_refused_start_is_told(self):
        wiz = self.wizard_to("confirm")
        fix("copy", {"ok": False, "error": "no-space", "error_text": "There is not enough free space at the destination.", "warnings": []}, rc=21)
        wiz.go_next()
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "not enough free" in self.win.get_visible_dialog().get_body(), 3))
        self.assertEqual(wiz.step, "confirm")

    def test_quick_analysis_lists_first_and_keeps_the_destination(self):
        forget_calls()
        wiz = self.wizard_to("what")
        wiz._choice["photos"].set_active(True)
        wiz.go_next()
        wiz.plan.method = "quick"
        self.mount_in_fixture(wiz)
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.preflight is not None, 3))
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "confirm" and wiz.preflight is not None, 3))
        fix("scan", {"id": "20261031-120000-abcd"})
        fix("status", job_json(kind="scan", state="analyzing", state_label="Listing the files", bytes_total=0, pausable=False))
        wiz.go_next()
        self.assertTrue(pump(lambda: any(c.startswith("--drive scan") for c in calls()), 3))
        call = next(c for c in calls() if c.startswith("--drive scan"))
        self.assertIn("--categories photos", call)
        self.assertIn(f"--copy-to {DEST}", call)

    def test_deep_on_a_physical_disk_is_an_image_first(self):
        fix("image-dry", {"ok": True, "error": "", "error_text": "", "avail": 2000 * GB, "total_bytes": 1000 * GB, "warnings": []})
        fix("image", {"id": "20261031-120000-abcd"})
        fix("status", job_json(kind="image", state="running", state_label="Making the disk image", then_carve="x"))
        forget_calls()
        wiz = self.wizard_to("what")
        wiz._choice["photos"].set_active(True)
        wiz.go_next()
        wiz.plan.method = "deep"
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "where" and wiz.preflight is not None, 3))
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "confirm" and wiz.preflight is not None, 3))
        self.see("the search needs your confirmation")
        self.assertFalse(any(c.startswith("--drive image") and "--no-wait" in c for c in calls()))
        wiz.go_next()
        self.assertTrue(pump(lambda: any("--no-wait" in c and c.startswith("--drive image") for c in calls()), 3))
        call = next(c for c in calls() if "--no-wait" in c and c.startswith("--drive image"))
        self.assertIn("--expect-diskseq 7", call)
        self.assertIn("--then-carve", call)
        self.assertIn("--categories photos", call)

    def test_deep_on_an_image_searches_directly(self):
        image = WORK / "disk.img"
        image.write_bytes(b"\0" * 16)
        fix("methods", {**METHODS, "source_kind": "image", "level": "na", "recommended": "deep", "deep_needs_image": False, "can_read": True})
        fix("carve-dry", {"ok": True, "error": "", "error_text": "", "avail": 500 * GB, "total_bytes": 0, "warnings": [{"key": "carve-names", "text": "Names are lost."}]})
        self.win.open_wizard(image=str(image))
        wiz = self.win.wizard
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "what", 3))
        wiz.go_next()
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "where" and wiz.preflight is not None, 4))
        self.assertTrue(wiz.next_btn.get_sensitive())
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "confirm" and wiz.preflight is not None, 4))
        self.see("Names are lost.")
        self.see("finding nothing is possible")

    def test_choose_files_marks_real_paths(self):
        wiz = self.wizard_to("how")
        wiz.plan.method = "copy"
        wiz.plan.scope = "choose"
        self.mount_in_fixture(wiz)
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "pick", 3))
        self.assertFalse(wiz.next_btn.get_sensitive(), "nothing marked yet")
        wiz.picker.marked.add(str(SOURCE / "pasta"))
        wiz._sync_nav()
        self.assertEqual(wiz.picker.items(), ["pasta"])
        self.assertTrue(wiz.next_btn.get_sensitive())
        forget_calls()
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "where" and wiz.preflight is not None, 3))
        self.assertTrue(any("--items-from" in c for c in calls()))
        self.assertEqual((WORK / "last-items").read_bytes(), b"pasta\0")
        self.assertTrue(pump(lambda: leftover_items() == [], 3), "each check removes its selection")

    def test_partitions_only_reads(self):
        wiz = self.wizard_to("how", method="partitions")
        fix("partitions", {"ok": True, "mode": "list", "found": [{"type": "Linux", "label": "LOST", "start": "0/32/33", "sectors": 2048, "size": 1048576}]})
        wiz.go_next()
        page = self.win.nav.get_visible_page()
        self.assertEqual(type(page).__name__, "PartitionsPage")
        forget_calls()
        click(page, "Read the partition table")
        self.see("LOST", page)
        self.see("does not rewrite partition tables", page)
        self.assertEqual(next(c for c in calls() if "partitions" in c), "--drive partitions /dev/sdb --json")

    def test_partitions_search_that_finds_nothing_promises_nothing(self):
        wiz = self.wizard_to("how", method="partitions")
        fix("partitions", {"ok": True, "mode": "search", "found": []})
        wiz.go_next()
        page = self.win.nav.get_visible_page()
        click(page, "Analyze the whole disk")
        self.see("does not prove there is no data", page)

    def whole_drive_to_how(self, rows):
        fix("methods", {**METHODS, "target": "/dev/sdb", "source_kind": "disk", "volume": "", "recommended": "image", "methods": rows})
        wiz = self.wizard_to("source")
        wiz.plan.volume = None
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "what", 4))
        wiz.go_next()
        self.assertEqual(wiz.step, "how")
        return wiz

    def test_whole_drive_leads_to_its_volume(self):
        # What a person met on a real disk: only lost partitions could be chosen
        rows = copy.deepcopy(METHOD_ROWS)
        for r in rows[:2]:
            r.update(available=False, why="pick-volume", why_text="Choose one of the volumes of this drive to see its files.")
        wiz = self.whole_drive_to_how(rows)
        self.see("You chose the whole drive")
        self.see("Not available: Choose one of the volumes")
        fix("methods", METHODS)
        forget_calls()
        click(wiz, "Use the volume ARQUIVOS")
        self.assertTrue(pump(lambda: wiz.plan.methods is not None and wiz.plan.volume is not None, 3))
        self.assertTrue(any("methods /dev/sdb1" in c for c in calls()))
        self.assertEqual(wiz.step, "how")
        self.assertEqual(wiz.plan.method, "copy")
        self.assertTrue(wiz.next_btn.get_sensitive())
        self.assertNotIn("You chose the whole drive", text(wiz))

    def test_the_row_of_a_method_offers_the_volume(self):
        rows = copy.deepcopy(METHOD_ROWS)
        rows[0].update(available=False, why="pick-volume", why_text="Choose one of the volumes of this drive to see its files.")
        wiz = self.whole_drive_to_how(rows)
        fix("methods", METHODS)
        click(wiz, "Use ARQUIVOS")
        self.assertTrue(pump(lambda: wiz.plan.volume is not None and wiz.plan.methods is not None, 3))
        self.assertEqual(wiz.plan.volume.device, "/dev/sdb1")

    def test_missing_tool_can_be_checked_again_after_installing(self):
        rows = copy.deepcopy(METHOD_ROWS)
        rows[2].update(available=False, why="no-ddrescue", why_text="GNU ddrescue is not installed (package ddrescue).")
        fix("methods", {**METHODS, "methods": rows})
        wiz = self.wizard_to("how", method="deep")
        wiz._enter("how")
        self.assertFalse(wiz.next_btn.get_sensitive())
        fix("methods", METHODS)
        forget_calls()
        click(wiz, "Check again")
        self.assertTrue(pump(lambda: any("methods /dev/sdb1" in c for c in calls()) and wiz.plan.methods is not None, 3))
        self.assertEqual(wiz.plan.method, "deep")
        self.assertTrue(wiz.next_btn.get_sensitive())

    def test_partitions_lead_back_to_the_files_of_a_volume(self):
        wiz = self.wizard_to("how", method="partitions")
        fix("partitions", {"ok": True, "mode": "list", "found": [{"type": "HPFS - NTFS", "label": "ARQUIVOS", "start": "0/32/33", "sectors": 2048, "size": 1048576}]})
        wiz.go_next()
        page = self.win.nav.get_visible_page()
        self.see("Volumes this drive already has", page)
        click(page, "Read the partition table")
        self.see("ARQUIVOS", page)
        forget_calls()
        click(page, "Recover its files")
        self.assertTrue(pump(lambda: self.win.nav.get_visible_page() is wiz and wiz.plan.methods is not None, 3))
        self.assertEqual(wiz.step, "how")
        self.assertEqual(wiz.plan.volume.device, "/dev/sdb1")
        self.assertTrue(any("methods /dev/sdb1" in c for c in calls()))

    def test_partitions_search_shows_time_and_says_there_is_no_percentage(self):
        wiz = self.wizard_to("how", method="partitions")
        fix("partitions", {"ok": True, "mode": "search", "found": []}, delay=1.5)
        wiz.go_next()
        page = self.win.nav.get_visible_page()
        click(page, "Analyze the whole disk")
        self.see("Elapsed: 00:00:0", page)
        self.see("there is no percentage", page)
        self.see("does not prove there is no data", page, timeout=5)
        self.assertIsNone(page._timer)

    def test_no_destination_available(self):
        fix("destinations", {"destinations": []})
        self.wizard_to("how")
        wiz = self.win.wizard
        self.mount_in_fixture(wiz)
        wiz.go_next()
        self.see("No other disk is mounted")
        self.assertFalse(wiz.next_btn.get_sensitive())

    def test_source_unmounted_meanwhile_goes_back_and_says_so(self):
        wiz = self.wizard_to("where")
        fix("list", {"partial": False, "devices": [system_disk(), seagate(), backup(DEST)]})
        self.win.refresh()
        self.assertTrue(pump(lambda: wiz.step == "how", 3))

    def test_trim_is_told_before(self):
        fix("methods", {**METHODS, "trim": True, "notes": [{"key": "trim", "text": "This SSD erases deleted blocks by itself (TRIM)."}]})
        self.wizard_to("how")
        self.see("TRIM")


class Jobs(Base):
    def open(self, **kw):
        fix("status", job_json(**kw))
        self.win.open_job("20261031-120000-abcd")
        pump(lambda: self.win.nav.get_visible_page().job is not None, 3)
        return self.win.nav.get_visible_page()

    def test_percentage_only_from_real_numbers(self):
        page = self.open(bytes_done=500, bytes_total=1000)
        self.assertEqual(page.percent.get_text(), "50%")
        self.assertAlmostEqual(page.bar.get_fraction(), 0.5)

    def test_no_total_no_percentage(self):
        page = self.open(bytes_total=0, bytes_done=500)
        self.assertEqual(page.percent.get_text(), "")
        self.see("to avoid extra reads")

    def test_estimate_is_marked(self):
        page = self.open(total_estimate=True)
        self.assertTrue(page.percent.get_text().startswith("≈"))

    def test_a_search_never_says_recovered(self):
        page = self.open(kind="carve", result_kind="carved-candidates", state_label="Searching by content", pass_=1, pausable=False)
        self.see("Candidates found", page)
        all_text = text(page).lower()
        self.assertNotIn("recovered", all_text)
        self.assertNotIn("deleted files", all_text)

    def test_a_search_cannot_be_paused(self):
        page = self.open(kind="carve", pausable=False)
        self.assertFalse(page.pause_btn.get_visible())
        self.assertTrue(page.cancel_btn.get_visible())

    def test_copy_can_pause_and_resume(self):
        page = self.open()
        self.assertTrue(page.pause_btn.get_visible())
        forget_calls()
        page.pause_btn.emit("clicked")
        self.assertTrue(pump(lambda: any("pause" in c for c in calls()), 3))
        fix("status", job_json(state="paused", state_label="Paused"))
        self.assertTrue(pump(lambda: page.job.state == "paused", 4))
        self.assertTrue(page.resume_btn.get_visible())
        self.assertFalse(page.pause_btn.get_visible())

    def test_cancel_asks_and_the_safe_answer_is_default(self):
        page = self.open()
        page.cancel_btn.emit("clicked")
        dialog = self.dialog()
        self.assertEqual(dialog.get_default_response(), "keep")
        self.assertEqual(dialog.get_close_response(), "keep")

    def test_stuck_disk_is_said_without_calling_it_a_crash(self):
        self.open(stuck=30)
        self.see("Waiting for the disk to answer")

    def test_finished_with_problems_is_not_success(self):
        fix_text("report", "the report")
        page = self.open(state="needs-attention", state_label="Finished, needs your attention", reason="files-left", reason_text="Some files were not copied.", failed=3, deferred=2)
        self.see("Some files were not copied.", page)
        self.assertTrue(page.retry_btn.get_visible())
        self.assertTrue(page.resume_btn.get_visible())
        self.assertEqual(page.stat["failed"].value.get_text(), "3")

    def test_scan_results_cta(self):
        fix_text("report", "the report")
        page = self.open(kind="scan", state="completed", state_label="List of files complete", files_done=5, bytes_total=0, pausable=False)
        self.assertTrue(page.results_btn.get_visible())
        self.assertFalse(page.resume_btn.get_visible())

    def test_image_with_a_search_next_needs_consent(self):
        fix_text("report", "the report")
        forget_calls()
        page = self.open(kind="image", state="completed", state_label="Disk image complete", destination=str(DEST / "a.img"), then_carve=str(DEST / "found"), categories="photos")
        self.assertTrue(page.next_btn.get_visible())
        self.assertFalse(any(c.startswith("--drive carve") for c in calls()), "never by itself")
        fix("carve", {"id": "20261031-120000-beef"})
        page.next_btn.emit("clicked")
        self.assertTrue(pump(lambda: any(c.startswith("--drive carve") for c in calls()), 3))
        self.assertIn("--categories photos", next(c for c in calls() if c.startswith("--drive carve")))

    def test_image_with_unread_areas_says_how_much(self):
        fix_text("report", "r")
        self.open(kind="image", state="needs-attention", state_label="Finished, needs your attention", reason_text="Some areas could not be read.", bad_bytes=4096)
        self.see("could not be read.")

    def test_job_gone(self):
        fix("status", "", rc=1)
        (FIX / "status.json").unlink()
        self.win.open_job("20261031-120000-dead")
        page = self.win.nav.get_visible_page()
        pump(timeout=0.5)
        self.assertIsNone(page.job)
        self.assertFalse(page._poll)

    def test_polling_stops_when_finished_and_when_left(self):
        fix_text("report", "r")
        page = self.open(state="completed", state_label="Completed and checked")
        self.assertTrue(pump(lambda: page._poll == 0, 3))

    def test_jobs_list(self):
        fix("jobs", {"jobs": [job_json(), job_json(id="20261031-120000-beef", state="paused", state_label="Paused", kind="image")]})
        self.win.refresh_jobs()
        self.win.show_jobs()
        self.see("Copying")
        self.see("Paused")
        self.see("Disk image")

    def test_closing_with_work_running_only_warns(self):
        fix("jobs", {"jobs": [job_json()]})
        self.win.refresh_jobs()
        pump(lambda: self.win.jobs, 3)
        forget_calls()
        self.assertTrue(self.win._close_request(self.win), "does not close yet")
        dialog = self.dialog()
        self.assertIn("continues in the background", dialog.get_body())
        self.assertFalse(any("cancel" in c or "pause" in c for c in calls()), "closing never stops a job")
        dialog.force_close()
        self.win.jobs = []


def write_index(records):
    path = WORK / "index-test"
    path.write_bytes(b"\0".join(records) + (b"\0" if records else b""))
    return path


class ResultIndex(unittest.TestCase):
    def test_reads_every_field_also_with_hostile_names(self):
        names = [b"a.jpg", "acentuação.pdf".encode(), b"com\ttab.png", b"-comeca.txt", b"nome\nquebra.mp3", b"\xff\xfeinvalido.jpg", b"pasta/ com espacos /x.zip"]
        path = write_index([b"%d\t%d\tphotos\t%s" % (i + 1, 1000 + i, n) for i, n in enumerate(names)])
        ix = Index(str(path))
        ix.load()
        self.assertEqual(len(ix), len(names))
        for i, n in enumerate(names):
            self.assertEqual(ix.raw(i), n)
            self.assertEqual(ix.sizes[i], i + 1)
        self.assertIn("com\ttab.png", ix.text(2))

    def test_empty_file(self):
        ix = Index(str(write_index([])))
        ix.load()
        self.assertEqual(len(ix), 0)

    def test_broken_record_is_skipped(self):
        ix = Index(str(write_index([b"garbage", b"1\t2\tphotos\tok.jpg", b"x\ty\tphotos\tbad.jpg"])))
        ix.load()
        self.assertEqual(len(ix), 1)

    def test_filters_and_order(self):
        ix = Index(str(write_index([b"10\t5\tphotos\tb.jpg", b"30\t9\tvideos\ta.mp4", b"20\t7\tphotos\tFOTO.png"])))
        ix.load()
        self.assertEqual(list(ix.order({"photos"}, "", "folder")), [0, 2])
        self.assertEqual(list(ix.order(set(), "foto", "folder")), [2])
        self.assertEqual(list(ix.order(set(), "", "size")), [1, 2, 0])
        self.assertEqual(list(ix.order(set(), "", "name")), [1, 0, 2])

    def test_a_million_records_stay_small(self):
        import resource
        records = [b"%d\t0\tphotos\trecup_dir.1/f%07d.jpg" % (i, i) for i in range(200000)]
        ix = Index(str(write_index(records)))
        del records
        t0 = time.time()
        ix.load()
        took = time.time() - t0
        self.assertEqual(len(ix), 200000)
        self.assertLess(took, 8)
        model = ResultsModel()
        model.show(ix, ix.order(set(), "", "folder"))
        self.assertEqual(model.get_n_items(), 200000)
        self.assertEqual(model.get_item(199999).path, "recup_dir.1/f0199999.jpg")
        self.assertIsNone(model.get_item(200000))
        self.assertGreater(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, 0)


class Results(Base):
    def open(self, kind="carved", dates=False, level=""):
        root = WORK / "results-root"
        (root / "recup_dir.1").mkdir(parents=True, exist_ok=True)
        records = [b"100\t0\tphotos\trecup_dir.1/f1.png", b"200\t0\tdocuments\trecup_dir.1/f2.pdf", b"300\t0\taudio\trecup_dir.1/f3.mp3", b"400\t0\tphotos\tnome\nquebra.jpg"]
        index = write_index(records)
        result_kind = "carved-candidates" if kind == "carved" else "existing-files"
        fix("status", job_json(id="20261031-120000-beef", kind="carve" if kind == "carved" else "scan", state="completed", level=level, copy_to=str(DEST) if kind != "carved" else ""))
        fix("results", {"id": "20261031-120000-beef", "kind": "carve", "result_kind": result_kind, "root": str(root), "index": str(index), "state": "completed", "names_kept": kind != "carved", "dates_kept": dates, "ready": True, "files": 4,
                        "categories": [{"id": "photos", "label": "Photos", "files": 2, "bytes": 500}, {"id": "documents", "label": "Documents", "files": 1, "bytes": 200}, {"id": "audio", "label": "Audio", "files": 1, "bytes": 300}]})
        self.win.open_results("20261031-120000-beef")
        page = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: page.model.get_n_items() == 4, 4))
        return page

    def test_candidates_are_called_candidates(self):
        page = self.open()
        self.see("Candidates found by content", page)
        self.assertIsNotNone(find_button(page, "Copy selected to another folder"))
        self.assertFalse(page.date_col.get_visible(), "no dates for what has none")

    def test_existing_files_are_not_called_deleted(self):
        page = self.open(kind="scan", dates=True)
        self.see("exist on the volume", page)
        self.see("Deleted files are not on this list", page)
        self.assertTrue(page.date_col.get_visible())
        self.assertIsNotNone(find_button(page, "Recover selected"))

    def test_filter_by_type(self):
        page = self.open()
        page.chip_buttons["photos"].set_active(True)
        self.assertTrue(pump(lambda: page.model.get_n_items() == 2, 3))
        self.assertFalse(page.all_chip.get_active())
        page.all_chip.set_active(True)
        self.assertTrue(pump(lambda: page.model.get_n_items() == 4, 3))
        self.assertFalse(page.chip_buttons["photos"].get_active())

    def test_search(self):
        page = self.open()
        page.search.set_text("f2")
        self.assertTrue(pump(lambda: page.model.get_n_items() == 1, 3))
        page.search.set_text("nothing like this")
        self.assertTrue(pump(lambda: page.stack.get_visible_child_name() == "nothing", 3))

    def test_selection_survives_filtering(self):
        page = self.open()
        page._select_all()
        self.assertEqual(len(page.selected), 4)
        self.assertEqual(page.selected_bytes, 1000)
        page.chip_buttons["audio"].set_active(True)
        pump(lambda: page.model.get_n_items() == 1, 3)
        self.assertEqual(len(page.selected), 4)
        page._select_none()
        self.assertEqual(page.selected_bytes, 0)
        self.assertFalse(page.save_btn.get_sensitive())

    def test_recover_selected_uses_the_engine_and_the_chosen_destination(self):
        page = self.open(kind="scan", dates=True)
        page._select_all()
        forget_calls()
        fix("copy", {"id": "20261031-120000-c0de"})
        fix("status", job_json())
        page.save_btn.emit("clicked")
        self.assertTrue(pump(lambda: any("--no-wait" in c for c in calls()), 4))
        call = next(c for c in calls() if "--no-wait" in c)
        self.assertIn(f"--destination {DEST}", call)
        self.assertIn("--items-from", call)
        path = call.split("--items-from ", 1)[1].split(" ")[0]
        names = (WORK / "last-items").read_bytes().split(b"\0")
        self.assertIn(b"recup_dir.1/f2.pdf", names)
        self.assertFalse([n for n in names if b"\n" in n], "a line break in a name cannot be handled safely")
        self.assertEqual(int((WORK / "last-items.mode").read_text(), 8) & 0o077, 0, "private")
        self.assertTrue(pump(lambda: not os.path.exists(path), 3), "the selection is removed once the engine has it")
        self.assertEqual(leftover_items(), [], "the check before it left nothing behind either")

    def test_a_selection_that_cannot_be_written_is_an_answer(self):
        folder = WORK / "big-mount"
        shutil.rmtree(folder, ignore_errors=True)
        folder.write_text("not a folder")
        try:
            forget_calls()
            got = []
            self.win.engine.copy(got.append, source="/src", destination=str(DEST), items=[b"a"], dry_run=True)
            self.assertTrue(pump(lambda: got, 3), "the caller always gets an answer")
            self.assertFalse(got[0].ok)
            self.assertTrue(got[0].message)
            self.assertFalse(calls(), "nothing was started without its selection")
        finally:
            folder.unlink()

    def test_carved_copy_goes_through_results_of(self):
        page = self.open()
        page._select_all()
        forget_calls()
        fix("copy", {"id": "20261031-120000-c0de"})
        fix("status", job_json())
        page._copy_to([b"recup_dir.1/f1.png"], str(DEST))
        self.assertTrue(pump(lambda: any("--no-wait" in c for c in calls()), 4))
        self.assertIn("--results-of 20261031-120000-beef", next(c for c in calls() if "--no-wait" in c))

    def test_refused_destination_offers_another(self):
        page = self.open(kind="scan")
        page._select_all()
        fix("copy-dry", {"ok": False, "error": "same-disk", "error_text": "The destination is on the same physical disk as the source."}, rc=20)
        page._copy_to([b"x"], "/same")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() and "same physical" in self.win.get_visible_dialog().get_body(), 3))

    def test_no_preview_for_a_drive_at_risk(self):
        from gui.pages.results import FileItem
        page = self.open(kind="scan", level="critical")
        self.assertFalse(page._can_preview(FileItem(0, "a.jpg", 10, 0, "photos")))
        self.win.nav.pop()
        pump(timeout=0.05)
        page = self.open()
        self.assertTrue(page._can_preview(FileItem(0, "a.jpg", 10, 0, "photos")))
        self.assertFalse(page._can_preview(FileItem(0, "a.exe", 10, 0, "other")))
        self.assertFalse(page._can_preview(FileItem(0, "huge.jpg", 10 ** 10, 0, "photos")))

    def test_not_ready(self):
        fix("status", job_json(kind="scan", state="running"))
        fix("results", {"id": "x", "result_kind": "existing-files", "ready": False, "categories": []})
        self.win.open_results("20261031-120000-beef")
        self.see("The list is not ready yet.", timeout=3)


ERASE_OK = {"device": "/dev/sdb", "name": "sdb (Samsung SSD 860, 500 GB)", "confirm_name": "sdb", "serial": "X", "why": "", "why_text": "", "detail": "", "table": "gpt", "token": "", "eligible": True, "frozen": False,
            "diskseq": 7, "erase_minutes": 4, "size": 500 * GB, "partitions": [{"device": "/dev/sdb1", "label": "DATA", "fstype": "ext4", "mountpoint": "", "size": 500 * GB}]}
TICKET = "0" * 32


class Erase(Base):
    def open(self, check=ERASE_OK):
        fix("erase-check", check)
        fix("erase-prepare", {**check, "token": TICKET})
        self.win.open_maintenance(self.win.device_by_id("serial:S1DFL8G9"))
        page = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: page.check is not None, 3))
        return page

    def to_typing(self, page):
        click(page, "Continue…")
        self.dialog().emit("response", "continue")
        self.assertTrue(pump(lambda: page.token is not None, 3))

    def entry(self, page):
        return next(x for x in widgets(page) if isinstance(x, Gtk.Entry) or isinstance(x, Gtk.Text) and False)

    def test_says_what_it_is_and_what_it_is_not(self):
        page = self.open()
        self.see("IT ERASES ALL THE FILES ON THE DRIVE FOR GOOD. THIS IS NOT RECOVERY.", page)
        self.see("DATA", page)
        self.see("about 4 min", page)

    def test_nothing_runs_by_opening(self):
        forget_calls()
        self.open()
        pump(timeout=0.2)
        self.assertFalse(any("__erase-run" in c or "erase-prepare" in c for c in calls()))

    def refusal(self, why, text_):
        forget_calls()
        page = self.open({**ERASE_OK, "eligible": False, "why": why, "why_text": text_})
        self.see(text_, page)
        self.assertIsNone(find_button(page, "Continue…"))
        self.assertFalse(any("erase-prepare" in c or "__erase-run" in c for c in calls()))

    def test_refused_system(self):
        self.refusal("system", "It holds the operating system that is running now.")

    def test_refused_usb(self):
        self.refusal("removable", "Secure Erase is only offered for drives connected inside the computer")

    def test_refused_nvme(self):
        self.refusal("not-ata", "Secure Erase is only available for SATA drives.")

    def test_refused_partition(self):
        self.refusal("not-disk", "Secure Erase works on a whole drive, not on a partition.")

    def test_refused_password(self):
        self.refusal("password", "A security password is set on this drive.")

    def test_first_confirmation_defaults_to_cancel(self):
        page = self.open()
        forget_calls()
        click(page, "Continue…")
        dialog = self.dialog()
        self.assertEqual(dialog.get_default_response(), "cancel")
        self.assertEqual(dialog.get_close_response(), "cancel")
        dialog.emit("response", "cancel")
        pump(timeout=0.1)
        self.assertFalse(any("erase" in c for c in calls()))

    def test_second_confirmation_wants_the_exact_name(self):
        page = self.open()
        self.to_typing(page)
        forget_calls()
        button = find_button(page, "Erase the whole drive")
        self.assertFalse(button.get_sensitive())
        entry = next(x for x in widgets(page) if isinstance(x, Gtk.Entry))
        for wrong in ("SDB", "sd", "sdb ", "/dev/sdb", ""):
            entry.set_text(wrong)
            self.assertFalse(button.get_sensitive(), wrong)
        entry.set_text("sdb")
        self.assertTrue(button.get_sensitive())
        self.assertFalse(entry.get_activates_default(), "Enter alone never erases")
        self.assertFalse(any("__erase-run" in c for c in calls()))

    def erase(self, page, result, rc=0):
        self.to_typing(page)
        entry = next(x for x in widgets(page) if isinstance(x, Gtk.Entry))
        entry.set_text("sdb")
        fix("__erase-run", result, rc=rc)
        forget_calls()
        click(page, "Erase the whole drive")
        self.assertTrue(pump(lambda: any("__erase-run" in c for c in calls()), 3))
        self.assertTrue(pump(lambda: not self.win.erase_running, 3))
        return next(c for c in calls() if "__erase-run" in c)

    def test_runs_with_the_ticket_and_the_typed_name_only(self):
        page = self.open()
        call = self.erase(page, {"ok": True, "stage": "finished", "title": "Drive erased", "kind": "info", "doc": [{"kind": "p", "text": "It keeps what is written."}]})
        self.assertIn(f"__erase-run {TICKET} --typed sdb", call)
        self.assertNotIn("--unfreeze", call)
        self.assertNotIn("--allow-services", call)
        self.see("Drive erased", page)
        self.see("It keeps what is written.", page)

    def test_failure_is_not_called_success(self):
        page = self.open()
        self.erase(page, {"ok": False, "stage": "finished", "title": "The drive is failing", "kind": "error", "doc": [{"kind": "p", "text": "Its old contents are still there."}]}, rc=12)
        self.see("The drive is failing", page)
        self.assertNotIn("Drive erased", text(page))

    def test_authorization_denied_erases_nothing(self):
        page = self.open()
        self.erase(page, {"ok": False, "stage": "finished", "title": "Unable to erase the drive", "kind": "error", "doc": [{"kind": "p", "text": "Permission was not granted. Nothing was erased."}]}, rc=5)
        self.see("Nothing was erased.", page)

    def test_busy_says_who_and_erases_nothing(self):
        page = self.open()
        self.erase(page, {"ok": False, "stage": "busy", "busy_summary": "Dolphin is using it.", "busy_advice": "Close it.", "doc": []}, rc=3)
        self.see("still in use", page)
        pump(timeout=0.1)
        self.assertIsNotNone(find_button(page, "Try again"))

    def test_services_are_never_stopped_silently(self):
        page = self.open()
        self.erase(page, {"ok": False, "stage": "services", "title": "Services use this device", "doc": [{"kind": "li", "text": "Plex (plex.service)"}]}, rc=9)
        dialog = self.dialog()
        self.assertIn("Plex", dialog.get_body())
        self.assertEqual(dialog.get_default_response(), "cancel")

    def test_frozen_needs_an_explicit_decision_to_sleep(self):
        page = self.open()
        self.erase(page, {"ok": False, "stage": "frozen", "title": "The drive is locked against erasing", "doc": [{"kind": "p", "text": "Sleeping once usually unlocks them."}]}, rc=11)
        dialog = self.dialog()
        self.assertIn("Sleeping", dialog.get_body())
        self.assertEqual(dialog.get_default_response(), "cancel")
        fix("__erase-run", {"ok": True, "stage": "finished", "title": "Drive erased", "kind": "info", "doc": []})
        forget_calls()
        dialog.emit("response", "sleep")
        self.assertTrue(pump(lambda: any("--unfreeze" in c for c in calls()), 3))

    def test_window_stays_open_while_erasing(self):
        self.win.erase_running = True
        self.assertTrue(self.win._close_request(self.win))
        dialog = self.dialog()
        self.assertIn("Do not turn off", dialog.get_body())
        dialog.force_close()

    def test_no_way_around_the_questions(self):
        code = (LIB / "gui/engine.py").read_text() + (LIB / "drive-erase.sh").read_text()
        self.assertNotIn("assume-yes", code)
        self.assertNotIn("--force", code)
        self.assertNotIn("--yes", code)


class Accessibility(Base):
    def test_icon_buttons_have_names(self):
        self.win.show_device("serial:S1DFL8G9", "health")
        pump(timeout=0.4)
        for widget in widgets(self.win):
            # The back button belongs to Adwaita, which names it itself
            if isinstance(widget, Gtk.Button) and widget.get_mapped() and widget.get_icon_name() and not widget.get_label() and widget.get_icon_name() != "go-previous-symbolic":
                self.assertTrue(widget.get_tooltip_text(), f"{widget.get_icon_name()} has no name")

    def test_escape_never_confirms(self):
        self.win.show_device("serial:S1DFL8G9")
        pump(timeout=0.2)
        click(self.win, "Mount read-only")
        dialog = self.dialog()
        self.assertEqual(dialog.get_close_response(), "cancel")

    def test_fits_a_small_screen(self):
        self.win.set_default_size(1024, 600)
        pump(timeout=0.2)
        self.assertLessEqual(self.win.get_height(), 720)
        minimum, _natural, _a, _b = self.win.measure(Gtk.Orientation.HORIZONTAL, -1)
        self.assertLessEqual(minimum, 400, "reflows on narrow windows")

    def test_every_page_reflows_on_a_narrow_window(self):
        self.win.show_device("serial:S1DFL8G9", "health")
        pump(timeout=0.5)
        # The header gives way to a title at the breakpoint: what matters is the content
        self.assertLessEqual(self.win.device_page.health.measure(Gtk.Orientation.HORIZONTAL, -1)[0], 340)
        self.assertLessEqual(self.win.overview.measure(Gtk.Orientation.HORIZONTAL, -1)[0], 400)
        wiz = self.wizard_to("how")
        self.assertLessEqual(wiz.measure(Gtk.Orientation.HORIZONTAL, -1)[0], 400)

    def test_narrow_collapses_to_one_pane(self):
        self.win.split.set_collapsed(True)
        self.win.show_device("serial:S1DFL8G9")
        pump(timeout=0.2)
        self.assertTrue(self.win.split.get_show_content())

    def test_light_and_dark(self):
        manager = Adw.StyleManager.get_default()
        for scheme in (Adw.ColorScheme.FORCE_DARK, Adw.ColorScheme.FORCE_LIGHT, Adw.ColorScheme.DEFAULT):
            manager.set_color_scheme(scheme)
            pump(timeout=0.05)
            self.see("Your drives and devices")

    def test_status_is_not_colour_alone(self):
        badge = next(x for x in widgets(self.win) if {"level-badge", "grade-pill"} & set(x.get_css_classes()) and x.get_mapped())
        self.assertTrue(any(isinstance(c, Gtk.Label) and c.get_text() for c in widgets(badge)))
        self.assertTrue(any(isinstance(c, Gtk.Image) for c in widgets(badge)))

    def test_no_fixed_colours_in_the_style(self):
        css = (LIB / "gui/style.css").read_text()
        import re
        self.assertFalse(re.search(r"#[0-9a-fA-F]{3,8}\b|rgba?\(", css), "named colours only: they follow the theme")


class Launcher(unittest.TestCase):
    """The real entry point and shell router, with the stand-in as the engine."""

    def run_b(self, *args, env=None, timeout=6):
        e = {k: v for k, v in os.environ.items()}
        e.update(env or {})
        return subprocess.run([str(REPO / "big-mount/usr/bin/bigmount"), *args], capture_output=True, text=True, env=e, timeout=timeout)

    def stays_open(self, *args):
        """The real program, on the private display, with the stand-in as the engine,
        on a bus of its own: not the running instance of whoever runs this."""
        env = {**os.environ, "DISPLAY": ":none", "LANGUAGE": "C", "PYTHONWARNINGS": "ignore"}
        log = WORK / f"launch-{time.time()}.log"
        with open(log, "w") as handle:
            proc = subprocess.Popen(["dbus-run-session", "--", str(REPO / "big-mount/usr/bin/bigmount"), *args], env=env,
                                    stdout=subprocess.DEVNULL, stderr=handle, start_new_session=True)
        time.sleep(3)
        alive = proc.poll() is None
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        err = log.read_text()
        self.assertTrue(alive, err)
        # The desktop portal of the private bus has no backend: its complaints are not ours
        problems = [line for line in err.splitlines() if ("Traceback" in line or "CRITICAL" in line) and "portal" not in line]
        self.assertEqual(problems, [], err)

    @unittest.skipUnless(shutil.which("dbus-run-session"), "dbus-run-session is not installed")
    def test_gui_drive_opens_and_stays_open(self):
        self.stays_open("--gui-drive")

    @unittest.skipUnless(shutil.which("dbus-run-session"), "dbus-run-session is not installed")
    def test_gui_drive_check_opens_the_same_application(self):
        self.stays_open("--gui-drive-check", "/dev/sdb")

    @unittest.skipUnless(shutil.which("dbus-run-session"), "dbus-run-session is not installed")
    def test_a_uuid_is_not_taken_for_a_path(self):
        self.stays_open("--gui-drive", "UUID=ABCD-1234")

    def test_both_flags_reach_the_same_program(self):
        code = (LIB / "drive.sh").read_text()
        self.assertEqual(code.count('python3 -I "$py"'), 1)
        cli = (LIB / "cli.sh").read_text()
        self.assertIn('--gui-drive | --gui-drive-check)', cli)
        self.assertIn('bm_gui_drive_main health "$@"', cli)
        self.assertNotIn("bm_gui_secure_erase", cli)

    def test_no_session_points_to_the_terminal(self):
        res = self.run_b("--gui-drive", env={"WAYLAND_DISPLAY": "", "DISPLAY": ""})
        self.assertEqual(res.returncode, 25)
        self.assertIn("bigmount --drive", res.stderr)
        res = self.run_b("--gui-drive-check", env={"WAYLAND_DISPLAY": "", "DISPLAY": ""})
        self.assertEqual(res.returncode, 25)

    def test_the_entry_point_is_only_python_and_gtk(self):
        src = (LIB / "drive-gui.py").read_text()
        self.assertIn('gi.require_version("Gtk", "4.0")', src)
        self.assertIn('gi.require_version("Adw", "1")', src)

    def test_boot_path_loads_nothing_of_this(self):
        boot = (REPO / "big-mount/usr/bin/bigmount").read_text()
        for bad in ("python", "gi.repository", "drive-gui", "gtk"):
            self.assertNotIn(bad, boot.lower())


class AboutAndWelcome(Base):
    def menu_actions(self):
        menu, out = self.win._menu(), []
        for i in range(menu.get_n_items()):
            section = menu.get_item_link(i, "section")
            for model, j in ([(section, k) for k in range(section.get_n_items())] if section else [(menu, i)]):
                out.append(model.get_item_attribute_value(j, "action", None).unpack())
        return out

    def test_the_menu_has_the_welcome_screen_and_about(self):
        actions = self.menu_actions()
        self.assertIn("app.welcome", actions)
        self.assertIn("app.about", actions)

    def test_about_says_what_it_does_who_made_it_and_where_to_ask(self):
        self.win.show_about()
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() is not None, 2))
        about = self.win.get_visible_dialog()
        self.assertIsInstance(about, Adw.AboutDialog)
        self.assertEqual(WEBSITE, "https://github.com/biglinux/big-mount")
        self.assertEqual(about.get_website(), WEBSITE)
        self.assertEqual(about.get_issue_url(), "https://github.com/biglinux/big-mount/issues")
        self.assertEqual(about.get_issue_url(), ISSUES)
        self.assertEqual(about.get_developers(), ["Bruno Gonçalves <bigbruno@gmail.com>", "Rafael Ruscher <rruscher@gmail.com>"])
        self.assertEqual(about.get_copyright(), "© 2026 BigLinux Team")
        # "... comes with absolutely no warranty. See the GNU General Public License, version 3 or later"
        self.assertEqual(about.get_license_type(), Gtk.License.GPL_3_0)
        doctor = (LIB / "doctor.sh").read_text()
        self.assertIn(f"\nBM_VERSION={about.get_version()}\n", doctor)
        self.assertIn("rescues files from a failing disk", about.get_comments())
        self.assertIn("mounts the partitions of internal disks at every boot", about.get_comments())

    def test_welcome_shows_what_it_can_do(self):
        self.win.show_welcome()
        self.assertTrue(pump(lambda: "Welcome to Big-Mount" in text(self.win), 3))
        welcome = self.win.get_visible_dialog()
        for words in ("Health in one word", "Rescue your files", "Safe removal", "Secure Erase", "Also in the terminal"):
            self.assertIn(words, text(welcome))
        self.assertTrue(welcome.show_switch.get_active())
        click(welcome, "Let's start")
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() is None, 2))
        self.assertTrue(welcome_at_start(parse(["bigmount"])))

    def test_welcome_can_stay_away(self):
        self.win.show_welcome()
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() is not None, 2))
        welcome = self.win.get_visible_dialog()
        welcome.show_switch.set_active(False)
        welcome.close()
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() is None, 2))
        self.assertIn("show=false", (WORK / "config/big-mount/gui.ini").read_text())
        self.assertFalse(welcome_at_start(parse(["bigmount"])))
        # And it is still in the menu
        self.win.show_welcome()
        self.assertTrue(pump(lambda: self.win.get_visible_dialog() is not None, 2))
        self.assertFalse(self.win.get_visible_dialog().show_switch.get_active())

    def test_on_a_narrow_screen_the_button_stays_whole(self):
        present_at(self.win, 360, 700)
        self.win.show_welcome()
        self.assertTrue(pump(lambda: "Welcome to Big-Mount" in text(self.win), 3))
        # Otherwise the test would pass on a wide window and prove nothing
        self.assertEqual(self.win.get_width(), 360)
        welcome = self.win.get_visible_dialog()
        pump(timeout=0.3)
        ok, bounds = welcome.start.compute_bounds(welcome)
        self.assertTrue(ok)
        self.assertGreater(bounds.get_width(), 0)
        self.assertLessEqual(bounds.get_x() + bounds.get_width(), welcome.get_width())

    def test_never_over_a_drive_that_was_asked_for(self):
        save_setting("welcome", "show", "true")
        self.assertFalse(welcome_at_start(parse(["bigmount", "--target", "/dev/sdb"])))
        self.assertFalse(welcome_at_start(parse(["bigmount", "--section", "health"])))


class ShellDialogs(unittest.TestCase):
    """dialog.py: what bigmount --gui, --gui-remove and the notifier show."""

    def make(self, argv, doc=()):
        d = shell_dialogs.Dialog(shell_dialog.parse(argv), list(doc))
        d.dialog.present(None)
        pump(timeout=0.05)
        self.addCleanup(lambda: d.dialog.force_close() if d.dialog.get_root() else None)
        return d

    def labels(self, d):
        return [x for x in widgets(d.dialog) if isinstance(x, Gtk.Label)]

    def test_the_document_arrives_as_data(self):
        doc = shell_dialog.read_document(b"h\0<b>Pen</b> is still in use\0p\0Close it.\0tr\0<i>App</i>\x1fcomm\t42\0kv\0Device\t/dev/sdz1\x1b[2J\0bogus\0x\0")
        self.assertEqual([k for k, _t in doc], ["h", "p", "tr", "kv"])
        self.assertNotIn("\x1b", doc[3][1])
        d = self.make(["question", "--button=no=No", "--button=yes=Yes"], doc)
        self.assertEqual(d.dialog.get_heading(), "<b>Pen</b> is still in use")
        self.assertFalse(d.dialog.get_heading_use_markup())
        self.assertEqual(d.dialog.get_body(), "Close it.")
        labels = self.labels(d)
        self.assertIn("<i>App</i>", [x.get_label() for x in labels])
        self.assertFalse(any(x.get_use_markup() for x in labels))

    def test_a_risky_question_defaults_to_the_safe_answer(self):
        d = self.make(["question", "--button=no=Cancel", "--button=yes=Close them", "--default=no", "--cancel=no", "--destructive=yes"],
                      [("h", "Close these programs?")])
        self.assertEqual(d.dialog.get_default_response(), "no")
        self.assertEqual(d.dialog.get_close_response(), "no")
        self.assertEqual(d.dialog.get_response_appearance("yes"), Adw.ResponseAppearance.DESTRUCTIVE)
        d.dialog.emit("response", "no")
        self.assertEqual(d.answer, "no")

    def test_the_answer_is_the_button_pressed(self):
        d = self.make(["question", "--button=3=Cancel", "--button=2=More", "--button=1=Try again", "--default=1", "--cancel=3", "--suggested=1"])
        self.assertEqual(d.dialog.get_response_appearance("1"), Adw.ResponseAppearance.SUGGESTED)
        d.dialog.emit("response", "2")
        self.assertEqual(d.answer, "2")

    def test_closing_a_question_without_cancel_is_no_answer(self):
        d = self.make(["question", "--button=yes=Open", "--button=other=Other"])
        self.assertNotIn(d.dialog.get_close_response(), ("yes", "other"))
        self.assertEqual(d.dialog.get_default_response(), "yes")
        d.dialog.emit("response", d.dialog.get_close_response())
        self.assertIsNone(d.answer)

    def test_a_menu_answers_with_the_key_of_the_item(self):
        d = self.make(["menu", "--title=Device is busy", "--text=What do you want to do?", "--item=refresh=Refresh the list", "--item=admin=All users"])
        self.assertEqual(d.dialog.get_heading(), "Device is busy")
        row = next(x for x in widgets(d.dialog) if isinstance(x, Adw.ActionRow) and x.get_title() == "All users")
        row.emit("activate")
        self.assertEqual(d.answer, "admin")
        d2 = self.make(["menu", "--item=a=A"])
        d2.dialog.emit("response", "cancel")
        self.assertIsNone(d2.answer)

    def test_input_gives_the_line_typed_or_nothing(self):
        d = self.make(["input", "--title=Erase", "--text=Type the name:"])
        d.entry.set_text("sdz")
        d.dialog.emit("response", "ok")
        self.assertEqual(d.answer, "sdz")
        d2 = self.make(["input", "--text=Type:"])
        d2.entry.set_text("sdz")
        d2.dialog.emit("response", "cancel")
        self.assertIsNone(d2.answer)

    def test_technical_text_is_shown_whole(self):
        path = WORK / "details.txt"
        path.write_text("open files:\n  pid=7 comm=<b>x</b>\n")
        args = shell_dialog.parse(["text", "--title=Technical details", f"--file={path}"])
        args.content = path.read_text()
        d = shell_dialogs.Dialog(args, [])
        d.dialog.present(None)
        pump(timeout=0.05)
        self.addCleanup(d.dialog.force_close)
        view = next(x for x in widgets(d.dialog) if isinstance(x, Gtk.TextView))
        buf = view.get_buffer()
        self.assertIn("comm=<b>x</b>", buf.get_text(buf.get_start_iter(), buf.get_end_iter(), False))
        self.assertFalse(view.get_editable())

    def test_wrong_arguments_and_no_display_are_never_an_answer(self):
        def run(*a, env=None):
            return subprocess.run([sys.executable, "-I", str(LIB / "dialog.py"), *a], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
        self.assertEqual(run("question").returncode, 2)
        self.assertEqual(run("question", "--button=nolabel").returncode, 2)
        unreadable = run("text", f"--file={WORK / 'no-such-file'}")
        self.assertEqual(unreadable.returncode, 2)
        self.assertEqual(unreadable.stdout, "")
        # No display at all: nothing to connect to, here or in the session of whoever runs this
        nowhere = WORK / "no-session"
        nowhere.mkdir(mode=0o700, exist_ok=True)
        bare = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "WAYLAND_DISPLAY", "GDK_BACKEND", "BROADWAY_DISPLAY")}
        bare["XDG_RUNTIME_DIR"] = str(nowhere)
        done = run("question", "--button=yes=Yes", env=bare)
        self.assertEqual(done.returncode, 25)
        self.assertEqual(done.stdout, "")

    def test_no_kdialog_or_zenity_anywhere(self):
        for path in LIB.rglob("*"):
            if path.is_file() and path.suffix in ("", ".sh", ".py"):
                self.assertNotRegex(path.read_text(errors="replace"), r"\b(kdialog|zenity)\b", path)


if SHOTS:
    class Shots(Base):
        def test_shots(self):
            shot(self.win, pathlib.Path(SHOTS) / "tests-home.png")


if __name__ == "__main__":
    unittest.main(verbosity=1 if "-v" not in sys.argv else 2, exit=True, warnings="ignore")
