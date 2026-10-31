"""Home: every drive at a glance, with what can be done with it."""

from gi.repository import Adw, Gtk

from .. import widgets as w
from ..common import _, human_size


class DriveCard(Gtk.FlowBoxChild):
    def __init__(self, window, dev):
        super().__init__(css_classes=["drive-slot"])
        self.dev = dev
        self.window = window
        card = w.box(spacing=12, css=("card", "drive-card"))
        head = w.hbox(12)
        image = w.icon(dev.symbolic_icon, 32, css=("drive-card-icon",))
        image.set_valign(Gtk.Align.START)
        head.append(image)
        names = w.box(spacing=2)
        names.set_hexpand(True)
        title = w.label(dev.name, css=("heading",))
        title.set_max_width_chars(24)
        names.append(title)
        names.append(w.label(dev.subtitle, css=("caption", "dim-label")))
        head.append(names)
        card.append(head)
        badge = w.LevelBadge(dev.health.level, dev.health.label, compact=True)
        badge.set_size_request(240, -1)
        card.append(badge)
        space = dev.space
        if space:
            card.append(w.UsageBar(*space))
        volumes = w.box(spacing=2)
        for vol in dev.content_volumes[:3]:
            parts = [vol.title, vol.fstype or "", vol.state_label]
            line = w.label(" · ".join(p for p in parts if p), css=("caption", "dim-label"), ellipsize=True)
            line.set_max_width_chars(36)
            volumes.append(line)
        if len(dev.content_volumes) > 3:
            volumes.append(w.label(_("and %d more") % (len(dev.content_volumes) - 3), css=("caption", "dim-label")))
        card.append(volumes)
        spacer = Gtk.Box(vexpand=True)
        card.append(spacer)
        mounted = [v for v in dev.content_volumes if v.mounted and v.state != "system"]
        rescue_style = ("suggested-action",) if dev.health.risky else ()
        buttons = []
        if len(mounted) == 1:
            buttons.append(w.button(_("Open files"), lambda: w.open_folder(window, mounted[0].mountpoint), icon_name="folder-open-symbolic"))
        if dev.kind != "optical":
            buttons.append(w.button(_("Recover files"), lambda: window.open_wizard(dev), css=rescue_style, icon_name="document-save-symbolic"))
        if dev.kind != "image":
            buttons.append(w.button(_("Check drive"), lambda: window.show_device(dev.stable_id, "health"), icon_name="system-search-symbolic"))
        card.append(w.button_row(*buttons))
        # Its natural width decides how many fit side by side, whatever the texts ask for
        self.set_child(Adw.Clamp(maximum_size=350, tightening_threshold=300, unit=Adw.LengthUnit.PX, child=card))
        self.update_property([Gtk.AccessibleProperty.LABEL], [f"{dev.name}, {dev.subtitle}, {dev.health.label}"])


class OverviewPage(Adw.NavigationPage):
    def __init__(self, window):
        super().__init__(title=_("Big-Mount"), tag="home")
        self.window = window
        self._signature = None

        self.content = w.box(spacing=18)
        self.content.append(w.label(_("Your drives and devices"), css=("title-1",)))
        self.content.append(w.label(_("Choose a drive to see its files, check its health or recover data."), css=("dim-label",)))
        self.alerts = w.box(spacing=6)
        self.content.append(self.alerts)
        self.running = w.box(spacing=6)
        self.content.append(self.running)
        self.flow = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=14, row_spacing=14,
                                min_children_per_line=1, max_children_per_line=3, homogeneous=True, activate_on_single_click=True)
        self.flow.update_property([Gtk.AccessibleProperty.LABEL], [_("Your drives and devices")])
        self.flow.connect("child-activated", lambda _f, child: window.show_device(child.dev.stable_id))
        self.content.append(self.flow)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.stack.add_named(w.page_scroller(self.content, maximum=1180), "list")
        self.stack.add_named(Adw.StatusPage(icon_name="drive-harddisk-symbolic", title=_("Looking at what is connected…")), "loading")
        self.stack.add_named(Adw.StatusPage(icon_name="drive-harddisk-symbolic", title=_("No storage device was found."),
                                            description=_("Connect a drive and it appears here by itself.")), "empty")
        self.stack.set_visible_child_name("loading")

        header = Adw.HeaderBar()
        header.pack_end(w.icon_button("view-refresh-symbolic", _("Refresh"), window.refresh))
        tool = Adw.ToolbarView(content=self.stack)
        tool.add_top_bar(header)
        self.set_child(tool)

    def update(self):
        win = self.window
        if not win.loaded:
            return
        if not win.devices:
            self.stack.set_visible_child_name("empty")
        else:
            self.stack.set_visible_child_name("list")
        signature = repr(win.devices) + repr([(j.id, j.state, j.bytes_done) for j in win.jobs if j.running]) + str(win.partial)
        if signature == self._signature:
            return
        self._signature = signature
        w.clear(self.flow)
        for dev in win.devices:
            self.flow.append(DriveCard(win, dev))
        w.clear(self.alerts)
        for dev in win.devices:
            if dev.health.level == "critical":
                self.alerts.append(self._alert(dev, _("%s reported serious problems. Copy your files to another drive before trying any repair.") % dev.name))
        if win.partial:
            self.alerts.append(self._plain_alert(_("A mounted device did not answer in time, so free space is not shown.")))
        w.clear(self.running)
        for job in [j for j in win.jobs if j.running]:
            self.running.append(self._running_row(job))

    def _alert(self, dev, text):
        return w.notice(text, "critical", _("Rescue my files"), lambda: self.window.open_wizard(dev))

    def _plain_alert(self, text):
        return w.notice(text)

    def _running_row(self, job):
        group = w.Group()
        done = human_size(job.bytes_done)
        r = w.row(f"{job.state_label}", f"{job.source} — {done}", activatable=True, icon_name="media-playback-start-symbolic")
        r.add_suffix(w.icon("go-next-symbolic"))
        r.connect("activated", lambda *_a: self.window.open_job(job.id))
        group.add_row(r)
        return group
