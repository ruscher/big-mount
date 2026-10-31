#!/usr/bin/python3
"""The real application driving the real engine, on scratch files only.

Nothing here touches a disk: the source is a folder under /var/tmp, the destination
a folder in /dev/shm, the image for the search a file made here. Listing the drives
of this computer only reads, and Secure Erase is only asked whether it may be used,
which it must refuse for the drive of the running system.

Usage: python3 tests/gui-e2e.py
"""

import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib

os.environ["LANGUAGE"] = "C"
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from gui_support import CALLBACK_ERRORS, REPO, WORK, Gtk, find_button, make_app, pump, text, widgets  # noqa: E402

os.environ.pop("BM_GUI_BIN", None)
app = make_app()

from gui.engine import Engine  # noqa: E402
from gui.window import MainWindow  # noqa: E402

REAL = str(REPO / "big-mount/usr/bin/bigmount")
STATE = WORK / "state"
os.environ["XDG_STATE_HOME"] = str(STATE)
SOURCE = pathlib.Path(tempfile.mkdtemp(prefix="bm-e2e-src-", dir="/var/tmp"))
OUT = pathlib.Path(tempfile.mkdtemp(prefix="bm-e2e-out-", dir="/dev/shm"))
for path in (SOURCE, OUT):
    import atexit
    atexit.register(shutil.rmtree, path, ignore_errors=True)


def same_filesystem():
    def src(p):
        return subprocess.run(["findmnt", "-n", "-o", "SOURCE", "-T", str(p)], capture_output=True, text=True).stdout.strip()
    return src(SOURCE) == src(OUT)


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def png(w, h):
    raw = b"".join(b"\0" + bytes((x * y + y) % 256 for x in range(w * 3)) for y in range(h))

    def c(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))
    return b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b"")


