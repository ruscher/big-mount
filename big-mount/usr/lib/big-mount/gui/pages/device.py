"""One drive: what is on it, how it is doing, what can be recovered and what was
already done. Details are one click away and risks are never hidden."""

import time

from gi.repository import Adw, Gio, GLib, Gtk

from .. import actions
from .. import widgets as w
from ..common import _, human_size, ngettext


def unlock_volume(window, vol, done):
    """The passphrase goes from this dialog to UDisks2 over D-Bus: never in
    arguments, files or logs."""
    entry = Gtk.PasswordEntry(show_peek_icon=True, activates_default=True)
    entry.update_property([Gtk.AccessibleProperty.LABEL], [_("Passphrase")])

    def answered(rid):
        secret = entry.get_text()
        entry.set_text("")
        if rid != "unlock" or not secret:
            return
        node = "".join(c if c.isalnum() else f"_{ord(c):02x}" for c in vol.device.rsplit("/", 1)[-1])
        path = "/org/freedesktop/UDisks2/block_devices/" + node
        bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

        def finished(connection, res):
            try:
                connection.call_finish(res)
                window.notify_text(_("Unlocked."))
            except GLib.Error as exc:
                w.alert(window, _("Could not unlock"), exc.message)
            window.refresh()
            done()
        bus.call("org.freedesktop.UDisks2", path, "org.freedesktop.UDisks2.Encrypted", "Unlock",
                 GLib.Variant("(sa{sv})", (secret, {})), None, Gio.DBusCallFlags.NONE, 120000, None, finished)
        del secret

    w.alert(window, _("Unlock %s") % vol.title, _("Type the passphrase of this volume."),
            responses=(("cancel", _("Cancel")), ("unlock", _("Unlock"))), default="unlock", close="cancel",
            suggested=("unlock",), callback=answered, extra=entry)


def mount_volume(window, dev, vol, then=None):
    """Read-only, always. On a drive at risk: block writing at the device, on by default."""
    check = Gtk.CheckButton(label=_("Also block writing on the device itself (asks for the password)"),
                            active=dev.health.risky)
    check.set_tooltip_text(_("Whatever a driver or another program tries, the disk does not change. It lasts until the drive is disconnected."))
    body = _("The volume is opened without changing anything on it.")
    if dev.health.risky:
        body += "\n\n" + dev.health.label

    def answered(rid):
        if rid == "mount":
            run_mount(window, dev, vol, check.get_active(), False, then)

    w.alert(window, _("Mount “%s” read-only") % vol.title, body,
            responses=(("cancel", _("Cancel")), ("mount", _("Mount read-only"))), default="mount", close="cancel",
            suggested=("mount",), callback=answered, extra=check)


def run_mount(window, dev, vol, protect, remount, then):
    window.notify_text(_("Mounting…"))

    def done(res):
        window.refresh()
        data = res.data or {}
        if data.get("ok"):
            if then:
                then(data)
            else:
                window.notify_text(_("Mounted read-only at %s") % data.get("mountpoint", ""))
            return
        if data.get("why") == "already-rw":
            def again(rid):
                if rid == "remount":
                    run_mount(window, dev, vol, protect, True, then)
            w.alert(window, _("Mount read-only"), data.get("text", ""),
                    responses=(("cancel", _("Cancel")), ("remount", _("Unmount and mount read-only"))),
                    default="cancel", close="cancel", callback=again)
            return
        text = data.get("text") or res.message or _("The reason could not be determined.")
        if data.get("detail"):
            text += "\n\n" + data["detail"]
        w.alert(window, _("Could not mount"), text)
    window.engine.mount(vol.device, done, protect=protect, remount=remount, diskseq=dev.diskseq)


def unmount_volume(window, vol, then=None):
    actions.unmount(window, vol.device, then=then)


