"""Small building blocks, so that every page looks and behaves the same. Text from
devices and files is data: nothing here treats it as markup."""

from gi.repository import Adw, Gio, GLib, Gtk, Pango

from .common import _, human_size
from .models import GRADE_ICONS, LEVEL_ICONS


def label(text="", css=(), wrap=True, xalign=0.0, ellipsize=False, selectable=False, role=Gtk.AccessibleRole.LABEL):
    # The role is set on this label only: Gtk.Widget.set_accessible_role() would
    # change the role of every label in the process
    w = Gtk.Label(label=text, xalign=xalign, use_markup=False, accessible_role=role)
    if wrap and not ellipsize:
        w.set_wrap(True)
        w.set_wrap_mode(Pango.WrapMode.WORD_CHAR)
    if ellipsize:
        w.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
    w.set_selectable(selectable)
    for c in css:
        w.add_css_class(c)
    return w


def icon(name, size=None, css=()):
    w = Gtk.Image(icon_name=name, accessible_role=Gtk.AccessibleRole.PRESENTATION)
    if size:
        w.set_pixel_size(size)
    for c in css:
        w.add_css_class(c)
    return w


def button(text, callback=None, css=(), icon_name=None, tooltip=None):
    b = Gtk.Button()
    if icon_name:
        content = Adw.ButtonContent(label=text, icon_name=icon_name, use_underline=True)
        b.set_child(content)
    else:
        b.set_label(text)
        b.set_use_underline(True)
    for c in css:
        b.add_css_class(c)
    if tooltip:
        b.set_tooltip_text(tooltip)
    if callback:
        b.connect("clicked", lambda *_a: callback())
    return b


def icon_button(name, tooltip, callback=None, css=("flat",)):
    """An icon alone needs a name of its own, for screen readers."""
    b = Gtk.Button(icon_name=name, tooltip_text=tooltip)
    b.update_property([Gtk.AccessibleProperty.LABEL], [tooltip])
    for c in css:
        b.add_css_class(c)
    if callback:
        b.connect("clicked", lambda *_a: callback())
    return b


def box(orientation=Gtk.Orientation.VERTICAL, spacing=0, margins=None, css=(), children=(), **kw):
    b = Gtk.Box(orientation=orientation, spacing=spacing, **kw)
    if margins is not None:
        b.set_margin_top(margins)
        b.set_margin_bottom(margins)
        b.set_margin_start(margins)
        b.set_margin_end(margins)
    for c in css:
        b.add_css_class(c)
    for child in children:
        b.append(child)
    return b


def hbox(spacing=0, **kw):
    return box(Gtk.Orientation.HORIZONTAL, spacing, **kw)


def button_row(*buttons):
    """Buttons side by side while they fit, one under the other when they do not:
    a long translation or big fonts must never push the window wider."""
    flow = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=8, row_spacing=8,
                       min_children_per_line=1, max_children_per_line=len(buttons) or 1, homogeneous=False)
    flow.set_halign(Gtk.Align.START)
    for b in buttons:
        flow.append(b)
        # The button takes the focus, not the slot it sits in
        b.get_parent().set_focusable(False)
    return flow


def clear(container):
    if isinstance(container, (Gtk.ListBox, Gtk.FlowBox)):
        # Their headers are children too, and are not theirs to remove one by one
        container.remove_all()
        return
    child = container.get_first_child()
    while child:
        following = child.get_next_sibling()
        container.remove(child)
        child = following


def row(title="", subtitle="", activatable=False, icon_name=None):
    """An ActionRow whose texts cannot be taken for markup."""
    r = Adw.ActionRow(use_markup=False, title=title, subtitle=subtitle)
    r.set_title_lines(0)
    r.set_subtitle_lines(0)
    if activatable:
        r.set_activatable(True)
    if icon_name:
        r.add_prefix(icon(icon_name))
    return r


def fact_row(title, value):
    """A fact: its name small, the value selectable, however long it is."""
    r = row(title, value)
    r.add_css_class("property")
    r.set_subtitle_selectable(True)
    return r


def escape(text):
    """For the few titles Adwaita always reads as markup."""
    return GLib.markup_escape_text(text or "")


class Group(Adw.PreferencesGroup):
    """A group of rows that can be filled again."""

    def __init__(self, title="", description=""):
        super().__init__()
        if title:
            self.set_title(escape(title))
        if description:
            self.set_description(escape(description))
        self._rows = []

    def add_row(self, widget):
        self.add(widget)
        self._rows.append(widget)
        return widget

    def clear_rows(self):
        for r in self._rows:
            self.remove(r)
        self._rows = []


def page_scroller(child, maximum=880, margin=18):
    """Scrolls, keeps a comfortable width, and works at 1024x600 with big fonts."""
    clamp = Adw.Clamp(maximum_size=maximum, tightening_threshold=600, child=child)
    clamp.set_margin_top(margin)
    clamp.set_margin_bottom(margin + 6)
    clamp.set_margin_start(margin)
    clamp.set_margin_end(margin)
    scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True, child=clamp)
    return scroller


class LevelBadge(Gtk.Box):
    """The health of a drive in an icon and in words: never in colour alone."""

    def __init__(self, level="unknown", text="", compact=False):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self.add_css_class("level-badge")
        self._image = Gtk.Image()
        self._image.set_valign(Gtk.Align.START)
        self._label = label(text, css=("caption",) if compact else ())
        self._label.set_hexpand(True)
        self.append(self._image)
        self.append(self._label)
        self.level = None
        self.update(level, text)

    def update(self, level, text):
        if self.level:
            self.remove_css_class(f"level-{self.level}")
        self.level = level
        self.add_css_class(f"level-{level}")
        self._image.set_from_icon_name(LEVEL_ICONS.get(level, LEVEL_ICONS["unknown"]))
        self._label.set_text(text)
        self.update_property([Gtk.AccessibleProperty.LABEL], [_("Health") + ": " + text])