class Real(unittest.TestCase):
    def setUp(self):
        self.win = MainWindow(app, engine=Engine(program=REAL))
        self.win.present()
        self.assertTrue(pump(lambda: self.win.loaded, 15))

    def tearDown(self):
        dialog = self.win.get_visible_dialog()
        if dialog:
            dialog.force_close()
        self.win.jobs = []
        self.win.close()
        pump(timeout=0.02)
        errors, CALLBACK_ERRORS[:] = list(CALLBACK_ERRORS), []
        self.assertEqual(errors, [], "exceptions in callbacks")

    def call(self, method, *args, **kw):
        got = {}
        method(lambda r: got.update(r=r), *args, **kw)
        self.assertTrue(pump(lambda: "r" in got, 30))
        return got["r"]

    def wait_job(self, job_id, timeout=60):
        end = time.time() + timeout
        while time.time() < end:
            res = self.call(lambda cb: self.win.engine.status(job_id, cb))
            if res.data and res.data["state"] not in ("pending", "analyzing", "running", "verifying", "stopping"):
                return res.data
            pump(timeout=0.2)
        self.fail("the job did not end")

    def test_the_real_list_opens(self):
        self.assertIsNotNone(self.win.devices)
        for dev in self.win.devices:
            self.assertTrue(dev.stable_id)

    def test_secure_erase_is_refused_for_the_running_system(self):
        system = next((d for d in self.win.devices if d.has_system), None)
        if not system:
            self.skipTest("no drive of the running system is visible here")
        res = self.call(lambda cb: self.win.engine.erase_check(system.device, cb))
        self.assertFalse(res.data["eligible"])
        res = self.call(lambda cb: self.win.engine.erase_prepare(system.device, cb))
        self.assertEqual(res.code, 20)
        self.assertEqual(res.data.get("token"), "")

    def test_forged_ticket_changes_nothing(self):
        res = self.call(lambda cb: self.win.engine.erase_run("0" * 32, "sda", cb))
        self.assertEqual(res.code, 20)
        self.assertFalse(res.data["ok"])

    @unittest.skipIf(same_filesystem(), "the scratch folders share a filesystem here")
    def test_list_select_and_recover_through_the_window(self):
        data = SOURCE / "data"
        (data / "fotos").mkdir(parents=True)
        (data / "fotos/ferias.jpg").write_bytes(os.urandom(4096))
        (data / "nota com espaco.pdf").write_bytes(os.urandom(100))
        (data / "-traco.pdf").write_bytes(os.urandom(100))
        (data / "acentuação.pdf").write_bytes(os.urandom(100))
        (data / "musica.mp3").write_bytes(os.urandom(100))
        (data / "linha\nquebra.pdf").write_bytes(os.urandom(10))
        dest = OUT / "list-copy"
        res = self.call(lambda cb: self.win.engine.scan(cb, str(data), "documents,photos", copy_to=str(dest)))
        job_id = res.data["id"]
        self.win.open_job(job_id)
        page = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: page.job and not page.job.running, 30), text(page))
        self.assertEqual(page.job.result_kind, "existing-files")
        self.assertEqual(page.job.files_done, 5)
        self.assertTrue(page.results_btn.get_visible())
        page.results_btn.emit("clicked")
        results = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: results.model.get_n_items() == 5, 15), text(results))
        results._select_all()
        before = {p.name for p in data.rglob("*")}
        results.save_btn.emit("clicked")
        self.assertTrue(pump(lambda: type(self.win.nav.get_visible_page()).__name__ == "JobPage" and self.win.nav.get_visible_page() is not page, 30), text(self.win))
        copy_page = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: copy_page.job and not copy_page.job.running, 60), text(copy_page))
        self.assertEqual(copy_page.job.state, "completed", copy_page.job.reason_text)
        for rel in ("fotos/ferias.jpg", "nota com espaco.pdf", "-traco.pdf", "acentuação.pdf"):
            self.assertEqual(sha(data / rel), sha(dest / rel), rel)
        self.assertFalse((dest / "musica.mp3").exists(), "it was not selected")
        self.assertEqual({p.name for p in data.rglob("*")}, before, "the source did not change")

    @unittest.skipIf(same_filesystem(), "the scratch folders share a filesystem here")
    def test_same_filesystem_is_refused_with_its_reason(self):
        res = self.call(lambda cb: self.win.engine.copy(cb, source=str(SOURCE), destination=str(SOURCE.parent / "bm-e2e-next"), dry_run=True, scan="no"))
        self.assertFalse(res.data["ok"])
        self.assertIn(res.data["error"], ("same-fs", "dest-denied"))

    def test_destination_inside_the_source_is_refused(self):
        res = self.call(lambda cb: self.win.engine.copy(cb, source=str(SOURCE), destination=str(SOURCE / "inside"), dry_run=True, scan="no"))
        self.assertEqual(res.data["error"], "dest-inside-source")

    @unittest.skipUnless(shutil.which("photorec"), "PhotoRec is not installed")
    def test_search_an_image_through_the_assistant(self):
        image = SOURCE / "disk.img"
        with open(image, "wb") as handle:
            handle.truncate(64 * 1024 * 1024)
            for offset in (1, 20, 50):
                handle.seek(offset * 1024 * 1024)
                handle.write(png(64, 64))
        before = sha(image)
        self.win.open_wizard(image=str(image))
        wiz = self.win.wizard
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "what", 15))
        wiz._choice["photos"].set_active(True)
        wiz.go_next()
        self.assertEqual(wiz.plan.method, "deep", "an image: search it")
        self.assertFalse(wiz.plan.methods.deep_needs_image)
        wiz.plan.dest_custom = True
        wiz.plan.dest_base = str(OUT / "found")
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "where" and wiz.preflight is not None, 15), text(wiz))
        self.assertTrue(wiz.preflight["ok"], wiz.preflight)
        wiz.go_next()
        self.assertTrue(pump(lambda: wiz.step == "confirm" and wiz.preflight is not None and wiz.next_btn.get_sensitive(), 15))
        wiz.go_next()
        self.assertTrue(pump(lambda: type(self.win.nav.get_visible_page()).__name__ == "JobPage", 15))
        page = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: page.job and not page.job.running, 120), text(page))
        self.assertEqual(page.job.state, "completed", page.job.reason_text)
        self.assertEqual(page.job.result_kind, "carved-candidates")
        self.assertEqual(page.job.files_done, 3)
        self.assertEqual(sha(image), before, "the image did not change")
        page.results_btn.emit("clicked")
        results = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: results.model.get_n_items() == 3, 15))
        self.assertFalse(results.date_col.get_visible())
        results._select_all()
        names = [results.index.raw(r) for r in sorted(results.selected)]
        target = OUT / "kept"
        results._copy_to(names, str(target))
        self.assertTrue(pump(lambda: self.win.nav.get_visible_page() is not results, 30), text(self.win))
        copy_page = self.win.nav.get_visible_page()
        self.assertTrue(pump(lambda: copy_page.job and not copy_page.job.running, 60))
        self.assertEqual(copy_page.job.state, "completed", copy_page.job.reason_text)
        self.assertEqual(len(list(target.rglob("*.png"))), 3)
        image.unlink()

    @unittest.skipUnless(shutil.which("testdisk"), "TestDisk is not installed")
    def test_partitions_of_an_image_change_nothing(self):
        image = SOURCE / "parts.img"
        with open(image, "wb") as handle:
            handle.truncate(16 * 1024 * 1024)
        subprocess.run(["sfdisk", "-q", str(image)], input=b"label: dos\n,8M,83\n,,83\n", check=True, env={**os.environ, "PATH": os.environ["PATH"] + ":/usr/sbin"})
        before = sha(image)
        res = self.call(lambda cb: self.win.engine.partitions(str(image), cb))
        self.assertTrue(res.data["ok"])
        self.assertEqual(len(res.data["found"]), 2)
        self.assertEqual(sha(image), before)
        res = self.call(lambda cb: self.win.engine.partitions(str(image), cb, search=True))
        self.assertTrue(res.data["ok"])
        self.assertEqual(sha(image), before, "the analysis wrote nothing")
        image.unlink()


__all__ = [json, Gtk, find_button, widgets]

if __name__ == "__main__":
    unittest.main(verbosity=2, warnings="ignore")
