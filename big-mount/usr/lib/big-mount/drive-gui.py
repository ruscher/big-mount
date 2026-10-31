#!/usr/bin/python3
"""Big-Mount drive manager: the graphical interface (bigmount --gui-drive).

It decides nothing about disks. Every fact and every operation comes from
`bigmount --drive ... --json`, the same commands a person can type, so this
window and the terminal cannot disagree. It runs as the logged-in user; what
needs more goes through UDisks2 or the polkit helper of the engine.

Nothing here reads the source disk on its own, except the folders the user
opens in the file tree, one at a time.
"""

import gettext
import json
import os
import sys
import time

from PySide6.QtCore import (QAbstractItemModel, QDir, QModelIndex, QObject, QProcess,
                            QProcessEnvironment, QSize, Qt, QTimer, QUrl, Signal)
from PySide6.QtDBus import QDBusConnection, QDBusMessage, QDBusPendingCallWatcher
from PySide6.QtGui import QAction, QDesktopServices, QFont, QIcon, QKeySequence, QPalette
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QButtonGroup, QCheckBox,
                               QComboBox, QDialog, QDialogButtonBox, QFileDialog,
                               QFileSystemModel, QFrame, QGridLayout, QHBoxLayout, QHeaderView,
                               QInputDialog, QLabel, QLineEdit, QListWidget, QListWidgetItem,
                               QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar,
                               QPushButton, QRadioButton, QScrollArea, QSizePolicy, QSpinBox,
                               QSplitter, QStackedWidget, QTabWidget, QTreeView, QVBoxLayout,
                               QWidget)

LIB_DIR = os.path.dirname(os.path.realpath(__file__))
PREFIX = os.path.normpath(os.path.join(LIB_DIR, "..", ".."))
BIGMOUNT = os.environ.get("BM_GUI_BIN") or os.path.join(PREFIX, "bin", "bigmount")
LOCALE_DIR = os.path.join(PREFIX, "share", "locale")

_ = gettext.translation("big-mount", LOCALE_DIR, fallback=True).gettext

# What the exit codes of the engine mean to this window
EXIT_OK, EXIT_BUSY, EXIT_REFUSED, EXIT_NOAUTH, EXIT_SAFETY = 0, 3, 4, 5, 20

RUNNING_STATES = {"pending", "analyzing", "running", "verifying", "stopping"}
RESUMABLE_STATES = {"paused", "interrupted", "cancelled", "needs-attention"}


def human_size(n):
    """Powers of 1000, like Dolphin and the terminal interface."""
    if n is None:
        return "?"
    n = float(n)
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if n < 1000 or unit == "TB":
            return f"{int(n)} {unit}" if unit == "B" or n >= 100 else f"{n:.1f} {unit}"
        n /= 1000
    return ""


def human_time(seconds):
    if seconds is None:
        return "—"
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"


def is_dark(widget):
    return widget.palette().color(QPalette.Window).lightness() < 128


def level_color(level, widget):
    """Status colours that stay readable on a light and on a dark theme."""
    dark = is_dark(widget)
    return {
        "critical": "#ff6b6b" if dark else "#c0392b",
        "attention": "#f5b041" if dark else "#b9770e",
        "normal": "#58d68d" if dark else "#1e8449",
    }.get(level, "#aab2bd" if dark else "#5d6d7e")


LEVEL_ICON = {
    "critical": "dialog-error",
    "attention": "dialog-warning",
    "normal": "emblem-ok-symbolic",
}


def theme_icon(name, fallback="drive-harddisk"):
    icon = QIcon.fromTheme(name)
    return icon if not icon.isNull() else QIcon.fromTheme(fallback)


# ---------------------------------------------------------------------------
# The engine: bigmount --drive, without ever blocking the window


class Engine(QObject):
    """Runs one command of the engine per call, and calls back with the result."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._running = set()

    def run(self, args, callback=None, json_output=True):
        """callback(data, exit_code, stdout, stderr). Returns the QProcess."""
        proc = QProcess(self)
        env = QProcessEnvironment.systemEnvironment()
        proc.setProcessEnvironment(env)
        full = ["--drive", *args]
        if json_output:
            full.append("--json")
        self._running.add(proc)

        def finished(code, _status):
            self._running.discard(proc)
            try:
                out = bytes(proc.readAllStandardOutput()).decode("utf-8", "replace")
                err = bytes(proc.readAllStandardError()).decode("utf-8", "replace")
            except RuntimeError:
                # The window closed while it ran: nobody is left to tell
                return
            data = None
            if json_output and out.strip():
                try:
                    data = json.loads(out)
                except ValueError:
                    data = None
            if callback:
                callback(data, code, out, err)
            proc.deleteLater()

        def failed(error):
            # The program did not even start: finished will not come
            if error == QProcess.FailedToStart:
                self._running.discard(proc)
                if callback:
                    callback(None, 127, "", proc.errorString())
                proc.deleteLater()

        proc.finished.connect(finished)
        proc.errorOccurred.connect(failed)
        proc.start(BIGMOUNT, full)
        return proc


# ---------------------------------------------------------------------------
# Small building blocks


class Card(QFrame):
    """A rounded panel that follows the colours of the theme."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("card")
        self.setFrameShape(QFrame.NoFrame)
        self.layout_ = QVBoxLayout(self)
        self.layout_.setContentsMargins(16, 14, 16, 14)
        self.layout_.setSpacing(8)


def heading(text, size=1.25, bold=True):
    label = QLabel(text)
    font = label.font()
    font.setPointSizeF(font.pointSizeF() * size)
    font.setBold(bold)
    label.setFont(font)
    label.setWordWrap(True)
    label.setTextFormat(Qt.PlainText)
    return label


def body(text="", muted=False):
    label = QLabel(text)
    label.setWordWrap(True)
    label.setTextFormat(Qt.PlainText)
    label.setTextInteractionFlags(Qt.TextSelectableByMouse)
    if muted:
        label.setProperty("muted", True)
    return label


def clear_layout(layout):
    while layout.count():
        item = layout.takeAt(0)
        if item.widget():
            item.widget().deleteLater()
        elif item.layout():
            clear_layout(item.layout())


def button(text, icon=None, primary=False, tip=""):
    btn = QPushButton(text)
    if icon:
        btn.setIcon(theme_icon(icon, icon))
    if primary:
        btn.setDefault(True)
        btn.setProperty("primary", True)
    if tip:
        btn.setToolTip(tip)
    return btn


class HealthPill(QWidget):
    """The health of a drive in icon and words: never in colour alone."""

    def __init__(self, level, label, parent=None):
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        icon = QLabel()
        icon.setPixmap(theme_icon(LEVEL_ICON.get(level, "dialog-question"), "dialog-information").pixmap(16, 16))
        text = QLabel(label)
        text.setWordWrap(True)
        text.setTextFormat(Qt.PlainText)
        text.setStyleSheet(f"color: {level_color(level, self)}; font-weight: 600;")
        lay.addWidget(icon, 0, Qt.AlignTop)
        lay.addWidget(text, 1)
        self.setAccessibleName(_("Health") + ": " + label)


class UsageBar(QProgressBar):
    def __init__(self, used, avail, parent=None):
        super().__init__(parent)
        total = used + avail
        self.setRange(0, 1000)
        self.setValue(int(used * 1000 / total) if total else 0)
        self.setTextVisible(False)
        self.setFixedHeight(6)
        self.setAccessibleName(_("Space") + f": {human_size(used)} / {human_size(avail)}")


# ---------------------------------------------------------------------------
# The list of drives


class DeviceRow(QWidget):
    def __init__(self, dev, parent=None):
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(10, 10, 10, 10)
        lay.setSpacing(10)
        icon = QLabel()
        icon.setPixmap(theme_icon(dev.get("icon", "drive-harddisk")).pixmap(32, 32))
        lay.addWidget(icon, 0, Qt.AlignTop)
        col = QVBoxLayout()
        col.setSpacing(2)
        title = QLabel(dev.get("name", ""))
        title.setTextFormat(Qt.PlainText)
        font = title.font()
        font.setBold(True)
        title.setFont(font)
        title.setWordWrap(True)
        col.addWidget(title)
        size = next((v.get("size") for v in dev.get("volumes", []) if v.get("device") == dev.get("device")), None)
        sub = QLabel(f"{dev.get('kind_label', '')} · {human_size(size)}")
        sub.setProperty("muted", True)
        sub.setTextFormat(Qt.PlainText)
        col.addWidget(sub)
        health = dev.get("health", {})
        col.addWidget(HealthPill(health.get("level", "unknown"), health.get("label", "")))
        lay.addLayout(col, 1)


