"""What a search found, on a list that stays light with a million files: names stay
in the file the engine wrote and only the rows on screen become objects. The words
are honest about what each list is: what exists, or candidates found by content."""

import collections
import mmap
import os
import threading
import time
from array import array

from gi.repository import Adw, Gdk, Gio, GLib, GObject, Gtk

from .. import actions
from .. import widgets as w
from ..common import _, human_size, ngettext
from ..models import RESULT_CARVED, fold

try:
    from gi.repository import GdkPixbuf
except ImportError:
    GdkPixbuf = None

CATEGORIES = ("photos", "videos", "documents", "audio", "archives", "other")
THUMB_TYPES = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp")
THUMB_MAX_BYTES = 32 * 1000 * 1000
PREVIEW_MAX_BYTES = 128 * 1000 * 1000
THUMB_CACHE = 256
# The first bytes of the formats offered. gdk-pixbuf picks its loader by content:
# only files that start like one of these reach a loader
PICTURE_MAGIC = (b"\xff\xd8\xff", b"\x89PNG\r\n\x1a\n", b"GIF87a", b"GIF89a", b"BM")


def picture(path, size):
    """The picture at PATH, at most SIZE pixels wide and high. ValueError when it is
    not one of the formats offered."""
    with open(path, "rb") as handle:
        head = handle.read(12)
    if not (head.startswith(PICTURE_MAGIC) or (head[:4] == b"RIFF" and head[8:12] == b"WEBP")):
        raise ValueError(path)
    return Gdk.Texture.new_for_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(path, size, size, True))


class Index:
    """The file the engine wrote, read without copying its names into memory:
    size<TAB>mtime<TAB>category<TAB>path<NUL>"""

    def __init__(self, path):
        self.handle = open(path, "rb")
        size = os.fstat(self.handle.fileno()).st_size
        self.mm = mmap.mmap(self.handle.fileno(), 0, prot=mmap.PROT_READ) if size else b""
        self.starts = array("Q")
        self.ends = array("Q")
        self.sizes = array("Q")
        self.mtimes = array("q")
        self.cats = array("B")

    def load(self, keep_going=lambda: True):
        mm = self.mm
        pos, end = 0, len(mm)
        codes = {c.encode(): i for i, c in enumerate(CATEGORIES)}
        n = 0
        while pos < end:
            stop = mm.find(b"\0", pos)
            if stop < 0:
                stop = end
            t1 = mm.find(b"\t", pos, stop)
            t2 = mm.find(b"\t", t1 + 1, stop) if t1 >= 0 else -1
            t3 = mm.find(b"\t", t2 + 1, stop) if t2 >= 0 else -1
            if t3 >= 0:
                try:
                    self.sizes.append(int(mm[pos:t1]))
                    self.mtimes.append(int(mm[t1 + 1:t2]))
                except ValueError:
                    pos = stop + 1
                    continue
                self.cats.append(codes.get(mm[t2 + 1:t3], len(CATEGORIES) - 1))
                self.starts.append(t3 + 1)
                self.ends.append(stop)
            pos = stop + 1
            n += 1
            if n % 20000 == 0:
                if not keep_going():
                    return
                time.sleep(0)

    def __len__(self):
        return len(self.starts)

    def raw(self, i):
        return bytes(self.mm[self.starts[i]:self.ends[i]])

    def text(self, i):
        return self.raw(i).decode("utf-8", "replace")

    def order(self, cats, query, sort, keep_going=lambda: True):
        """The records to show, as indexes, or None when keep_going() said to stop.
        Runs in a thread. The search ignores case and accents, as on Home."""
        q = fold(query) if query else None
        wanted = {CATEGORIES.index(c) for c in cats} if cats else None
        out = array("L")
        for i in range(len(self.starts)):
            if i % 20000 == 0 and not keep_going():
                return None
            if wanted is not None and self.cats[i] not in wanted:
                continue
            if q is not None:
                name = self.raw(i)
                # Most names are ASCII: folding them is only lowering them
                if q not in (name.lower().decode() if name.isascii() else fold(name.decode("utf-8", "replace"))):
                    continue
            out.append(i)
        if sort == "size":
            out = array("L", sorted(out, key=lambda i: -self.sizes[i]))
        elif sort == "name":
            out = array("L", sorted(out, key=lambda i: self.raw(i).lower()))
        elif sort == "date":
            out = array("L", sorted(out, key=lambda i: -self.mtimes[i]))
        return out


