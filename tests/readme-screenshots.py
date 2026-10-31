#!/usr/bin/python3
"""The pictures of the application in the README, always reproducible.

This is the real window, drawn off screen, in English. Its data comes from a
stand-in for `bigmount` that answers with sample drives, so a picture never shows
the disks, labels or files of whoever runs this. No disk is involved, and nothing
appears on the screen.

Usage: python3 tests/readme-screenshots.py [DIR] [--dark]     (default: docs/images)
"""

import os
import pathlib
import struct
import sys
import zlib

os.environ["LANGUAGE"] = os.environ.get("SHOTS_LANGUAGE", "C")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from gui_support import (Adw, GB, REPO, WORK, backup, drive, fix, make_app, pump,  # noqa: E402
                         seagate, shot, system_disk, vol)

DARK = "--dark" in sys.argv
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
OUT = pathlib.Path(ARGS[0]) if ARGS else REPO / "docs/images"
OUT.mkdir(parents=True, exist_ok=True)

app = make_app()
Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK if DARK else Adw.ColorScheme.FORCE_LIGHT)

from gui.window import MainWindow  # noqa: E402

# What the pictures show for the backup disk: a path like the others, never the
# random scratch folder, so the same code always gives the same pictures
MOUNT = pathlib.PurePath("/run/media/maria/Backup")
SOURCE = WORK / "arquivos"
(SOURCE / "Fotos").mkdir(parents=True)
(SOURCE / "Documentos").mkdir()
(SOURCE / "Fotos/ferias.jpg").write_text("x")
(SOURCE / "relatorio.pdf").write_text("x")
SEA = seagate()
SEA["health"].update(grade="critical")
SEA["volumes"][1].update(state="mounted-ro", state_label="Mounted read-only", mountpoint=str(SOURCE), used=412 * GB, avail=588 * GB, read_only=True)
SEA_UNMOUNTED = seagate()
SEA_UNMOUNTED["health"].update(grade="critical")
BK = backup(MOUNT)
BK["health"].update(grade="good", notes=[{"key": "smart-unread", "text": "Only the system log was consulted. Without the drive's own report (SMART) it cannot be called healthy."}])
SYS = system_disk()
SYS["health"].update(grade="healthy", smart={"hours": 7610, "temperature": 34, "nvme_used": 5, "nvme_media": 0})
LUKS = drive("/dev/sdc", "Kingston DataTraveler", volumes=[vol("/dev/sdc1", fstype="crypto_LUKS", state="locked", state_label="Encrypted and locked", size=64 * GB)], serial="KG1", size=64 * GB)
CARD = drive("/dev/mmcblk0", "SD card", kind="sd", kind_label="SD card", volumes=[vol("/dev/mmcblk0p1", fstype="vfat", label="CAMERA", size=128 * GB)], serial="SD9", size=128 * GB)
fix("list", {"partial": False, "devices": [SYS, SEA_UNMOUNTED, BK, LUKS, CARD]})
fix("jobs", {"jobs": []})
fix("diagnose", {"device": SEA, "tools": {"smartctl": True, "ddrescue": True, "photorec": True, "testdisk": True, "rsync": True},
                 "advice": ["Copy what matters now, starting with the most important files. Every extra read wears a failing disk.",
                            "Do not run repair tools on this disk: they write, and they can destroy what is still readable.",
                            "If the data is very important and cannot be replaced, consider a data recovery professional before insisting."],
                 "kernel": ["blk_update_request: I/O error, dev sdb, sector 2048"], "volumes": []})
fix("destinations", {"destinations": [
    {"path": str(MOUNT), "device": "/dev/sda1", "level": "normal", "why": "", "name": "Backup", "fstype": "ntfs", "avail": 1200 * GB, "independent": True, "recommended": True},
    {"path": "/home/maria", "device": "/dev/nvme0n1p2", "level": "normal", "why": "", "name": "Home folder", "fstype": "btrfs", "avail": 579 * GB, "independent": True, "recommended": True},
    {"path": "/run/media/maria/OTHER", "device": "/dev/sdb2", "level": "critical", "why": "same-disk", "name": "OTHER", "fstype": "ext4", "avail": 200 * GB, "independent": False, "recommended": False}]})