class DeviceList(QListWidget):
    selected = Signal(dict)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("devices")
        self.setAccessibleName(_("Storage devices"))
        self.setSelectionMode(QAbstractItemView.SingleSelection)
        self.setVerticalScrollMode(QAbstractItemView.ScrollPerPixel)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.setUniformItemSizes(False)
        self.currentItemChanged.connect(self._changed)
        self._devices = []

    def set_devices(self, devices):
        """Keeps the selection by device name across a refresh."""
        current = self.current_device_name()
        self.blockSignals(True)
        self.clear()
        self._devices = devices
        restore = -1
        for i, dev in enumerate(devices):
            item = QListWidgetItem(self)
            item.setData(Qt.UserRole, dev)
            health = dev.get("health", {})
            item.setData(Qt.AccessibleTextRole, f"{dev.get('name')}, {dev.get('kind_label')}, {health.get('label')}")
            self.setItemWidget(item, DeviceRow(dev))
            if dev.get("device") == current:
                restore = i
        self._fit_rows()
        self.blockSignals(False)
        if restore >= 0:
            self.setCurrentRow(restore)
        elif devices:
            self.setCurrentRow(0)

    def _fit_rows(self):
        """Wrapped text needs the height for the width the row really has."""
        width = max(self.viewport().width() - 14, 120)
        for i in range(self.count()):
            item = self.item(i)
            row = self.itemWidget(item)
            if row:
                item.setSizeHint(QSize(width, row.layout().totalHeightForWidth(width) + 8))

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._fit_rows()

    def current_device_name(self):
        item = self.currentItem()
        return item.data(Qt.UserRole).get("device") if item else None

    def select_device(self, name):
        for i in range(self.count()):
            if self.item(i).data(Qt.UserRole).get("device") == name:
                self.setCurrentRow(i)
                return True
        return False

    def _changed(self, current, _previous):
        if current:
            self.selected.emit(current.data(Qt.UserRole))


# ---------------------------------------------------------------------------
# What one drive looks like


class DevicePage(QScrollArea):
    """Facts first, in plain words. Technical details one click away."""

    action = Signal(str, dict, dict)  # verb, device, volume

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine = engine
        self.setWidgetResizable(True)
        self.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        self.lay = QVBoxLayout(inner)
        self.lay.setContentsMargins(18, 18, 18, 18)
        self.lay.setSpacing(12)
        self.setWidget(inner)
        self.dev = None
        self.tools = {}
        self.diag = None

    def show_device(self, dev):
        same = self.dev and self.dev.get("device") == dev.get("device")
        self.dev = dev
        if not same:
            self.diag = None
        self._render()
        self.engine.run(["diagnose", dev["device"]], self._diagnosed)

    def _diagnosed(self, data, _code, _out, _err):
        if not data or not self.dev or data.get("device", {}).get("device") != self.dev.get("device"):
            return
        self.diag = data
        self.tools = data.get("tools", {})
        self._render()

    def _render(self):
        clear_layout(self.lay)
        dev = self.dev
        if not dev:
            return
        health = dev.get("health", {})
        head = QHBoxLayout()
        icon = QLabel()
        icon.setPixmap(theme_icon(dev.get("icon", "drive-harddisk")).pixmap(48, 48))
        head.addWidget(icon, 0, Qt.AlignTop)
        names = QVBoxLayout()
        names.setSpacing(2)
        names.addWidget(heading(dev.get("name", ""), 1.45))
        size = next((v.get("size") for v in dev.get("volumes", []) if v.get("device") == dev.get("device")), None)
        parts = [dev.get("kind_label", ""), human_size(size)]
        if dev.get("transport_label") and dev.get("kind") not in ("usb", "nvme"):
            parts.append(dev["transport_label"])
        parts.append(dev.get("device", ""))
        names.addWidget(body(" · ".join(p for p in parts if p), muted=True))
        head.addLayout(names, 1)
        self.lay.addLayout(head)
        self.lay.addWidget(self._health_card(dev, health))
        vols = [v for v in dev.get("volumes", []) if not (v.get("type") == "disk" and v.get("state") == "container")]
        if vols:
            self.lay.addWidget(heading(_("Volumes"), 1.1))
        else:
            self.lay.addWidget(body(_("No filesystem was recognized on it. If it should have partitions, searching for them with TestDisk does not change the disk.")))
        for vol in vols:
            self.lay.addWidget(self._volume_card(dev, vol))
        self.lay.addWidget(self._tools_row(dev))
        self.lay.addStretch(1)

    def _health_card(self, dev, health):
        card = Card()
        level = health.get("level", "unknown")
        card.layout_.addWidget(HealthPill(level, health.get("label", "")))
        for reason in health.get("reasons", []):
            card.layout_.addWidget(body("• " + reason.get("text", "")))
        if self.diag:
            for advice in self.diag.get("advice", []):
                card.layout_.addWidget(body("→ " + advice))
        smart = health.get("smart", {})
        if smart.get("verdict"):
            text = _("SMART verdict") + f": {smart['verdict']}"
            if smart.get("hours") is not None:
                text += " · " + _("Power-on hours") + f": {smart['hours']}"
            card.layout_.addWidget(body(text, muted=True))
        return card

    def _volume_card(self, dev, vol):
        card = Card()
        title = vol.get("label") or vol.get("device", "").rsplit("/", 1)[-1]
        top = QHBoxLayout()
        top.addWidget(heading(title, 1.05), 1)
        fs = vol.get("fstype") or _("unknown")
        top.addWidget(body(f"{fs} · {human_size(vol.get('size'))}", muted=True), 0, Qt.AlignRight)
        card.layout_.addLayout(top)
        state = vol.get("state_label", "")
        if vol.get("mountpoint"):
            state += " — " + vol["mountpoint"]
        card.layout_.addWidget(body(state))
        if vol.get("device_read_only"):
            card.layout_.addWidget(body(_("Writing is also blocked on the device itself until it is disconnected."), muted=True))
        if vol.get("used") is not None and vol.get("avail") is not None:
            card.layout_.addWidget(UsageBar(vol["used"], vol["avail"]))
            card.layout_.addWidget(body(_("%(used)s used, %(free)s free") % {
                "used": human_size(vol["used"]), "free": human_size(vol["avail"])}, muted=True))
        if vol.get("multi_device"):
            card.layout_.addWidget(body(_("This volume spans more than one device. All of them must be connected."), muted=True))
        if self.diag:
            why = next((v for v in self.diag.get("volumes", []) if v.get("volume") == vol.get("device")), {})
            if why.get("reason") and why.get("cause") not in ("ok", "not-mounted", "system", ""):
                card.layout_.addWidget(body(why["reason"]))
        row = QHBoxLayout()
        row.setSpacing(6)
        st = vol.get("state")
        risky = dev.get("health", {}).get("level") in ("critical", "attention")

        def add(verb, text, icon=None, primary=False, tip=""):
            btn = button(text, icon, primary, tip)
            btn.setAccessibleDescription(title)
            btn.clicked.connect(lambda: self.action.emit(verb, dev, vol))
            row.addWidget(btn)

        if st == "unmounted":
            if vol.get("fs_supported"):
                add("rescue", _("&Recover files…"), "edit-copy", primary=risky)
                add("mount", _("&Mount read-only"), "media-mount")
            else:
                card.layout_.addWidget(body(_("This computer has no driver for this filesystem. Installing the right package may solve it.")))
        elif st in ("mounted-ro", "mounted-rw"):
            add("rescue", _("&Copy files to another disk…"), "edit-copy", primary=risky)
            add("open", _("&Open folder"), "folder-open")
            add("unmount", _("&Unmount"), "media-eject")
        elif st == "locked":
            add("unlock", _("Un&lock…"), "object-unlocked")
        elif st == "no-fs":
            add("advanced", _("Look for &lost partitions…"), "edit-find")
        row.addStretch(1)
        card.layout_.addLayout(row)
        return card

    def _tools_row(self, dev):
        wrap = QWidget()
        lay = QHBoxLayout(wrap)
        lay.setContentsMargins(0, 4, 0, 0)
        lay.setSpacing(6)

        def add(verb, text, icon, tip=""):
            btn = button(text, icon, tip=tip)
            btn.clicked.connect(lambda: self.action.emit(verb, dev, {}))
            lay.addWidget(btn)

        add("details", _("&Technical details"), "documentation")
        if dev.get("kind") != "image" and self.tools.get("smartctl"):
            add("smart", _("Read &SMART…"), "drive-harddisk", _("Asks for the administrator password. Through USB it can take a minute."))
        add("advanced", _("&Advanced recovery…"), "tools-wizard")
        add("report", _("Export &report…"), "document-save")
        if dev.get("kind") != "image":
            add("check", _("Check and erase…"), "dialog-password", _("The drive check of Big-Mount, with Secure Erase"))
        lay.addStretch(1)
        return wrap