class FileItem(GObject.Object):
    __gtype_name__ = "BigMountFileItem"

    def __init__(self, record, path, size, mtime, category):
        super().__init__()
        self.record = record
        self.path = path
        self.size = size
        self.mtime = mtime
        self.category = category


class ResultsModel(GObject.Object, Gio.ListModel):
    """Only the rows on screen exist as objects."""

    __gtype_name__ = "BigMountResultsModel"

    def __init__(self):
        super().__init__()
        self.index = None
        self.visible = array("L")

    def do_get_item_type(self):
        return FileItem.__gtype__

    def do_get_n_items(self):
        return len(self.visible)

    def do_get_item(self, position):
        if position >= len(self.visible) or self.index is None:
            return None
        i = self.visible[position]
        ix = self.index
        return FileItem(i, ix.text(i), ix.sizes[i], ix.mtimes[i], CATEGORIES[ix.cats[i]])

    def show(self, index, visible):
        before = len(self.visible)
        self.index = index
        self.visible = visible
        self.items_changed(0, before, len(visible))


class Thumbnails:
    """Small pictures, one worker, latest asked first, limited. Only for files found
    by content, which are on another disk: the source is never read for a picture."""

    def __init__(self):
        self.cache = collections.OrderedDict()
        self.queue = collections.deque()
        self.wake = threading.Condition()
        self.stopped = False
        self.thread = None

    def request(self, path, callback):
        hit = self.cache.get(path)
        if hit is not None:
            self.cache.move_to_end(path)
            callback(hit)
            return
        with self.wake:
            self.queue.appendleft((path, callback))
            while len(self.queue) > 64:
                self.queue.pop()
            if not self.thread:
                self.thread = threading.Thread(target=self._work, daemon=True)
                self.thread.start()
            self.wake.notify()

    def _work(self):
        while True:
            with self.wake:
                while not self.queue and not self.stopped:
                    self.wake.wait()
                if self.stopped:
                    return
                path, callback = self.queue.popleft()
            try:
                texture = picture(path, 64)
            except (GLib.Error, OSError, TypeError, ValueError):
                continue
            GLib.idle_add(self._deliver, path, texture, callback)

    def _deliver(self, path, texture, callback):
        self.cache[path] = texture
        while len(self.cache) > THUMB_CACHE:
            self.cache.popitem(last=False)
        callback(texture)
        return False

    def stop(self):
        with self.wake:
            self.stopped = True
            self.queue.clear()
            self.wake.notify()


