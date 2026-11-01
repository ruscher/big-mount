"""The one way to the disks: `bigmount --drive ... --json`, without ever blocking
the window. Commands are lists of arguments, never a line for a shell. Only a
question is ever given up on, when it does not end or the window closes. An
operation (mount, unmount, removal, the start of a job) always runs to its end,
and a job has its own supervisor."""

import json
import os
import signal
import tempfile

from gi.repository import Gio, GLib

from .common import BIGMOUNT, ngettext

# A question about the system has a limit; an operation does not
ASK_SECONDS = 60


class Result:
    __slots__ = ("data", "code", "out", "err")

    def __init__(self, data, code, out, err):
        self.data = data
        self.code = code
        self.out = out
        self.err = err

    @property
    def ok(self):
        return self.code == 0

    @property
    def message(self):
        """What to tell a person when this went wrong."""
        if isinstance(self.data, dict):
            for key in ("error_text", "text", "reason"):
                if self.data.get(key):
                    return self.data[key]
        return self.err.strip() or self.out.strip()


class Engine:
    def __init__(self, program=None):
        self.program = program or os.environ.get("BM_GUI_BIN") or BIGMOUNT
        self._questions = set()
        # Changes to a drive in flight: the window stays open until they end
        self.operations = set()

    def run(self, args, callback=None, json_output=True, limit=ASK_SECONDS, drive=True, operation=False):
        """callback(Result). limit: seconds, or None for no limit. operation: it
        changes something, so it is never given up on."""
        argv = [self.program]
        if drive:
            argv.append("--drive")
        argv += list(args)
        if json_output:
            argv.append("--json")
        flags = Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
        try:
            proc = Gio.Subprocess.new(argv, flags)
        except GLib.Error as exc:
            if callback:
                failure = Result(None, 127, "", exc.message)
                GLib.idle_add(lambda: callback(failure) and False)
            return None
        running = self.operations if operation else self._questions
        running.add(proc)
        timer = 0
        timed_out = False

        def give_up():
            nonlocal timer, timed_out
            timer = 0
            timed_out = True
            proc.send_signal(signal.SIGTERM)
            return False
        if limit and not operation:
            timer = GLib.timeout_add_seconds(limit, give_up)

        def finished(p, res):
            if timer:
                GLib.source_remove(timer)
            running.discard(p)
            out, err = b"", b""
            try:
                _ok, stdout, stderr = p.communicate_finish(res)
                out = stdout.get_data() if stdout else b""
                err = stderr.get_data() if stderr else b""
            except GLib.Error as exc:
                err = exc.message.encode("utf-8", "replace")
            text = out.decode("utf-8", "replace") if out else ""
            data = None
            if json_output and text.strip():
                try:
                    data = json.loads(text)
                except ValueError:
                    data = None
            code = p.get_exit_status() if p.get_if_exited() else 128
            err = err.decode("utf-8", "replace") if err else ""
            if timed_out:
                err = ngettext("No answer from the system in %d second.", "No answer from the system in %d seconds.", limit) % limit
            if callback:
                callback(Result(data, code, text, err))

        proc.communicate_async(None, None, finished)
        return proc

    def shutdown(self):
        """Questions still being asked have nobody left to answer to."""
        for proc in list(self._questions):
            proc.send_signal(signal.SIGTERM)
        self._questions.clear()

    # ----- questions
    def list_devices(self, cb):
        self.run(["list"], cb)

    def inspect(self, target, cb):
        self.run(["inspect", target], cb)

    def diagnose(self, target, cb, smart=False):
        self.run(["diagnose", target, *(["--smart"] if smart else [])], cb, limit=None if smart else ASK_SECONDS)

    def resolve(self, target, cb):
        self.run(["resolve", target], cb)

    def methods(self, target, cb):
        self.run(["methods", target], cb)

    def destinations(self, cb, source=None, device=None, need=0):
        args = ["destinations"]
        if source:
            args += ["--source", source]
        if device:
            args += ["--device", device]
        if need:
            args += ["--need", str(need)]
        self.run(args, cb)

    def jobs(self, cb):
        self.run(["jobs"], cb)

    def status(self, job_id, cb):
        self.run(["status", job_id], cb)

    def results(self, job_id, cb):
        self.run(["results", job_id], cb)

    def report_text(self, target, cb):
        self.run(["report", target], cb, json_output=False)

    def report_file(self, target, path, anonymize, cb):
        self.run(["report", target, "--output", path, "--replace", *(["--anonymize"] if anonymize else [])],
                 cb, json_output=False, operation=True)

    # ----- operations
    def mount(self, device, cb, protect=False, remount=False, diskseq=None):
        args = ["mount", device, "--read-only"]
        if protect:
            args.append("--protect")
        if remount:
            args.append("--remount")
        if diskseq is not None:
            args += ["--expect-diskseq", str(diskseq)]
        self.run(args, cb, operation=True)

    def unmount(self, device, cb, allow_services=False):
        self.run(["unmount", device, *(["--allow-services"] if allow_services else [])], cb, operation=True)

    def safe_remove(self, device, cb, allow_services=False):
        self.run(["safe-remove", device, *(["--allow-services"] if allow_services else [])], cb, operation=True)

    def busy(self, device, cb):
        self.run(["busy", device], cb)

    def close_apps(self, device, cb):
        self.run(["close-apps", device], cb, operation=True)

    def protect(self, device, cb, on=True):
        self.run(["protect" if on else "unprotect", device], cb, json_output=False, operation=True)

    def partitions(self, target, cb, search=False):
        self.run(["partitions", target, *(["--search"] if search else [])], cb, limit=None)

    def copy(self, cb, source=None, destination="", dry_run=False, items=None, results_of=None,
             on_conflict="skip", verify="basic", stall=90, bwlimit=0, scan=None):
        """items: names (bytes) relative to the source. They go in a private file that
        the engine reads when it starts (a job keeps its own copy), removed when it ends."""
        args = ["copy"]
        if results_of:
            args += ["--results-of", results_of]
        else:
            args += ["--source", source]
        args += ["--destination", destination, "--on-conflict", on_conflict, "--verify", verify, "--stall-seconds", str(stall)]
        if bwlimit:
            args += ["--bwlimit", str(bwlimit)]
        path = None
        if items:
            try:
                path = write_items(items)
            except OSError as exc:
                # The runtime folder is full or cannot be written: the usual failure
                if cb:
                    failure = Result(None, 1, "", f"{exc.filename or ''}: {exc.strerror}")
                    GLib.idle_add(lambda: cb(failure) and False)
                return
            args += ["--items-from", path]
        if scan:
            args += ["--scan", scan]
        args.append("--dry-run" if dry_run else "--no-wait")

        def done(res):
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass
            if cb:
                cb(res)
        self.run(args, done, limit=None, operation=not dry_run)

    def scan(self, cb, source, categories="all", copy_to="", dry_run=False):
        args = ["scan", "--source", source, "--categories", categories]
        if copy_to:
            args += ["--copy-to", copy_to]
        args.append("--dry-run" if dry_run else "--no-wait")
        self.run(args, cb, operation=not dry_run)

    def carve(self, cb, source, destination, categories="all", dry_run=False):
        args = ["carve", "--source", source, "--destination", destination, "--categories", categories]
        args.append("--dry-run" if dry_run else "--no-wait")
        self.run(args, cb, operation=not dry_run)

    def image(self, cb, source, image, diskseq=None, then_carve="", categories="", dry_run=False):
        args = ["image", "--source", source, "--image", image]
        if diskseq is not None:
            args += ["--expect-diskseq", str(diskseq)]
        if then_carve:
            args += ["--then-carve", then_carve]
        if categories:
            args += ["--categories", categories]
        args.append("--dry-run" if dry_run else "--no-wait")
        self.run(args, cb, operation=not dry_run)

    def pause(self, job_id, cb):
        self.run(["pause", job_id], cb, json_output=False, operation=True)

    def cancel(self, job_id, cb):
        self.run(["cancel", job_id], cb, json_output=False, operation=True)

    def resume(self, job_id, cb, retry=False):
        self.run(["resume", job_id, "--no-wait", *(["--retry-deferred"] if retry else [])], cb, json_output=False, operation=True)

    # ----- Secure Erase: asks, a ticket, and the erase. See drive-erase.sh
    def erase_check(self, device, cb):
        self.run(["erase-check", device], cb)

    def erase_prepare(self, device, cb):
        self.run(["erase-prepare", device], cb)

    def erase_run(self, token, typed, cb, allow_services=False, unfreeze=False):
        args = ["__erase-run", token, "--typed", typed]
        if allow_services:
            args.append("--allow-services")
        if unfreeze:
            args.append("--unfreeze")
        self.run(args, cb, operation=True)


def write_items(items):
    """NUL-separated, private, for `copy --items-from`. Names as raw bytes: a name
    from an old disk may not be valid UTF-8, and it must reach rsync as it is."""
    folder = os.path.join(GLib.get_user_runtime_dir(), "big-mount")
    os.makedirs(folder, mode=0o700, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix="items-", dir=folder)
    try:
        with os.fdopen(fd, "wb") as handle:
            for item in items:
                handle.write(item + b"\0")
    except OSError:
        os.unlink(path)
        raise
    return path