# ---------------------------------------------------------------------------
# Choosing what to copy


class CheckableFileModel(QFileSystemModel):
    """The file tree with check boxes. A folder marked covers what is inside."""

    changed_selection = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.marked = set()
        # Nothing that needs to read files or settle on a stuck mount: the tree
        # lists one folder when it is opened, in its own thread, and that's all
        self.setOption(QFileSystemModel.DontWatchForChanges, True)
        self.setOption(QFileSystemModel.DontResolveSymlinks, True)
        self.setOption(QFileSystemModel.DontUseCustomDirectoryIcons, True)
        self.setReadOnly(True)
        self.setFilter(QDir.AllEntries | QDir.NoDotAndDotDot | QDir.Hidden | QDir.System)

    def _covered(self, path):
        probe = path
        while probe and probe != "/":
            if probe in self.marked:
                return True
            probe = os.path.dirname(probe)
        return False

    def flags(self, index):
        flags = super().flags(index)
        if index.column() == 0:
            flags |= Qt.ItemIsUserCheckable
        return flags

    def data(self, index, role=Qt.DisplayRole):
        if role == Qt.CheckStateRole and index.column() == 0:
            return Qt.Checked if self._covered(self.filePath(index)) else Qt.Unchecked
        return super().data(index, role)

    def setData(self, index, value, role=Qt.EditRole):
        if role == Qt.CheckStateRole and index.column() == 0:
            path = self.filePath(index)
            if Qt.CheckState(value) == Qt.Checked:
                # What was marked inside is now covered by this one
                self.marked = {m for m in self.marked if not m.startswith(path + "/")}
                self.marked.add(path)
            elif path in self.marked:
                self.marked.discard(path)
            else:
                # Inside a marked folder: mark its other items instead
                parent = os.path.dirname(path)
                while parent and parent not in self.marked and parent != "/":
                    parent = os.path.dirname(parent)
                if parent in self.marked:
                    QMessageBox.information(None, _("Choose files and folders"),
                                            _("This item is inside a marked folder. Unmark the folder to choose its items one by one."))
                    return False
            self.dataChanged.emit(index, index, [Qt.CheckStateRole])
            self.layoutChanged.emit()
            self.changed_selection.emit()
            return True
        return super().setData(index, value, role)


class StepBar(QWidget):
    """Where you are in the assistant."""

    def __init__(self, steps, parent=None):
        super().__init__(parent)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        self.labels = []
        for i, step in enumerate(steps):
            label = QLabel(f"{i + 1}. {step}")
            label.setTextFormat(Qt.PlainText)
            self.labels.append(label)
            lay.addWidget(label)
            if i < len(steps) - 1:
                lay.addWidget(QLabel("›"))
        lay.addStretch(1)

    def set_step(self, current):
        for i, label in enumerate(self.labels):
            font = label.font()
            font.setBold(i == current)
            label.setFont(font)
            label.setEnabled(i <= current)
        self.setAccessibleName(self.labels[current].text() if self.labels else "")


