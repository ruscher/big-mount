"""The guided rescue, in one window: from where, what, how, to where, confirm.
Going back loses nothing. The engine says what is possible and refuses what is
not: here a refusal is shown in plain words, and the unsafe choices (the same
physical disk, above all) have no button that overrides them."""

import os
import signal
import time

from gi.repository import Adw, Gio, GLib, Gtk

from .. import widgets as w
from ..common import _, human_size, human_time, ngettext
from ..models import Methods
from .device import mount_volume, run_mount

STEP_NUMBER = {"source": 1, "what": 2, "how": 3, "pick": 3, "where": 4, "confirm": 5}
STEP_TITLES = {
    "source": lambda: _("Where should files be recovered from?"),
    "what": lambda: _("What are you looking for?"),
    "how": lambda: _("How should they be looked for?"),
    "pick": lambda: _("Choose files and folders"),
    "where": lambda: _("Where should they be saved?"),
    "confirm": lambda: _("Check and start"),
}

METHOD_TEXT = {
    "quick": (lambda: _("Quick analysis"),
              lambda: _("Lists the files that exist on the volume, by type, and you choose what to copy. Deleted files are not on this list."),
              "edit-find-symbolic"),
    "copy": (lambda: _("Copy files directly"),
             lambda: _("Copies everything, or the folders you choose, with their names. It does not filter by type, and it does not go through what you leave out."),
             "edit-copy-symbolic"),
    "deep": (lambda: _("Deep analysis"),
             lambda: _("Searches every sector for files by their content. It can find what no longer appears, but names and folders are lost, some files come out incomplete and nothing is guaranteed."),
             "system-search-symbolic"),
    "image": (lambda: _("Make a disk image only"),
              lambda: _("Copies the whole device to a file on another disk with GNU ddrescue, keeping a map so it can resume and never reads a good area twice."),
              "media-floppy-symbolic"),
    "partitions": (lambda: _("Look for lost partitions"),
                   lambda: _("TestDisk reads the partition table and analyzes the disk. It only shows what it finds: nothing is written."),
                   "drive-multidisk-symbolic"),
}


def safe_name(text):
    return (text or _("Recovered")).replace("/", "-").replace("\n", " ").strip() or _("Recovered")


class Choice(Gtk.ToggleButton):
    """A big card with an icon and a word."""

    def __init__(self, key, text, icon_name):
        super().__init__(css_classes=["choice-card"])
        self.key = key
        content = w.box(spacing=6)
        content.append(w.icon(icon_name, 28))
        title = w.label(text, xalign=0.5)
        content.append(title)
        self.set_child(content)
        self.update_property([Gtk.AccessibleProperty.LABEL], [text])


class Plan:
    """What was chosen so far. One object: going back and forth keeps it."""

    def __init__(self):
        self.device = None
        self.volume = None
        self.image = ""
        self.categories = {"all"}
        self.methods = None
        self.method = None
        self.scope = "everything"
        self.items = []
        self.dest_base = ""
        self.dest_custom = False
        self.protect = None
        self.on_conflict = "skip"
        self.verify = "basic"
        self.bwlimit = 0
        self.stall = 90
        self.stamp = time.strftime("%Y-%m-%d")

    @property
    def source_name(self):
        if self.image:
            return os.path.basename(self.image)
        if self.volume:
            return self.volume.title
        return self.device.name if self.device else ""

    @property
    def target(self):
        if self.image:
            return self.image
        if self.volume:
            return self.volume.device
        return self.device.device if self.device else ""

    @property
    def category_arg(self):
        return "all" if "all" in self.categories or not self.categories else ",".join(sorted(self.categories))

    @property
    def mountpoint(self):
        return self.volume.mountpoint if self.volume else ""

    @property
    def carve_first_image(self):
        return self.method == "deep" and self.methods and self.methods.deep_needs_image

    @property
    def needs_mount(self):
        return self.method in ("copy", "quick") and self.volume is not None and not self.volume.mounted

    @property
    def dest_folder(self):
        if not self.dest_base:
            return ""
        if self.dest_custom:
            return self.dest_base
        return os.path.join(self.dest_base, _("Recovered files") + f" - {safe_name(self.source_name)} - {self.stamp}")

    @property
    def image_path(self):
        return os.path.join(self.dest_folder, f"{safe_name(self.source_name)}.img")

    @property
    def carve_folder(self):
        return os.path.join(self.dest_folder, _("Files found"))


