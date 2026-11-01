"""Advanced maintenance: erasing a drive with its own Secure Erase. The opposite
of recovering files, and it looks like it. The engine decides who may be erased
and does it; this page only asks, twice, and tells the truth about the outcome."""

from gi.repository import Adw, Gtk

from .. import widgets as w
from ..common import _, human_duration, human_size


class MaintenancePage(Adw.NavigationPage):
    def __init__(self, window, dev):
        super().__init__(title=_("Advanced maintenance"), tag="maintenance")
        self.window = window
        self.dev = dev
        self.check = None
        self.token = None
        self.typed = ""
        self.allow_services = False
        self.unfreeze = False

        self.box = w.box(spacing=18)
        self.scroller = w.page_scroller(self.box, maximum=720)
        tool = Adw.ToolbarView(content=self.scroller)
        tool.add_top_bar(Adw.HeaderBar())
        self.set_child(tool)
        self._loading()
        window.engine.erase_check(dev.device, self._checked)

    def _loading(self):
        w.clear(self.box)
        self.box.append(Adw.StatusPage(icon_name="system-search-symbolic", title=_("Checking this drive…")))

    def _danger_panel(self):
        panel = w.box(spacing=8, css=("danger-panel",))
        head = w.hbox(10)
        head.append(w.icon("dialog-warning-symbolic", 24))
        head.append(w.label(_("Erase data permanently"), css=("title-3",)))
        panel.append(head)
        panel.append(w.label(_("IT ERASES ALL THE FILES ON THE DRIVE FOR GOOD. THIS IS NOT RECOVERY."), css=("heading",)))
        panel.append(w.label(_("To get your files back, go to Recover files instead.")))
        return panel

    def _checked(self, res):
        data = res.data if isinstance(res.data, dict) else None
        self.check = data
        w.clear(self.box)
        self.box.append(self._danger_panel())
        if not data:
            self.box.append(w.label(res.message or _("This drive cannot be erased.")))
            return
        self.box.append(w.label(data.get("name", ""), css=("title-4",)))
        if not data.get("eligible"):
            refuse = w.Group(_("It cannot be used on this drive"))
            subtitle = data.get("detail", "")
            refuse.add_row(w.row(data.get("why_text") or _("This drive cannot be erased."), subtitle, icon_name="changes-prevent-symbolic"))
            self.box.append(refuse)
            self.box.append(w.label(_("Nothing was changed. Secure Erase is only offered for SATA drives inside the computer, not in use by the running system, and it is never offered through USB."), css=("dim-label",)))
            back = w.button(_("Back"), lambda: self.window.nav.pop(), css=("pill",))
            back.set_halign(Gtk.Align.START)
            self.box.append(back)
            return
        self._explain(data)

    def _explain(self, data):
        self.box.append(w.label(_("The drive will erase itself completely, with its own Secure Erase command. Every partition and every file on it will be lost for good. This cannot be undone.")))
        parts = w.Group(_("These partitions will be lost:"))
        for p in data.get("partitions", []):
            title = p.get("label") or p.get("device", "")
            bits = [p.get("device", ""), human_size(p.get("size")), p.get("fstype", "")]
            if p.get("mountpoint"):
                bits.append(p["mountpoint"])
            parts.add_row(w.row(title, " · ".join(b for b in bits if b)))
        if not data.get("partitions"):
            parts.add_row(w.row(_("No partition was found on it.")))
        self.box.append(parts)
        info = w.Group(_("What to expect"))
        minutes = data.get("erase_minutes") or 0
        if minutes >= 508:
            info.add_row(w.row(_("The drive announces that erasing takes more than 8 hours.")))
        elif minutes > 0:
            info.add_row(w.row(_("The drive announces that erasing takes about %s.") % human_duration(minutes * 60)))
        info.add_row(w.row(_("Afterwards an empty partition table is written and read back, to check that the drive keeps what is written again.")))
        info.add_row(w.row(_("The administrator password will be requested.")))
        if data.get("frozen"):
            info.add_row(w.row(_("The computer may have to sleep for a moment first.")))
        self.box.append(info)
        cancel = w.button(_("Cancel"), lambda: self.window.nav.pop(), css=("pill",))
        cont = w.button(_("Continue…"), self._first_confirmation, css=("pill",))
        self.box.append(w.button_row(cancel, cont))
        cancel.grab_focus()

    # First confirmation: Cancel is the default, and Escape is Cancel
    def _first_confirmation(self):
        def answered(rid):
            if rid == "continue":
                self.window.engine.erase_prepare(self.dev.device, self._prepared, diskseq=self.check.get("diskseq"))
        w.alert(self.window, _("Erase the whole drive?"),
                _("Every file on %s will be lost for good. Have you copied what you need?") % self.check.get("name", ""),
                responses=(("cancel", _("Cancel")), ("continue", _("Continue…"))),
                default="cancel", close="cancel", destructive=("continue",), callback=answered)

    def _prepared(self, res):
        data = res.data if isinstance(res.data, dict) else None
        if not data or not data.get("token") or not data.get("eligible"):
            self.check = data or self.check
            w.clear(self.box)
            self.box.append(self._danger_panel())
            self.box.append(w.label((data or {}).get("why_text") or res.message or _("This drive cannot be erased.")))
            return
        self.check = data
        self.token = data["token"]
        self._second_confirmation()

    # Second confirmation: the name of the drive, typed by a person
    def _second_confirmation(self):
        name = self.check["confirm_name"]
        w.clear(self.box)
        self.box.append(self._danger_panel())
        self.box.append(w.label(_("To confirm, type the name of the drive (%s):") % name, css=("heading",)))
        entry = Gtk.Entry(placeholder_text=name, activates_default=False)
        entry.update_property([Gtk.AccessibleProperty.LABEL], [_("To confirm, type the name of the drive (%s):") % name])
        self.box.append(entry)
        cancel = w.button(_("Cancel"), lambda: self.window.nav.pop(), css=("pill",))
        erase = w.button(_("Erase the whole drive"), lambda: self._run(entry.get_text()), css=("pill", "destructive-action"))
        erase.set_sensitive(False)
        entry.connect("changed", lambda e: erase.set_sensitive(e.get_text() == name))
        self.box.append(w.button_row(cancel, erase))
        entry.grab_focus()

    def _run(self, typed):
        self.typed = typed
        w.clear(self.box)
        status = Adw.StatusPage(icon_name="dialog-warning-symbolic", title=_("Erasing the drive"),
                                description=_("Do not turn off the computer or disconnect the drive."))
        spinner = Gtk.Spinner(spinning=True)
        spinner.set_size_request(32, 32)
        status.set_child(spinner)
        self.box.append(status)
        self.set_can_pop(False)
        self.window.set_erase_running(True, allow_suspend=self.unfreeze)
        self.window.engine.erase_run(self.token, typed, self._finished, allow_services=self.allow_services, unfreeze=self.unfreeze)

    def _finished(self, res):
        self.window.set_erase_running(False)
        self.set_can_pop(True)
        self.window.refresh()
        data = res.data if isinstance(res.data, dict) else None
        if not data:
            self._outcome(_("Unable to erase the drive"), res.message or _("The drive could not be erased."), "error", [])
            return
        stage = data.get("stage")
        if stage == "busy":
            self._outcome(_("The drive is still in use. Nothing was erased."),
                          "\n\n".join(x for x in (data.get("busy_summary"), data.get("busy_advice")) if x), "warning", [],
                          retry=True)
        elif stage == "services":
            self._services(data)
        elif stage == "frozen":
            self._frozen(data)
        else:
            self._outcome(data.get("title") or _("Unable to erase the drive"), "", data.get("kind", "error"), data.get("doc", []))

    def _services(self, data):
        text = "\n".join(d.get("text", "") for d in data.get("doc", []))

        def answered(rid):
            if rid == "stop":
                self.allow_services = True
                self._run(self.typed)
            else:
                self.window.nav.pop()
        w.alert(self.window, _("Services use this device"), text,
                responses=(("cancel", _("Cancel")), ("stop", _("Stop them and continue"))),
                default="cancel", close="cancel", destructive=("stop",), callback=answered)

    def _frozen(self, data):
        text = "\n\n".join(d.get("text", "") for d in data.get("doc", []) if d.get("kind") != "h")

        def answered(rid):
            if rid == "sleep":
                self.unfreeze = True
                self._run(self.typed)
            else:
                self._outcome(_("Nothing was erased."), "", "info", [])
        w.alert(self.window, data.get("title") or _("The drive is locked against erasing"), text,
                responses=(("cancel", _("Cancel")), ("sleep", _("Sleep now"))),
                default="cancel", close="cancel", callback=answered)

    def _outcome(self, title, text, kind, doc, retry=False):
        w.clear(self.box)
        icon_name = {"info": "object-select-symbolic", "warning": "dialog-warning-symbolic"}.get(kind, "dialog-error-symbolic")
        status = Adw.StatusPage(icon_name=icon_name, title=title)
        inner = w.box(spacing=8)
        for item in doc:
            if item.get("kind") == "h":
                continue
            inner.append(w.label(("• " if item.get("kind") == "li" else "") + item.get("text", "")))
        back = w.button(_("Back"), lambda: self.window.nav.pop(), css=("pill",))
        back.set_halign(Gtk.Align.CENTER)
        if retry:
            again = w.button(_("Try again"), lambda: self._run(self.typed), css=("pill",))
            again.set_halign(Gtk.Align.CENTER)
            inner.append(again)
        inner.append(back)
        status.set_child(inner)
        status.set_description(w.escape(text) if text else None)
        self.box.append(status)
