"""The window: drives on the side, what is being looked at beside them, and one
place that knows the drives and the jobs. Pages never ask for a list themselves."""

from gi.repository import Adw, GLib, Gtk

from . import widgets as w
from .about import create_about
from .common import _, ngettext
from .engine import Engine
from .models import Device, Job, find_device
from .monitor import DeviceMonitor
from .pages.device import DevicePage
from .pages.job import JobPage, JobsPage
from .pages.maintenance import MaintenancePage
from .pages.overview import OverviewPage
from .pages.rescue import RescueWizard
from .pages.results import ResultsPage
from .welcome import WelcomeDialog

JOBS_SECONDS = 5


class Route(Gtk.ListBoxRow):
    def __init__(self, kind, value=None):
        super().__init__()
        self.kind = kind
        self.value = value


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, app, engine=None):
        super().__init__(application=app, title=_("Big-Mount"), default_width=1080, default_height=720)
        self.set_size_request(360, 420)
        self.set_icon_name("big-mount")
        self.engine = engine or Engine()
        self.devices = []
        self.jobs = []
        self.partial = False
        self.loaded = False
        self.selected_id = None
        self.pending_route = None
        self._listing = False
        self._relist = False
        self._jobs_timer = 0
        self._jobs_busy = False
        self.erase_running = False
        self._closing = False
        self._inhibit = 0
        self.wizard = None

        self.toasts = Adw.ToastOverlay()
        self.nav = Adw.NavigationView()
        self.split = Adw.NavigationSplitView(min_sidebar_width=240, max_sidebar_width=320, sidebar_width_fraction=0.26)
        self.split.set_sidebar(self._build_sidebar())
        self.split.set_content(Adw.NavigationPage(title=_("Big-Mount"), child=self.nav))
        self.toasts.set_child(self.split)
        self.set_content(self.toasts)

        self.overview = OverviewPage(self)
        self.device_page = DevicePage(self)
        self.jobs_page = JobsPage(self)
        self.nav.add(self.overview)

        narrow = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 720sp"))
        narrow.add_setter(self.split, "collapsed", True)
        self.device_page.add_breakpoint_setters(narrow)
        self.add_breakpoint(narrow)

        self.connect("close-request", self._close_request)

        self.monitor = DeviceMonitor()
        self.monitor.connect("changed", lambda *_a: self.refresh())
        self.refresh()
        self.refresh_jobs()

    # ----- the side
    def _build_sidebar(self):
        self.side_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE, css_classes=["navigation-sidebar"])
        self.side_list.update_property([Gtk.AccessibleProperty.LABEL], [_("Your drives and devices")])
        self.side_list.connect("row-activated", self._side_activated)
        self.side_list.set_header_func(self._side_header)
        scroller = Gtk.ScrolledWindow(child=self.side_list, vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)

        menu_button = Gtk.MenuButton(icon_name="open-menu-symbolic", tooltip_text=_("Main menu"), menu_model=self._menu())
        menu_button.update_property([Gtk.AccessibleProperty.LABEL], [_("Main menu")])
        header = Adw.HeaderBar()
        header.pack_end(menu_button)
        header.set_title_widget(Adw.WindowTitle(title=_("Big-Mount")))
        tool = Adw.ToolbarView(content=scroller)
        tool.add_top_bar(header)
        return Adw.NavigationPage(title=_("Big-Mount"), child=tool)

    def _menu(self):
        from gi.repository import Gio
        menu = Gio.Menu()
        menu.append(_("Refresh"), "app.refresh")
        about = Gio.Menu()
        about.append(_("Welcome screen"), "app.welcome")
        about.append(_("About Big-Mount"), "app.about")
        menu.append_section(None, about)
        return menu

    def _side_header(self, row, before):
        if row.kind == "device" and (before is None or before.kind != "device"):
            head = w.label(_("Drives"), css=("caption-heading", "dim-label"))
            head.set_margin_start(12)
            head.set_margin_top(10)
            head.set_margin_bottom(4)
            row.set_header(head)
        elif row.kind == "job":
            row.set_header(None)
        elif row.kind == "jobs":
            sep = Gtk.Separator()
            sep.set_margin_top(8)
            sep.set_margin_bottom(8)
            row.set_header(sep)
        else:
            row.set_header(None)

    def _side_row(self, kind, value, title, icon_name, subtitle=None, level=None):
        row = Route(kind, value)
        if kind == "jobs" and value[1]:
            subtitle = ngettext("%d running", "%d running", value[1]) % value[1]
        inner = w.hbox(10)
        inner.set_margin_top(6)
        inner.set_margin_bottom(6)
        inner.append(w.icon(icon_name))
        text = w.box()
        text.set_hexpand(True)
        text.append(w.label(title, ellipsize=True))
        if subtitle:
            text.append(w.label(subtitle, css=("caption", "dim-label"), ellipsize=True))
        inner.append(text)
        if level in ("critical", "attention"):
            badge = w.icon("dialog-error-symbolic" if level == "critical" else "dialog-warning-symbolic", css=("level-icon", f"level-{level}"))
            badge.set_valign(Gtk.Align.CENTER)
            inner.append(badge)
        if kind == "jobs":
            total, running = value
            count = w.label(str(total), css=("count-badge",) if running else ("count-badge", "count-idle"), wrap=False)
            count.set_valign(Gtk.Align.CENTER)
            inner.append(count)
        row.set_child(inner)
        accessible = title if not subtitle else f"{title}, {subtitle}"
        if kind == "jobs":
            accessible = f"{title}, {value[0]}" + (f", {subtitle}" if subtitle else "")
        row.update_property([Gtk.AccessibleProperty.LABEL], [accessible])
        return row

    def _job_row(self, job):
        """A running job under 'Copies and searches': its progress, a click away."""
        row = Route("job", job.id)
        inner = w.box(spacing=4)
        inner.set_margin_top(4)
        inner.set_margin_bottom(6)
        inner.set_margin_start(28)
        top = w.hbox(6)
        name = w.label(job.title, css=("caption",), ellipsize=True)
        name.set_hexpand(True)
        top.append(name)
        pct = w.label(job.percent_text, css=("caption", "numeric"), wrap=False)
        top.append(pct)
        inner.append(top)
        bar = Gtk.ProgressBar()
        if job.percent is not None:
            bar.set_fraction(job.percent / 100)
        else:
            # No measured total: a bar that says it is working, never a made-up share
            bar.pulse()
        inner.append(bar)
        inner.append(w.label(job.state_label, css=("caption", "dim-label"), ellipsize=True))
        row.set_child(inner)
        text = f"{job.state_label}: {job.title}" + (f", {job.percent_text}" if job.percent_text else "")
        bar.update_property([Gtk.AccessibleProperty.LABEL], [text])
        row.update_property([Gtk.AccessibleProperty.LABEL], [text])
        row.set_tooltip_text(text)
        return row

    def _fill_sidebar(self):
        w.clear(self.side_list)
        self.side_list.append(self._side_row("home", None, _("Home"), "go-home-symbolic"))
        for dev in self.devices:
            self.side_list.append(self._side_row("device", dev.stable_id, dev.name, dev.symbolic_icon, dev.subtitle, dev.health.level))
        running = [j for j in self.jobs if j.running]
        self.side_list.append(self._side_row("jobs", (len(self.jobs), len(running)), _("Copies and searches"), "folder-download-symbolic"))
        for job in running:
            self.side_list.append(self._job_row(job))
        self._mark_sidebar()

    def _mark_sidebar(self):
        page = self.nav.get_visible_page()
        want = ("home", None)
        if page is self.jobs_page:
            want = ("jobs", None)
        elif isinstance(page, JobPage) and not self.selected_id:
            want = ("job", page.job_id)
        elif self.selected_id and page is not self.overview:
            want = ("device", self.selected_id)
        index = 0
        while (row := self.side_list.get_row_at_index(index)) is not None:
            if row.kind == want[0] and (want[0] not in ("device", "job") or row.value == want[1]):
                self.side_list.select_row(row)
                return
            index += 1
        self.side_list.unselect_all()

    def _side_activated(self, _list, row):
        if row.kind == "home":
            self.show_overview()
        elif row.kind == "device":
            self.show_device(row.value)
        elif row.kind == "job":
            self.show_job(row.value)
        else:
            self.show_jobs()
        self.split.set_show_content(True)

    # ----- what is connected
    def refresh(self):
        """One list at a time: a refresh asked meanwhile runs once, after it."""
        if self._listing:
            self._relist = True
            return
        self._listing = True
        self.engine.list_devices(self._listed)

    def _listed(self, res):
        self._listing = False
        if self._relist:
            self._relist = False
            self.refresh()
        if not isinstance(res.data, dict):
            self.notify_text(res.message or _("The list of devices could not be read."))
            self.loaded = True
            self.overview.update()
            return
        self.partial = bool(res.data.get("partial"))
        self.devices = [Device.from_json(d) for d in res.data.get("devices", [])]
        self.loaded = True
        self._fill_sidebar()
        self.overview.update()
        self.device_page.devices_changed()
        if self.wizard:
            self.wizard.devices_changed()
        if self.pending_route is not None:
            target, section = self.pending_route
            self.pending_route = None
            self._route_now(target, section)

    def device_by_id(self, stable_id):
        return find_device(self.devices, stable_id=stable_id)

    def device_by_name(self, name):
        return find_device(self.devices, name=name)

    # ----- jobs
    def refresh_jobs(self):
        if self._jobs_busy:
            return
        self._jobs_busy = True
        self.engine.jobs(self._jobs_listed)

    def _jobs_listed(self, res):
        self._jobs_busy = False
        if isinstance(res.data, dict):
            self.jobs = [Job.from_json(j) for j in res.data.get("jobs", [])]
            self._fill_sidebar()
            self.overview.update()
            self.jobs_page.update()
            self.device_page.jobs_changed()
        # Only while something runs: an idle window does nothing at all
        if any(j.running for j in self.jobs):
            if not self._jobs_timer:
                self._jobs_timer = GLib.timeout_add_seconds(JOBS_SECONDS, self._jobs_tick)
        return

    def _jobs_tick(self):
        self._jobs_timer = 0
        self.refresh_jobs()
        return False

    # ----- where to go
    def route(self, target, section):
        """From the command line, also from a second instance."""
        if not self.loaded:
            self.pending_route = (target, section)
            return
        self._route_now(target, section)

    def _route_now(self, target, section):
        if not target:
            if section == "health" and self.selected_id:
                self.show_device(self.selected_id, section)
            elif section == "health":
                self.notify_text(_("Choose a drive to see how it is doing."))
                self.show_overview()
            else:
                self.show_overview()
            return

        def resolved(res):
            data = res.data or {}
            dev = self.device_by_name(data.get("disk", "")) if res.ok else None
            if dev:
                self.show_device(dev.stable_id, section)
            else:
                self.notify_text(data.get("error_text") or _("This device was not found."))
                self.show_overview()
        self.engine.resolve(target, resolved)

    def _go(self, page):
        pages = [self.overview]
        if page is not self.overview:
            pages.append(page)
        self.nav.replace(pages)
        self.split.set_show_content(True)
        self._mark_sidebar()

    def _erase_holds(self):
        """Secure Erase keeps its page in front until it ends: its outcome must be seen."""
        if not self.erase_running:
            return False
        self.notify_text(_("A drive is being erased"))
        self._mark_sidebar()
        return True

    def show_overview(self):
        if self._erase_holds():
            return
        self.wizard = None
        self.selected_id = None
        self._go(self.overview)

    def show_device(self, stable_id, section=None):
        if self._erase_holds():
            return
        self.wizard = None
        self.selected_id = stable_id
        self.device_page.show(stable_id, section)
        self._go(self.device_page)

    def show_jobs(self):
        if self._erase_holds():
            return
        self.wizard = None
        self.refresh_jobs()
        self._go(self.jobs_page)

    def show_job(self, job_id):
        """From the side: the page of that job, on top of Home."""
        if self._erase_holds():
            return
        self.wizard = None
        self.selected_id = None
        self.nav.replace([self.overview, JobPage(self, job_id)])
        self.split.set_show_content(True)
        self._mark_sidebar()

    def open_wizard(self, device=None, volume=None, image=None):
        self.wizard = RescueWizard(self, device, volume, image)
        self.nav.push(self.wizard)

    def close_wizard(self):
        self.wizard = None
        self.nav.pop()

    def open_job(self, job_id, replace_top=False):
        page = JobPage(self, job_id)
        if replace_top:
            stack = [self.overview]
            if self.selected_id:
                stack.append(self.device_page)
            self.wizard = None
            self.nav.replace([*stack, page])
        else:
            self.nav.push(page)

    def open_results(self, job_id):
        self.nav.push(ResultsPage(self, job_id))

    def open_maintenance(self, device):
        self.nav.push(MaintenancePage(self, device))

    def show_about(self):
        create_about().present(self)

    def show_welcome(self):
        WelcomeDialog().present(self)

    def notify_text(self, text):
        w.toast(self.toasts, text)

    # ----- Secure Erase keeps the computer awake, and the window open
    def set_erase_running(self, running, allow_suspend=False):
        app = self.get_application()
        self.erase_running = running
        if running and app:
            flags = Gtk.ApplicationInhibitFlags.LOGOUT
            if not allow_suspend:
                flags |= Gtk.ApplicationInhibitFlags.SUSPEND
            self._inhibit = app.inhibit(self, flags, _("A drive is being erased"))
        elif self._inhibit and app:
            app.uninhibit(self._inhibit)
            self._inhibit = 0

    def _close_request(self, _window):
        if self.erase_running:
            w.alert(self, _("A drive is being erased"),
                    _("Do not turn off the computer or disconnect the drive. This window can be closed when it ends."))
            return True
        if self.engine.operations:
            w.alert(self, _("Wait a moment"),
                    _("An operation on a drive is still running. This window can be closed when it ends."))
            return True
        running = [j for j in self.jobs if j.running]
        if running and not self._closing:
            def answered(rid):
                if rid == "close":
                    self._closing = True
                    self.close()
            w.alert(self, _("It keeps working"),
                    _("The work continues in the background, also with this window closed. Open Big-Mount again to follow it."),
                    responses=(("stay", _("Stay here")), ("close", _("Close the window"))),
                    default="stay", close="stay", callback=answered)
            return True
        self.monitor.stop()
        self.engine.shutdown()
        return False
