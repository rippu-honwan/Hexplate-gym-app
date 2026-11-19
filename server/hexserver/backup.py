"""A second copy of everything, in iCloud Drive (or HEXPLATE_BACKUP), so a dead Mac loses nothing.

- The database (every version the phone sent, the webhooks) is copied with SQLite's own backup a
  minute after the phone stops syncing: one file a day, `hexplate-YYYY-MM-DD.sqlite3`, the latest
  KEEP days kept.
- Each Watch motion file is copied the moment it arrives, before the server answers the phone:
  the phone deletes its copy only when both the server and the backup hold it (`can_delete`).

Writes go to a `.part` file renamed into place, so iCloud never uploads half a file.
"""
import datetime as dt
import os
import shutil
import sqlite3
import threading
import time
from pathlib import Path

ICLOUD = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs"
KEEP = 30
QUIET_SECONDS = 60


class Backup:
    def __init__(self, store, folder: Path | None = None):
        self.store = store
        env = os.environ.get("HEXPLATE_BACKUP")
        self.folder = Path(folder or env or ICLOUD / "Hexplate Backup")
        self.in_icloud = not (folder or env)
        self._timer = None
        self._lock = threading.Lock()

    @property
    def on(self) -> bool:
        return self.store.setting("backup", "on") != "off"

    def _ready(self):
        if self.in_icloud and not ICLOUD.is_dir():
            raise OSError("iCloud Drive is off on this Mac (System Settings › Apple Account › iCloud › iCloud Drive).")
        (self.folder / "motion").mkdir(parents=True, exist_ok=True)

    def _result(self, error=None):
        self.store.set_setting("backup_error", error)
        if not error:
            self.store.set_setting("backup_at", time.time())

    @staticmethod
    def _explain(e: Exception) -> str:
        if isinstance(e, PermissionError):
            return "No permission to write to the backup folder. Give the server's Python Full Disk Access, or set HEXPLATE_BACKUP to another folder."
        return str(e)

    # MARK: motion files

    def motion(self, name: str) -> bool:
        """Copies one motion file; True when the backup holds it, same size as the server's."""
        src = self.store.motion_dir / name
        try:
            self._ready()
            dst = self.folder / "motion" / name
            part = dst.with_name(dst.name + ".part")
            shutil.copyfile(src, part)
            part.replace(dst)
            ok = dst.stat().st_size == src.stat().st_size
            self._result(None if ok else "A motion file came out the wrong size in the backup.")
            return ok
        except OSError as e:
            self._result(self._explain(e))
            return False

    def can_delete(self, name: str) -> bool:
        """The phone may delete its copy: the backup holds it, or you switched the backup off."""
        return self.motion(name) if self.on else True

    # MARK: the database

    def soon(self):
        """After a sync: one copy once the phone has been quiet for a minute (a burst of syncs is one copy)."""
        if not self.on:
            return
        with self._lock:
            if self._timer:
                self._timer.cancel()
            self._timer = threading.Timer(QUIET_SECONDS, self.database)
            self._timer.daemon = True
            self._timer.start()

    def database(self) -> bool:
        try:
            self._ready()
            dst = self.folder / f"hexplate-{dt.date.today()}.sqlite3"
            part = dst.with_name(dst.name + ".part")
            part.unlink(missing_ok=True)
            # Its own connections: this runs on a timer thread, and SQLite's backup reads a
            # consistent copy while the server keeps writing.
            src, out = sqlite3.connect(self.store.folder / "hexplate.sqlite3"), sqlite3.connect(part)
            try:
                src.backup(out)
                out.execute("PRAGMA journal_mode=DELETE")   # one self-contained file, readable as it is
            finally:
                out.close()
                src.close()
                for extra in ("-wal", "-shm"):   # left by the source's WAL header before the switch
                    part.with_name(part.name + extra).unlink(missing_ok=True)
            part.replace(dst)
            for old in sorted(self.folder.glob("hexplate-*.sqlite3"))[:-KEEP]:
                old.unlink()
            self._result()
            return True
        except (OSError, sqlite3.Error) as e:
            self._result(self._explain(e))
            return False

    def everything(self) -> tuple[int, bool]:
        """Back up now: the database, and every motion file the backup lacks. (files copied, all ok)"""
        ok = self.database()
        copied = 0
        if ok:
            have = {p.name for p in (self.folder / "motion").glob("*.csv")}
            for f in sorted(self.store.motion_dir.glob("*.csv")):
                if f.name not in have:
                    if not self.motion(f.name):
                        return copied, False
                    copied += 1
        return copied, ok

    def status(self):
        files = sorted(self.folder.glob("hexplate-*.sqlite3")) if self.folder.is_dir() else []
        motion = len(list((self.folder / "motion").glob("*.csv"))) if (self.folder / "motion").is_dir() else 0
        at = self.store.setting("backup_at")
        return {"on": self.on, "folder": str(self.folder), "in_icloud": self.in_icloud, "copies": len(files), "motion": motion,
                "at": float(at) if at else None, "error": self.store.setting("backup_error")}