class HealthView(Gtk.Box):
    """What is known and how: 'not examined' is never 'no alert'."""

    def __init__(self, page):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.page = page
        self.window = page.window
        self.diag = None
        self.dev = None
        self.smart_busy = False

    def show_device(self, dev, fresh=True):
        self.dev = dev
        if fresh:
            self.diag = None
        self._render()
        self.window.engine.diagnose(dev.device, self._diagnosed)

    def _diagnosed(self, res):
        data = res.data
        if not isinstance(data, dict) or not self.dev or data.get("device", {}).get("device") != self.dev.device:
            return
        self.diag = data
        self._render()
        # Why a volume cannot be written comes with the diagnosis
        self.page.refresh_overview()

    def _evidence(self, dev):
        return {
            "smart+log": _("Based on the drive's SMART report and on the system log since this computer started."),
            "log": _("Based on the system log since this computer started. The drive's own report (SMART) was not read."),
            "smart": _("Based on the drive's SMART report. The system log could not be read."),
            "none": _("Nothing could be consulted yet, so nothing can be said about this drive."),
        }.get(dev.health.basis, "")

    def _headline(self, dev):
        level = dev.health.level
        if level == "critical":
            return _("This drive is failing. Copy your files to another drive before trying any repair.")
        if level == "attention":
            return _("Something is not right with this drive. Copy what matters to another place.")
        if level == "normal":
            return _("No alert was found in the information consulted.")
        if level == "na":
            return _("This is a disk image: it has no health of its own.")
        return _("Not examined yet: there is not enough information.")

    def _render(self):
        w.clear(self)
        dev = self.dev
        if not dev:
            return
        h = dev.health
        panel = w.box(spacing=10, css=("health-panel", "card", f"level-{h.level}"))
        top = w.hbox(10)
        grade = w.GradeBadge(h)
        grade.add_css_class("grade-large")
        top.append(grade)
        top.append(w.LevelBadge(h.level, h.label))
        panel.append(top)
        panel.append(w.label(self._headline(dev), css=("title-3",)))
        panel.append(w.label(self._evidence(dev), css=("dim-label",)))
        buttons = []
        if dev.kind != "optical":
            buttons.append(w.button(_("Rescue my files"), lambda: self.window.open_wizard(dev),
                                    css=("suggested-action", "pill") if h.risky else ("pill",), icon_name="document-save-symbolic"))
        buttons.append(w.button(_("Export diagnosis…"), self._export, css=("pill",), icon_name="document-save-as-symbolic"))
        panel.append(w.button_row(*buttons))
        self.append(panel)

        reasons = w.Group(_("What was found"))
        for reason in h.reasons:
            reasons.add_row(w.row(reason.get("text", ""), icon_name="dialog-warning-symbolic"))
        if h.reasons:
            self.append(reasons)

        if h.notes:
            notes = w.Group(_("Why it is not called healthy"))
            for note in h.notes:
                notes.add_row(w.row(note.get("text", ""), icon_name="dialog-information-symbolic"))
            self.append(notes)

        if self.diag and self.diag.get("advice"):
            advice = w.Group(_("What to do"))
            for text in self.diag["advice"]:
                advice.add_row(w.row(text, icon_name="go-next-symbolic"))
            self.append(advice)

        if dev.kind not in ("image", "optical"):
            self.append(self._smart_group(dev))
        self.append(self._details_group(dev))
        self.append(self._maintenance_group(dev))

    def _smart_group(self, dev):
        group = w.Group(_("What the drive itself reports (SMART)"))
        smart = dev.health.smart or {}
        tools = (self.diag or {}).get("tools", {})
        read_at = smart.get("read_at")
        if read_at:
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(read_at))
            group.set_description(w.escape(_("Read at %s, through the administrator password.") % when))
        elif dev.health.basis in ("smart", "smart+log"):
            group.set_description(w.escape(_("As the system keeps it up to date, without a password.")))
        values = (
            (_("Overall verdict"), {"passed": _("Passed"), "failed": _("Failing")}.get(smart.get("verdict"), smart.get("verdict"))),
            (_("Sectors waiting to be replaced"), smart.get("pending")),
            (_("Sectors already replaced"), smart.get("reallocated")),
            (_("Sectors it could not read offline"), smart.get("offline")),
            (_("Errors it could not correct"), smart.get("uncorrectable")),
            (_("Cable or adapter errors"), smart.get("crc")),
            (_("NVMe media errors"), smart.get("nvme_media")),
            (_("NVMe life used"), f"{smart['nvme_used']}%" if smart.get("nvme_used") is not None else None),
            (_("Hours powered on"), self._hours(smart.get("hours"))),
            (_("Temperature now"), f"{smart['temperature']} °C" if smart.get("temperature") is not None else None),
        )
        shown = False
        for title, value in values:
            if value in (None, ""):
                continue
            r = w.row(title)
            r.add_suffix(w.label(str(value), css=("numeric",), wrap=False))
            group.add_row(r)
            shown = True
        if not shown:
            subtitle = _("Not read yet. It needs the administrator password, and through USB it can take a minute. Many USB adapters do not pass it through.")
            group.add_row(w.row(_("Not read"), subtitle))
        if self.diag and not tools.get("smartctl"):
            group.add_row(w.row(_("smartctl is not installed (package smartmontools), so SMART details cannot be read.")))
        else:
            read = w.button(_("Read SMART…") if not shown else _("Read SMART again…"), self._read_smart, css=("flat",))
            read.set_sensitive(not self.smart_busy)
            read.set_tooltip_text(_("Asks for the administrator password. It only reads: no test is started."))
            group.set_header_suffix(read)
        return group

    @staticmethod
    def _hours(hours):
        if hours is None or hours == "":
            return None
        years = (int(hours) + 4380) // 8760
        if years < 1:
            return str(hours)
        if years == 1:
            return _("%s (about a year of use)") % hours
        return _("%(h)s (about %(y)d years of use)") % {"h": hours, "y": years}

    def _read_smart(self):
        if self.smart_busy or not self.dev:
            return
        self.smart_busy = True
        self.window.notify_text(_("Reading SMART. Through USB it can take a minute."))
        self._render()
        dev = self.dev

        def done(res):
            self.smart_busy = False
            line = res.err.strip().splitlines()[-1] if res.err.strip() else ""
            if line:
                self.window.notify_text(line)
            self.window.refresh()
            self._render()
            if isinstance(res.data, dict):
                self.diag = res.data
                self._render()
        self.window.engine.diagnose(dev.device, done, smart=True)

    def _details_group(self, dev):
        group = w.Group(_("Details"))
        rows = (
            (_("Manufacturer"), dev.vendor), (_("Model"), dev.model), (_("Type"), dev.kind_label),
            (_("Connection"), dev.transport_label), (_("Capacity"), human_size(dev.size)),
            (_("Partition table"), (dev.pttype or "").upper()), (_("Device"), dev.device),
        )
        for title, value in rows:
            if value:
                group.add_row(w.fact_row(title, value))
        if dev.serial:
            serial = w.row(_("Serial number"), _("Hidden. It identifies this drive: it is also left out of shared reports."))
            shown = w.label("", css=("monospace", "dim-label"), selectable=True)
            serial.add_suffix(shown)

            def reveal(button):
                if button.get_active():
                    shown.set_text(dev.serial)
                else:
                    shown.set_text("")
            eye = Gtk.ToggleButton(icon_name="view-reveal-symbolic", tooltip_text=_("Show the serial number"), css_classes=["flat"], valign=Gtk.Align.CENTER)
            eye.update_property([Gtk.AccessibleProperty.LABEL], [_("Show the serial number")])
            eye.connect("toggled", reveal)
            serial.add_suffix(eye)
            group.add_row(serial)
        lines = (self.diag or {}).get("kernel") or []
        if lines:
            r = w.row(_("Messages from the system log"),
                      ngettext("%d recent message about this drive", "%d recent messages about this drive", len(lines)) % len(lines), activatable=True)
            r.add_suffix(w.icon("go-next-symbolic"))
            r.connect("activated", lambda *_a: w.TextDialog(_("Messages from the system log"), "\n".join(lines)).present(self.window))
            group.add_row(r)
        tech = w.row(_("Technical details"), activatable=True)
        tech.add_suffix(w.icon("go-next-symbolic"))
        tech.connect("activated", lambda *_a: self.page.show_technical())
        group.add_row(tech)
        return group

    def _maintenance_group(self, dev):
        group = w.Group(_("Advanced maintenance"))
        r = w.row(_("Erase data permanently"), _("Separate from recovery. Warns first, then checks the drive and asks twice more."), activatable=True)
        r.add_suffix(w.icon("go-next-symbolic"))
        r.connect("activated", lambda *_a: actions.erase(self.window, dev))
        group.add_row(r)
        return group

    def _export(self):
        self.page.export_report()