class PreviewDialog(Adw.Dialog):
    """One picture, on request. Files that were found are never opened or run."""

    def __init__(self, path, name):
        super().__init__(title=name, content_width=640, content_height=520)
        self.picture = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, vexpand=True, hexpand=True)
        self.picture.update_property([Gtk.AccessibleProperty.LABEL], [name])
        self.stack = Gtk.Stack()
        spinner = Gtk.Spinner(spinning=True, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        spinner.set_size_request(32, 32)
        self.stack.add_named(spinner, "loading")
        self.stack.add_named(self.picture, "picture")
        self.problem = Adw.StatusPage(icon_name="image-missing-symbolic", title=_("This picture cannot be shown"),
                                      description=_("It may be incomplete. That is common with files found by content."))
        self.stack.add_named(self.problem, "problem")
        tool = Adw.ToolbarView(content=self.stack)
        tool.add_top_bar(Adw.HeaderBar())
        self.set_child(tool)
        threading.Thread(target=self._load, args=(path,), daemon=True).start()

    def _load(self, path):
        try:
            texture = picture(path, 1280)
        except (GLib.Error, OSError, TypeError, ValueError):
            GLib.idle_add(self.stack.set_visible_child_name, "problem")
            return
        GLib.idle_add(self._show, texture)

    def _show(self, texture):
        self.picture.set_paintable(texture)
        self.stack.set_visible_child_name("picture")
        return False


class ResultsPage(Adw.NavigationPage):
    def __init__(self, window, job_id):
        super().__init__(title=_("What was found"), tag=f"results-{job_id}")
        self.window = window
        self.job_id = job_id
        self.info = {}
        self.job = {}
        self.index = None
        self.model = ResultsModel()
        self.selected = set()
        self.selected_bytes = 0
        self.filters = set()
        self.query = ""
        self.sort = "folder"
        self.generation = 0
        self._search_timer = 0
        self.thumbs = Thumbnails() if GdkPixbuf else None
        self._alive = True

        self.banner = w.box()
        self.banner.set_margin_start(12)
        self.banner.set_margin_end(12)
        self.banner.set_margin_top(10)
        self.chips = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE, column_spacing=6, row_spacing=6, max_children_per_line=7, homogeneous=False)
        self.search = Gtk.SearchEntry(placeholder_text=_("Search by name"), hexpand=True)
        self.search.update_property([Gtk.AccessibleProperty.LABEL], [_("Search by name")])
        self.search.connect("search-changed", self._search_changed)
        self.sorter = Gtk.DropDown.new_from_strings([_("As found"), _("Largest first"), _("By name")])
        self.sorter.update_property([Gtk.AccessibleProperty.LABEL], [_("Order")])
        self.sorter.connect("notify::selected", self._sort_changed)
        tools = w.hbox(8)
        tools.append(self.search)
        tools.append(self.sorter)
        tools.set_margin_start(12)
        tools.set_margin_end(12)
        self.chips.set_margin_start(12)
        self.chips.set_margin_end(12)

        self.view = Gtk.ColumnView(model=Gtk.NoSelection.new(self.model), show_row_separators=False, reorderable=False)
        self.view.add_css_class("data-table")
        self.view.update_property([Gtk.AccessibleProperty.LABEL], [_("What was found")])
        self._add_column("", self._setup_check, self._bind_check, self._unbind_check)
        name_col = self._add_column(_("Name"), self._setup_name, self._bind_name, self._unbind_name)
        name_col.set_expand(True)
        self.type_col = self._add_column(_("Type"), self._setup_text, self._bind_type)
        self.size_col = self._add_column(_("Size"), self._setup_text, self._bind_size)
        self.date_col = self._add_column(_("Date"), self._setup_text, self._bind_date)
        scroller = Gtk.ScrolledWindow(child=self.view, vexpand=True)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE, vexpand=True)
        self.stack.add_named(scroller, "list")
        self.loading = Adw.StatusPage(icon_name="edit-find-symbolic", title=_("Reading the list…"))
        self.stack.add_named(self.loading, "loading")
        self.nothing = Adw.StatusPage(icon_name="edit-find-symbolic", title=_("Nothing to show"),
                                      description=_("No file matches what you asked for."))
        self.stack.add_named(self.nothing, "nothing")
        self.stack.set_visible_child_name("loading")

        self.count = w.label("", css=("caption", "dim-label"), wrap=False)
        self.count.set_margin_start(14)
        self.count.set_margin_end(14)
        self.save_btn = w.button(_("Recover selected"), self._recover, css=("suggested-action",), icon_name="document-save-symbolic")
        self.save_btn.set_sensitive(False)
        all_btn = w.button(_("Select all shown"), self._select_all, css=("flat",))
        none_btn = w.button(_("Clear selection"), self._select_none, css=("flat",))
        bar = Gtk.ActionBar()
        bar.pack_start(all_btn)
        bar.pack_start(none_btn)
        bar.pack_end(self.save_btn)

        self.open_btn = w.icon_button("folder-open-symbolic", _("Open destination"), self._open_folder)
        self.report_btn = w.icon_button("document-save-as-symbolic", _("Save report"), self._save_report)
        self.other_btn = w.button(_("Try another method"), self._other_method, css=("flat",))
        header = Adw.HeaderBar()
        header.pack_end(self.other_btn)
        header.pack_end(self.report_btn)
        header.pack_end(self.open_btn)

        body = w.box(spacing=8)
        body.append(self.banner)
        body.append(self.chips)
        body.append(tools)
        body.append(self.stack)
        body.append(self.count)
        tool = Adw.ToolbarView(content=body)
        tool.add_top_bar(header)
        tool.add_bottom_bar(bar)
        self.set_child(tool)
        self.connect("hidden", self._hidden)
        window.engine.status(job_id, self._got_job)

    def _hidden(self, *_a):
        # Popped for good, not just covered by the copy it started
        if self.window.nav.find_page(self.get_tag()) is None:
            self._alive = False
            if self.thumbs:
                self.thumbs.stop()

    # ----- loading
    def _got_job(self, res):
        self.job = res.data if isinstance(res.data, dict) else {}
        self.window.engine.results(self.job_id, self._got_results)

    def _got_results(self, res):
        data = res.data if isinstance(res.data, dict) else {}
        self.info = data
        carved = data.get("result_kind") == RESULT_CARVED
        if carved:
            self.banner.append(w.notice(_("Candidates found by content. They are saved in the destination folder, without their names and folders, and some may be incomplete. Check them before deleting anything.")))
            self.save_btn.set_child(Adw.ButtonContent(label=_("Copy selected to another folder"), icon_name="document-save-symbolic"))
        else:
            self.banner.append(w.notice(_("These files exist on the volume and have not been copied yet. Deleted files are not on this list.")))
        self.open_btn.set_visible(carved)
        self.date_col.set_visible(bool(data.get("dates_kept")))
        if not data.get("ready"):
            self.loading.set_title(_("The list is not ready yet."))
            return
        self._fill_chips(data.get("categories") or [])
        threading.Thread(target=self._load_index, args=(data["index"],), daemon=True).start()

    def _fill_chips(self, cats):
        w.clear(self.chips)
        self.chip_buttons = {}
        total = sum(c.get("files", 0) for c in cats)
        all_chip = Gtk.ToggleButton(label=_("All (%d)") % total, active=True, css_classes=["chip"])
        all_chip.connect("toggled", self._all_toggled)
        self.all_chip = all_chip
        self.chips.append(all_chip)
        for cat in sorted(cats, key=lambda c: CATEGORIES.index(c["id"]) if c["id"] in CATEGORIES else 99):
            chip = Gtk.ToggleButton(label=f"{cat['label']} ({cat.get('files', 0)})", css_classes=["chip"])
            chip.connect("toggled", self._chip_toggled, cat["id"])
            self.chip_buttons[cat["id"]] = chip
            self.chips.append(chip)

    def _load_index(self, path):
        try:
            index = Index(path)
            index.load(lambda: self._alive)
        except (OSError, ValueError) as exc:
            GLib.idle_add(self._load_failed, str(exc))
            return
        GLib.idle_add(self._index_ready, index)

    def _load_failed(self, text):
        self.loading.set_title(_("The list could not be read."))
        self.loading.set_description(w.escape(text))
        return False

    def _index_ready(self, index):
        self.index = index
        self._refilter()
        return False

    # ----- filters
    def _all_toggled(self, button):
        if button.get_active():
            self.filters = set()
            for chip in self.chip_buttons.values():
                if chip.get_active():
                    chip.set_active(False)
            self._refilter()
        elif not self.filters:
            button.set_active(True)

    def _chip_toggled(self, button, cat):
        if button.get_active():
            self.filters.add(cat)
            if self.all_chip.get_active():
                self.all_chip.set_active(False)
        else:
            self.filters.discard(cat)
            if not self.filters:
                # Turning "All" on refilters by itself
                if not self.all_chip.get_active():
                    self.all_chip.set_active(True)
                return
        self._refilter()

    def _search_changed(self, entry):
        self.query = entry.get_text().strip()
        if self._search_timer:
            GLib.source_remove(self._search_timer)
        self._search_timer = GLib.timeout_add(220, self._search_fire)

    def _search_fire(self):
        self._search_timer = 0
        self._refilter()
        return False

    def _sort_changed(self, dropdown, _p):
        self.sort = {0: "folder", 1: "size", 2: "name"}.get(dropdown.get_selected(), "folder")
        self._refilter()

    def _refilter(self):
        if not self.index:
            return
        self.generation += 1
        generation = self.generation
        index, filters, query, sort = self.index, set(self.filters), self.query, self.sort

        def work():
            # A newer filter makes this one useless: it stops instead of competing
            order = index.order(filters, query, sort, lambda: generation == self.generation)
            if order is not None:
                GLib.idle_add(self._show_order, generation, order)
        threading.Thread(target=work, daemon=True).start()

    def _show_order(self, generation, order):
        if generation != self.generation:
            return False
        self.model.show(self.index, order)
        self.stack.set_visible_child_name("list" if len(order) else "nothing")
        self._update_count()
        return False

    # ----- selection
    def _toggle(self, record, on):
        size = self.index.sizes[record]
        if on and record not in self.selected:
            self.selected.add(record)
            self.selected_bytes += size
        elif not on and record in self.selected:
            self.selected.discard(record)
            self.selected_bytes -= size
        self._update_count()

    def _select_all(self):
        for record in self.model.visible:
            if record not in self.selected:
                self.selected.add(record)
                self.selected_bytes += self.index.sizes[record]
        self.model.items_changed(0, len(self.model.visible), len(self.model.visible))
        self._update_count()

    def _select_none(self):
        self.selected.clear()
        self.selected_bytes = 0
        self.model.items_changed(0, len(self.model.visible), len(self.model.visible))
        self._update_count()

    def _update_count(self):
        shown = len(self.model.visible)
        text = _("%(shown)d shown, %(sel)d selected (%(size)s)") % {"shown": shown, "sel": len(self.selected), "size": human_size(self.selected_bytes)}
        self.count.set_text(text)
        self.save_btn.set_sensitive(bool(self.selected))

    # ----- columns
    def _add_column(self, title, setup, bind, unbind=None):
        factory = Gtk.SignalListItemFactory()
        factory.connect("setup", setup)
        factory.connect("bind", bind)
        if unbind:
            factory.connect("unbind", unbind)
        column = Gtk.ColumnViewColumn(title=title, factory=factory)
        self.view.append_column(column)
        return column

    def _setup_check(self, _f, cell):
        check = Gtk.CheckButton()
        check.update_property([Gtk.AccessibleProperty.LABEL], [_("Select")])
        cell.set_child(check)
        cell.handler = 0

    def _bind_check(self, _f, cell):
        item = cell.get_item()
        check = cell.get_child()
        check.set_active(item.record in self.selected)
        check.update_property([Gtk.AccessibleProperty.LABEL], [item.path])
        cell.handler = check.connect("toggled", lambda c, r=item.record: self._toggle(r, c.get_active()))

    def _unbind_check(self, _f, cell):
        if cell.handler:
            cell.get_child().disconnect(cell.handler)
            cell.handler = 0

    def _setup_name(self, _f, cell):
        row = w.hbox(8, css=("file-cell",))
        image = Gtk.Image(pixel_size=32)
        image.add_css_class("thumb")
        name = w.label("", ellipsize=True)
        name.set_hexpand(True)
        eye = w.icon_button("view-reveal-symbolic", _("Preview"), css=("flat", "circular"))
        eye.set_valign(Gtk.Align.CENTER)
        row.append(image)
        row.append(name)
        row.append(eye)
        cell.set_child(row)
        cell.parts = (image, name, eye)
        cell.eye_handler = 0
        cell.bound_path = None

    def _full_path(self, item):
        return os.path.join(self.info.get("root", ""), item.path)

    def _can_preview(self, item):
        if not GdkPixbuf or not item.path.lower().endswith(THUMB_TYPES) or item.size > PREVIEW_MAX_BYTES:
            return False
        # A picture of a drive at risk is one more read of it: not offered
        return self.info.get("result_kind") == RESULT_CARVED or self.job.get("level") not in ("critical", "attention")

    def _bind_name(self, _f, cell):
        item = cell.get_item()
        image, name, eye = cell.parts
        image.set_from_icon_name(w.category_icon(item.category))
        name.set_text(item.path)
        name.set_tooltip_text(item.path)
        can = self._can_preview(item)
        eye.set_visible(can)
        full = self._full_path(item)
        cell.bound_path = full
        if can:
            cell.eye_handler = eye.connect("clicked", lambda *_a, p=full, n=item.path: PreviewDialog(p, n).present(self.window))
        if (self.thumbs and self.info.get("result_kind") == RESULT_CARVED and
                item.path.lower().endswith(THUMB_TYPES) and item.size <= THUMB_MAX_BYTES):
            def deliver(texture, cell=cell, path=full, image=image):
                if cell.bound_path == path:
                    image.set_from_paintable(texture)
            self.thumbs.request(full, deliver)

    def _unbind_name(self, _f, cell):
        cell.bound_path = None
        _image, _name, eye = cell.parts
        if cell.eye_handler:
            eye.disconnect(cell.eye_handler)
            cell.eye_handler = 0

    def _setup_text(self, _f, cell):
        cell.set_child(w.label("", css=("caption", "dim-label"), wrap=False))

    def _bind_type(self, _f, cell):
        labels = {c["id"]: c["label"] for c in self.info.get("categories") or []}
        cell.get_child().set_text(labels.get(cell.get_item().category, ""))

    def _bind_size(self, _f, cell):
        cell.get_child().set_text(human_size(cell.get_item().size))

    def _bind_date(self, _f, cell):
        mtime = cell.get_item().mtime
        cell.get_child().set_text(time.strftime("%Y-%m-%d", time.localtime(mtime)) if mtime else "")

    # ----- what can be done
    def _recover(self):
        names = [self.index.raw(r) for r in sorted(self.selected)]
        # The engine cannot handle a line break in a name safely, and says so
        kept = [n for n in names if b"\n" not in n]
        skipped = len(names) - len(kept)
        if not kept:
            w.alert(self.window, _("It cannot be copied"), _("A path has a line break in its name. It cannot be handled safely."))
            return
        if skipped:
            self.window.notify_text(ngettext("%d file with a line break in its name was left out. It cannot be handled safely.",
                                             "%d files with a line break in their names were left out. They cannot be handled safely.", skipped) % skipped)
        hint = self.job.get("copy_to") or ""
        if hint:
            self._copy_to(kept, hint)
            return
        dialog = Gtk.FileDialog(title=_("Choose where to save"))

        def chosen(d, res):
            try:
                folder = d.select_folder_finish(res)
            except GLib.Error:
                return
            if folder.get_path():
                self._copy_to(kept, folder.get_path())
        dialog.select_folder(self.window, None, chosen)

    def _copy_to(self, names, destination):
        carved = self.info.get("result_kind") == RESULT_CARVED
        kwargs = {"results_of": self.job_id} if carved else {"source": self.info.get("root", "")}

        def started(res):
            data = res.data if isinstance(res.data, dict) else {}
            if data.get("id"):
                self.window.refresh_jobs()
                self.window.open_job(data["id"])
            else:
                w.alert(self.window, _("It did not start"), data.get("error_text") or res.message or _("The reason could not be determined."))

        def checked(res):
            data = res.data if isinstance(res.data, dict) else {}
            if not data.get("ok"):
                def answered(rid):
                    if rid == "other":
                        dialog = Gtk.FileDialog(title=_("Choose where to save"))

                        def chosen(d, r):
                            try:
                                folder = d.select_folder_finish(r)
                            except GLib.Error:
                                return
                            if folder.get_path():
                                self._copy_to(names, folder.get_path())
                        dialog.select_folder(self.window, None, chosen)
                w.alert(self.window, _("It cannot be saved here"), data.get("error_text") or res.message,
                        responses=(("close", _("Close")), ("other", _("Choose another folder…"))),
                        default="other", close="close", callback=answered)
                return
            self.window.engine.copy(started, destination=destination, items=names, **kwargs)
        self.window.engine.copy(checked, destination=destination, items=names, dry_run=True, scan="no", **kwargs)

    def _open_folder(self):
        root = self.info.get("root")
        if root:
            w.open_folder(self.window, root)

    def _save_report(self):
        actions.save_report(self.window, self.job_id, _("Save report"), f"big-mount-{self.job_id}.txt", True)

    def _other_method(self):
        self.window.open_wizard()
