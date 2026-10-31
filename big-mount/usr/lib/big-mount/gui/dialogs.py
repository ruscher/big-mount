"""The dialogs of the shell side (dialog.py), drawn like the rest of the application.
The document is data: every text goes into a label as plain text."""

from gi.repository import Adw, GLib, Gtk

from . import widgets as w
from .common import _

GROUPED = ("kv", "li", "th", "tr", "pre")


def blocks(doc):
    """Consecutive lines of the same kind make one block; th and tr one table."""
    out = []
    for kind, text in doc:
        group = "table" if kind in ("th", "tr") else kind
        if out and group in GROUPED + ("table",) and out[-1][0] == group:
            out[-1][1].append((kind, text))
        else:
            out.append((group, [(kind, text)]))
    return out


def _cell(text, header):
    first, _sep, second = text.partition("\x1f")
    cell = w.box(spacing=2)
    cell.append(w.label(first, css=("heading",) if header else ()))
    if second:
        cell.append(w.label(second, css=("caption", "dim-label")))
    return cell


def render(doc):
    """The document as widgets, in its order."""
    content = w.box(spacing=12)
    for group, lines in blocks(doc):
        if group == "h":
            content.append(w.label(lines[0][1], css=("title-4",)))
        elif group == "p":
            content.append(w.label(lines[0][1]))
        elif group == "kv":
            grid = Gtk.Grid(column_spacing=12, row_spacing=4)
            for i, (_k, text) in enumerate(lines):
                key, _sep, value = text.partition("\t")
                grid.attach(w.label(key, css=("dim-label",), wrap=False), 0, i, 1, 1)
                v = w.label(value)
                v.set_hexpand(True)
                grid.attach(v, 1, i, 1, 1)
            content.append(grid)
        elif group == "li":
            items = w.box(spacing=4)
            for _k, text in lines:
                item = w.hbox(8)
                item.append(w.label("•", wrap=False))
                item.append(w.label(text))
                items.append(item)
            content.append(items)
        elif group == "table":
            grid = Gtk.Grid(column_spacing=16, row_spacing=8)
            for r, (kind, text) in enumerate(lines):
                for c, cell in enumerate(text.split("\t")):
                    grid.attach(_cell(cell, kind == "th"), c, r, 1, 1)
            content.append(grid)
        elif group == "pre":
            pre = w.label("\n".join(t for _k, t in lines), css=("monospace", "caption"))
            content.append(pre)
    return content


def _heading(args, doc):
    """What the dialog is about: its first heading, or the title it was given."""
    if doc and doc[0][0] == "h":
        return doc[0][1], doc[1:]
    return args.title or "Big-Mount", doc


def _scrolled(child, wide):
    scroller = Gtk.ScrolledWindow(child=child, hscrollbar_policy=Gtk.PolicyType.NEVER,
                                  propagate_natural_height=True, max_content_height=440)
    scroller.set_size_request(560 if wide else -1, -1)
    return scroller


class Dialog:
    """One dialog, its own main loop, one answer."""

    def __init__(self, args, doc):
        self.args = args
        self.answer = None
        self.loop = GLib.MainLoop()
        heading, doc = _heading(args, doc)
        self.dialog = Adw.AlertDialog(heading=heading)
        self.dialog.set_heading_use_markup(False)
        self.dialog.set_body_use_markup(False)
        wide = args.mode == "text" or any(k in ("th", "tr", "pre") for k, _t in doc) or len(doc) > 6
        if hasattr(self.dialog, "set_prefer_wide_layout"):
            self.dialog.set_prefer_wide_layout(wide)
        # A first short paragraph is the body; the rest is shown below it
        if doc and doc[0][0] == "p" and (len(doc) == 1 or args.mode in ("message", "question")):
            self.dialog.set_body(doc[0][1])
            doc = doc[1:]
        extra = getattr(self, "_" + args.mode)(doc)
        if extra is not None:
            self.dialog.set_extra_child(_scrolled(extra, wide) if args.mode != "text" else extra)
        self.dialog.connect("response", self._response)
        self.dialog.connect("closed", lambda *_a: self.loop.quit())

    def _respond(self, buttons, default, cancel):
        for key, label in buttons:
            self.dialog.add_response(key, label)
        appearance = {self.args.destructive: Adw.ResponseAppearance.DESTRUCTIVE,
                      self.args.suggested: Adw.ResponseAppearance.SUGGESTED}
        for key, _label in buttons:
            if key in appearance:
                self.dialog.set_response_appearance(key, appearance[key])
        self.dialog.set_default_response(default)
        self.dialog.set_close_response(cancel)
        self.cancel = cancel

    def _message(self, doc):
        self._respond([("close", _("Close"))], "close", "close")
        return render(doc) if doc else None

    def _question(self, doc):
        keys = [k for k, _l in self.args.buttons]
        cancel = self.args.cancel if self.args.cancel in keys else keys[0]
        default = self.args.default if self.args.default in keys else cancel
        self._respond(self.args.buttons, default, cancel)
        return render(doc) if doc else None

    def _menu(self, doc):
        self._respond([("cancel", _("Cancel"))], "cancel", "cancel")
        content = render(doc)
        if self.args.text:
            content.append(w.label(self.args.text))
        rows = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE, css_classes=["boxed-list"])
        for key, label in self.args.items:
            row = Adw.ActionRow(title=label, activatable=True, use_markup=False)
            row.add_suffix(w.icon("go-next-symbolic"))
            row.key = key
            rows.append(row)
        rows.connect("row-activated", lambda _l, row: self._choose(row.key))
        content.append(rows)
        return content

    def _input(self, doc):
        self._respond([("cancel", _("Cancel")), ("ok", _("OK"))], "ok", "cancel")
        self.dialog.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        content = render(doc)
        if self.args.text:
            content.append(w.label(self.args.text))
        self.entry = Gtk.Entry(activates_default=True)
        self.entry.update_property([Gtk.AccessibleProperty.LABEL], [self.args.text or self.dialog.get_heading()])
        content.append(self.entry)
        self.dialog.set_focus(self.entry)
        return content

    def _text(self, _doc):
        self._respond([("close", _("Close"))], "close", "close")
        # Read by dialog.py, which refuses a file it cannot read: never an empty text
        text = self.args.content
        view = Gtk.TextView(editable=False, monospace=True, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        for side in ("top", "bottom", "left", "right"):
            getattr(view, f"set_{side}_margin")(8)
        view.get_buffer().set_text(text)
        view.update_property([Gtk.AccessibleProperty.LABEL], [self.dialog.get_heading()])
        scroller = Gtk.ScrolledWindow(child=view, css_classes=["card"])
        scroller.set_size_request(680, 380)
        return scroller

    def _choose(self, key):
        self.answer = key
        self.dialog.force_close()

    def _response(self, _dialog, rid):
        if self.answer is not None:
            return
        if self.args.mode == "input":
            if rid == "ok":
                self.answer = self.entry.get_text()
        elif self.args.mode == "question":
            self.answer = rid
        elif self.args.mode in ("message", "text"):
            self.answer = ""

    def run(self):
        self.dialog.present(None)
        self.loop.run()
        if self.answer is None:
            return 1
        if self.answer:
            print(self.answer, flush=True)
        return 0


def run(args, doc):
    return Dialog(args, doc).run()