class GradeBadge(Gtk.Box):
    """The grade of a drive as a pill: an icon and a word, never colour alone. The
    tooltip says what the grade rests on."""

    def __init__(self, health):
        super().__init__(orientation=Gtk.Orientation.HORIZONTAL, spacing=5, valign=Gtk.Align.CENTER,
                         accessible_role=Gtk.AccessibleRole.LABEL)
        self.add_css_class("grade-pill")
        self.add_css_class(f"grade-{health.grade}")
        self.append(icon(GRADE_ICONS.get(health.grade, GRADE_ICONS["unknown"]), 14))
        self.append(label(health.grade_label, wrap=False))
        tip = health.label
        if health.notes:
            tip += "\n" + "\n".join(n.get("text", "") for n in health.notes)
        self.set_tooltip_text(tip)
        self.update_property([Gtk.AccessibleProperty.LABEL], [_("Health") + ": " + health.grade_label])


class UsageBar(Gtk.Box):
    """How full a volume is, with the words beside it."""

    def __init__(self, used, avail):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        total = (used or 0) + (avail or 0)
        bar = Gtk.LevelBar(min_value=0, max_value=1, value=(used / total) if total else 0, mode=Gtk.LevelBarMode.CONTINUOUS)
        bar.remove_offset_value(Gtk.LEVEL_BAR_OFFSET_LOW)
        bar.remove_offset_value(Gtk.LEVEL_BAR_OFFSET_HIGH)
        bar.remove_offset_value(Gtk.LEVEL_BAR_OFFSET_FULL)
        text = _("%(used)s used, %(free)s free") % {"used": human_size(used), "free": human_size(avail)}
        bar.update_property([Gtk.AccessibleProperty.LABEL], [text])
        self.append(bar)
        self.append(label(text, css=("caption", "dim-label")))


def alert(parent, heading, body="", responses=(("close", None),), default="close", close="close",
          destructive=(), suggested=(), callback=None, extra=None):
    """A question with the safe answer as default. responses: (id, label).
    Nothing is destructive unless asked, and Escape is always the close answer."""
    dialog = Adw.AlertDialog(heading=heading, body=body)
    dialog.set_body_use_markup(False)
    dialog.set_heading_use_markup(False)
    for rid, text in responses:
        dialog.add_response(rid, text or _("Close"))
    for rid in destructive:
        dialog.set_response_appearance(rid, Adw.ResponseAppearance.DESTRUCTIVE)
    for rid in suggested:
        dialog.set_response_appearance(rid, Adw.ResponseAppearance.SUGGESTED)
    dialog.set_default_response(default)
    dialog.set_close_response(close)
    if extra:
        dialog.set_extra_child(extra)
    if callback:
        dialog.connect("response", lambda _d, rid: callback(rid))
    dialog.present(parent)
    return dialog


def notice(text, level="info", action=None, callback=None):
    """A message that stays on the page, with an icon and in words. Its action, if any,
    is what the person most probably should do next."""
    card = hbox(12, css=("notice", f"notice-{level}"))
    image = icon({"critical": "dialog-error-symbolic", "attention": "dialog-warning-symbolic"}.get(level, "dialog-information-symbolic"), 20)
    image.set_valign(Gtk.Align.START)
    card.append(image)
    text_label = label(text)
    text_label.set_hexpand(True)
    card.append(text_label)
    if action:
        b = button(action, callback, css=("suggested-action",) if level == "critical" else ())
        b.set_valign(Gtk.Align.CENTER)
        card.append(b)
    return card


def toast(overlay, text, timeout=4):
    t = Adw.Toast(title=text, timeout=timeout)
    t.set_use_markup(False)
    overlay.add_toast(t)
    return t


def open_folder(window, path):
    """The folder in the file manager of the person. Never a file that was found."""
    launcher = Gtk.FileLauncher.new(Gio.File.new_for_path(path))
    launcher.launch(window, None, None)


class TextDialog(Adw.Dialog):
    """Technical text: selectable, monospace, and out of the way of the rest."""

    def __init__(self, title, text):
        super().__init__(title=title, content_width=760, content_height=520)
        view = Gtk.TextView(editable=False, monospace=True, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        view.set_top_margin(12)
        view.set_bottom_margin(12)
        view.set_left_margin(12)
        view.set_right_margin(12)
        view.get_buffer().set_text(text)
        view.update_property([Gtk.AccessibleProperty.LABEL], [title])
        scroller = Gtk.ScrolledWindow(child=view, vexpand=True)
        tool = Adw.ToolbarView(content=scroller)
        header = Adw.HeaderBar()
        copy = icon_button("edit-copy-symbolic", _("Copy"), lambda: view.get_clipboard().set(text))
        header.pack_start(copy)
        tool.add_top_bar(header)
        self.set_child(tool)


class Stat(Gtk.Box):
    """One number of a job, with what it counts."""

    def __init__(self, caption):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=2, css_classes=["stat"])
        self.caption = label(caption, css=("caption", "dim-label"))
        self.value = label("—", css=("numeric", "title-4"))
        self.append(self.value)
        self.append(self.caption)

    def set_value(self, text):
        self.value.set_text(text)
        self.set_visible(bool(text))


def category_icon(cat):
    return {
        "photos": "image-x-generic-symbolic",
        "videos": "video-x-generic-symbolic",
        "documents": "x-office-document-symbolic",
        "audio": "audio-x-generic-symbolic",
        "archives": "package-x-generic-symbolic",
        "other": "text-x-generic-symbolic",
    }.get(cat, "text-x-generic-symbolic")