class FilePicker(Gtk.Box):
    """The folders of the source, opened one at a time, when the person opens them.
    Nothing reads a file, and no folder is read before it is asked for."""

    ATTRS = "standard::name,standard::display-name,standard::type,standard::size,standard::is-symlink"

    def __init__(self, on_change):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.on_change = on_change
        self.marked = set()
        self.root = ""
        # The rows on screen, to show what a marked folder covers
        self._bound = set()
        self._showing = False
        self.count = w.label("", css=("caption", "dim-label"))
        self.view = Gtk.ListView()
        self.view.add_css_class("navigation-sidebar")
        self.view.update_property([Gtk.AccessibleProperty.LABEL], [_("Choose files and folders")])
        factory = Gtk.SignalListItemFactory()
        factory.connect("setup", self._setup)
        factory.connect("bind", self._bind)
        factory.connect("unbind", self._unbind)
        self.view.set_factory(factory)
        scroller = Gtk.ScrolledWindow(child=self.view, vexpand=True, min_content_height=280, has_frame=True)
        self.append(scroller)
        self.append(self.count)
        self._sync()

    def load(self, root):
        if root == self.root:
            return
        self.root = root
        self.marked = set()
        base = self._list_for(Gio.File.new_for_path(root))
        tree = Gtk.TreeListModel.new(base, False, False, self._children)
        self.view.set_model(Gtk.NoSelection.new(tree))
        self._sync()

    def _list_for(self, file):
        lst = Gtk.DirectoryList.new(self.ATTRS, file)
        lst.set_monitored(False)
        lst.set_io_priority(GLib.PRIORITY_LOW)
        sorter = Gtk.CustomSorter.new(self._compare)
        return Gtk.SortListModel.new(lst, sorter)

    def _compare(self, a, b, _data):
        da = a.get_file_type() == Gio.FileType.DIRECTORY
        db = b.get_file_type() == Gio.FileType.DIRECTORY
        if da != db:
            return -1 if da else 1
        na, nb = a.get_display_name().casefold(), b.get_display_name().casefold()
        return (na > nb) - (na < nb)

    def _children(self, info):
        if info.get_file_type() != Gio.FileType.DIRECTORY or info.get_is_symlink():
            return None
        parent = info.get_attribute_object("standard::file")
        if parent is None:
            return None
        return self._list_for(parent)

    def _setup(self, _f, item):
        expander = Gtk.TreeExpander()
        row = w.hbox(8)
        check = Gtk.CheckButton()
        image = Gtk.Image()
        name = w.label("", ellipsize=True)
        name.set_hexpand(True)
        size = w.label("", css=("caption", "dim-label"), wrap=False)
        for child in (check, image, name, size):
            row.append(child)
        expander.set_child(row)
        item.set_child(expander)
        item.widgets = (expander, check, image, name, size)
        item.handler = 0

    def _path(self, info):
        f = info.get_attribute_object("standard::file")
        return f.get_path() if f else ""

    def _covered(self, path):
        probe = path
        while probe and probe != "/":
            if probe in self.marked:
                return True
            probe = os.path.dirname(probe)
        return False

    def _bind(self, _f, item):
        expander, check, image, name, size = item.widgets
        tree_row = item.get_item()
        expander.set_list_row(tree_row)
        info = tree_row.get_item()
        item.path = self._path(info)
        is_dir = info.get_file_type() == Gio.FileType.DIRECTORY
        image.set_from_icon_name("folder-symbolic" if is_dir else "text-x-generic-symbolic")
        name.set_text(info.get_display_name())
        size.set_text("" if is_dir else human_size(info.get_size()))
        self._show_mark(item)
        check.update_property([Gtk.AccessibleProperty.LABEL], [info.get_display_name()])
        item.handler = check.connect("toggled", self._toggled, item.path)
        self._bound.add(item)

    def _unbind(self, _f, item):
        _expander, check, *_rest = item.widgets
        if item.handler:
            check.disconnect(item.handler)
            item.handler = 0
        self._bound.discard(item)

    def _show_mark(self, item):
        """Inside a marked folder a row is marked too, and only that folder unmarks it."""
        check = item.widgets[1]
        self._showing = True
        check.set_active(self._covered(item.path))
        check.set_sensitive(not self._covered(os.path.dirname(item.path)))
        self._showing = False

    def _toggled(self, check, path):
        if self._showing:
            return
        if check.get_active():
            # What was marked inside is now covered by this one
            self.marked = {m for m in self.marked if not m.startswith(path + "/")}
            self.marked.add(path)
        else:
            self.marked.discard(path)
        for item in self._bound:
            self._show_mark(item)
        self._sync()
        self.on_change()

    def _sync(self):
        n = len(self.marked)
        self.count.set_text(ngettext("%d item marked. The total is measured in the next steps.",
                                     "%d items marked. The total is measured in the next steps.", n) % n if n else _("Nothing was marked."))

    def items(self):
        return sorted(os.path.relpath(p, self.root) for p in self.marked)


