"""The welcome screen: what Big-Mount can do, once, when it opens on its home."""

from gi.repository import Adw, Gtk

from . import widgets as w
from .common import _, save_setting, setting


def features():
    """(icon, title, description), in the order a person meets them."""
    return [
        ("drive-harddisk-symbolic", _("Drives mounted at boot"),
         _("The partitions of internal disks are mounted at every boot, ready to use.")),
        ("security-high-symbolic", _("Health in one word"),
         _("Critical, Poor, Good or Healthy, from SMART, errors, age and temperature.")),
        ("document-save-symbolic", _("Rescue your files"),
         _("Copies files off a failing disk with real progress, and resumes after a power cut.")),
        ("drive-multidisk-symbolic", _("Disk images and lost partitions"),
         _("Reads a damaged disk only once, and finds partitions that were lost.")),
        ("changes-prevent-symbolic", _("Why can't I write here?"),
         _("Explains read-only devices, and fixes them when that is safe.")),
        ("system-run-symbolic", _("Busy devices"),
         _("Shows which programs keep a device busy, and asks them to close.")),
        ("media-eject-symbolic", _("Safe removal"),
         _("Unmounts and powers off a drive without forcing anything.")),
        ("dialog-warning-symbolic", _("Warnings when it matters"),
         _("Optional, in the menu: when a drive with problems is mounted, you are told, once per boot.")),
        ("edit-clear-all-symbolic", _("Secure Erase"),
         _("Restores an internal SATA SSD that no longer keeps what is written.")),
        ("utilities-terminal-symbolic", _("Also in the terminal"),
         _("The same tools without a window: bigmount --drive")),
    ]


def should_show():
    return setting("welcome", "show", "true") != "false"


def _feature(icon_name, title, description):
    row = w.hbox(12)
    image = w.icon(icon_name, 32, css=("dim-label",))
    image.set_valign(Gtk.Align.START)
    row.append(image)
    text = w.box(spacing=4)
    text.append(w.label(title, css=("heading",)))
    desc = w.label(description, css=("dim-label",))
    desc.set_max_width_chars(40)
    text.append(desc)
    row.append(text)
    return row


class WelcomeDialog(Adw.Dialog):
    def __init__(self):
        super().__init__(title=_("Welcome to Big-Mount"), content_width=900, content_height=650)
        content = w.box(spacing=12)
        for side in ("start", "end", "top"):
            getattr(content, f"set_margin_{side}")(20)
        content.set_margin_bottom(12)

        head = w.box(spacing=12)
        head.set_halign(Gtk.Align.CENTER)
        head.append(w.icon("big-mount", 64))
        title = w.label(_("Welcome to Big-Mount"), css=("title-1",), xalign=0.5, role=Gtk.AccessibleRole.HEADING)
        head.append(title)
        head.append(w.label(_("Your drives, how they are doing, and your files safe on another disk."),
                            css=("title-4", "dim-label"), xalign=0.5))
        content.append(head)

        # Two columns where there is room, one on a narrow screen
        grid = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, homogeneous=True, min_children_per_line=1,
                           max_children_per_line=2, column_spacing=24, row_spacing=16)
        grid.set_margin_top(18)
        grid.set_valign(Gtk.Align.START)
        for icon_name, name, description in features():
            child = Gtk.FlowBoxChild(child=_feature(icon_name, name, description), focusable=False)
            grid.append(child)
        content.append(grid)

        tip = w.label(_("Tip: type to search your drives; F5 refreshes, Ctrl+J opens copies and searches."),
                      css=("caption", "dim-label"), xalign=0.5)
        tip.set_margin_top(12)
        content.append(tip)
        scroller = Gtk.ScrolledWindow(child=content, vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)

        bottom = w.hbox(12)
        for side in ("start", "end"):
            getattr(bottom, f"set_margin_{side}")(20)
        bottom.set_margin_top(12)
        bottom.set_margin_bottom(16)
        self.show_switch = Gtk.Switch(active=should_show(), valign=Gtk.Align.CENTER)
        # It wraps: the footer is outside the scroller, and the button must stay reachable
        switch_label = w.label(_("Show this screen on startup"))
        switch_label.set_hexpand(True)
        self.show_switch.update_property([Gtk.AccessibleProperty.LABEL], [switch_label.get_text()])
        switch_box = w.hbox(8)
        switch_box.append(self.show_switch)
        switch_box.append(switch_label)
        switch_box.set_hexpand(True)
        bottom.append(switch_box)
        self.start = Gtk.Button(label=_("Let's start"), css_classes=["suggested-action", "pill"])
        self.start.set_size_request(150, -1)
        self.start.connect("clicked", lambda *_a: self.close())
        bottom.append(self.start)

        outer = w.box()
        outer.append(scroller)
        outer.append(Gtk.Separator())
        outer.append(bottom)
        self.set_child(Gtk.WindowHandle(child=outer))
        self.set_default_widget(self.start)
        self.set_focus(self.start)
        # However it is closed (the button, Escape), the choice is kept
        self.connect("closed", lambda *_a: save_setting("welcome", "show", "true" if self.show_switch.get_active() else "false"))
