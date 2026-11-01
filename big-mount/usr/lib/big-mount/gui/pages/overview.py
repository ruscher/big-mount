"""Home: every drive at a glance, as a list or as a grid, grouped by where it is,
with a search, its health in one word, and what can be done with it."""

from gi.repository import Adw, Gtk

from .. import actions
from .. import widgets as w
from ..common import _, human_size, ngettext, save_setting, setting

VIEWS = ("list", "grid")
CARD_WIDTH = 300
CARD_CHARS = 36


def load_view():
    """The last view chosen, list by default."""
    view = setting("home", "view", "list")
    return view if view in VIEWS else "list"


def save_view(view):
    save_setting("home", "view", view)


def group_of(dev):
    if dev.kind == "image":
        return "image"
    return "external" if dev.external else "internal"


GROUP_TITLES = {
    "internal": lambda: _("On this computer"),
    "external": lambda: _("External devices"),
    "image": lambda: _("Disk images"),
}


def volumes_line(dev):
    """Its volumes in one line: name, filesystem, state, free space."""
    parts = []
    for vol in dev.content_volumes[:3]:
        bits = [vol.title, (vol.fstype or "").upper() if vol.fstype in ("ntfs", "vfat", "exfat") else vol.fstype, vol.state_label]
        if vol.avail is not None:
            bits.append(_("%s free") % human_size(vol.avail))
        parts.append(" · ".join(b for b in bits if b))
    if len(dev.content_volumes) > 3:
        more = len(dev.content_volumes) - 3
        parts.append(ngettext("and %d more", "and %d more", more) % more)
    return "\n".join(parts) or _("No volume recognized")


def quick_buttons(window, dev, icons_only):
    """What is done most: open its files, recover them, remove it safely."""
    buttons = []
    mounted = [v for v in dev.content_volumes if v.mounted and v.state != "system"]

    def make(text, icon_name, callback, css=()):
        if icons_only:
            # A flat button for most; the one that matters now is filled and round
            b = w.icon_button(icon_name, text, callback, css=("circular", *css) if css else ("flat",))
            b.set_valign(Gtk.Align.CENTER)
            return b
        return w.button(text, callback, css=css, icon_name=icon_name)

    if len(mounted) == 1:
        buttons.append(make(_("Open files"), "folder-open-symbolic", lambda: w.open_folder(window, mounted[0].mountpoint)))
    if dev.kind != "optical":
        style = ("suggested-action",) if dev.health.risky else ()
        buttons.append(make(_("Recover files"), "document-save-symbolic", lambda: window.open_wizard(dev), style))
    if dev.external and dev.kind != "image" and not dev.has_system:
        buttons.append(make(_("Safely remove"), "media-eject-symbolic", lambda: actions.unmount(window, dev.device, remove=True)))
    return buttons


class DriveRow(Adw.ActionRow):
    """A drive in the list: one line of what it is, its volumes, its grade, actions."""

    def __init__(self, window, dev):
        super().__init__(use_markup=False, activatable=True)
        # Names of drives and volumes are data: set as text, after markup is off
        self.set_title(dev.name)
        self.set_subtitle(f"{dev.subtitle} · {dev.device}\n{volumes_line(dev)}")
        self.dev = dev
        self.add_css_class("drive-row")
        self.set_title_lines(1)
        self.set_subtitle_lines(4)
        image = w.icon(dev.symbolic_icon, 28, css=("drive-row-icon",))
        image.set_valign(Gtk.Align.CENTER)
        self.add_prefix(image)
        self.add_suffix(w.GradeBadge(dev.health))
        for b in quick_buttons(window, dev, icons_only=True):
            self.add_suffix(b)
        self.add_suffix(actions.drive_menu(window, self, dev))
        self.connect("activated", lambda *_a: window.show_device(dev.stable_id))
        self.update_property([Gtk.AccessibleProperty.LABEL], [f"{dev.name}, {dev.subtitle}, {dev.health.grade_label}"])


class DriveCard(Gtk.FlowBoxChild):
    """A drive in the grid: the same, with room for its usage."""

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
        menu = actions.drive_menu(window, self, dev)
        menu.set_valign(Gtk.Align.START)
        head.append(menu)
        card.append(head)
        grade = w.hbox(8)
        badge = w.GradeBadge(dev.health)
        badge.set_halign(Gtk.Align.START)
        grade.append(badge)
        card.append(grade)
        if dev.health.label:
            detail = w.label(dev.health.label, css=("caption", "dim-label"))
            detail.set_max_width_chars(CARD_CHARS)
            card.append(detail)
        space = dev.space
        if space:
            card.append(w.UsageBar(*space))
        vols = w.label(volumes_line(dev), css=("caption", "dim-label"))
        vols.set_max_width_chars(CARD_CHARS)
        card.append(vols)
        card.append(Gtk.Box(vexpand=True))
        buttons = quick_buttons(window, dev, icons_only=False)
        if buttons:
            card.append(w.button_row(*buttons))
        # Its natural width decides how many fit side by side: long texts wrap instead
        card.set_size_request(CARD_WIDTH, -1)
        self.set_child(card)
        self.update_property([Gtk.AccessibleProperty.LABEL], [f"{dev.name}, {dev.subtitle}, {dev.health.grade_label}"])