class RescueWizard(QWidget):
    """Choose → destination → review → copy → report. Going back loses nothing."""

    finished = Signal()
    job_started = Signal(str)

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine = engine
        self.source = ""
        self.device = {}
        self.preflight = None
        self.preflight_proc = None
        self.allow = {"same-disk": False, "rw-source": False, "dest-risky": False}
        lay = QVBoxLayout(self)
        lay.setContentsMargins(18, 18, 18, 12)
        lay.setSpacing(10)
        self.title = heading(_("Copy files to another disk"), 1.35)
        lay.addWidget(self.title)
        self.steps = StepBar([_("What"), _("Where to"), _("Review")])
        lay.addWidget(self.steps)
        self.stack = QStackedWidget()
        lay.addWidget(self.stack, 1)
        nav = QHBoxLayout()
        self.back_btn = button(_("&Back"), "go-previous")
        self.back_btn.clicked.connect(self.go_back)
        self.next_btn = button(_("&Next"), "go-next", primary=True)
        self.next_btn.clicked.connect(self.go_next)
        self.cancel_btn = button(_("Close"), "dialog-cancel")
        self.cancel_btn.clicked.connect(self.finished)
        self._build_what()
        self._build_where()
        self._build_review()
        nav.addWidget(self.cancel_btn)
        nav.addStretch(1)
        nav.addWidget(self.back_btn)
        nav.addWidget(self.next_btn)
        lay.addLayout(nav)

    # ----- step 1
    def _build_what(self):
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.setContentsMargins(0, 0, 0, 0)
        self.source_label = body()
        lay.addWidget(self.source_label)
        self.all_radio = QRadioButton(_("Copy &everything"))
        self.pick_radio = QRadioButton(_("C&hoose files and folders"))
        self.all_radio.setChecked(True)
        group = QButtonGroup(self)
        group.addButton(self.all_radio)
        group.addButton(self.pick_radio)
        lay.addWidget(self.all_radio)
        lay.addWidget(self.pick_radio)
        self.tree = QTreeView()
        self.tree.setAccessibleName(_("Choose files and folders"))
        self.tree.setUniformRowHeights(True)
        self.tree.setAnimated(False)
        self.tree.setSortingEnabled(True)
        self.tree.sortByColumn(0, Qt.AscendingOrder)
        self.model = None
        lay.addWidget(self.tree, 1)
        self.pick_count = body(muted=True)
        lay.addWidget(self.pick_count)
        self.pick_radio.toggled.connect(self._pick_toggled)
        self._pick_toggled(False)
        self.stack.addWidget(page)

    def _pick_toggled(self, checked):
        self.tree.setEnabled(checked)
        if checked and self.model is None and self.source:
            self._attach_model()
        self._update_count()

    def _attach_model(self):
        self.model = CheckableFileModel(self)
        self.model.changed_selection.connect(self._update_count)
        root = self.model.setRootPath(self.source)
        self.tree.setModel(self.model)
        self.tree.setRootIndex(root)
        header = self.tree.header()
        header.setSectionResizeMode(0, QHeaderView.Stretch)
        for column in (2,):
            self.tree.hideColumn(column)

    def _update_count(self):
        if self.pick_radio.isChecked() and self.model:
            n = len(self.model.marked)
            self.pick_count.setText(_("%d items marked. The total is measured in the next steps.") % n if n else _("Nothing was marked."))
        else:
            self.pick_count.setText("")
        self._sync_nav()

    def items(self):
        if not self.pick_radio.isChecked() or not self.model:
            return []
        return sorted(os.path.relpath(p, self.source) for p in self.model.marked)

    # ----- step 2
    def _build_where(self):
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(body(_("Where to? Places on another physical disk, with room, come first.")))
        self.dest_list = QListWidget()
        self.dest_list.setAccessibleName(_("Destination"))
        self.dest_list.currentItemChanged.connect(self._dest_picked)
        lay.addWidget(self.dest_list, 1)
        row = QHBoxLayout()
        row.addWidget(QLabel(_("&Destination folder:")))
        self.dest_edit = QLineEdit()
        self.dest_edit.textChanged.connect(self._sync_nav)
        row.itemAt(0).widget().setBuddy(self.dest_edit)
        row.addWidget(self.dest_edit, 1)
        browse = button(_("&Browse…"), "folder-open")
        browse.clicked.connect(self._browse)
        row.addWidget(browse)
        lay.addLayout(row)
        grid = QGridLayout()
        self.conflict = QComboBox()
        self.conflict.addItem(_("Keep the existing file (safe)"), "skip")
        self.conflict.addItem(_("Replace it, keeping the old one aside"), "backup")
        self.conflict.addItem(_("Replace it"), "overwrite")
        self.verify = QComboBox()
        self.verify.addItem(_("Basic: rsync confirms each file as it is copied"), "basic")
        self.verify.addItem(_("Names, sizes and dates compared at the end"), "metadata")
        self.verify.addItem(_("Content compared at the end (reads the source again)"), "full")
        conflict_label = QLabel(_("If a file already e&xists:"))
        conflict_label.setBuddy(self.conflict)
        verify_label = QLabel(_("Chec&k the result:"))
        verify_label.setBuddy(self.verify)
        grid.addWidget(conflict_label, 0, 0)
        grid.addWidget(self.conflict, 0, 1)
        grid.addWidget(verify_label, 1, 0)
        grid.addWidget(self.verify, 1, 1)
        self.stall = QSpinBox()
        self.stall.setRange(0, 3600)
        self.stall.setValue(90)
        self.stall.setSuffix(" s")
        self.stall.setToolTip(_("A file that does not advance for this long is set aside, so that the others are saved first. 0: never."))
        stall_label = QLabel(_("Set &aside a stuck file after:"))
        stall_label.setBuddy(self.stall)
        grid.addWidget(stall_label, 2, 0)
        grid.addWidget(self.stall, 2, 1)
        self.limit = QSpinBox()
        self.limit.setRange(0, 4000000)
        self.limit.setSingleStep(1000)
        self.limit.setSpecialValueText(_("no limit"))
        self.limit.setSuffix(" kB/s")
        limit_label = QLabel(_("Limit the reading &speed:"))
        limit_label.setBuddy(self.limit)
        grid.addWidget(limit_label, 3, 0)
        grid.addWidget(self.limit, 3, 1)
        grid.setColumnStretch(1, 1)
        lay.addLayout(grid)
        self.stack.addWidget(page)

    def _dest_picked(self, current, _previous):
        if current:
            folder = current.data(Qt.UserRole)
            name = (self.device.get("name") or _("Recovered")).replace("/", "-")
            stamp = time.strftime("%Y-%m-%d")
            self.dest_edit.setText(os.path.join(folder, _("Recovered files") + f" - {name} - {stamp}"))

    def _browse(self):
        start = self.dest_edit.text() or os.path.expanduser("~")
        path = QFileDialog.getExistingDirectory(self, _("Destination"), start)
        if path:
            self.dest_edit.setText(path)

    def _load_destinations(self):
        # Reloading the list must not overwrite what the user chose or typed
        self.dest_list.blockSignals(True)
        self.dest_list.clear()
        self.dest_list.blockSignals(False)
        placeholder = QListWidgetItem(_("Looking for places…"), self.dest_list)
        placeholder.setFlags(Qt.NoItemFlags)
        self.engine.run(["destinations", "--source", self.source], self._got_destinations)

    def _got_destinations(self, data, _code, _out, _err):
        self.dest_list.blockSignals(True)
        self.dest_list.clear()
        self.dest_list.blockSignals(False)
        reasons = {"risky": _("drive with critical alerts"), "same-disk": _("same physical disk as the source"),
                   "no-space": _("not enough space")}
        rows = sorted((data or {}).get("destinations", []), key=lambda d: (not d.get("recommended"), -(d.get("avail") or 0)))
        first = None
        for d in rows:
            text = f"{d.get('name', '')} — {d.get('path', '')}\n{human_size(d.get('avail'))} " + _("free")
            if not d.get("recommended"):
                text += " · " + reasons.get(d.get("why"), "")
            item = QListWidgetItem(text, self.dest_list)
            item.setData(Qt.UserRole, d.get("path"))
            item.setIcon(theme_icon("emblem-ok-symbolic" if d.get("recommended") else "dialog-warning", "folder"))
            if d.get("recommended") and first is None:
                first = item
        if first is not None and not self.dest_edit.text():
            self.dest_list.setCurrentItem(first)
        if not rows:
            item = QListWidgetItem(_("No other disk is mounted. Connect one, or choose a folder."), self.dest_list)
            item.setFlags(Qt.NoItemFlags)

    # ----- step 3
    def _build_review(self):
        page = QWidget()
        self.review = QVBoxLayout(page)
        self.review.setContentsMargins(0, 0, 0, 0)
        self.stack.addWidget(page)

    def _args(self):
        args = ["--source", self.source, "--destination", self.dest_edit.text().strip(),
                "--on-conflict", self.conflict.currentData(), "--verify", self.verify.currentData(),
                "--stall-seconds", str(self.stall.value())]
        if self.limit.value() > 0:
            args += ["--bwlimit", str(self.limit.value())]
        for item in self.items():
            args += ["--item", item]
        if self.allow["same-disk"]:
            args.append("--allow-same-disk")
        if self.allow["rw-source"]:
            args.append("--allow-rw-source")
        if self.allow["dest-risky"]:
            args.append("--allow-risky-destination")
        return args

    def _run_preflight(self):
        clear_layout(self.review)
        self.preflight = None
        self.review.addWidget(body(_("Checking the source and the destination…")))
        busy = QProgressBar()
        busy.setRange(0, 0)
        self.review.addWidget(busy)
        self.review.addStretch(1)
        self._sync_nav()
        self.preflight_proc = self.engine.run(["copy", *self._args(), "--dry-run"], self._preflight_done)

    def _preflight_done(self, data, _code, _out, err):
        self.preflight_proc = None
        clear_layout(self.review)
        self.preflight = data
        if not data:
            self.review.addWidget(body(err or _("The copy was refused.")))
            self.review.addStretch(1)
            self._sync_nav()
            return
        if data.get("error"):
            card = Card()
            card.layout_.addWidget(HealthPill("critical", _("The copy was refused.")))
            card.layout_.addWidget(body(data.get("error_text", "")))
            override = {"same-disk": _("&Use the same physical disk anyway"),
                        "rw-source": _("&Copy from it while it is mounted with writing enabled"),
                        "dest-risky": _("&Use that drive with critical alerts anyway")}.get(data["error"])
            if override:
                check = QCheckBox(override)
                check.toggled.connect(lambda on, key=data["error"]: self._override(key, on))
                card.layout_.addWidget(check)
            self.review.addWidget(card)
        else:
            card = Card()
            card.layout_.addWidget(heading(_("Ready to copy"), 1.1))
            grid = QGridLayout()
            rows = [(_("Source"), data.get("source", "")), (_("Destination"), data.get("destination", ""))]
            if data.get("scanned"):
                rows.append((_("To copy"), _("%(files)s files, %(size)s") % {
                    "files": data.get("total_files", 0), "size": human_size(data.get("total_bytes"))}))
            elif data.get("total_estimate"):
                rows.append((_("To copy"), "≈ " + human_size(data.get("total_bytes"))))
            else:
                rows.append((_("To copy"), _("not measured")))
            if data.get("avail") is not None:
                rows.append((_("Free at the destination"), human_size(data["avail"])))
            if data.get("conflicts"):
                rows.append((_("Already there, with different content"), str(data["conflicts"])))
            for i, (k, v) in enumerate(rows):
                grid.addWidget(body(k, muted=True), i, 0, Qt.AlignTop)
                grid.addWidget(body(str(v)), i, 1)
            grid.setColumnStretch(1, 1)
            card.layout_.addLayout(grid)
            self.review.addWidget(card)
        for warning in data.get("warnings", []):
            self.review.addWidget(HealthPill("attention", warning.get("text", "")))
        self.review.addStretch(1)
        self._sync_nav()

    def _override(self, key, on):
        self.allow[key] = on
        if on:
            self._run_preflight()

    # ----- navigation
    def start(self, source, device):
        self.source = source
        self.device = device
        self.preflight = None
        self.allow = dict.fromkeys(self.allow, False)
        self.model = None
        self.tree.setModel(None)
        self.all_radio.setChecked(True)
        self.dest_edit.clear()
        self.source_label.setText(_("Source") + f": {source}")
        self.stack.setCurrentIndex(0)
        self.steps.set_step(0)
        self._sync_nav()

    def _sync_nav(self):
        step = self.stack.currentIndex()
        self.back_btn.setEnabled(step > 0)
        if step == 0:
            ok = self.all_radio.isChecked() or bool(self.model and self.model.marked)
            self.next_btn.setText(_("&Next"))
        elif step == 1:
            ok = bool(self.dest_edit.text().strip())
            self.next_btn.setText(_("&Next"))
        else:
            ok = bool(self.preflight and self.preflight.get("ok"))
            self.next_btn.setText(_("&Start copying"))
        self.next_btn.setEnabled(ok)

    def go_back(self):
        step = self.stack.currentIndex()
        if self.preflight_proc is not None:
            self.preflight_proc.terminate()
            self.preflight_proc = None
        if step > 0:
            self.stack.setCurrentIndex(step - 1)
            self.steps.set_step(step - 1)
        self._sync_nav()

    def go_next(self):
        step = self.stack.currentIndex()
        if step == 0:
            self.stack.setCurrentIndex(1)
            self.steps.set_step(1)
            self._load_destinations()
        elif step == 1:
            self.stack.setCurrentIndex(2)
            self.steps.set_step(2)
            self._run_preflight()
        else:
            self.next_btn.setEnabled(False)
            self.engine.run(["copy", *self._args(), "--no-wait"], self._started)
            return
        self._sync_nav()

    def _started(self, data, code, _out, err):
        if data and data.get("id"):
            self.job_started.emit(data["id"])
        else:
            QMessageBox.warning(self, _("The copy was refused."), (data or {}).get("error_text") or err or str(code))
            self._sync_nav()


