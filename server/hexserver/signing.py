"""Refresh Hexplate's free Apple ID signing (7-day Personal Team profile) and reinstall on iPhone + Watch.

Free Apple ID provisioning profiles expire after 7 days, after which iOS/watchOS refuses to open the
app until Xcode re-signs and reinstalls it over the existing copy (preserving all app data). From
this Mac, we regenerate the Xcode project, locate the paired physical iPhone (and paired Apple Watch,
if present) with `devicectl`, build with `-allowProvisioningUpdates` under a monotonic `2.<epoch>`
build version, and install the signed `.app` bundles onto the phone and watch.
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
BUILD_MAJOR = "2"  # Keep in sync with CURRENT_PROJECT_VERSION in app/Config.xcconfig.
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


def _clean_error(text: str, device: str = "iPhone") -> str:
    """Short, single-line summary of an Xcode/devicectl failure without leaking device IDs."""
    low = text.lower()
    if "no accounts with app store connect" in low or "no profiles for" in low or "requires a provisioning profile" in low:
        if device == "Apple Watch" or "watchkitapp" in low or "hexplatewatch" in low:
            return "Xcode could not renew Apple Watch signing. Open Xcode › Settings › Accounts and sign in with your Apple ID."
        return "Xcode could not renew signing. Open Xcode › Settings › Accounts and sign in with your Apple ID."
    if "passcode" in low or "device is locked" in low or "unlock" in low:
        return f"{device} is locked. Unlock your {device} and try again."
    if "could not connect" in low or "unable to connect" in low or "timed out" in low or "not connected" in low or "unreachable" in low:
        if device == "Apple Watch":
            return "Could not reach your Apple Watch. Keep it unlocked on your wrist near your unlocked iPhone."
        return "Could not reach your iPhone. Keep it unlocked on the same Wi-Fi or connect it by USB."
    if "developer mode" in low:
        return f"Enable Developer Mode on your {device} (Settings › Privacy & Security › Developer Mode)."
    if "maximum number of apps" in low:
        return "Free Apple ID limit (3 sideloaded apps) reached on this iPhone. Remove another sideloaded app and try again."
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    picked = next((ln for ln in reversed(lines) if "error:" in ln.lower() or "failed" in ln.lower()), lines[-1] if lines else "")
    picked = re.sub(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b", "<device>", picked)
    picked = re.sub(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b", "<device>", picked)
    picked = re.sub(r"\b[0-9A-Fa-f]{40}\b", "<device>", picked)
    return (picked[:240] + "…") if len(picked) > 240 else (picked or "Xcode signing refresh failed.")


def profile_expiry(app_path: Path) -> float | None:
    """Reads ExpirationDate from embedded.mobileprovision inside a built .app/.appex bundle."""
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


def all_profile_expiry(app_path: Path) -> float | None:
    """Earliest ExpirationDate across a built .app and all embedded Watch / .appex bundles."""
    expiries = [e for p in app_path.rglob("embedded.mobileprovision") if (e := profile_expiry(p.parent)) is not None]
    return min(expiries) if expiries else None


def _pick_physical(devices: list[dict], *, platform: str, device_type: str, default_name: str) -> dict | None:
    candidates = []
    for d in devices:
        hp = d.get("hardwareProperties") or {}
        cp = d.get("connectionProperties") or {}
        dp = d.get("deviceProperties") or {}
        if hp.get("reality") != "physical" or hp.get("platform") != platform or hp.get("deviceType") != device_type:
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
            "name": dp.get("name") or default_name,
            "transport": cp.get("transportType") or "",
        }))
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


def pick_iphone(devices: list[dict]) -> dict | None:
    """Picks the best paired physical iPhone from `devicectl list devices` JSON output."""
    return _pick_physical(devices, platform="iOS", device_type="iPhone", default_name="iPhone")


def pick_watch(devices: list[dict]) -> dict | None:
    """Picks the best paired physical Apple Watch from `devicectl list devices` JSON output."""
    return _pick_physical(devices, platform="watchOS", device_type="appleWatch", default_name="Apple Watch")


class Signing:
    def __init__(
        self,
        store,
        app_dir: Path | None = None,
        derived_dir: Path | None = None,
        runner=subprocess.run,
        platform: str | None = None,
        which=shutil.which,
    ):
        self.store = store
        self.app_dir = Path(app_dir or APP_DIR)
        self.derived_dir = Path(derived_dir or (store.folder / "signing-build"))
        self._run = runner
        self._which = which
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

    def _find_devices(self) -> tuple[dict, dict | None]:
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
        devices = data.get("result", {}).get("devices", [])
        dev = pick_iphone(devices)
        if not dev:
            raise RuntimeError("No paired iPhone found. Connect your iPhone to this Mac by USB or Wi-Fi and unlock it.")
        return dev, pick_watch(devices)

    def _ensure_project(self) -> Path:
        if not (self.app_dir / "Local.xcconfig").is_file():
            raise RuntimeError("app/Local.xcconfig is missing. Add DEVELOPMENT_TEAM = <TEAM_ID> first.")
        proj = self.app_dir / "Hexplate.xcodeproj"
        xcodegen = self._which("xcodegen", path=SAFE_PATH)
        if xcodegen:
            res = self._run([xcodegen], cwd=str(self.app_dir), capture_output=True, text=True, timeout=60, env=_env())
            if res.returncode != 0 or not proj.is_dir():
                raise RuntimeError(_clean_error((res.stderr or "") + "\n" + (res.stdout or "")))
            return proj
        if proj.is_dir():
            return proj
        raise RuntimeError("Hexplate.xcodeproj is missing and xcodegen was not found.")

    def refresh_sync(self) -> tuple[bool, str]:
        """Runs the full signing refresh synchronously (used by the worker thread and tests)."""
        if not self.available:
            with self._lock:
                self._running = False
                self._stage = ""
            return False, UNAVAILABLE_MSG
        try:
            now = time.time()
            build_ver = f"CURRENT_PROJECT_VERSION={BUILD_MAJOR}.{int(now)}"
            self._set_stage("Checking iPhone…")
            proj = self._ensure_project()
            dev, watch = self._find_devices()
            self.derived_dir.mkdir(parents=True, exist_ok=True)

            watch_skip: str | None = None
            if watch is not None:
                self._set_stage("Provisioning Apple Watch…")
                try:
                    wbuild = self._run(
                        [
                            "/usr/bin/xcodebuild",
                            "-project", str(proj),
                            "-scheme", "HexplateWatch",
                            "-configuration", "Debug",
                            "-destination", f"id={watch['udid']}",
                            "-destination-timeout", "30",
                            "-derivedDataPath", str(self.derived_dir),
                            "-allowProvisioningUpdates",
                            build_ver,
                            "build",
                        ],
                        cwd=str(self.app_dir), capture_output=True, text=True, timeout=300, env=_env(),
                    )
                    if wbuild.returncode != 0:
                        watch_skip = _clean_error((wbuild.stderr or "") + "\n" + (wbuild.stdout or ""), device="Apple Watch")
                except subprocess.TimeoutExpired:
                    watch_skip = _clean_error("timed out", device="Apple Watch")
                except OSError as e:
                    watch_skip = _clean_error(str(e), device="Apple Watch")

            self._set_stage("Building and renewing Apple ID signing…")
            build = self._run(
                [
                    "/usr/bin/xcodebuild",
                    "-project", str(proj),
                    "-scheme", "Hexplate",
                    "-configuration", "Debug",
                    "-destination", f"id={dev['udid']}",
                    "-derivedDataPath", str(self.derived_dir),
                    "-allowProvisioningUpdates",
                    build_ver,
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

            if watch is not None and watch_skip is None:
                self._set_stage("Installing on Apple Watch…")
                watch_app = self.derived_dir / "Build/Products/Debug-watchos/HexplateWatch.app"
                if not watch_app.is_dir():
                    watch_skip = "Build finished but HexplateWatch.app was not found."
                else:
                    try:
                        winst = self._run(
                            [
                                "/usr/bin/xcrun", "devicectl", "device", "install", "app",
                                "--device", watch["core_id"],
                                str(watch_app),
                            ],
                            capture_output=True, text=True, timeout=600, env=_env(),
                        )
                        if winst.returncode != 0:
                            watch_skip = _clean_error((winst.stderr or "") + "\n" + (winst.stdout or ""), device="Apple Watch")
                    except subprocess.TimeoutExpired:
                        watch_skip = _clean_error("timed out", device="Apple Watch")
                    except OSError as e:
                        watch_skip = _clean_error(str(e), device="Apple Watch")

            exp = all_profile_expiry(app_path) or (now + SEVEN_DAYS)
            if watch is None:
                device_summary = dev["name"]
                err_summary = None
            elif watch_skip is None:
                device_summary = f"{dev['name']} + {watch['name']}"
                err_summary = None
            else:
                device_summary = f"{dev['name']} (Watch skipped)"
                err_summary = f"iPhone refreshed; Watch skipped: {watch_skip}"
            self.record_result(at=now, expires=exp, device=device_summary, error=err_summary)
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