class RescueWizard(Adw.NavigationPage):
    def __init__(self, window, device=None, volume=None, image=None):
        super().__init__(title=_("Recover files"), tag="rescue")
        self.window = window
        self.plan = Plan()
        self.plan.device = device
        self.plan.volume = volume
        self.plan.image = image or ""
        if device and volume is None:
            # One volume with files is what a person means by "this drive"
            usable = [v for v in device.content_volumes if v.can_hold_files]
            if len(usable) == 1:
                self.plan.volume = usable[0]
        self.step = "source"
        self.destinations = None
        self.preflight = None
        self._preflight_token = 0
        self._rows = {}
        self._radio_group = None
        self._updating = False

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT, transition_duration=180, vexpand=True)
        self.source_box = w.box(spacing=18)
        self.what_box = w.box(spacing=18)
        self.how_box = w.box(spacing=18)
        self.where_box = w.box(spacing=18)
        self.confirm_box = w.box(spacing=18)
        self.picker = FilePicker(self._sync_nav)
        pick_box = w.box(spacing=12)
        pick_box.append(w.label(_("Mark what to copy. A marked folder takes everything inside. Only the folders you open are read."), css=("dim-label",)))
        pick_box.append(self.picker)
        for name, child in (("source", self.source_box), ("what", self.what_box), ("how", self.how_box), ("pick", pick_box),
                            ("where", self.where_box), ("confirm", self.confirm_box)):
            self.stack.add_named(w.page_scroller(child, maximum=760), name)

        self.stepper = w.hbox(6, css=("stepper",))
        self.stepper.set_halign(Gtk.Align.CENTER)
        self._step_pills = []
        for i in range(1, 6):
            pill = Gtk.Label(label=str(i), css_classes=["step-pill"])
            self._step_pills.append(pill)
            self.stepper.append(pill)
            if i < 5:
                line = Gtk.Box(css_classes=["step-line"], valign=Gtk.Align.CENTER)
                self.stepper.append(line)
        self.heading = w.label("", css=("title-2",), xalign=0.5, role=Gtk.AccessibleRole.HEADING)
        self.heading.set_margin_start(16)
        self.heading.set_margin_end(16)
        self.heading.set_margin_bottom(6)
        top = w.box(children=(self.stepper, self.heading))

        self.back_btn = w.button(_("Back"), self.go_back, icon_name="go-previous-symbolic")
        self.next_btn = w.button(_("Next"), self.go_next, css=("suggested-action",))
        bar = Gtk.ActionBar()
        bar.pack_start(self.back_btn)
        bar.pack_end(self.next_btn)
        self.status_label = w.label("", css=("caption", "dim-label"), ellipsize=True)
        bar.set_center_widget(self.status_label)

        header = Adw.HeaderBar(show_back_button=False)
        header.pack_start(w.button(_("Cancel"), self.cancel))
        tool = Adw.ToolbarView(content=self.stack)
        tool.add_top_bar(header)
        tool.add_top_bar(top)
        tool.add_bottom_bar(bar)
        self.set_child(tool)
        self.set_can_pop(True)
        self.connect("hidden", self._hidden)
        self._enter("source")

    def _hidden(self, *_a):
        # Left for good (also by a gesture or a shortcut), not just covered
        if self.window.wizard is self and self.window.nav.find_page(self.get_tag()) is None:
            self.window.wizard = None

    # ----- moving
    def cancel(self):
        self.window.close_wizard()

    def _enter(self, name):
        self.step = name
        getattr(self, f"_enter_{name}")()
        self.stack.set_visible_child_name(name)
        self.heading.set_text(STEP_TITLES[name]())
        number = STEP_NUMBER[name]
        for i, pill in enumerate(self._step_pills, 1):
            pill.remove_css_class("current")
            pill.remove_css_class("done")
            if i == number:
                pill.add_css_class("current")
            elif i < number:
                pill.add_css_class("done")
        self.stepper.update_property([Gtk.AccessibleProperty.LABEL], [_("Step %(n)d of %(t)d") % {"n": number, "t": 5}])
        self._sync_nav()

    def go_back(self):
        order = {"what": "source", "how": "what", "pick": "how", "where": "how", "confirm": "where"}
        if self.step == "where" and self.plan.method == "copy" and self.plan.scope == "choose":
            self._enter("pick")
        elif self.step in order:
            self._enter(order[self.step])

    def go_next(self):
        plan = self.plan
        if self.step == "source":
            self._load_methods(lambda: self._enter("what"))
        elif self.step == "what":
            self._enter("how")
        elif self.step == "how":
            self._after_how()
        elif self.step == "pick":
            plan.items = self.picker.items()
            self._enter("where")
        elif self.step == "where":
            self._enter("confirm")
        elif self.step == "confirm":
            self._start()

    def _sync_nav(self):
        step = self.step
        plan = self.plan
        self.back_btn.set_sensitive(step != "source")
        text, ok = _("Next"), True
        if step == "source":
            ok = bool(plan.target) and (not plan.device or self.window.device_by_id(plan.device.stable_id) is not None or bool(plan.image))
        elif step == "what":
            ok = bool(plan.categories)
        elif step == "how":
            m = plan.methods.get(plan.method) if plan.methods and plan.method else None
            ok = bool(m and m.available)
            if plan.method == "partitions":
                text = _("Look for partitions")
        elif step == "pick":
            ok = bool(self.picker.marked)
        elif step == "where":
            ok = bool(self.preflight and self.preflight.get("ok"))
        elif step == "confirm":
            ok = bool(self.preflight and self.preflight.get("ok"))
            text = _("Start")
        self.next_btn.set_label(text)
        self.next_btn.set_sensitive(ok)

    def devices_changed(self):
        plan = self.plan
        if plan.device:
            current = self.window.device_by_id(plan.device.stable_id)
            if current is None:
                # Whatever comes next under that name is another disk
                self.window.notify_text(_("The device was disconnected or replaced. Nothing was done."))
                plan.device = None
                plan.volume = None
                plan.methods = None
                self._enter("source")
                return
            plan.device = current
            if plan.volume:
                plan.volume = next((v for v in current.volumes if v.device == plan.volume.device), None)
                # Unmounted while the assistant was open: the path it had means nothing now
                if self.step in ("pick", "where", "confirm") and plan.method in ("copy", "quick") and not (plan.volume and plan.volume.mounted):
                    self.window.notify_text(_("The source was unmounted. Nothing was done."))
                    self._enter("how")
                    return
        if self.step == "source":
            self._enter_source()
            self._sync_nav()

    # ----- 1: from where
    def _enter_source(self):
        box = self.source_box
        w.clear(box)
        self._radio_group = None
        box.append(w.label(_("Choose the drive or the volume. Nothing is read or changed yet."), css=("dim-label",), xalign=0.5))
        for dev in self.window.devices:
            if dev.kind == "optical":
                continue
            box.append(self._source_group(dev))
        image_group = w.Group(_("A disk image"))
        r = w.row(_("A disk image saved before"), self.plan.image or _("Searching it does not touch any disk."), activatable=True, icon_name="application-x-firmware-symbolic")
        radio = Gtk.CheckButton(group=self._radio_group, active=bool(self.plan.image), valign=Gtk.Align.CENTER)
        self._radio_group = self._radio_group or radio
        radio.update_property([Gtk.AccessibleProperty.LABEL], [_("A disk image saved before")])
        r.add_prefix(radio)
        r.connect("activated", lambda *_a: self._pick_image())
        radio.connect("toggled", lambda b: b.get_active() and not self.plan.image and self._pick_image())
        image_group.add_row(r)
        box.append(image_group)
        self.image_row = r

    def _source_group(self, dev):
        group = w.Group(dev.name, dev.subtitle)
        badge = w.LevelBadge(dev.health.level, dev.health.label, compact=True)
        if dev.health.risky:
            group.set_header_suffix(badge)
            badge.set_valign(Gtk.Align.CENTER)
            badge.set_hexpand(False)
        vols = dev.content_volumes
        for vol in vols:
            bits = [vol.fstype or _("unknown"), human_size(vol.size), vol.state_label]
            if vol.mountpoint:
                bits.append(vol.mountpoint)
            icon_name = "channel-secure-symbolic" if vol.state == "locked" else "drive-harddisk-symbolic"
            group.add_row(self._source_row(dev, vol, vol.title, " · ".join(b for b in bits if b), icon_name))
        whole = _("For an image or a deep search: every sector, whatever the volumes.")
        if vols:
            whole = _("Only for a disk image, a deep search or lost partitions. To copy files, choose a volume above.")
        group.add_row(self._source_row(dev, None, _("The whole drive"), whole, dev.symbolic_icon))
        return group

    def _source_row(self, dev, vol, title, subtitle, icon_name):
        plan = self.plan
        selected = (not plan.image and plan.device and plan.device.stable_id == dev.stable_id and
                    (plan.volume.device if plan.volume else None) == (vol.device if vol else None))
        radio = Gtk.CheckButton(group=self._radio_group, active=bool(selected), valign=Gtk.Align.CENTER)
        radio.update_property([Gtk.AccessibleProperty.LABEL], [title])
        self._radio_group = self._radio_group or radio
        r = w.row(title, subtitle, activatable=True)
        r.add_prefix(w.icon(icon_name))
        r.add_prefix(radio)
        r.set_activatable_widget(radio)

        def toggled(button):
            if button.get_active():
                plan.image = ""
                plan.device = dev
                plan.volume = vol
                plan.methods = None
                plan.method = None
                self._sync_nav()
        radio.connect("toggled", toggled)
        return r

    def _pick_image(self):
        dialog = Gtk.FileDialog(title=_("Image file"))

        def chosen(d, res):
            try:
                f = d.open_finish(res)
            except GLib.Error:
                return
            plan = self.plan
            plan.image = f.get_path() or ""
            plan.device = None
            plan.volume = None
            plan.methods = None
            plan.method = None
            self.image_row.set_subtitle(plan.image)
            self._sync_nav()
        dialog.open(self.window, None, chosen)

    def _load_methods(self, then):
        self.next_btn.set_sensitive(False)
        self.status_label.set_text(_("Checking what can be done…"))

        def got(res):
            self.status_label.set_text("")
            if not isinstance(res.data, dict):
                w.alert(self.window, _("This source cannot be used"), res.message)
                self._sync_nav()
                return
            self.plan.methods = Methods.from_json(res.data)
            if not self.plan.method:
                self.plan.method = self.plan.methods.recommended
                recommended = self.plan.methods.get(self.plan.method)
                if not recommended or not recommended.available:
                    usable = next((m for m in self.plan.methods.methods if m.available), None)
                    self.plan.method = usable.id if usable else None
            then()
        self.window.engine.methods(self.plan.target, got)

    # ----- 2: what
    def _enter_what(self):
        box = self.what_box
        w.clear(box)
        plan = self.plan
        box.append(w.label(_("You can choose more than one. If you are not sure, leave All."), css=("dim-label",), xalign=0.5))
        flow = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=10, row_spacing=10, homogeneous=True,
                           min_children_per_line=2, max_children_per_line=3)
        choices = [("all", _("All types"), "folder-symbolic")]
        for cat in plan.methods.categories:
            choices.append((cat["id"], cat["label"], w.category_icon(cat["id"])))
        self._choice = {}
        for key, text, icon_name in choices:
            c = Choice(key, text, icon_name)
            c.set_active(key in plan.categories)
            c.connect("toggled", self._category_toggled)
            self._choice[key] = c
            flow.append(c)
        box.append(flow)
        self.what_notes = w.box(spacing=6)
        box.append(self.what_notes)
        self._render_category_notes()

    def _category_toggled(self, button):
        if self._updating:
            return
        self._updating = True
        plan = self.plan
        if button.key == "all":
            if button.get_active():
                plan.categories = {"all"}
                for key, c in self._choice.items():
                    if key != "all":
                        c.set_active(False)
            else:
                button.set_active(True)
        else:
            if button.get_active():
                plan.categories.discard("all")
                plan.categories.add(button.key)
                self._choice["all"].set_active(False)
            else:
                plan.categories.discard(button.key)
                if not plan.categories:
                    plan.categories = {"all"}
                    self._choice["all"].set_active(True)
        self._updating = False
        self._render_category_notes()
        self._sync_nav()

    def _render_category_notes(self):
        w.clear(self.what_notes)
        if "all" in self.plan.categories:
            return
        for cat in self.plan.methods.categories:
            if cat["id"] in self.plan.categories and cat.get("deep_note"):
                self.what_notes.append(w.label(f"{cat['label']}: {cat['deep_note']}", css=("caption", "dim-label")))

    # ----- 3: how
    def _enter_how(self):
        box = self.how_box
        w.clear(box)
        plan = self.plan
        methods = plan.methods
        for note in methods.notes:
            box.append(self._note(note.get("text", "")))
        if methods.level in ("critical", "attention"):
            box.append(w.notice(_("This drive reported problems: every extra read wears it. Nothing starts without you."), "attention"))
        if methods.recommended_why:
            box.append(self._note(methods.recommended_why))
        usable = self._usable_volumes()
        if usable:
            box.append(w.notice(_("You chose the whole drive. Copying files and the quick analysis work with the files of a volume."), "info"))
            box.append(w.button_row(*(w.button(_("Use the volume %s") % v.title.replace("_", "__"), lambda v=v: self.use_volume(v), css=("pill", "suggested-action"))
                                      for v in usable)))
        group = w.Group()
        self._radio_group = None
        order = [methods.recommended] + [m for m in ("quick", "copy", "deep") if m != methods.recommended]
        for mid in order:
            if mid in ("image", "partitions") and mid != methods.recommended:
                continue
            group.add_row(self._method_row(mid))
        box.append(group)
        advanced = Adw.ExpanderRow(title=_("Advanced"), subtitle=_("Tools that work with the whole disk"), use_markup=False)
        for mid in ("image", "partitions"):
            if mid != methods.recommended:
                advanced.add_row(self._method_row(mid))
        adv_group = w.Group()
        adv_group.add_row(advanced)
        box.append(adv_group)
        self.scope_group = w.Group(_("What to copy"))
        self._radio_scope = None
        for key, title, subtitle in (("everything", _("Everything"), _("All the files of this volume.")),
                                     ("choose", _("Choose files and folders"), _("Only what you mark. Recommended on a drive with problems: the most important first."))):
            radio = Gtk.CheckButton(group=self._radio_scope, active=plan.scope == key, valign=Gtk.Align.CENTER)
            self._radio_scope = self._radio_scope or radio
            radio.update_property([Gtk.AccessibleProperty.LABEL], [title])
            r = w.row(title, subtitle, activatable=True)
            r.add_prefix(radio)
            r.set_activatable_widget(radio)
            radio.connect("toggled", lambda b, k=key: b.get_active() and self._set_scope(k))
            self.scope_group.add_row(r)
        box.append(self.scope_group)
        self.scope_group.set_visible(plan.method == "copy")
        self.deep_note = w.label("", css=("dim-label",))
        box.append(self.deep_note)
        self._render_deep_note()

    def _usable_volumes(self):
        """The volumes with files of a drive chosen whole: what copy and quick need."""
        plan = self.plan
        if plan.image or not plan.device or plan.volume:
            return []
        return [v for v in plan.device.content_volumes if v.can_hold_files]

    def use_volume(self, vol):
        """Back to step 3 with a volume of the same drive as the source."""
        nav = self.window.nav
        if nav.get_visible_page() is not self:
            nav.pop_to_page(self)
        plan = self.plan
        plan.image = ""
        plan.volume = vol
        plan.methods = None
        plan.method = None
        self._load_methods(lambda: self._enter("how"))

    def check_again(self):
        """After a missing tool was installed: ask the engine again, keep the choice."""
        plan = self.plan
        keep = plan.method
        plan.methods = None
        plan.method = None

        def then():
            m = plan.methods.get(keep)
            if m and m.available:
                plan.method = keep
            self._enter("how")
        self._load_methods(then)

    def _note(self, text):
        row = w.hbox(10)
        row.append(w.icon("dialog-information-symbolic"))
        t = w.label(text)
        t.set_hexpand(True)
        row.append(t)
        return row

    def _set_scope(self, key):
        self.plan.scope = key

    def _method_row(self, mid):
        plan = self.plan
        m = plan.methods.get(mid)
        title_fn, sub_fn, icon_name = METHOD_TEXT[mid]
        subtitle = sub_fn()
        if m and m.password:
            subtitle += " " + _("It asks for the administrator password.")
        if m and not m.available:
            subtitle = _("Not available: %s") % (m.why_text or subtitle)
        r = w.row(title_fn(), subtitle, activatable=bool(m and m.available))
        radio = Gtk.CheckButton(group=self._radio_group, active=plan.method == mid, valign=Gtk.Align.CENTER)
        self._radio_group = self._radio_group or radio
        radio.update_property([Gtk.AccessibleProperty.LABEL], [title_fn()])
        radio.set_sensitive(bool(m and m.available))
        r.add_prefix(w.icon(icon_name))
        r.add_prefix(radio)
        if m and m.available:
            r.set_activatable_widget(radio)
        elif m and m.why == "pick-volume" and len(self._usable_volumes()) == 1:
            # The row stays readable: its reason is what to do next
            vol = self._usable_volumes()[0]
            r.add_suffix(self._row_button(_("Use %s") % vol.title.replace("_", "__"), lambda: self.use_volume(vol)))
        elif m and m.why.startswith("no-"):
            r.add_suffix(self._row_button(_("Check again"), self.check_again,
                                          tooltip=_("After installing the package, check again without leaving the assistant.")))
        if mid == plan.methods.recommended:
            pill = w.label(_("Recommended"), css=("recommended-pill",), wrap=False)
            pill.set_valign(Gtk.Align.CENTER)
            r.add_suffix(pill)

        def toggled(button):
            if button.get_active():
                plan.method = mid
                self.scope_group.set_visible(mid == "copy")
                self._render_deep_note()
                self._sync_nav()
        radio.connect("toggled", toggled)
        return r

    def _row_button(self, text, callback, tooltip=None):
        b = w.button(text, callback, tooltip=tooltip)
        b.set_valign(Gtk.Align.CENTER)
        return b

    def _render_deep_note(self):
        plan = self.plan
        text = ""
        if plan.method == "deep" and plan.methods.deep_needs_image:
            text = _("First a disk image is made, which needs free space elsewhere as large as the source (%s). Then the image is searched, and the disk rests.") % human_size(plan.methods.size)
        elif plan.method == "copy" and "all" not in plan.categories:
            text = _("A direct copy does not filter by type. To choose by type, use the quick analysis.")
        self.deep_note.set_text(text)
        self.deep_note.set_visible(bool(text))

    def _after_how(self):
        plan = self.plan
        if plan.method == "partitions":
            self.window.nav.push(PartitionsPage(self.window, plan, self))
            return
        if plan.needs_mount:
            mount_volume(self.window, plan.device, plan.volume, self._mounted)
            return
        self._continue_after_mount()

    def _mounted(self, data):
        # The list refreshes on its own soon; the path is already known
        if self.plan.volume:
            self.plan.volume.mountpoint = data.get("mountpoint", "")
            self.plan.volume.state = "mounted-ro" if data.get("read_only") else "mounted-rw"
        self._continue_after_mount()

    def _continue_after_mount(self):
        plan = self.plan
        if plan.method == "copy" and plan.scope == "choose":
            self.picker.load(plan.mountpoint)
            self._enter("pick")
        else:
            plan.items = []
            self._enter("where")

    def _enter_pick(self):
        """The list was loaded when the volume was known: going back keeps the marks."""

    # ----- 4: where
    def _enter_where(self):
        box = self.where_box
        w.clear(box)
        plan = self.plan
        need = 0
        if plan.method == "image" or plan.carve_first_image:
            need = plan.methods.size or 0
        self.preflight = None
        route = w.label(_("From: %s") % plan.source_name, css=("heading",), xalign=0.5)
        box.append(route)
        box.append(w.label(_("Never on the same physical disk as the source. If that disk fails, both are lost."), css=("dim-label",), xalign=0.5))
        self.dest_group = w.Group(_("Places on another disk"))
        self.dest_group.add_row(w.row(_("Looking for places…")))
        box.append(self.dest_group)
        other = w.Group()
        custom = w.row(_("Choose another folder…"), plan.dest_base if plan.dest_custom else "", activatable=True, icon_name="folder-open-symbolic")
        custom.connect("activated", lambda *_a: self._pick_folder())
        other.add_row(custom)
        self.custom_row = custom
        box.append(other)
        self.dest_status = w.box(spacing=6)
        box.append(self.dest_status)
        kwargs = {"need": need}
        if not plan.image:
            if plan.mountpoint:
                kwargs["source"] = plan.mountpoint
            else:
                kwargs["device"] = plan.target
        self.window.engine.destinations(self._got_destinations, **kwargs)
        if plan.dest_base:
            self._run_preflight()

    def _got_destinations(self, res):
        if self.step != "where":
            return
        plan = self.plan
        self.dest_group.clear_rows()
        rows = (res.data or {}).get("destinations", [])
        rows.sort(key=lambda d: (not d.get("recommended"), -(d.get("avail") or 0)))
        reasons = {"risky": _("drive with critical alerts"), "same-disk": _("same physical disk as the source"),
                   "no-space": _("not enough space")}
        self._radio_group = None
        first = None
        for d in rows:
            subtitle = f"{d.get('path', '')}\n{human_size(d.get('avail'))} " + _("free")
            if d.get("fstype"):
                subtitle += f" · {d['fstype']}"
            ok = d.get("recommended")
            if not ok:
                subtitle += "\n" + _("Not available: %s") % reasons.get(d.get("why"), "")
            r = w.row(d.get("name", ""), subtitle, activatable=bool(ok))
            radio = Gtk.CheckButton(group=self._radio_group, active=plan.dest_base == d.get("path") and not plan.dest_custom, valign=Gtk.Align.CENTER)
            self._radio_group = self._radio_group or radio
            radio.update_property([Gtk.AccessibleProperty.LABEL], [d.get("name", "")])
            radio.set_sensitive(bool(ok))
            r.add_prefix(radio)
            if ok:
                r.set_activatable_widget(radio)
                if first is None:
                    first = (radio, d)
                radio.connect("toggled", lambda b, path=d.get("path"): b.get_active() and self._set_dest(path, False))
            else:
                r.set_sensitive(False)
            self.dest_group.add_row(r)
        if not rows:
            self.dest_group.add_row(w.row(_("No other disk is mounted. Connect one, or choose a folder.")))
        if not plan.dest_base and first:
            first[0].set_active(True)

    def _pick_folder(self):
        def chosen(path):
            self.custom_row.set_subtitle(path)
            self._set_dest(path, True)
        w.choose_folder(self.window, chosen)

    def _set_dest(self, path, custom):
        self.plan.dest_base = path
        self.plan.dest_custom = custom
        self._run_preflight()

    # Every check of the destination is the engine's, in a dry run
    def _run_preflight(self, measure=False):
        plan = self.plan
        self.preflight = None
        self._preflight_token += 1
        token = self._preflight_token
        self._show_dest_status(_("Checking this place…"), "busy")
        self._sync_nav()

        def done(res):
            if token != self._preflight_token:
                return
            data = res.data if isinstance(res.data, dict) else {"ok": False, "error_text": res.message or _("The check could not be done.")}
            self.preflight = data
            if self.step == "where":
                if data.get("ok"):
                    text = _("Everything can be saved here.")
                    if data.get("avail") is not None:
                        text = _("It can be saved here: %s free.") % human_size(data["avail"])
                    self._show_dest_status(text, "ok")
                else:
                    self._show_dest_status(data.get("error_text") or _("It cannot be saved here."), "error", data.get("error"))
            elif self.step == "confirm":
                self._render_confirm()
            self._sync_nav()

        engine = self.window.engine
        if plan.method == "copy":
            engine.copy(done, source=plan.mountpoint, destination=plan.dest_folder, dry_run=True,
                        items=self._items(), on_conflict=plan.on_conflict, verify=plan.verify,
                        scan=None if measure else "no")
        elif plan.method == "quick":
            engine.copy(done, source=plan.mountpoint, destination=plan.dest_folder, dry_run=True, scan="no")
        elif plan.method == "image" or plan.carve_first_image:
            engine.image(done, plan.target, plan.image_path if plan.method == "image" or plan.carve_first_image else "",
                         diskseq=plan.device.diskseq if plan.device else None, dry_run=True)
        else:
            engine.carve(done, plan.target, plan.dest_folder, plan.category_arg, dry_run=True)

    def _items(self):
        """The selection, as the names the engine gets."""
        return [i.encode("utf-8", "surrogateescape") for i in self.plan.items]

    def _show_dest_status(self, text, kind, error=None):
        box = self.dest_status
        w.clear(box)
        row = w.hbox(10)
        if kind == "busy":
            spinner = Gtk.Spinner(spinning=True)
            row.append(spinner)
        else:
            level = {"ok": "normal", "error": "critical"}.get(kind, "unknown")
            badge = w.LevelBadge(level, text)
            badge.set_hexpand(True)
            box.append(badge)
            if error == "rw-source":
                box.append(self._remount_button())
            return
        t = w.label(text, css=("dim-label",))
        t.set_hexpand(True)
        row.append(t)
        box.append(row)

    def _remount_button(self):
        plan = self.plan

        def remount():
            def mounted(data):
                self._mounted(data)
                self._enter("where")
            run_mount(self.window, plan.device, plan.volume, plan.device.health.risky, True, mounted)
        b = w.button(_("Unmount and mount read-only"), remount, css=("suggested-action",))
        b.set_halign(Gtk.Align.START)
        return b

    # ----- 5: confirm
    def _enter_confirm(self):
        w.clear(self.confirm_box)
        self.confirm_box.append(Adw.StatusPage(icon_name="system-search-symbolic", title=_("Checking the source and the destination…")))
        self._run_preflight(measure=True)

    def _render_confirm(self):
        box = self.confirm_box
        w.clear(box)
        plan = self.plan
        data = self.preflight or {}
        if not data.get("ok"):
            box.append(w.LevelBadge("critical", data.get("error_text") or _("It cannot be started.")))
            return
        route = w.hbox(12, css=("card", "route-card"))
        for i, (icon_name, caption, name) in enumerate((("drive-harddisk-symbolic", _("Source"), plan.source_name),
                                                        ("folder-symbolic", _("Destination"), plan.dest_folder))):
            if i == 1:
                arrow = w.icon("go-next-symbolic", 24)
                arrow.set_valign(Gtk.Align.CENTER)
                route.append(arrow)
            col = w.box(spacing=2)
            col.set_hexpand(True)
            picture = w.icon(icon_name, 28)
            picture.set_halign(Gtk.Align.START)
            col.append(picture)
            col.append(w.label(caption, css=("caption", "dim-label")))
            col.append(w.label(name, css=("heading",)))
            route.append(col)
        box.append(route)
        group = w.Group()
        method_title = METHOD_TEXT[plan.method][0]()
        group.add_row(w.fact_row(_("Method"), method_title))
        what = self._what_text()
        if what:
            group.add_row(w.fact_row(_("What"), what))
        total = data.get("total_bytes") or 0
        if plan.method == "image" or plan.carve_first_image:
            group.add_row(w.fact_row(_("Space it will use"), human_size(total)))
        elif data.get("scanned") and plan.method == "copy":
            group.add_row(w.fact_row(_("To copy"), _("%(files)s files, %(size)s") % {"files": data.get("total_files", 0), "size": human_size(total)}))
        elif data.get("total_estimate"):
            group.add_row(w.fact_row(_("To copy"), "≈ " + human_size(total)))
        if data.get("avail") is not None:
            group.add_row(w.fact_row(_("Free at the destination"), human_size(data["avail"])))
        if data.get("conflicts"):
            group.add_row(w.fact_row(_("Already there, with different content"), str(data["conflicts"])))
        box.append(group)
        promise = {
            "copy": _("Your files will be copied with their names. Nothing is written to the source."),
            "quick": _("First a list of what exists is made. Then you choose what to copy. Nothing is written to the source."),
            "deep": _("Files will be searched for by their content. Names and folders are lost, some files may come out incomplete, and finding nothing is possible. Nothing is written to the source."),
            "image": _("The disk is read once, into a file. Nothing is written to it."),
        }.get(plan.method, "")
        box.append(w.label(promise))
        warnings = list(data.get("warnings") or [])
        if plan.carve_first_image:
            warnings.append({"text": _("After the image, the search needs your confirmation. It can also be started later.")})
        if warnings:
            warn = w.Group(_("Good to know"))
            for item in warnings:
                warn.add_row(w.row(item.get("text", ""), icon_name="dialog-warning-symbolic"))
            box.append(warn)
        if plan.method == "copy":
            box.append(self._copy_options())

    def _what_text(self):
        plan = self.plan
        if plan.method == "copy":
            return ngettext("%d item you marked", "%d items you marked", len(plan.items)) % len(plan.items) if plan.items else _("Everything")
        if "all" in plan.categories:
            return _("All types")
        labels = {c["id"]: c["label"] for c in plan.methods.categories}
        return ", ".join(labels.get(c, c) for c in sorted(plan.categories))

    def _copy_options(self):
        plan = self.plan
        group = w.Group()
        expander = Adw.ExpanderRow(title=_("More options"), use_markup=False)
        conflict = Adw.ComboRow(title=_("If a file already exists"), use_markup=False)
        conflict_keys = ["skip", "backup", "overwrite"]
        conflict.set_model(Gtk.StringList.new([_("Keep the existing file (safe)"), _("Replace it, keeping the old one aside"), _("Replace it")]))
        conflict.set_selected(conflict_keys.index(plan.on_conflict))
        conflict.connect("notify::selected", lambda c, _p: setattr(plan, "on_conflict", conflict_keys[c.get_selected()]))
        verify = Adw.ComboRow(title=_("Check the result"), use_markup=False)
        verify_keys = ["basic", "metadata", "full"]
        verify.set_model(Gtk.StringList.new([_("Basic: rsync confirms each file as it is copied"), _("Names, sizes and dates compared at the end"),
                                             _("Content compared at the end (reads the source again)")]))
        verify.set_selected(verify_keys.index(plan.verify))
        verify.connect("notify::selected", lambda c, _p: setattr(plan, "verify", verify_keys[c.get_selected()]))
        stall = Adw.SpinRow.new_with_range(0, 3600, 10)
        stall.set_title(_("Set aside a stuck file after (seconds)"))
        stall.set_use_markup(False)
        stall.set_subtitle(_("A file that does not advance for this long is set aside, so that the others are saved first. 0: never."))
        stall.set_value(plan.stall)
        stall.connect("notify::value", lambda s, _p: setattr(plan, "stall", int(s.get_value())))
        limit = Adw.SpinRow.new_with_range(0, 4000000, 1000)
        limit.set_title(_("Limit the reading speed (kB/s)"))
        limit.set_use_markup(False)
        limit.set_subtitle(_("0: no limit"))
        limit.set_value(plan.bwlimit)
        limit.connect("notify::value", lambda s, _p: setattr(plan, "bwlimit", int(s.get_value())))
        for r in (conflict, verify, stall, limit):
            expander.add_row(r)
        group.add_row(expander)
        return group

    def _start(self):
        plan = self.plan
        self.next_btn.set_sensitive(False)
        self.status_label.set_text(_("Starting…"))

        def started(res):
            self.status_label.set_text("")
            data = res.data if isinstance(res.data, dict) else {}
            if data.get("id"):
                self.window.refresh_jobs()
                self.window.open_job(data["id"], replace_top=True)
                return
            w.alert(self.window, _("It did not start"), data.get("error_text") or res.message or _("The reason could not be determined."))
            self._sync_nav()

        engine = self.window.engine
        if plan.method == "copy":
            engine.copy(started, source=plan.mountpoint, destination=plan.dest_folder, items=self._items(),
                        on_conflict=plan.on_conflict, verify=plan.verify, stall=plan.stall, bwlimit=plan.bwlimit)
        elif plan.method == "quick":
            engine.scan(started, plan.mountpoint, plan.category_arg, copy_to=plan.dest_folder)
        elif plan.method == "image":
            engine.image(started, plan.target, plan.image_path, diskseq=plan.device.diskseq if plan.device else None)
        elif plan.carve_first_image:
            engine.image(started, plan.target, plan.image_path, diskseq=plan.device.diskseq if plan.device else None,
                         then_carve=plan.carve_folder, categories=plan.category_arg)
        else:
            engine.carve(started, plan.target, plan.dest_folder, plan.category_arg)