# ---------------------------------------------------------------------------
# A running or finished job


class JobPage(QWidget):
    """Real numbers only. Without a total the bar says it is working, no more."""

    closed = Signal()
    open_device = Signal()

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine = engine
        self.job_id = None
        self.state = None
        self._polling = False
        self.timer = QTimer(self)
        self.timer.setInterval(1000)
        self.timer.timeout.connect(self.poll)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(18, 18, 18, 12)
        lay.setSpacing(10)
        self.title = heading("", 1.35)
        lay.addWidget(self.title)
        self.reason = body()
        lay.addWidget(self.reason)
        self.bar = QProgressBar()
        self.bar.setMinimumHeight(24)
        self.bar.setAlignment(Qt.AlignCenter)
        self.bar.setAccessibleName(_("Progress"))
        lay.addWidget(self.bar)
        self.grid = QGridLayout()
        self.values = {}
        rows = [("source", _("Source")), ("dest", _("Destination")), ("files", _("Files")), ("copied", _("Copied")),
                ("speed", _("Speed")), ("elapsed", _("Elapsed")), ("eta", _("Remaining")), ("current", _("Current file")),
                ("aside", _("Set aside")), ("failed", _("Failed"))]
        for i, (key, text) in enumerate(rows):
            k = body(text, muted=True)
            v = body()
            self.values[key] = (k, v)
            self.grid.addWidget(k, i, 0, Qt.AlignTop)
            self.grid.addWidget(v, i, 1)
        self.grid.setColumnStretch(1, 1)
        lay.addLayout(self.grid)
        self.report = QPlainTextEdit()
        self.report.setReadOnly(True)
        self.report.setAccessibleName(_("Report"))
        self.report.hide()
        lay.addWidget(self.report, 1)
        self.spacer = QWidget()
        self.spacer.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        lay.addWidget(self.spacer, 1)
        row = QHBoxLayout()
        self.close_btn = button(_("Close"), "dialog-close")
        self.close_btn.clicked.connect(self.closed)
        self.log_btn = button(_("Show &log"), "text-x-log")
        self.log_btn.clicked.connect(self.show_log)
        self.open_btn = button(_("&Open destination"), "folder-open")
        self.open_btn.clicked.connect(self.open_dest)
        self.retry_btn = button(_("&Try set-aside files again"), "view-refresh",
                                tip=_("Reads the damaged areas again, which puts more strain on the disk."))
        self.retry_btn.clicked.connect(lambda: self.resume(True))
        self.pause_btn = button(_("&Pause"), "media-playback-pause")
        self.pause_btn.clicked.connect(self.pause)
        self.resume_btn = button(_("&Resume"), "media-playback-start", primary=True)
        self.resume_btn.clicked.connect(lambda: self.resume(False))
        self.cancel_btn = button(_("&Cancel copy"), "process-stop")
        self.cancel_btn.clicked.connect(self.cancel)
        row.addWidget(self.close_btn)
        row.addWidget(self.log_btn)
        row.addStretch(1)
        for b in (self.open_btn, self.retry_btn, self.cancel_btn, self.pause_btn, self.resume_btn):
            row.addWidget(b)
            # The state of a job shows the ones it needs. All of them at once
            # would make the window wider than what it ever shows
            b.hide()
        lay.addLayout(row)
        self.data = {}

    def show_job(self, job_id):
        self.job_id = job_id
        self.state = None
        self.report.hide()
        self.spacer.show()
        self.poll()
        self.timer.start()

    def poll(self):
        if self._polling or not self.job_id:
            return
        self._polling = True
        self.engine.run(["status", self.job_id], self._polled)

    def _polled(self, data, _code, _out, _err):
        self._polling = False
        if data:
            self.update_view(data)

    def _set(self, key, value):
        k, v = self.values[key]
        v.setText(value)
        k.setVisible(bool(value))
        v.setVisible(bool(value))

    def update_view(self, d):
        self.data = d
        state = d.get("state", "")
        running = state in RUNNING_STATES
        self.title.setText(d.get("state_label", state))
        self.reason.setText(d.get("reason_text", ""))
        self.reason.setVisible(bool(d.get("reason_text")))
        done, total = d.get("bytes_done") or 0, d.get("bytes_total") or 0
        if total > 0:
            pct = min(100, int(done * 100 / total))
            self.bar.setRange(0, 100)
            self.bar.setValue(pct)
            self.bar.setFormat(("≈ %p%" if d.get("total_estimate") else "%p%"))
        elif running:
            # No total is known. A moving bar, and no made-up percentage.
            self.bar.setRange(0, 0)
            self.bar.setFormat(_("working"))
        else:
            self.bar.setRange(0, 100)
            self.bar.setValue(100 if state == "completed" else 0)
        self.bar.setVisible(running or total > 0 or state == "completed")
        self._set("source", d.get("source", ""))
        self._set("dest", d.get("destination", ""))
        files = str(d.get("files_done", 0))
        if d.get("files_total"):
            files += f" / {d['files_total']}"
        self._set("files", files if d.get("kind") != "image" else "")
        copied = human_size(done)
        if total:
            copied += (" / ≈ " if d.get("total_estimate") else " / ") + human_size(total)
        self._set("copied", copied)
        speed = ""
        if running and d.get("rate_now") is not None:
            speed = f"{human_size(d['rate_now'])}/s (" + _("average") + f" {human_size(d.get('rate_avg'))}/s)"
        self._set("speed", speed)
        self._set("elapsed", human_time(d.get("elapsed")))
        self._set("eta", human_time(d["eta"]) if running and d.get("eta") is not None else "")
        current = d.get("current", "") if running else ""
        if running and (d.get("stuck") or 0) > 5:
            current = _("Waiting for the disk to answer, for %s seconds") % d["stuck"] + " — " + current
        self._set("current", current)
        self._set("aside", str(d["deferred"]) if d.get("deferred") else "")
        self._set("failed", str(d["failed"]) if d.get("failed") else "")

        self.pause_btn.setVisible(running)
        self.pause_btn.setEnabled(state != "stopping")
        self.cancel_btn.setVisible(running)
        self.cancel_btn.setEnabled(state != "stopping")
        self.resume_btn.setVisible(state in RESUMABLE_STATES)
        self.retry_btn.setVisible(state in ("needs-attention", "completed", "paused", "interrupted") and bool(d.get("deferred")))
        self.open_btn.setVisible(bool(d.get("destination")) and not running and d.get("kind") != "image")

        if not running and state != self.state:
            self.timer.stop()
            self.engine.run(["report", self.job_id], self._report_ready, json_output=False)
        self.state = state

    def _report_ready(self, _data, _code, out, _err):
        self.report.setPlainText(out)
        self.report.show()
        self.spacer.hide()

    def pause(self):
        self.engine.run(["pause", self.job_id], lambda *_a: self.poll(), json_output=False)

    def cancel(self):
        box = QMessageBox(QMessageBox.Question, _("Cancel copy"),
                          _("Stop the copy? Files already copied stay at the destination, and the copy can be resumed later."),
                          parent=self)
        stop = box.addButton(_("Stop the copy"), QMessageBox.DestructiveRole)
        keep = box.addButton(_("Keep copying"), QMessageBox.RejectRole)
        box.setDefaultButton(keep)
        box.exec()
        if box.clickedButton() == stop:
            self.engine.run(["cancel", self.job_id], lambda *_a: self.poll(), json_output=False)

    def resume(self, retry):
        args = ["resume", self.job_id, "--no-wait"]
        if retry:
            args.append("--retry-deferred")

        def done(_d, _code, _out, err):
            self.state = None
            self.report.hide()
            self.spacer.show()
            self.timer.start()
            self.poll()
            if err.strip():
                self.reason.setText(err.strip())
        self.engine.run(args, done, json_output=False)

    def show_log(self):
        dialog = QDialog(self)
        dialog.setWindowTitle(_("Log"))
        dialog.resize(760, 480)
        lay = QVBoxLayout(dialog)
        text = QPlainTextEdit()
        text.setReadOnly(True)
        text.setLineWrapMode(QPlainTextEdit.NoWrap)
        font = QFont("monospace")
        font.setStyleHint(QFont.Monospace)
        text.setFont(font)
        path = os.path.join((self.data.get("dir") or ""), "events.log")
        try:
            with open(path, "rb") as handle:
                handle.seek(0, os.SEEK_END)
                handle.seek(max(0, handle.tell() - 200000))
                text.setPlainText(handle.read().decode("utf-8", "replace"))
        except OSError as exc:
            text.setPlainText(str(exc))
        lay.addWidget(text)
        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(dialog.reject)
        lay.addWidget(buttons)
        dialog.exec()

    def open_dest(self):
        QDesktopServices.openUrl(QUrl.fromLocalFile(self.data.get("destination", "")))


