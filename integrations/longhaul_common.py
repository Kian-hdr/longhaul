"""User-only Longhaul job messages. No conversation or media contents are copied."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import time
import uuid


def root_directory():
    return Path(os.environ.get("LONGHAUL_DATA_DIR", Path.home() / "Library/Application Support/Longhaul"))


def secure_directory(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("Unsafe Longhaul data directory")
    path.chmod(0o700)
    return path


def write_message(folder, key, payload):
    directory = secure_directory(root_directory() / folder)
    data = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
    if len(data) > 65536:
        raise ValueError("Longhaul message too large")
    name = hashlib.sha256(key.encode()).hexdigest() + ".json"
    descriptor, temporary = tempfile.mkstemp(prefix=".pending-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, directory / name)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)  # Only this writer's disposable incomplete message.


class JobPublisher:
    def __init__(self, source, title, checkpoint_capable=False):
        self.id = str(uuid.uuid4())
        self.source = source
        self.session = self.id
        self.payload = dict(version=1, id=self.id, source=source, title=title[:180],
                            phase="running", sequence=0, session=self.session, pid=os.getpid(),
                            checkpointCapable=checkpoint_capable)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.responded = set()
        self.update()
        self.thread = threading.Thread(target=self._heartbeat, daemon=True)
        self.thread.start()

    def update(self, **changes):
        with self.lock:
            self.payload.update(changes)
            self.payload["sequence"] += 1
            write_message("events", self.source + ":" + self.id, self.payload)

    def _heartbeat(self):
        while not self.stop.wait(15):
            try:
                self.update()
            except Exception as error:
                print("Longhaul heartbeat unavailable:", type(error).__name__)

    def finish(self, phase="completed"):
        self.stop.set()
        self.thread.join(timeout=2)
        self.update(phase=phase)

    def requests(self):
        directory = secure_directory(root_directory() / "requests")
        result = []
        for path in directory.glob("*.json"):
            try:
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 65536:
                    continue
                value = json.loads(path.read_text())
                deadline = datetime.datetime.fromisoformat(value["deadline"].replace("Z", "+00:00"))
                if value["id"] not in self.responded and value["jobID"] == self.id and value["source"] == self.source and value["session"] == self.session and deadline > datetime.datetime.now(datetime.timezone.utc):
                    result.append(value)
            except (ValueError, OSError, KeyError):
                continue
        return sorted(result, key=lambda item: item['deadline'], reverse=True)[:32]

    def acknowledge(self, request, paths, summary, success=True):
        payload = dict(requestID=request["id"], jobID=self.id, source=self.source,
                       session=self.session, savedPaths=[str(p) for p in paths],
                       summary=summary[:1800], success=success)
        write_message("receipts", request["id"], payload)
        self.responded.add(request["id"])
