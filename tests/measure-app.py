#!/usr/bin/python3
"""What the application costs, measured: start, memory, CPU when idle, and a long
list of results. Runs on a private display with a stand-in for the engine, so the
numbers are of the window, on any machine, without touching a disk.

Usage: python3 tests/measure-app.py
"""

import os
import pathlib
import resource
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
os.environ["LANGUAGE"] = "C"

from gui_support import REPO, WORK, backup, fix, make_app, pump, seagate, system_disk  # noqa: E402

fix("list", {"partial": False, "devices": [system_disk(), seagate(), backup(WORK)]})
fix("jobs", {"jobs": []})


def rss_kb(pid):
    with open(f"/proc/{pid}/status", encoding="ascii") as handle:
        for line in handle:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat", encoding="ascii") as handle:
        fields = handle.read().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def children_of(pid):
    out = subprocess.run(["ps", "-o", "pid=,stat=,comm=", "--ppid", str(pid)], capture_output=True, text=True).stdout
    return [line.split() for line in out.splitlines() if line.strip()]


def measure_process():
    env = {**os.environ, "DISPLAY": ":none", "PYTHONWARNINGS": "ignore"}
    t0 = time.time()
    proc = subprocess.Popen(["dbus-run-session", "--", "python3", "-I", str(REPO / "big-mount/usr/lib/big-mount/drive-gui.py")],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    pid = None
    while time.time() - t0 < 15 and pid is None:
        found = subprocess.run(["pgrep", "-g", str(proc.pid), "-f", "drive-gui.py"], capture_output=True, text=True).stdout.split()
        pid = next((int(p) for p in found if int(p) != proc.pid and "python3" in open(f"/proc/{p}/cmdline", "rb").read().decode("utf-8", "replace").split("\0")[0]), None)
        time.sleep(0.02)
    calls = WORK / "calls"
    while time.time() - t0 < 15 and not calls.exists():
        time.sleep(0.01)
    start = time.time() - t0
    time.sleep(4)
    rss = rss_kb(pid)
    before = cpu_ticks(pid)
    forks_before = len(calls.read_text().splitlines())
    time.sleep(20)
    used = (cpu_ticks(pid) - before) * 1000 / os.sysconf("SC_CLK_TCK")
    forks = len(calls.read_text().splitlines()) - forks_before
    kids = children_of(pid)
    zombies = [k for k in kids if k[1].startswith("Z")]
    os.killpg(proc.pid, signal.SIGTERM)
    proc.wait()
    print(f"until the list is asked for: {start * 1000:.0f} ms")
    print(f"memory when idle (RSS): {rss / 1024:.0f} MiB")
    print(f"CPU when idle, in 20 s: {used:.0f} ms")
    print(f"engine calls when idle, in 20 s: {forks}")
    print(f"children: {[k[2] for k in kids]}, zombies: {len(zombies)}")


def measure_results(count):
    from gui.pages.results import Index, ResultsModel
    path = WORK / "index-measure"
    with open(path, "wb") as handle:
        for i in range(count):
            handle.write(b"%d\t0\tphotos\tpasta/subpasta/recup_dir.%d/f%09d.jpg\0" % (i, i // 500, i))
    before = rss_kb(os.getpid())
    t0 = time.time()
    index = Index(str(path))
    index.load()
    loaded = time.time() - t0
    t0 = time.time()
    order = index.order({"photos"}, "f0001", "folder")
    filtered = time.time() - t0
    model = ResultsModel()
    model.show(index, index.order(set(), "", "folder"))
    model.get_item(count // 2)
    print(f"{count} records: read in {loaded:.2f} s, search in {filtered:.2f} s ({len(order)} found), "
          f"{(rss_kb(os.getpid()) - before) / 1024:.0f} MiB more")


measure_process()
app = make_app()
for n in (100000, 1000000):
    measure_results(n)
print(f"peak of this process: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024:.0f} MiB")
pump(timeout=0.01)