class JobsPage(QWidget):
    """Copies and images, running and past."""

    open_job = Signal(str)

    def __init__(self, engine, parent=None):
        super().__init__(parent)
        self.engine = engine
        self._polling = False
        lay = QVBoxLayout(self)
        lay.setContentsMargins(18, 18, 18, 12)
        lay.addWidget(heading(_("Copies and images"), 1.35))
        self.list = QListWidget()
        self.list.setAccessibleName(_("Copies and images"))
        self.list.itemActivated.connect(self._activated)
        lay.addWidget(self.list, 1)
        self.empty = body(_("No copies or images yet."), muted=True)
        lay.addWidget(self.empty)

    def refresh(self):
        if self._polling:
            return
        self._polling = True
        self.engine.run(["jobs"], self._done)

    def _done(self, data, _code, _out, _err):
        self._polling = False
        jobs = (data or {}).get("jobs", [])
        current = self.list.currentItem().data(Qt.UserRole) if self.list.currentItem() else None
        self.list.clear()
        self.empty.setVisible(not jobs)
        for job in jobs:
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(job.get("created") or 0))
            text = f"{job.get('state_label')} — {when}\n{job.get('source')} → {job.get('destination')}"
            item = QListWidgetItem(text, self.list)
            item.setData(Qt.UserRole, job.get("id"))
            icon = {"completed": "emblem-ok-symbolic", "failed": "dialog-error", "needs-attention": "dialog-warning",
                    "interrupted": "dialog-warning"}.get(job.get("state"), "edit-copy")
            item.setIcon(theme_icon(icon, "edit-copy"))
            if job.get("id") == current:
                self.list.setCurrentItem(item)

    def _activated(self, item):
        self.open_job.emit(item.data(Qt.UserRole))


# ---------------------------------------------------------------------------
# Dialogs


class MountDialog(QDialog):
    """On a drive at risk: block writing at the device, on by default."""

    def __init__(self, dev, vol, parent=None):
        super().__init__(parent)
        self.setWindowTitle(_("Mount read-only"))
        lay = QVBoxLayout(self)
        name = vol.get("label") or vol.get("device")
        lay.addWidget(heading(name, 1.15))
        lay.addWidget(body(_("The volume is opened without changing anything on it.")))
        health = dev.get("health", {})
        risky = health.get("level") in ("critical", "attention")
        if risky:
            lay.addWidget(HealthPill(health.get("level"), health.get("label", "")))
        self.protect = QCheckBox(_("Also block &writing on the device itself (asks for the password)"))
        self.protect.setChecked(risky)
        self.protect.setToolTip(_("Whatever a driver or another program tries, the disk does not change. It lasts until the drive is disconnected."))
        lay.addWidget(self.protect)
        buttons = QDialogButtonBox(QDialogButtonBox.Cancel)
        ok = buttons.addButton(_("&Mount read-only"), QDialogButtonBox.AcceptRole)
        ok.setDefault(True)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        lay.addWidget(buttons)


