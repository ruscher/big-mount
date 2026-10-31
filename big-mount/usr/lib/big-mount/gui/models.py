"""What the engine says, as typed objects. Nothing here decides anything about a
disk: every value comes from `bigmount --drive ... --json`."""

from dataclasses import dataclass, field
from enum import Enum

from .common import _


class UiState(str, Enum):
    """The state of anything on screen. The same words everywhere."""

    IDLE = "idle"
    LOADING = "loading"
    READY = "ready"
    ATTENTION = "attention"
    ERROR = "error"
    RUNNING = "running"
    PAUSED = "paused"
    CANCELLED = "cancelled"
    PARTIAL = "partial"
    COMPLETED = "completed"
    DEVICE_DISCONNECTED = "device-disconnected"
    AUTHORIZATION_REQUIRED = "authorization-required"


RUNNING_STATES = {"pending", "analyzing", "running", "verifying", "stopping"}
RESUMABLE_STATES = {"paused", "interrupted", "cancelled", "needs-attention"}

# What a result means. A list of what exists, candidates rebuilt from content and
# copied files must never be called the same thing.
RESULT_EXISTING = "existing-files"
RESULT_CARVED = "carved-candidates"
RESULT_COPIED = "copied-files"
RESULT_IMAGE = "disk-image"

SYMBOLIC_ICONS = {
    "nvme": "drive-harddisk-solidstate-symbolic",
    "ssd": "drive-harddisk-solidstate-symbolic",
    "hdd": "drive-harddisk-symbolic",
    "usb": "drive-removable-media-symbolic",
    "sd": "media-flash-symbolic",
    "emmc": "media-flash-symbolic",
    "optical": "drive-optical-symbolic",
    "image": "application-x-firmware-symbolic",
}

LEVEL_ICONS = {
    "critical": "dialog-error-symbolic",
    "attention": "dialog-warning-symbolic",
    "normal": "object-select-symbolic",
    "unknown": "dialog-question-symbolic",
    "na": "dialog-information-symbolic",
}

RISKY_LEVELS = {"critical", "attention"}


@dataclass
class Health:
    level: str = "unknown"
    label: str = ""
    basis: str = "none"
    reasons: list = field(default_factory=list)
    smart: dict = field(default_factory=dict)

    @classmethod
    def from_json(cls, d):
        d = d or {}
        return cls(d.get("level", "unknown"), d.get("label", ""), d.get("basis", "none"),
                   list(d.get("reasons") or []), dict(d.get("smart") or {}))

    @property
    def risky(self):
        return self.level in RISKY_LEVELS


@dataclass
class Volume:
    device: str
    type: str = "part"
    fstype: str = ""
    fsver: str = ""
    label: str = ""
    uuid: str = ""
    state: str = ""
    state_label: str = ""
    mountpoint: str = ""
    size: int | None = None
    used: int | None = None
    avail: int | None = None
    read_only: bool = False
    device_read_only: bool = False
    fs_supported: bool = False
    multi_device: bool = False

    @classmethod
    def from_json(cls, d):
        known = {k: d[k] for k in cls.__dataclass_fields__ if k in d}
        return cls(**known)

    @property
    def title(self):
        return self.label or self.device.rsplit("/", 1)[-1]

    @property
    def mounted(self):
        return self.state in ("mounted-rw", "mounted-ro", "system")

    @property
    def can_hold_files(self):
        return self.mounted or (self.state == "unmounted" and self.fs_supported)


@dataclass
class Device:
    device: str
    name: str = ""
    kind: str = "unknown"
    kind_label: str = ""
    icon: str = ""
    model: str = ""
    vendor: str = ""
    serial: str = ""
    transport: str = ""
    transport_label: str = ""
    stable_id: str = ""
    pttype: str = ""
    size: int | None = None
    diskseq: int | None = None
    removable: bool = False
    hotplug: bool = False
    rotational: bool = False
    trim: bool = False
    volumes: list = field(default_factory=list)
    health: Health = field(default_factory=Health)

    @classmethod
    def from_json(cls, d):
        known = {k: d[k] for k in cls.__dataclass_fields__ if k in d and k not in ("volumes", "health")}
        dev = cls(**known)
        dev.volumes = [Volume.from_json(v) for v in d.get("volumes") or []]
        dev.health = Health.from_json(d.get("health"))
        if not dev.stable_id:
            dev.stable_id = f"device:{dev.device}"
        return dev

    @property
    def symbolic_icon(self):
        return SYMBOLIC_ICONS.get(self.kind, "drive-harddisk-symbolic")

    @property
    def content_volumes(self):
        """What a person calls its volumes: not the bare disk when it only holds others."""
        return [v for v in self.volumes if not (v.device == self.device and not v.fstype)]

    @property
    def space(self):
        """Used and free over its mounted volumes. None when no volume reports it."""
        used = avail = 0
        known = False
        for v in self.content_volumes:
            if v.used is not None and v.avail is not None:
                used += v.used
                avail += v.avail
                known = True
        return (used, avail) if known else None

    @property
    def has_system(self):
        return any(v.state == "system" for v in self.volumes)

    @property
    def subtitle(self):
        from .common import human_size
        parts = [self.kind_label, human_size(self.size)]
        return " · ".join(p for p in parts if p)


