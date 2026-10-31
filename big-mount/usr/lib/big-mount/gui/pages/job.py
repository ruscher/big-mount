"""A job, running or finished. Real numbers only: without a total the bar says it
is working and no more, and a missing answer is not called a crash."""

import os

from gi.repository import Adw, GLib, Gtk

from .. import widgets as w
from ..common import _, human_duration, human_size, human_time
from ..models import Job, RESULT_CARVED, RESULT_EXISTING
from .device import job_row

POLL_MS = 1500
PULSE_MS = 180


def animations_on():
    settings = Gtk.Settings.get_default()
    return settings is None or settings.get_property("gtk-enable-animations")


class JobPage(Adw.NavigationPage):
    def __init__(self, window, job_id):
        super().__init__(title=_("Working"), tag=f"job-{job_id}")
        self.window = window
        self.job_id = job_id
        self.job = None
        self._poll = 0
        self._pulse = 0
        self._busy = False
        self._report_state = None

        content = w.box(spacing=16)
        self.state_icon = w.icon("media-playback-start-symbolic", 32)
        self.spinner = Gtk.Spinner()
        self.spinner.set_size_request(32, 32)
        self.title = w.label(_("Looking…"), css=("title-1",))
        self.title.set_accessible_role(Gtk.AccessibleRole.STATUS)
        self.subtitle = w.label("", css=("dim-label",))
        head = w.hbox(14)
        head.append(self.spinner)
        head.append(self.state_icon)
        names = w.box(spacing=2)
        names.set_hexpand(True)
        names.append(self.title)
        names.append(self.subtitle)
        head.append(names)
        content.append(head)

        self.percent = w.label("", css=("big-percent", "numeric"))
        content.append(self.percent)
        self.bar = Gtk.ProgressBar()
        self.bar.update_property([Gtk.AccessibleProperty.LABEL], [_("Progress")])
        content.append(self.bar)
        self.phase = w.label("", css=("caption", "dim-label"))
        content.append(self.phase)

        self.stats = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=8, row_spacing=8, min_children_per_line=2, max_children_per_line=5)
        self.stat = {}
        for key, caption in (("files", _("Files")), ("examined", _("Files examined")), ("bytes", _("Data")), ("speed", _("Speed")),
                             ("elapsed", _("Elapsed")), ("eta", _("Remaining")), ("aside", _("Set aside")), ("failed", _("Failed"))):
            self.stat[key] = w.Stat(caption)
            self.stats.append(self.stat[key])
        content.append(self.stats)

        self.reason = w.label("")
        content.append(self.reason)
        self.current = w.label("", css=("caption", "dim-label"), ellipsize=True)
        content.append(self.current)

        self.route_group = w.Group()
        self.source_row = w.fact_row(_("Source"), "")
        self.dest_row = w.fact_row(_("Destination"), "")
        self.route_group.add_row(self.source_row)
        self.route_group.add_row(self.dest_row)
        content.append(self.route_group)

        self.report_expander = Gtk.Expander(label=_("Report"))
        self.report_view = w.label("", css=("monospace", "caption"), selectable=True)
        self.report_expander.set_child(self.report_view)
        self.report_expander.set_visible(False)
        content.append(self.report_expander)

        self.actions = Gtk.ActionBar()
        self.cancel_btn = w.button(_("Cancel"), self._cancel, icon_name="process-stop-symbolic")
        self.pause_btn = w.button(_("Pause"), self._pause, icon_name="media-playback-pause-symbolic")
        self.resume_btn = w.button(_("Resume"), lambda: self._resume(False), css=("suggested-action",), icon_name="media-playback-start-symbolic")
        self.retry_btn = w.button(_("Try set-aside files again"), lambda: self._resume(True),
                                  tooltip=_("Reads the damaged areas again, which puts more strain on the disk."))
        self.results_btn = w.button(_("See what was found"), lambda: window.open_results(self.job_id), css=("suggested-action",), icon_name="view-list-bullet-symbolic")
        self.next_btn = w.button(_("Search this image for files"), self._search_image, css=("suggested-action",), icon_name="system-search-symbolic")
        self.open_btn = w.button(_("Open destination"), self._open_dest, icon_name="folder-open-symbolic")
        self.log_btn = w.button(_("Show log"), self._show_log, css=("flat",))
        for b in (self.log_btn, self.cancel_btn):
            self.actions.pack_start(b)
        for b in (self.next_btn, self.results_btn, self.resume_btn, self.retry_btn, self.pause_btn, self.open_btn):
            self.actions.pack_end(b)
            b.set_visible(False)

        tool = Adw.ToolbarView(content=w.page_scroller(content))
        tool.add_top_bar(Adw.HeaderBar())
        tool.add_bottom_bar(self.actions)
        self.set_child(tool)
        self.connect("showing", lambda *_a: self.start())
        self.connect("hiding", lambda *_a: self.stop())

    def start(self):
        self.poll()
        if not self._poll:
            self._poll = GLib.timeout_add(POLL_MS, self.poll)

    def stop(self):
        if self._poll:
            GLib.source_remove(self._poll)
            self._poll = 0
        self._stop_pulse()

    def poll(self):
        if not self._busy:
            self._busy = True
            self.window.engine.status(self.job_id, self._polled)
        return True

    def _polled(self, res):
        self._busy = False
        if isinstance(res.data, dict):
            self.apply(Job.from_json(res.data))
        elif not res.ok:
            self.title.set_text(res.message or _("This job no longer exists."))
            self.stop()

    def _start_pulse(self):
        if not self._pulse and animations_on():
            self._pulse = GLib.timeout_add(PULSE_MS, lambda: (self.bar.pulse(), True)[1])

    def _stop_pulse(self):
        if self._pulse:
            GLib.source_remove(self._pulse)
            self._pulse = 0

    def apply(self, job):
        previous = self.job
        self.job = job
        running = job.running
        self.set_title(job.state_label)
        self.title.set_text(job.state_label)
        self.subtitle.set_text(job.kind_label)
        self.spinner.set_visible(running)
        self.spinner.set_spinning(running)
        self.state_icon.set_visible(not running)
        self.state_icon.set_from_icon_name(job.icon)

        done, total = job.bytes_done or 0, job.bytes_total or 0
        pct = min(100, done * 100 // total) if total else None
        if pct is not None:
            self._stop_pulse()
            self.bar.set_fraction(pct / 100)
            self.percent.set_text(("≈ " if job.total_estimate else "") + f"{pct}%")
        elif running:
            self._start_pulse()
            self.percent.set_text("")
        else:
            self._stop_pulse()
            self.bar.set_fraction(1.0 if job.state == "completed" else 0.0)
            self.percent.set_text("")
        self.percent.set_visible(bool(self.percent.get_text()))
        self.bar.set_visible(running or pct is not None or job.state == "completed")

        phase = ""
        if running and job.kind == "carve" and job.pass_:
            phase = _("Pass %d of the search. The percentage restarts at each pass.") % job.pass_
        elif running and job.kind == "scan":
            phase = _("It goes through the folders, so the total is only known at the end.")
        elif running and pct is None and job.kind == "copy":
            phase = _("The total is not measured on a drive at risk, to avoid extra reads. It shows what was copied so far.")
        self.phase.set_text(phase)
        self.phase.set_visible(bool(phase))

        files = f"{job.files_done}"
        if job.files_total:
            files += f" / {job.files_total}"
        self.stat["files"].caption.set_text(job.count_label)
        self.stat["files"].set_value(files if job.kind != "image" else "")
        self.stat["examined"].set_value(str(job.scanned) if job.kind == "scan" else "")
        data = human_size(done)
        if total:
            data += (" / ≈ " if job.total_estimate else " / ") + human_size(total)
        self.stat["bytes"].set_value(data)
        self.stat["speed"].set_value(f"{human_size(job.rate_now)}/s" if running and job.rate_now else "")
        self.stat["elapsed"].set_value(human_time(job.elapsed))
        self.stat["eta"].set_value(human_duration(job.eta) if running and job.eta is not None else "")
        self.stat["aside"].set_value(str(job.deferred) if job.deferred else "")
        self.stat["failed"].set_value(str(job.failed) if job.failed else "")
        for key in self.stat:
            parent = self.stat[key].get_parent()
            if parent:
                parent.set_visible(self.stat[key].get_visible())

        reason = job.reason_text
        if job.kind == "image" and job.bad_bytes:
            reason = (reason + " " if reason else "") + _("%s could not be read.") % human_size(job.bad_bytes)
        self.reason.set_text(reason)
        self.reason.set_visible(bool(reason))
        current = job.current if running else ""
        if running and (job.stuck or 0) > 5:
            what = _("Waiting for the disk to answer, for %s seconds") % job.stuck
            current = f"{what} — {current}" if current else what
        self.current.set_text(current)
        self.current.set_visible(bool(current))

        self.source_row.set_subtitle(job.source)
        self.dest_row.set_subtitle(job.destination)
        self.dest_row.set_visible(bool(job.destination))

        self.pause_btn.set_visible(running and job.pausable)
        self.pause_btn.set_sensitive(job.state != "stopping")
        self.cancel_btn.set_visible(running)
        self.cancel_btn.set_sensitive(job.state != "stopping")
        self.resume_btn.set_visible(job.can_resume)
        self.resume_btn.set_child(Adw.ButtonContent(label=_("Search again") if job.kind in ("scan", "carve") else _("Resume"),
                                                    icon_name="media-playback-start-symbolic"))
        self.retry_btn.set_visible(job.state in ("needs-attention", "completed", "paused", "interrupted") and job.deferred > 0)
        self.results_btn.set_visible(job.has_results and job.files_done > 0)
        self.open_btn.set_visible(bool(job.destination) and not running and job.kind != "image" and os.path.isdir(job.destination))
        self.next_btn.set_visible(job.kind == "image" and not running and job.state in ("completed", "needs-attention") and bool(job.then_carve))

        if not running:
            self.stop()
            if job.state != self._report_state:
                self._report_state = job.state
                self.window.engine.report_text(self.job_id, self._report)
                self.window.refresh_jobs()
        elif previous and not previous.running:
            self.report_expander.set_visible(False)
            self._report_state = None

    def _report(self, res):
        text = res.out or res.err
        self.report_view.set_text(text)
        self.report_expander.set_visible(bool(text.strip()))

    def _pause(self):
        self.window.engine.pause(self.job_id, lambda _r: self.poll())

    def _cancel(self):
        job = self.job
        if not job:
            return
        text = _("Stop the search? What was found so far stays.") if job.kind in ("scan", "carve") else \
            _("Stop the copy? Files already copied stay at the destination, and the copy can be resumed later.")

        def answered(rid):
            if rid == "stop":
                self.window.engine.cancel(self.job_id, lambda _r: self.poll())
        w.alert(self.window, _("Stop this work?"), text, responses=(("keep", _("Keep working")), ("stop", _("Stop"))),
                default="keep", close="keep", destructive=("stop",), callback=answered)

    def _resume(self, retry):
        def done(res):
            if res.err.strip():
                self.window.notify_text(res.err.strip())
            self.start()
            self.window.refresh_jobs()
        self.window.engine.resume(self.job_id, done, retry=retry)

    def _search_image(self):
        job = self.job

        def started(res):
            data = res.data or {}
            if data.get("id"):
                self.window.refresh_jobs()
                self.window.open_job(data["id"], replace_top=True)
            else:
                w.alert(self.window, _("The search did not start"), res.message)
        self.window.engine.carve(started, job.destination, job.then_carve, job.categories or "all")

    def _open_dest(self):
        if self.job:
            w.open_folder(self.window, self.job.destination)

    def _show_log(self):
        job = self.job
        if not job:
            return
        name = {"image": "ddrescue.out", "scan": "scan.err", "carve": "report.txt"}.get(job.kind, "events.log")
        path = os.path.join(job.dir or "", name)
        try:
            with open(path, "rb") as handle:
                handle.seek(0, os.SEEK_END)
                handle.seek(max(0, handle.tell() - 200000))
                text = handle.read().decode("utf-8", "replace")
        except OSError as exc:
            text = str(exc)
        w.TextDialog(_("Log"), text or _("Nothing was recorded.")).present(self.window)


class JobsPage(Adw.NavigationPage):
    """Everything copied or searched, on any drive."""

    def __init__(self, window):
        super().__init__(title=_("Copies and searches"), tag="jobs")
        self.window = window
        self.box = w.box(spacing=18)
        self.box.append(w.label(_("Copies and searches"), css=("title-1",)))
        self.box.append(w.label(_("They keep working with this window closed, and what stopped can be resumed."), css=("dim-label",)))
        self.group = w.Group()
        self.box.append(self.group)
        self.empty = Adw.StatusPage(icon_name="folder-download-symbolic", title=_("No copies or images yet."),
                                    description=_("When you recover files, the work is listed here."))
        self.box.append(self.empty)
        tool = Adw.ToolbarView(content=w.page_scroller(self.box))
        tool.add_top_bar(Adw.HeaderBar())
        self.set_child(tool)
        self._signature = None

    def update(self):
        signature = repr([(j.id, j.state, j.source, j.destination) for j in self.window.jobs])
        if signature == self._signature:
            return
        self._signature = signature
        self.group.clear_rows()
        for job in self.window.jobs:
            self.group.add_row(job_row(self.window, job))
        self.empty.set_visible(not self.window.jobs)
        self.group.set_visible(bool(self.window.jobs))


__all__ = ["JobPage", "JobsPage", "RESULT_CARVED", "RESULT_EXISTING"]