class PartitionsPage(Adw.NavigationPage):
    """TestDisk, read-only: it shows what it finds and writes nothing."""

    def __init__(self, window, plan, wizard=None):
        super().__init__(title=_("Look for lost partitions"), tag="partitions")
        self.window = window
        self.plan = plan
        self.wizard = wizard
        self._timer = None
        self._proc = None
        self.box = w.box(spacing=18)
        self.box.append(w.label(_("TestDisk reads the partition table and analyzes the disk. It only shows what it finds: nothing is written."), css=("dim-label",)))
        self.list_btn = w.button(_("Read the partition table"), lambda: self.run(False), css=("pill",))
        self.search_btn = w.button(_("Analyze the whole disk"), lambda: self.run(True), css=("pill",),
                                   tooltip=_("It reads all of the disk. On a drive with problems this is extra wear."))
        self.box.append(w.button_row(self.list_btn, self.search_btn))
        if plan.methods and plan.methods.level in ("critical", "attention"):
            self.box.append(w.label(_("This drive reported problems: analyzing all of it is extra wear. A disk image first spares it."), css=("dim-label",)))
        self.results = w.box(spacing=12)
        self.box.append(self.results)
        self.box.append(self._volumes_group())
        tool = Adw.ToolbarView(content=w.page_scroller(self.box, maximum=760))
        tool.add_top_bar(Adw.HeaderBar())
        self.set_child(tool)
        self.connect("hidden", self._hidden)

    def _hidden(self, *_a):
        # Popped: nobody waits for the analysis any more
        if self.window.nav.find_page(self.get_tag()) is None:
            self._stop()
            if self._timer:
                GLib.source_remove(self._timer)
                self._timer = None

    def _stop(self, *_a):
        """The engine stops TestDisk on SIGTERM, also the one the helper runs as root."""
        if self._proc:
            self._proc.send_signal(signal.SIGTERM)
            self.stop_btn.set_sensitive(False)
            self.stop_btn.set_label(_("Stopping…"))

    def _volumes_group(self):
        """The volumes the system already sees on this drive are not lost: their files
        can be recovered directly, which is what a person usually came for."""
        plan = self.plan
        vols = [v for v in plan.device.content_volumes if v.can_hold_files] if plan.device and not plan.image else []
        group = w.Group(_("Volumes this drive already has"),
                        _("They are not lost. To recover their files, copying them is faster and reads the disk less than any analysis."))
        for vol in vols:
            bits = [vol.fstype, human_size(vol.size), vol.state_label]
            r = w.row(vol.title, " · ".join(b for b in bits if b), icon_name="drive-harddisk-symbolic")
            if self.wizard:
                b = w.button(_("Recover its files"), lambda v=vol: self.wizard.use_volume(v), css=("suggested-action",))
                b.set_valign(Gtk.Align.CENTER)
                r.add_suffix(b)
            group.add_row(r)
        group.set_visible(bool(vols))
        return group

    def run(self, search):
        w.clear(self.results)
        spinner = Gtk.Spinner(spinning=True)
        spinner.set_size_request(24, 24)
        self.results.append(spinner)
        self.results.append(w.label(_("Looking for partitions…"), xalign=0.5))
        self.elapsed = w.label("", css=("dim-label", "numeric"), xalign=0.5)
        self.results.append(self.elapsed)
        if search:
            self.results.append(w.label(_("TestDisk does not say how far it has gone, so there is no percentage. Analyzing a whole disk reads all of it and can take hours; the drive can be used for nothing else meanwhile."),
                                        css=("caption", "dim-label"), xalign=0.5))
        self.stop_btn = w.button(_("Stop"), self._stop, css=("pill",))
        self.stop_btn.set_halign(Gtk.Align.CENTER)
        self.results.append(self.stop_btn)
        self.list_btn.set_sensitive(False)
        self.search_btn.set_sensitive(False)
        started = GLib.get_monotonic_time()

        def tick():
            seconds = (GLib.get_monotonic_time() - started) // 1000000
            self.elapsed.set_text(_("Elapsed: %s") % human_time(seconds))
            return True
        tick()
        self._timer = GLib.timeout_add_seconds(1, tick)
        target = self.plan.device.device if self.plan.device and not self.plan.image else self.plan.target
        self._proc = self.window.engine.partitions(target, lambda res: self._done(res, search), search=search)

    def _done(self, res, search):
        self._proc = None
        if self._timer:
            GLib.source_remove(self._timer)
            self._timer = None
        self.list_btn.set_sensitive(True)
        self.search_btn.set_sensitive(True)
        w.clear(self.results)
        data = res.data if isinstance(res.data, dict) else None
        if data and data.get("error") == "cancelled":
            self.results.append(w.label(data.get("error_text", ""), xalign=0.5))
            return
        if data is None or data.get("error"):
            self.results.append(w.LevelBadge("critical", (data or {}).get("error_text") or res.message or _("The search failed.")))
            return
        found = data.get("found") or []
        group = w.Group(_("What TestDisk found") if found else "")
        for p in found:
            title = p.get("label") or p.get("type", "")
            group.add_row(w.row(title, f"{p.get('type', '')} · {human_size(p.get('size'))} · {p.get('start', '')}"))
        if found:
            self.results.append(group)
            self.results.append(w.label(_("Big-Mount does not rewrite partition tables, on purpose: a mistake there can lose everything. A disk image, or a search by content, recovers files without that risk."), css=("dim-label",)))
        elif search:
            self.results.append(w.label(_("The analysis did not recognize any partition. That does not prove there is no data: a search by content may still find files.")))
        else:
            self.results.append(w.label(_("The partition table is empty or unreadable. Analyzing the whole disk may find what it no longer lists.")))