@dataclass
class Job:
    id: str
    kind: str = "copy"
    result_kind: str = ""
    state: str = ""
    state_label: str = ""
    reason: str = ""
    reason_text: str = ""
    source: str = ""
    destination: str = ""
    name: str = ""
    current: str = ""
    verify: str = ""
    verify_result: str = ""
    dir: str = ""
    categories: str = ""
    then_carve: str = ""
    copy_to: str = ""
    map: str = ""
    level: str = ""
    files_done: int = 0
    files_total: int = 0
    bytes_done: int = 0
    bytes_total: int = 0
    rate_now: int = 0
    rate_avg: int = 0
    elapsed: int = 0
    eta: int | None = None
    deferred: int = 0
    failed: int = 0
    differ: int = 0
    conflicts: int = 0
    read_errors: int = 0
    stuck: int = 0
    created: int = 0
    finished: int | None = None
    scanned: int = 0
    pass_: int = 0
    bad_bytes: int = 0
    total_estimate: bool = False
    pausable: bool = False

    @classmethod
    def from_json(cls, d):
        known = {k: v for k, v in d.items() if k in cls.__dataclass_fields__}
        job = cls(**known)
        job.pass_ = d.get("pass", 0) or 0
        return job

    @property
    def running(self):
        return self.state in RUNNING_STATES

    @property
    def can_resume(self):
        if self.kind in ("scan", "carve"):
            return self.state in ("interrupted", "cancelled")
        return self.state in RESUMABLE_STATES

    @property
    def has_results(self):
        return self.kind in ("scan", "carve") and not self.running

    @property
    def ui_state(self):
        if self.running:
            return UiState.RUNNING
        return {
            "paused": UiState.PAUSED,
            "cancelled": UiState.CANCELLED,
            "completed": UiState.COMPLETED,
            "failed": UiState.ERROR,
            "needs-attention": UiState.PARTIAL,
            "interrupted": UiState.PARTIAL,
        }.get(self.state, UiState.IDLE)

    @property
    def icon(self):
        return {
            UiState.RUNNING: "media-playback-start-symbolic",
            UiState.PAUSED: "media-playback-pause-symbolic",
            UiState.CANCELLED: "process-stop-symbolic",
            UiState.COMPLETED: "object-select-symbolic",
            UiState.ERROR: "dialog-error-symbolic",
            UiState.PARTIAL: "dialog-warning-symbolic",
        }.get(self.ui_state, "folder-symbolic")

    @property
    def kind_label(self):
        return {
            "copy": _("Copy of files"),
            "image": _("Disk image"),
            "scan": _("List of files"),
            "carve": _("Search by content"),
        }.get(self.kind, self.kind)

    @property
    def count_label(self):
        """What files_done counts. Never 'recovered' for what was only found."""
        return {
            "copy": _("Files copied"),
            "scan": _("Files listed"),
            "carve": _("Candidates found"),
        }.get(self.kind, _("Files"))


@dataclass
class Method:
    id: str
    available: bool = False
    why: str = ""
    why_text: str = ""
    finds: str = ""
    password: bool = False

    @classmethod
    def from_json(cls, d):
        return cls(**{k: d[k] for k in cls.__dataclass_fields__ if k in d})


@dataclass
class Methods:
    target: str = ""
    source_kind: str = ""
    device: str = ""
    volume: str = ""
    disk: str = ""
    level: str = ""
    state: str = ""
    mountpoint: str = ""
    fstype: str = ""
    recommended: str = ""
    recommended_why: str = ""
    size: int | None = None
    trim: bool = False
    can_read: bool = False
    deep_needs_image: bool = False
    methods: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    categories: list = field(default_factory=list)

    @classmethod
    def from_json(cls, d):
        known = {k: d[k] for k in cls.__dataclass_fields__ if k in d and k != "methods"}
        m = cls(**known)
        m.methods = [Method.from_json(x) for x in d.get("methods") or []]
        return m

    def get(self, method_id):
        return next((m for m in self.methods if m.id == method_id), None)


def find_device(devices, stable_id=None, name=None):
    for d in devices:
        if stable_id and d.stable_id == stable_id:
            return d
        if name and d.device == name:
            return d
    return None