METHODS = {"target": "/dev/sdb1", "source_kind": "volume", "device": "/dev/sdb1", "volume": "/dev/sdb1", "disk": "/dev/sdb", "level": "critical", "state": "unmounted",
           "mountpoint": "", "fstype": "ntfs", "recommended": "copy", "recommended_why": "The drive reported problems: copy what matters first, without going through everything.",
           "size": 1000 * GB, "trim": False, "can_read": False, "deep_needs_image": True,
           "methods": [{"id": "copy", "available": True, "why": "", "why_text": "", "finds": "existing", "password": False},
                       {"id": "quick", "available": True, "why": "", "why_text": "", "finds": "existing", "password": False},
                       {"id": "deep", "available": True, "why": "", "why_text": "", "finds": "carved", "password": True},
                       {"id": "image", "available": True, "why": "", "why_text": "", "finds": "image", "password": True},
                       {"id": "partitions", "available": True, "why": "", "why_text": "", "finds": "partitions", "password": True}],
           "notes": [], "categories": [
               {"id": "photos", "label": "Photos", "deep_note": "HEIC and WebP photos are found only when searching all types."},
               {"id": "videos", "label": "Videos", "deep_note": ""}, {"id": "documents", "label": "Documents", "deep_note": ""},
               {"id": "audio", "label": "Audio", "deep_note": ""}, {"id": "archives", "label": "Compressed files", "deep_note": ""}]}
fix("methods", METHODS)
fix("mount", {"device": "/dev/sdb1", "mountpoint": str(SOURCE), "why": "", "text": "", "detail": "", "ok": True, "read_only": True, "protected": True, "exit": 0})
fix("copy-dry", {"error": "", "error_text": "", "source": str(SOURCE), "destination": str(MOUNT / "out"), "level": "critical", "total_bytes": 412 * GB, "total_files": 0, "conflicts": 0,
                 "avail": 1200 * GB, "ok": True, "total_estimate": True, "same_disk": False, "scanned": False,
                 "warnings": [{"key": "source-risk", "text": "The source drive reported problems. Files that do not advance are set aside so the rest is saved first."},
                              {"key": "total-estimate", "text": "The total is the used space of the volume: an approximation."}]})


def job(**kw):
    base = {"id": "20261031-120000-abcd", "kind": "copy", "result_kind": "copied-files", "state": "running", "state_label": "Copying", "reason": "", "reason_text": "",
            "source": "/run/media/maria/ARQUIVOS", "destination": str(MOUNT), "name": "ARQUIVOS", "current": "Fotos/2019/ferias/DSC_0142.jpg", "verify": "basic", "verify_result": "", "dir": str(WORK),
            "categories": "", "then_carve": "", "copy_to": "", "map": "", "level": "critical", "files_done": 18342, "files_total": 0, "bytes_done": 148 * GB, "bytes_total": 412 * GB,
            "rate_now": 94 * 1000 * 1000, "rate_avg": 88 * 1000 * 1000, "elapsed": 1720, "eta": 2800, "deferred": 2, "failed": 0, "differ": 0, "conflicts": 0, "read_errors": 3, "stuck": 0,
            "created": 1793419273, "finished": None, "scanned": 0, "pass": 0, "bad_bytes": 0, "total_estimate": True, "pausable": True}
    base.update(kw)
    return base


win = MainWindow(app)
win.set_default_size(1024, 700)
win.present()
assert pump(lambda: win.loaded, 8)
pump(timeout=0.3)
suffix = "-dark" if DARK else ""
shot(win, OUT / f"app-overview{suffix}.png")
win.overview.set_view("grid")
pump(timeout=0.3)
shot(win, OUT / f"app-overview-grid{suffix}.png")
win.overview.set_view("list")
pump(timeout=0.2)

win.show_device(SEA_UNMOUNTED["stable_id"])
pump(timeout=0.4)
shot(win, OUT / f"app-drive{suffix}.png")
win.show_device(SEA_UNMOUNTED["stable_id"], "health")
pump(timeout=0.6)
shot(win, OUT / f"app-health{suffix}.png")