class AdvancedDialog(QDialog):
    """Tools that read and write elsewhere. Each says what it needs."""

    image_started = Signal(str)

    def __init__(self, engine, dev, tools, parent=None):
        super().__init__(parent)
        self.engine = engine
        self.dev = dev
        self.setWindowTitle(_("Advanced recovery"))
        self.resize(640, 480)
        lay = QVBoxLayout(self)
        lay.addWidget(body(_("These tools do not change the disk.")))
        tabs = QTabWidget()
        lay.addWidget(tabs, 1)
        tabs.addTab(self._image_tab(tools), _("Disk image"))
        tabs.addTab(self._parts_tab(tools), _("Lost partitions"))
        tabs.addTab(self._carve_tab(tools), _("Search by content"))
        buttons = QDialogButtonBox(QDialogButtonBox.Close)
        buttons.rejected.connect(self.reject)
        lay.addWidget(buttons)

    def _missing(self, lay, text):
        lay.addWidget(HealthPill("attention", text))

    def _image_tab(self, tools):
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.addWidget(body(_("Copies the whole device to a file on another disk with GNU ddrescue, keeping a map so it can resume and never reads a good area twice. Then you work on the copy, and the disk rests. It asks for the administrator password.")))
        if not tools.get("ddrescue"):
            self._missing(lay, _("GNU ddrescue is not installed (package ddrescue). It makes the disk image."))
        row = QHBoxLayout()
        self.image_path = QLineEdit()
        self.image_path.setAccessibleName(_("Image file, on another disk:"))
        label = QLabel(_("Image file, on another disk:"))
        label.setBuddy(self.image_path)
        browse = button(_("&Browse…"), "folder-open")
        browse.clicked.connect(lambda: self._pick(self.image_path, True))
        row.addWidget(self.image_path, 1)
        row.addWidget(browse)
        lay.addWidget(label)
        lay.addLayout(row)
        start = button(_("&Make the image"), "document-save", primary=True)
        start.setEnabled(bool(tools.get("ddrescue")))
        start.clicked.connect(self._start_image)
        lay.addWidget(start, 0, Qt.AlignLeft)
        lay.addStretch(1)
        return page

    def _pick(self, edit, save):
        if save:
            path, _f = QFileDialog.getSaveFileName(self, _("Image file"), edit.text() or os.path.expanduser("~"))
        else:
            path, _f = QFileDialog.getOpenFileName(self, _("Image file"), edit.text() or os.path.expanduser("~"))
        if path:
            edit.setText(path)

    def _start_image(self):
        path = self.image_path.text().strip()
        if not path:
            return

        def done(data, code, _out, err):
            if data and data.get("id"):
                self.image_started.emit(data["id"])
                self.accept()
            else:
                QMessageBox.warning(self, _("Disk image"), err or str(code))
        self.engine.run(["image", "--source", self.dev["device"], "--image", path, "--no-wait"], done)

    def _parts_tab(self, tools):
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.addWidget(body(_("Looks for partitions with TestDisk and only lists what it finds. Nothing is written to the partition table. It asks for the administrator password.")))
        if not tools.get("testdisk"):
            self._missing(lay, _("TestDisk is not installed (package testdisk)."))
        output = QPlainTextEdit()
        output.setReadOnly(True)
        output.setAccessibleName(_("Lost partitions"))
        go = button(_("&Look for partitions"), "edit-find", primary=True)
        go.setEnabled(bool(tools.get("testdisk")))

        def run():
            go.setEnabled(False)
            output.setPlainText(_("Looking for partitions…"))

            def done(_d, _code, out, err):
                go.setEnabled(True)
                output.setPlainText(out or err)
            self.engine.run(["partitions", self.dev["device"]], done, json_output=False)
        go.clicked.connect(run)
        lay.addWidget(go, 0, Qt.AlignLeft)
        lay.addWidget(output, 1)
        return page

    def _carve_tab(self, tools):
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.addWidget(body(_("Searches an image for files by their content with PhotoRec. It finds files even without a filesystem, but their original names and folders cannot be kept.")))
        if not tools.get("photorec"):
            self._missing(lay, _("PhotoRec is not installed (package testdisk)."))
        src = QLineEdit()
        dst = QLineEdit()
        src_label = QLabel(_("Image file:"))
        src_label.setBuddy(src)
        dst_label = QLabel(_("Destination folder:"))
        dst_label.setBuddy(dst)
        grid = QGridLayout()
        browse = button(_("&Browse…"), "folder-open")
        browse.clicked.connect(lambda: self._pick(src, False))
        grid.addWidget(src_label, 0, 0)
        grid.addWidget(src, 0, 1)
        grid.addWidget(browse, 0, 2)
        grid.addWidget(dst_label, 1, 0)
        grid.addWidget(dst, 1, 1)
        browse2 = button(_("B&rowse…"), "folder-open")

        def pick_dir():
            path = QFileDialog.getExistingDirectory(self, _("Destination"), dst.text() or os.path.expanduser("~"))
            if path:
                dst.setText(path)
        browse2.clicked.connect(pick_dir)
        grid.addWidget(browse2, 1, 2)
        lay.addLayout(grid)
        state = body()
        go = button(_("&Search for files"), "edit-find", primary=True)
        go.setEnabled(bool(tools.get("photorec")))

        def run():
            if not src.text().strip() or not dst.text().strip():
                return
            go.setEnabled(False)
            state.setText(_("Searching. This reads the whole image and can take a long time."))

            def done(data, _code, _out, err):
                go.setEnabled(True)
                if data and data.get("ok"):
                    state.setText(_("%(n)s files found by content in %(dir)s. Their original names and folders could not be kept.") % {
                        "n": data.get("recovered"), "dir": data.get("destination")})
                else:
                    state.setText(err or _("The search failed."))
            self.engine.run(["carve", "--source", src.text().strip(), "--destination", dst.text().strip()], done)
        go.clicked.connect(run)
        lay.addWidget(go, 0, Qt.AlignLeft)
        lay.addWidget(state)
        lay.addStretch(1)
        return page


# ---------------------------------------------------------------------------
# The window


STYLE = """
QFrame#card { background: palette(base); border: 1px solid palette(mid); border-radius: 8px; }
QLabel[muted="true"] { color: palette(placeholder-text); }
QListWidget#devices { border: none; background: palette(window); outline: 0; }
QListWidget#devices::item { border-radius: 8px; margin: 3px 6px; }
QListWidget#devices::item:selected { background: SELECTION; border: 1px solid palette(highlight); }
QProgressBar { border-radius: 4px; }
"""


def setup_icons():
    """Qt alone may look nowhere but in its resources, and may not know the theme
    Plasma uses. Reads the choice of the user; Breeze when there is none."""
    paths = list(QIcon.themeSearchPaths())
    for root in (os.path.expanduser("~/.local/share/icons"), os.path.expanduser("~/.icons"), "/usr/share/icons"):
        if root not in paths and os.path.isdir(root):
            paths.append(root)
    QIcon.setThemeSearchPaths(paths)
    if QIcon.themeName():
        return
    theme = "breeze"
    try:
        with open(os.path.expanduser("~/.config/kdeglobals"), encoding="utf-8", errors="replace") as handle:
            section = ""
            for line in handle:
                line = line.strip()
                if line.startswith("["):
                    section = line
                elif section == "[Icons]" and line.startswith("Theme="):
                    theme = line[6:] or theme
    except OSError:
        pass
    QIcon.setThemeName(theme)
    QIcon.setFallbackThemeName("breeze")


def app_style(app):
    """A soft selection: the status colours on top must stay readable."""
    c = app.palette().color(QPalette.Highlight)
    return STYLE.replace("SELECTION", f"rgba({c.red()}, {c.green()}, {c.blue()}, 50)")