class OverviewPage(Adw.NavigationPage):
    def __init__(self, window):
        super().__init__(title=_("Big-Mount"), tag="home")
        self.window = window
        self._signature = None
        self._running_signature = None
        self.view = load_view()
        self.query = ""

        self.content = w.box(spacing=18)
        self.content.append(w.label(_("Your drives and devices"), css=("title-1",)))
        self.content.append(w.label(_("Choose a drive to see its files, check its health or recover data."), css=("dim-label",)))
        self.alerts = w.box(spacing=6)
        self.content.append(self.alerts)
        self.running = w.box(spacing=6)
        self.content.append(self.running)

        tools = w.hbox(8)
        self.search = Gtk.SearchEntry(placeholder_text=_("Search by name, model, label or folder"), hexpand=True)
        self.search.update_property([Gtk.AccessibleProperty.LABEL], [_("Search drives")])
        self.search.connect("search-changed", self._searched)
        self.search.set_key_capture_widget(self)
        tools.append(self.search)
        switch = w.hbox(0, css=("linked",))
        self.view_buttons = {}
        first = None
        for key, icon_name, text in (("list", "view-list-symbolic", _("List")), ("grid", "view-grid-symbolic", _("Grid"))):
            b = Gtk.ToggleButton(icon_name=icon_name, tooltip_text=text, active=self.view == key, group=first)
            b.update_property([Gtk.AccessibleProperty.LABEL], [text])
            b.connect("toggled", lambda button, k=key: button.get_active() and self.set_view(k))
            first = first or b
            self.view_buttons[key] = b
            switch.append(b)
        tools.append(switch)
        self.content.append(tools)

        self.groups = w.box(spacing=18)
        self.groups.update_property([Gtk.AccessibleProperty.LABEL], [_("Your drives and devices")])
        self.content.append(self.groups)

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

    def set_view(self, view):
        if view == self.view or view not in VIEWS:
            return
        self.view = view
        self.view_buttons[view].set_active(True)
        save_view(view)
        self._render_drives()

    def _searched(self, entry):
        self.query = entry.get_text().strip()
        self._render_drives()

    def update(self):
        win = self.window
        if not win.loaded:
            return
        if not win.devices:
            self.stack.set_visible_child_name("empty")
        else:
            self.stack.set_visible_child_name("list")
        # Rebuilt only when what is listed changes: progress is updated in place, so
        # the focus and an open menu stay where they are
        signature = repr(win.devices) + str(win.partial)
        if signature != self._signature:
            self._signature = signature
            self._render_drives()
            w.clear(self.alerts)
            for dev in win.devices:
                if dev.health.level == "critical":
                    self.alerts.append(self._alert(dev, _("%s reported serious problems. Copy your files to another drive before trying any repair.") % dev.name))
            if win.partial:
                self.alerts.append(self._plain_alert(_("A mounted device did not answer in time, so free space is not shown.")))
        running = [j for j in win.jobs if j.running]
        signature = repr([(j.id, j.state_label) for j in running])
        if signature != self._running_signature:
            self._running_signature = signature
            w.clear(self.running)
            for job in running:
                self.running.append(self._running_row(job))
            return
        for group, job in zip(self._running_groups(), running, strict=True):
            self._show_progress(group, job)

    def _render_drives(self):
        w.clear(self.groups)
        words = self.query.split()
        shown = [d for d in self.window.devices if d.matches(words)]
        if words and not shown:
            self.groups.append(Adw.StatusPage(icon_name="edit-find-symbolic", title=_("No drive matches “%s”") % self.query,
                                              description=_("Search by name, model, volume label, folder or health.")))
            return
        for key in ("internal", "external", "image"):
            devs = [d for d in shown if group_of(d) == key]
            if not devs:
                continue
            section = w.box(spacing=8)
            head = w.label(f"{GROUP_TITLES[key]()} · {len(devs)}", css=("heading",), role=Gtk.AccessibleRole.HEADING)
            section.append(head)
            if self.view == "list":
                box = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"])
                for dev in devs:
                    box.append(DriveRow(self.window, dev))
            else:
                box = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=14, row_spacing=14,
                                  min_children_per_line=1, max_children_per_line=3, homogeneous=True, activate_on_single_click=True)
                box.set_halign(Gtk.Align.START)
                box.connect("child-activated", lambda _f, child: self.window.show_device(child.dev.stable_id))
                for dev in devs:
                    box.append(DriveCard(self.window, dev))
            box.update_property([Gtk.AccessibleProperty.LABEL], [GROUP_TITLES[key]()])
            section.append(box)
            self.groups.append(section)

    def _alert(self, dev, text):
        return w.notice(text, "critical", _("Rescue my files"), lambda: self.window.open_wizard(dev))

    def _plain_alert(self, text):
        return w.notice(text)

    def _running_groups(self):
        child = self.running.get_first_child()
        while child:
            yield child
            child = child.get_next_sibling()

    def _running_row(self, job):
        group = w.Group()
        group.row = w.row(job.state_label, activatable=True, icon_name="media-playback-start-symbolic")
        group.pct = w.label("", css=("numeric", "heading"), wrap=False)
        group.row.add_suffix(group.pct)
        group.row.add_suffix(w.icon("go-next-symbolic"))
        group.row.connect("activated", lambda *_a: self.window.open_job(job.id))
        group.add_row(group.row)
        self._show_progress(group, job)
        return group

    @staticmethod
    def _show_progress(group, job):
        group.row.set_subtitle(f"{job.source} — {human_size(job.bytes_done)}")
        group.pct.set_text(job.percent_text)
        group.pct.set_visible(job.percent is not None)
