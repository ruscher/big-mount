"""Connecting or removing a drive updates the list: udev and the mount table tell
us, so nothing polls. Many events become one refresh."""

import signal

import gi
from gi.repository import Gio, GLib, GObject

try:
    gi.require_version("GioUnix", "2.0")
    from gi.repository import GioUnix
except (ImportError, ValueError):  # older GLib: it is still in Gio
    GioUnix = None

DEBOUNCE_MS = 700


class DeviceMonitor(GObject.Object):
    __gsignals__ = {"changed": (GObject.SignalFlags.RUN_LAST, None, ())}

    def __init__(self):
        super().__init__()
        self._timer = 0
        self._proc = None
        self._stream = None
        self._mounts = None
        self._mounts_handler = 0
        self._cancel = Gio.Cancellable()
        self._start_udev()
        self._start_mounts()

    def _start_udev(self):
        try:
            self._proc = Gio.Subprocess.new(["udevadm", "monitor", "--udev", "--subsystem-match=block"],
                                            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error:
            return
        self._stream = Gio.DataInputStream.new(self._proc.get_stdout_pipe())
        self._read_line()

    def _read_line(self):
        self._stream.read_line_async(GLib.PRIORITY_LOW, self._cancel, self._got_line)

    def _got_line(self, stream, res):
        try:
            line, _length = stream.read_line_finish(res)
        except GLib.Error:
            return
        if line is None:
            return
        # An event is "UDEV  [time] action path (block)"; the header lines it
        # prints first are not
        if line.startswith(b"UDEV  ["):
            self.poke()
        self._read_line()

    def _start_mounts(self):
        try:
            cls = GioUnix.MountMonitor if GioUnix else Gio.UnixMountMonitor
            self._mounts = cls.get()
            self._mounts_handler = self._mounts.connect("mounts-changed", lambda *_a: self.poke())
        except (AttributeError, TypeError):
            self._mounts = None

    def poke(self):
        if self._timer:
            GLib.source_remove(self._timer)
        self._timer = GLib.timeout_add(DEBOUNCE_MS, self._fire)

    def _fire(self):
        self._timer = 0
        self.emit("changed")
        return False

    def stop(self):
        """The mount monitor is one object for the whole process: its handler goes
        with this monitor, as does udevadm."""
        self._cancel.cancel()
        if self._mounts_handler:
            self._mounts.disconnect(self._mounts_handler)
            self._mounts_handler = 0
        if self._proc:
            self._proc.send_signal(signal.SIGTERM)
            self._proc = None
        if self._timer:
            GLib.source_remove(self._timer)
            self._timer = 0
        if self._proc:
            self._proc.force_exit()
            self._proc = None