class MainWindow(QMainWindow):
    def __init__(self, select=None):
        super().__init__()
        self.setWindowTitle(_("Big-Mount — Storage manager"))
        self.setWindowIcon(theme_icon("big-mount", "drive-harddisk"))
        self.resize(1040, 700)
        self.engine = Engine(self)
        self.select = select
        self._listing = False
        self.smart_busy = False

        self.pages = QStackedWidget()
        self.devices = DeviceList()
        self.devices.selected.connect(self._device_selected)
        self.device_page = DevicePage(self.engine)
        self.device_page.action.connect(self._action)
        self.wizard = RescueWizard(self.engine)
        self.wizard.finished.connect(self.show_devices)
        self.wizard.job_started.connect(self.open_job)
        self.job_page = JobPage(self.engine)
        self.job_page.closed.connect(self.show_devices)
        self.jobs_page = JobsPage(self.engine)
        self.jobs_page.open_job.connect(self.open_job)
        self.empty = heading(_("No storage device was found."), 1.2)
        self.empty.setAlignment(Qt.AlignCenter)
        for w in (self.device_page, self.wizard, self.job_page, self.jobs_page, self.empty):
            self.pages.addWidget(w)

        left = QWidget()
        # A model name is one long word, and a label cannot wrap it
        left.setMinimumWidth(270)
        left_lay = QVBoxLayout(left)
        left_lay.setContentsMargins(0, 8, 0, 8)
        left_lay.addWidget(self.devices, 1)
        jobs_btn = button(_("Copies and &images"), "view-history")
        jobs_btn.clicked.connect(self.show_jobs)
        left_lay.addWidget(jobs_btn)
        self.jobs_btn = jobs_btn
        splitter = QSplitter()
        splitter.addWidget(left)
        splitter.addWidget(self.pages)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([320, 720])
        splitter.setChildrenCollapsible(False)
        self.setCentralWidget(splitter)

        refresh = QAction(self)
        refresh.setShortcut(QKeySequence.Refresh)
        refresh.triggered.connect(self.refresh)
        self.addAction(refresh)
        quit_action = QAction(self)
        quit_action.setShortcut(QKeySequence.Quit)
        quit_action.triggered.connect(self.close)
        self.addAction(quit_action)

        self.status = self.statusBar()
        self.notice = QLabel()
        self.notice.setTextFormat(Qt.PlainText)
        self.status.addWidget(self.notice, 1)

        # Connecting or removing a drive updates the list: udev tells us, no polling
        self.monitor = QProcess(self)
        self.monitor.readyReadStandardOutput.connect(self._udev_event)
        self.monitor.start("udevadm", ["monitor", "--udev", "--subsystem-match=block"])
        self.debounce = QTimer(self)
        self.debounce.setSingleShot(True)
        self.debounce.setInterval(700)
        self.debounce.timeout.connect(self.refresh)
        # Mounts change without udev events
        self.mounts = QTimer(self)
        self.mounts.setInterval(15000)
        self.mounts.timeout.connect(self.refresh)
        self.mounts.start()

        self.refresh()

    def closeEvent(self, event):
        self.monitor.kill()
        self.monitor.waitForFinished(500)
        if self.job_page.state in RUNNING_STATES:
            self.status.showMessage(_("The copy continues in the background."))
        event.accept()

    def _udev_event(self):
        self.monitor.readAllStandardOutput()
        self.debounce.start()

    # ----- list
    def refresh(self):
        if self._listing:
            return
        self._listing = True
        self.engine.run(["list"], self._listed)

    def _listed(self, data, code, _out, err):
        self._listing = False
        if data is None:
            self.notice.setText(err.strip() or _("The list of devices could not be read."))
            return
        devices = data.get("devices", [])
        if data.get("partial"):
            self.notice.setText(_("A mounted device did not answer in time, so free space is not shown."))
        else:
            self.notice.setText("")
        previous = self.devices.current_device_name()
        self.devices.set_devices(devices)
        if self.select and self.devices.select_device(self.select):
            self.select = None
        # The drive on the screen went away: say it, do not pretend
        if previous and not any(d.get("device") == previous for d in devices):
            self.notice.setText(_("The device was disconnected or replaced. Nothing was done."))
        if not devices:
            self.pages.setCurrentWidget(self.empty)
        elif self.pages.currentWidget() is self.empty:
            self.show_devices()

    def _device_selected(self, dev):
        self.device_page.show_device(dev)
        # Never pull the user out of an assistant or a copy because of a refresh
        if self.pages.currentWidget() in (self.empty,):
            self.pages.setCurrentWidget(self.device_page)

    def show_devices(self):
        self.pages.setCurrentWidget(self.device_page)
        self.refresh()

    def show_jobs(self):
        self.jobs_page.refresh()
        self.pages.setCurrentWidget(self.jobs_page)

    def open_job(self, job_id):
        self.job_page.show_job(job_id)
        self.pages.setCurrentWidget(self.job_page)

    # ----- actions on a drive
    def _action(self, verb, dev, vol):
        getattr(self, "_do_" + verb.replace("-", "_"))(dev, vol)

    def _do_open(self, _dev, vol):
        QDesktopServices.openUrl(QUrl.fromLocalFile(vol.get("mountpoint", "")))

    def _mount(self, dev, vol, then=None):
        dialog = MountDialog(dev, vol, self)
        if dialog.exec() != QDialog.Accepted:
            return
        args = ["mount", vol["device"], "--read-only"]
        if dialog.protect.isChecked():
            args.append("--protect")
        self._mount_run(args, dev, vol, then)

    def _mount_run(self, args, dev, vol, then):
        self.notice.setText(_("Mounting…"))

        def done(data, code, _out, err):
            self.notice.setText("")
            self.refresh()
            if data and data.get("ok"):
                if then:
                    then(data)
                return
            why = (data or {}).get("why")
            if why == "already-rw":
                box = QMessageBox(QMessageBox.Question, _("Mount read-only"), (data or {}).get("text", ""), parent=self)
                again = box.addButton(_("Unmount and mount read-only"), QMessageBox.AcceptRole)
                box.addButton(QMessageBox.Cancel)
                box.exec()
                if box.clickedButton() == again:
                    self._mount_run([*args, "--remount"], dev, vol, then)
                return
            box = QMessageBox(QMessageBox.Warning, _("Could not mount"), (data or {}).get("text") or err or str(code), parent=self)
            detail = (data or {}).get("detail")
            if detail:
                box.setDetailedText(detail)
            box.exec()
        self.engine.run(args, done)

    def _do_mount(self, dev, vol):
        self._mount(dev, vol)

    def _do_rescue(self, dev, vol):
        if vol.get("mountpoint"):
            self._open_wizard(vol["mountpoint"], dev)
            return
        self._mount(dev, vol, lambda data: self._open_wizard(data.get("mountpoint"), dev))

    def _open_wizard(self, mountpoint, dev):
        self.wizard.start(mountpoint, dev)
        self.pages.setCurrentWidget(self.wizard)

    def _do_unmount(self, _dev, vol):
        self.notice.setText(_("Unmounting…"))

        def done(data, code, _out, err):
            self.notice.setText("")
            self.refresh()
            if code == 0:
                self.notice.setText(_("Unmounted. Everything was written to the device."))
                return
            text = ""
            if data:
                text = "\n\n".join(x for x in (data.get("busy_summary"), data.get("busy_advice"), data.get("reason")) if x)
            QMessageBox.warning(self, _("Could not unmount"), text or err or str(code))
        self.engine.run(["unmount", vol["device"]], done)

    def _do_details(self, dev, _vol):
        def done(_d, _code, out, err):
            dialog = QDialog(self)
            dialog.setWindowTitle(_("Technical details"))
            dialog.resize(760, 520)
            lay = QVBoxLayout(dialog)
            text = QPlainTextEdit()
            text.setReadOnly(True)
            text.setPlainText(out or err)
            lay.addWidget(text)
            buttons = QDialogButtonBox(QDialogButtonBox.Close)
            buttons.rejected.connect(dialog.reject)
            lay.addWidget(buttons)
            dialog.exec()
        self.engine.run(["report", dev["device"]], done, json_output=False)

    def _do_smart(self, dev, _vol):
        if self.smart_busy:
            return
        self.smart_busy = True
        self.notice.setText(_("Reading SMART. Through USB it can take a minute."))

        def done(_d, _code, _out, err):
            self.smart_busy = False
            self.notice.setText(err.strip().splitlines()[-1] if err.strip() else "")
            self.device_page.diag = None
            self.refresh()
            self.device_page.show_device(dev)
        self.engine.run(["diagnose", dev["device"], "--smart"], done)

    def _do_advanced(self, dev, _vol):
        dialog = AdvancedDialog(self.engine, dev, self.device_page.tools, self)
        dialog.image_started.connect(self.open_job)
        dialog.exec()

    def _do_report(self, dev, _vol):
        path, _f = QFileDialog.getSaveFileName(self, _("Export report"), os.path.expanduser("~/big-mount-report.txt"))
        if not path:
            return
        box = QMessageBox(QMessageBox.Question, _("Export report"), _("Hide serial numbers, labels and your user name?"), parent=self)
        hide = box.addButton(_("Hide them"), QMessageBox.YesRole)
        box.addButton(_("Keep them"), QMessageBox.NoRole)
        box.setDefaultButton(hide)
        box.exec()
        args = ["report", dev["device"], "--output", path]
        if box.clickedButton() == hide:
            args.append("--anonymize")

        def done(_d, code, out, err):
            self.notice.setText(out.strip() or err.strip() or str(code))
        self.engine.run(args, done, json_output=False)

    def _do_check(self, dev, _vol):
        QProcess.startDetached(BIGMOUNT, ["--gui-drive-check", dev["device"]])

    def _do_unlock(self, _dev, vol):
        """The passphrase goes from this dialog to UDisks2 over D-Bus: never in
        arguments, files or logs."""
        name = vol.get("label") or vol.get("device")
        password, ok = QInputDialog.getText(self, _("Unlock"), _("Passphrase of %s:") % name, QLineEdit.Password)
        if not ok or not password:
            return
        node = vol["device"].rsplit("/", 1)[-1].replace("-", "_2d")
        path = "/org/freedesktop/UDisks2/block_devices/" + node
        message = QDBusMessage.createMethodCall("org.freedesktop.UDisks2", path, "org.freedesktop.UDisks2.Encrypted", "Unlock")
        message.setArguments([password, {}])
        pending = QDBusConnection.systemBus().asyncCall(message, 120000)
        del password, message
        watcher = QDBusPendingCallWatcher(pending, self)

        def done(call):
            reply = QDBusMessage(call.reply())
            call.deleteLater()
            if reply.type() == QDBusMessage.ErrorMessage:
                QMessageBox.warning(self, _("Unlock"), reply.errorMessage())
            self.refresh()
        watcher.finished.connect(done)


def main():
    if os.geteuid() == 0:
        print("bigmount: the graphical interface does not run as root", file=sys.stderr)
        return 5
    app = QApplication(sys.argv[:1])
    app.setApplicationName("big-mount")
    app.setDesktopFileName("big-mount")
    setup_icons()
    app.setStyleSheet(app_style(app))
    window = MainWindow(sys.argv[1] if len(sys.argv) > 1 else None)
    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