class DevicePage(Adw.NavigationPage):
    def __init__(self, window):
        super().__init__(title=_("Drive"), tag="device")
        self.window = window
        self.dev = None
        self.stable_id = None
        self._signature = None

        self.header = Adw.HeaderBar()
        self.stack = Adw.ViewStack()
        self.overview_box = w.box(spacing=18)
        self.health = HealthView(self)
        self.rescue_box = w.box(spacing=18)
        self.history_box = w.box(spacing=18)
        self.stack.add_titled_with_icon(w.page_scroller(self.overview_box), "overview", _("Overview"), "drive-harddisk-symbolic")
        self.stack.add_titled_with_icon(w.page_scroller(self.rescue_box), "rescue", _("Recover"), "document-save-symbolic")
        self.stack.add_titled_with_icon(w.page_scroller(self.health), "health", _("Health"), "emblem-system-symbolic")
        self.stack.add_titled_with_icon(w.page_scroller(self.history_box), "history", _("History"), "document-open-recent-symbolic")
        self.switcher = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        self.narrow_title = Adw.WindowTitle(title=_("Drive"))
        self.header.set_title_widget(self.switcher)
        self.menu_button = Gtk.MenuButton(icon_name="view-more-symbolic", tooltip_text=_("More options"))
        self.menu_button.update_property([Gtk.AccessibleProperty.LABEL], [_("More options")])
        self.header.pack_end(self.menu_button)
        self.bar = Adw.ViewSwitcherBar(stack=self.stack)

        self.content = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        self.content.add_named(self.stack, "drive")
        self.gone = Adw.StatusPage(icon_name="drive-removable-media-symbolic", title=_("The drive was disconnected"),
                                   description=_("Nothing else was done. Connect it again and it comes back here."))
        self.gone.set_child(w.button(_("Back to my drives"), window.show_overview, css=("pill",)))
        self.content.add_named(self.gone, "gone")
        tool = Adw.ToolbarView(content=self.content)
        tool.add_top_bar(self.header)
        tool.add_bottom_bar(self.bar)
        self.set_child(tool)
        self._install_actions()

    def add_breakpoint_setters(self, breakpoint_):
        breakpoint_.add_setter(self.header, "title-widget", self.narrow_title)
        breakpoint_.add_setter(self.bar, "reveal", True)

    def _install_actions(self):
        group = Gio.SimpleActionGroup()
        for name, handler in (("technical", self.show_technical), ("report", self.export_report), ("remove", self.safe_remove),
                              ("unmount", self.unmount), ("force", self.force_unmount),
                              ("protect", self.protect), ("maintenance", self.maintenance), ("refresh", self.window.refresh)):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda _a, _p, h=handler: h())
            group.add_action(action)
        self.insert_action_group("device", group)
        menu = Gio.Menu()
        first = Gio.Menu()
        first.append(_("Refresh"), "device.refresh")
        first.append(_("Technical details"), "device.technical")
        first.append(_("Export diagnosis…"), "device.report")
        menu.append_section(None, first)
        second = Gio.Menu()
        second.append(_("Block writing on the device…"), "device.protect")
        second.append(_("Unmount"), "device.unmount")
        second.append(_("Force unmount (close the programs using it)…"), "device.force")
        second.append(_("Safely remove"), "device.remove")
        menu.append_section(None, second)
        third = Gio.Menu()
        third.append(_("Erase data permanently…"), "device.maintenance")
        menu.append_section(None, third)
        self.menu_button.set_menu_model(menu)

    # ----- what is shown
    def show(self, stable_id, section=None):
        changed = stable_id != self.stable_id
        self.stable_id = stable_id
        self.dev = self.window.device_by_id(stable_id)
        self._signature = None
        self._render(fresh=changed)
        if section:
            self.stack.set_visible_child_name(section)
        elif changed:
            self.stack.set_visible_child_name("overview")

    def devices_changed(self):
        if not self.stable_id:
            return
        self.dev = self.window.device_by_id(self.stable_id)
        self._render(fresh=False)

    def jobs_changed(self):
        if self.dev:
            self._render_history()

    def _render(self, fresh):
        dev = self.dev
        if not dev:
            self.set_title(_("The drive was disconnected"))
            self.content.set_visible_child_name("gone")
            self._signature = None
            return
        self.content.set_visible_child_name("drive")
        self.set_title(dev.name)
        self.narrow_title.set_title(dev.name)
        signature = repr(dev)
        if signature == self._signature and not fresh:
            return
        self._signature = signature
        self._render_overview()
        self._render_rescue()
        self.health.show_device(dev, fresh=fresh)
        self._render_history()

    def _hero(self, dev):
        hero = w.hbox(16)
        image = w.icon(dev.symbolic_icon, 48, css=("hero-icon",))
        image.set_valign(Gtk.Align.START)
        hero.append(image)
        names = w.box(spacing=4)
        names.set_hexpand(True)
        names.append(w.label(dev.name, css=("title-2",)))
        names.append(w.label(dev.subtitle + (" · " + dev.device), css=("dim-label",)))
        names.append(w.LevelBadge(dev.health.level, dev.health.label))
        hero.append(names)
        return hero

    def refresh_overview(self):
        if self.dev:
            self._render_overview()

    def _render_overview(self):
        box = self.overview_box
        w.clear(box)
        dev = self.dev
        box.append(self._hero(dev))
        buttons = [w.button(_("Recover files"), lambda: self.window.open_wizard(dev), icon_name="document-save-symbolic",
                            css=("suggested-action", "pill") if dev.health.risky else ("pill",))]
        if dev.kind != "image":
            buttons.append(w.button(_("Check drive"), lambda: self.stack.set_visible_child_name("health"),
                                    icon_name="system-search-symbolic", css=("pill",)))
        box.append(w.button_row(*buttons))
        vols = dev.content_volumes
        if not vols:
            box.append(w.Group(_("Volumes"), _("No filesystem was recognized on it. If it should have partitions, searching for them with TestDisk does not change the disk.")))
        else:
            head = w.label(_("Volumes"), css=("heading",))
            box.append(head)
        for vol in vols:
            box.append(self._volume_card(dev, vol))

    def _volume_card(self, dev, vol):
        card = w.box(spacing=8, css=("card", "drive-card"))
        top = w.hbox(10)
        top.append(w.icon({"crypto_LUKS": "channel-secure-symbolic", "BitLocker": "channel-secure-symbolic"}.get(vol.fstype, "drive-harddisk-symbolic")))
        title = w.label(vol.title, css=("heading",))
        title.set_hexpand(True)
        top.append(title)
        top.append(w.label(" · ".join(x for x in (vol.fstype or _("unknown"), human_size(vol.size)) if x), css=("caption", "dim-label"), wrap=False))
        card.append(top)
        state = vol.state_label
        if vol.mountpoint:
            state += " — " + vol.mountpoint
        card.append(w.label(state, css=("dim-label",), selectable=True))
        if vol.device_read_only:
            card.append(w.label(_("Writing is also blocked on the device itself until it is disconnected."), css=("caption", "dim-label")))
        if vol.used is not None and vol.avail is not None:
            card.append(w.UsageBar(vol.used, vol.avail))
        if vol.multi_device:
            card.append(w.label(_("This volume spans more than one device. All of them must be connected."), css=("caption", "dim-label")))
        reason = self._write_cause(vol)
        if reason:
            card.append(w.label(reason))
        buttons = []
        if vol.state == "unmounted":
            if vol.fs_supported:
                buttons.append(w.button(_("Mount read-only"), lambda: mount_volume(self.window, dev, vol), icon_name="media-eject-symbolic"))
            else:
                card.append(w.label(_("This computer has no driver for this filesystem. Installing the right package may solve it.")))
        elif vol.state in ("mounted-ro", "mounted-rw"):
            buttons.append(w.button(_("Open files"), lambda: w.open_folder(self.window, vol.mountpoint), icon_name="folder-open-symbolic"))
            buttons.append(w.button(_("Unmount"), lambda: unmount_volume(self.window, vol), icon_name="media-eject-symbolic"))
        elif vol.state == "system":
            buttons.append(w.button(_("Open files"), lambda: w.open_folder(self.window, vol.mountpoint), icon_name="folder-open-symbolic"))
        elif vol.state == "locked":
            buttons.append(w.button(_("Unlock…"), lambda: unlock_volume(self.window, vol, self.window.refresh), icon_name="channel-insecure-symbolic"))
        if buttons:
            card.append(w.button_row(*buttons))
        return card

    def _write_cause(self, vol):
        diag = self.health.diag or {}
        why = next((v for v in diag.get("volumes", []) if v.get("volume") == vol.device), {})
        if why.get("reason") and why.get("cause") not in ("ok", "not-mounted", "system", ""):
            return why["reason"]
        return ""

    def _render_rescue(self):
        box = self.rescue_box
        w.clear(box)
        dev = self.dev
        box.append(self._hero(dev))
        box.append(w.label(_("Copy your files to another place, step by step. This never writes to this drive."), css=("title-4",)))
        start = w.button(_("Start recovering files"), lambda: self.window.open_wizard(dev), css=("suggested-action", "pill"), icon_name="document-save-symbolic")
        start.set_halign(Gtk.Align.START)
        box.append(start)
        group = w.Group(_("What can be done"))
        group.add_row(w.row(_("Copy files that can still be read"), _("The quickest and safest: names and folders are kept."), icon_name="edit-copy-symbolic"))
        group.add_row(w.row(_("List what exists, by type"), _("Goes through the folders. Then you choose what to copy."), icon_name="edit-find-symbolic"))
        group.add_row(w.row(_("Search by content"), _("For when files cannot be opened. Names and folders are lost, and nothing is guaranteed."), icon_name="system-search-symbolic"))
        box.append(group)
        if dev.trim:
            box.append(w.label(_("This SSD erases deleted blocks by itself (TRIM). Files deleted some time ago may be gone for good, however deep the search."), css=("dim-label",)))

    def _render_history(self):
        box = self.history_box
        w.clear(box)
        dev = self.dev
        mounts = [v.mountpoint for v in dev.volumes if v.mountpoint]
        names = [v.device for v in dev.volumes]
        jobs = [j for j in self.window.jobs if j.source in names or any(j.source == m or j.source.startswith(m + "/") for m in mounts)]
        group = w.Group(_("Copies and searches of this drive"))
        for job in jobs:
            group.add_row(job_row(self.window, job))
        if not jobs:
            box.append(Adw.StatusPage(icon_name="document-open-recent-symbolic", title=_("Nothing yet"),
                                      description=_("What you copy from this drive is listed here.")))
        else:
            box.append(group)

    # ----- menu
    def show_technical(self):
        if not self.dev:
            return

        def done(res):
            w.TextDialog(_("Technical details"), res.out or res.err).present(self.window)
        self.window.engine.report_text(self.dev.device, done)

    def export_report(self):
        if not self.dev:
            return
        dev = self.dev

        def answered(rid):
            if rid != "cancel":
                actions.save_report(self.window, dev.device, _("Export diagnosis"), f"big-mount-{dev.device.rsplit('/', 1)[-1]}.txt", rid == "hide")

        w.alert(self.window, _("Export diagnosis"), _("Hide serial numbers, labels and your user name?"),
                responses=(("cancel", _("Cancel")), ("keep", _("Keep them")), ("hide", _("Hide them"))),
                default="hide", close="cancel", suggested=("hide",), callback=answered)

    def safe_remove(self):
        if self.dev:
            actions.unmount(self.window, self.dev.device, remove=True)

    def unmount(self):
        if self.dev:
            actions.unmount(self.window, actions.drive_target(self.dev))

    def force_unmount(self):
        if self.dev:
            actions.force_unmount(self.window, actions.drive_target(self.dev))

    def protect(self):
        if not self.dev:
            return
        dev = self.dev
        vols = [v for v in dev.content_volumes if v.state != "system"] or dev.volumes
        target = vols[0].device if len(vols) == 1 else dev.device

        def answered(rid):
            if rid != "protect":
                return

            def done(res):
                self.window.refresh()
                self.window.notify_text((res.out or res.err).strip())
            self.window.engine.protect(target, done)

        w.alert(self.window, _("Block writing on the device"),
                _("Whatever a driver or another program tries, the disk does not change. It lasts until the drive is disconnected. It asks for the administrator password."),
                responses=(("cancel", _("Cancel")), ("protect", _("Block writing"))), default="cancel", close="cancel", callback=answered)

    def maintenance(self):
        if self.dev:
            actions.erase(self.window, self.dev)


def job_row(window, job):
    when = time.strftime("%Y-%m-%d %H:%M", time.localtime(job.created or 0))
    subtitle = f"{job.kind_label} — {when}\n{job.source}"
    if job.destination:
        subtitle += f" → {job.destination}"
    r = w.row(job.state_label, subtitle, activatable=True, icon_name=job.icon)
    r.add_suffix(w.icon("go-next-symbolic"))
    r.connect("activated", lambda *_a: window.open_job(job.id))
    return r
