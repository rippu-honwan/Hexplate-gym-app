"""Refresh Hexplate's free Apple ID signing (7-day Personal Team profile) and reinstall on iPhone.

Free Apple ID provisioning profiles expire after 7 days, after which iOS refuses to open the app
until Xcode re-signs and reinstalls it over the existing copy (preserving all app data). From this
Mac, we locate the paired physical iPhone with `devicectl`, build with `-allowProvisioningUpdates`,
and install the signed `.app` back onto the phone.
"""
import datetime as dt
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

APP_DIR = Path(__file__).resolve().parents[2] / "app"
SEVEN_DAYS = 7 * 86400
SAFE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
UNAVAILABLE_MSG = "Apple ID signing requires macOS with Xcode. Run signing refresh on your Mac."


def _env() -> dict[str, str]:
    env = dict(os.environ)
    cur = env.get("PATH", "")
    parts = [p for p in (cur.split(":") if cur else []) if p]
    for p in SAFE_PATH.split(":"):
        if p not in parts:
            parts.append(p)
    env["PATH"] = ":".join(parts)
    return env


def _clean_error(text: str) -> str:
    """Short, single-line summary of an Xcode/devicectl failure without leaking device IDs."""
    low = text.lower()
    if "no accounts with app store connect" in low or "no profiles for" in low or "requires a provisioning profile" in low:
        return "Xcode could not renew signing. Open Xcode › Settings › Accounts and sign in with your Apple ID."
    if "passcode" in low or "device is locked" in low or "unlock" in low:
        return "iPhone is locked. Unlock your iPhone and try again."
    if "could not connect" in low or "unable to connect" in low or "timed out" in low or "not connected" in low or "unreachable" in low:
        return "Could not reach your iPhone. Keep it unlocked on the same Wi-Fi or connect it by USB."
    if "developer mode" in low:
        return "Enable Developer Mode on your iPhone (Settings › Privacy & Security › Developer Mode)."
    if "maximum number of apps" in low:
        return "Free Apple ID limit (3 sideloaded apps) reached on this iPhone. Remove another sideloaded app and try again."
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    picked = next((ln for ln in reversed(lines) if "error:" in ln.lower() or "failed" in ln.lower()), lines[-1] if lines else "")
    picked = re.sub(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b", "<device>", picked)
    picked = re.sub(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b", "<device>", picked)
    picked = re.sub(r"\b[0-9A-Fa-f]{40}\b", "<device>", picked)
    return (picked[:240] + "…") if len(picked) > 240 else (picked or "Xcode signing refresh failed.")


def profile_expiry(app_path: Path) -> float | None:
    """Reads ExpirationDate from embedded.mobileprovision inside a built .app bundle."""
    prof = app_path / "embedded.mobileprovision"
    if not prof.is_file():
        return None
    try:
        raw = prof.read_bytes()
        a, b = raw.find(b"<?xml"), raw.find(b"</plist>")
        if a < 0 or b < 0:
            return None
        pl = plistlib.loads(raw[a : b + len(b"</plist>")])
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    exp = pl.get("ExpirationDate")
    if isinstance(exp, dt.datetime):
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=dt.timezone.utc)
        return exp.timestamp()
    return None


def pick_iphone(devices: list[dict]) -> dict | None:
    """Picks the best paired physical iPhone from `devicectl list devices` JSON output."""
    candidates = []
    for d in devices:
        hp = d.get("hardwareProperties") or {}
        cp = d.get("connectionProperties") or {}
        dp = d.get("deviceProperties") or {}
        if hp.get("reality") != "physical" or hp.get("platform") != "iOS" or hp.get("deviceType") != "iPhone":
            continue
        if cp.get("pairingState") != "paired":
            continue
        udid = hp.get("udid")
        core_id = d.get("identifier") or udid
        if not udid or not core_id:
            continue
        score = (
            1 if cp.get("tunnelState") == "connected" else 0,
            1 if cp.get("transportType") == "wired" else 0,
            1 if dp.get("developerModeStatus") == "enabled" else 0,
            str(cp.get("lastConnectionDate") or ""),
        )
        candidates.append((score, {
            "udid": udid,
            "core_id": core_id,
            "name": dp.get("name") or "iPhone",
            "transport": cp.get("transportType") or "",
        }))
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


class Signing:
    def __init__(
        self,
        store,
        app_dir: Path | None = None,
        derived_dir: Path | None = None,
        runner=subprocess.run,
        platform: str | None = None,
    ):
        self.store = store
        self.app_dir = Path(app_dir or APP_DIR)
        self.derived_dir = Path(derived_dir or (store.folder / "signing-build"))
        self._run = runner
        self.platform = platform or sys.platform
        self._lock = threading.Lock()
        self._running = False
        self._stage = ""

    @property
    def available(self) -> bool:
        return self.platform == "darwin"

    def record_result(
        self,
        *,
        at: float | None = None,
        expires: float | None = None,
        device: str | None = None,
        error: str | None = None,
    ) -> dict:
        if at is not None:
            self.store.set_setting("signing_at", at)
        if expires is not None:
            self.store.set_setting("signing_expires", expires)
        if device is not None:
            self.store.set_setting("signing_device", device)
        self.store.set_setting("signing_error", error)
        return self.status()

    def _set_stage(self, stage: str):
        with self._lock:
            self._stage = stage

    def _find_iphone(self) -> dict:
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tf:
            out_path = Path(tf.name)
        try:
            res = self._run(
                ["/usr/bin/xcrun", "devicectl", "list", "devices", "--json-output", str(out_path)],
                capture_output=True, text=True, timeout=20, env=_env(),
            )
            if res.returncode != 0:
                raise RuntimeError(_clean_error((res.stderr or "") + "\n" + (res.stdout or "")))
            data = json.loads(out_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, subprocess.TimeoutExpired) as e:
            raise RuntimeError(f"Could not list connected devices: {e}") from e
        finally:
            out_path.unlink(missing_ok=True)
        dev = pick_iphone(data.get("result", {}).get("devices", []))
        if not dev:
            raise RuntimeError("No paired iPhone found. Connect your iPhone to this Mac by USB or Wi-Fi and unlock it.")
        return dev

    def _ensure_project(self) -> Path:
        if not (self.app_dir / "Local.xcconfig").is_file():
            raise RuntimeError("app/Local.xcconfig is missing. Add DEVELOPMENT_TEAM = <TEAM_ID> first.")
        proj = self.app_dir / "Hexplate.xcodeproj"
        if proj.is_dir():
            return proj
        xcodegen = shutil.which("xcodegen", path=SAFE_PATH)
        if not xcodegen:
            raise RuntimeError("Hexplate.xcodeproj is missing and xcodegen was not found.")
        res = self._run([xcodegen], cwd=str(self.app_dir), capture_output=True, text=True, timeout=60, env=_env())
        if res.returncode != 0 or not proj.is_dir():
            raise RuntimeError(_clean_error((res.stderr or "") + "\n" + (res.stdout or "")))
        return proj

    def refresh_sync(self) -> tuple[bool, str]:
        """Runs the full signing refresh synchronously (used by the worker thread and tests)."""
        if not self.available:
            with self._lock:
                self._running = False
                self._stage = ""
            return False, UNAVAILABLE_MSG
        try:
            self._set_stage("Checking iPhone…")
            proj = self._ensure_project()
            dev = self._find_iphone()

            self._set_stage("Building and renewing Apple ID signing…")
            self.derived_dir.mkdir(parents=True, exist_ok=True)
            build = self._run(
                [
                    "/usr/bin/xcodebuild",
                    "-project", str(proj),
                    "-scheme", "Hexplate",
                    "-configuration", "Debug",
                    "-destination", f"id={dev['udid']}",
                    "-derivedDataPath", str(self.derived_dir),
                    "-allowProvisioningUpdates",
                    "build",
                ],
                cwd=str(self.app_dir), capture_output=True, text=True, timeout=600, env=_env(),
            )
            if build.returncode != 0:
                raise RuntimeError(_clean_error((build.stderr or "") + "\n" + (build.stdout or "")))

            app_path = self.derived_dir / "Build/Products/Debug-iphoneos/Hexplate.app"
            if not app_path.is_dir():
                raise RuntimeError("Build finished but Hexplate.app was not found.")

            self._set_stage("Installing on iPhone…")
            inst = self._run(
                [
                    "/usr/bin/xcrun", "devicectl", "device", "install", "app",
                    "--device", dev["core_id"],
                    str(app_path),
                ],
                capture_output=True, text=True, timeout=180, env=_env(),
            )
            if inst.returncode != 0:
                raise RuntimeError(_clean_error((inst.stderr or "") + "\n" + (inst.stdout or "")))

            now = time.time()
            exp = profile_expiry(app_path) or (now + SEVEN_DAYS)
            self.record_result(at=now, expires=exp, device=dev["name"], error=None)
            return True, ""
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as e:
            msg = str(e) if isinstance(e, RuntimeError) else _clean_error(str(e))
            self.store.set_setting("signing_error", msg)
            return False, msg
        finally:
            with self._lock:
                self._running = False
                self._stage = ""

    def start(self) -> bool:
        """Starts a background refresh; returns False if unavailable or already running."""
        if not self.available:
            return False
        with self._lock:
            if self._running:
                return False
            self._running = True
            self._stage = "Checking iPhone…"
        self.store.set_setting("signing_error", None)
        t = threading.Thread(target=self.refresh_sync, daemon=True)
        t.start()
        return True

    def status(self) -> dict:
        with self._lock:
            running, stage = self._running, self._stage
        at = self.store.setting("signing_at")
        exp = self.store.setting("signing_expires")
        return {
            "available": self.available,
            "running": running,
            "stage": stage,
            "at": float(at) if at else None,
            "expires": float(exp) if exp else None,
            "device": self.store.setting("signing_device"),
            "error": self.store.setting("signing_error"),
        }