win.open_wizard(win.device_by_id(SEA_UNMOUNTED["stable_id"]), win.device_by_id(SEA_UNMOUNTED["stable_id"]).content_volumes[0])
pump(timeout=0.3)
shot(win, OUT / f"app-rescue-source{suffix}.png")
wiz = win.wizard
wiz.go_next()
assert pump(lambda: wiz.step == "what", 5)
pump(timeout=0.2)
shot(win, OUT / f"app-rescue-what{suffix}.png")
wiz.go_next()
pump(timeout=0.2)
shot(win, OUT / f"app-rescue-how{suffix}.png")
wiz.plan.volume.mountpoint = str(SOURCE)
wiz.plan.volume.state = "mounted-ro"
wiz.go_next()
assert pump(lambda: wiz.step == "where", 5)
assert pump(lambda: wiz.preflight is not None, 6)
pump(timeout=0.3)
shot(win, OUT / f"app-rescue-where{suffix}.png")
wiz.go_next()
assert pump(lambda: wiz.step == "confirm" and wiz.preflight is not None, 6)
pump(timeout=0.3)
shot(win, OUT / f"app-rescue-confirm{suffix}.png")

fix("status", job())
fix("jobs", {"jobs": [job()]})
win.refresh_jobs()
win.open_job("20261031-120000-abcd", replace_top=True)
pump(timeout=0.6)
shot(win, OUT / f"app-job-running{suffix}.png")

# Results: a real index in the format of the engine


def png(w, h):
    raw = b"".join(b"\0" + bytes((x * 3 + y * 5) % 256 for x in range(w * 3)) for y in range(h))

    def c(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b))
    return b"\x89PNG\r\n\x1a\n" + c(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + c(b"IDAT", zlib.compress(raw)) + c(b"IEND", b"")


carved = WORK / "found"
(carved / "recup_dir.1").mkdir(parents=True)
records = []
for i in range(40):
    cat, ext = (("photos", "png") if i % 3 == 0 else ("documents", "pdf") if i % 3 == 1 else ("audio", "mp3"))
    name = f"recup_dir.1/f{2048 + i * 4096:07d}.{ext}"
    if ext == "png":
        (carved / name).write_bytes(png(64, 48))
    records.append(f"{(i + 1) * 183042}\t0\t{cat}\t{name}".encode())
index = WORK / "index"
index.write_bytes(b"\0".join(records) + b"\0")
fix("status", job(id="20261031-120000-beef", kind="carve", result_kind="carved-candidates", state="completed", state_label="Search complete", files_done=40, source="/home/maria/disk.img", destination=str(carved), bytes_total=0, bytes_done=int(1e9), eta=None, deferred=0, level="", total_estimate=False))
fix("results", {"id": "20261031-120000-beef", "kind": "carve", "result_kind": "carved-candidates", "root": str(carved), "index": str(index), "state": "completed", "names_kept": False, "dates_kept": False, "ready": True,
                "files": 40, "categories": [{"id": "photos", "label": "Photos", "files": 14, "bytes": 1000}, {"id": "documents", "label": "Documents", "files": 13, "bytes": 1000}, {"id": "audio", "label": "Audio", "files": 13, "bytes": 1000}]})
win.open_results("20261031-120000-beef")
pump(timeout=1.0)
shot(win, OUT / f"app-results{suffix}.png")

win.show_overview()
pump(timeout=0.1)
fix("erase-check", {"device": "/dev/sde", "name": "sde (Samsung SSD 860, 500 GB)", "confirm_name": "sde", "serial": "X", "why": "", "why_text": "", "detail": "", "table": "gpt", "token": "", "eligible": True, "frozen": True, "diskseq": 9, "erase_minutes": 4, "size": 500 * GB,
                    "partitions": [{"device": "/dev/sde1", "label": "DATA", "fstype": "ext4", "mountpoint": "", "size": 500 * GB}]})
win.open_maintenance(win.device_by_id(BK["stable_id"]))
pump(timeout=0.5)
shot(win, OUT / f"app-erase{suffix}.png")

# The same window where there is little room
small = MainWindow(app)
small.set_default_size(420, 700)
small.present()
assert pump(lambda: small.loaded, 8)
pump(timeout=0.5)
small.show_device(SEA_UNMOUNTED["stable_id"], "health")
pump(timeout=0.8)
shot(small, OUT / f"app-narrow{suffix}.png")
print("written to", OUT)
