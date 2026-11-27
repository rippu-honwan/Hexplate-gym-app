import datetime as dt
import json
import plistlib
import subprocess
from pathlib import Path
from types import SimpleNamespace

from hexserver.signing import Signing, _clean_error, all_profile_expiry, pick_iphone, pick_watch, profile_expiry


def test_pick_iphone_and_watch_filter_and_prioritize():
    devices = [
        {"identifier": "sim-1", "hardwareProperties": {"reality": "simulated", "platform": "iOS", "deviceType": "iPhone", "udid": "U-SIM"},
         "connectionProperties": {"pairingState": "paired", "transportType": "sameMachine", "tunnelState": "connected"}, "deviceProperties": {"name": "Sim"}},
        {"identifier": "watch-sim", "hardwareProperties": {"reality": "simulated", "platform": "watchOS", "deviceType": "appleWatch", "udid": "U-WSIM"},
         "connectionProperties": {"pairingState": "paired", "transportType": "sameMachine", "tunnelState": "connected"}, "deviceProperties": {"name": "Sim Watch"}},
        {"identifier": "watch-disc", "hardwareProperties": {"reality": "physical", "platform": "watchOS", "deviceType": "appleWatch", "udid": "U-WD"},
         "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "disconnected"},
         "deviceProperties": {"name": "Idle Watch", "developerModeStatus": "enabled"}},
        {"identifier": "watch-conn", "hardwareProperties": {"reality": "physical", "platform": "watchOS", "deviceType": "appleWatch", "udid": "U-WC"},
         "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "connected"},
         "deviceProperties": {"name": "Active Watch", "developerModeStatus": "enabled"}},
        {"identifier": "wifi-1", "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "U-WIFI"},
         "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "disconnected"},
         "deviceProperties": {"name": "My iPhone", "developerModeStatus": "enabled"}},
        {"identifier": "usb-1", "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "U-USB"},
         "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"},
         "deviceProperties": {"name": "USB iPhone", "developerModeStatus": "enabled"}},
    ]
    picked = pick_iphone(devices)
    assert picked["core_id"] == "usb-1" and picked["udid"] == "U-USB"
    picked2 = pick_iphone(devices[:-1])
    assert picked2["core_id"] == "wifi-1" and picked2["udid"] == "U-WIFI"
    assert pick_iphone(devices[:4]) is None

    wpicked = pick_watch(devices)
    assert wpicked["core_id"] == "watch-conn" and wpicked["udid"] == "U-WC" and wpicked["name"] == "Active Watch"
    wpicked2 = pick_watch(devices[:3])
    assert wpicked2["core_id"] == "watch-disc" and wpicked2["udid"] == "U-WD"
    assert pick_watch(devices[:2]) is None


def test_profile_expiry_reads_embedded_plist_and_takes_recursive_min(tmp_path):
    app = tmp_path / "Hexplate.app"
    watch = app / "Watch/HexplateWatch.app"
    watch_ext = watch / "PlugIns/HexplateWatchWidgets.appex"
    watch_ext.mkdir(parents=True)

    iphone_exp = dt.datetime(2026, 11, 29, 12, 0, 0, tzinfo=dt.timezone.utc)
    watch_exp = dt.datetime(2026, 11, 27, 8, 30, 0, tzinfo=dt.timezone.utc)
    (app / "embedded.mobileprovision").write_bytes(b"\x30\x82DERHEADER" + plistlib.dumps({"ExpirationDate": iphone_exp}) + b"\x00\x01TRAILER")
    (watch_ext / "embedded.mobileprovision").write_bytes(b"\x30\x82DERHEADER" + plistlib.dumps({"ExpirationDate": watch_exp}) + b"\x00\x01TRAILER")

    assert profile_expiry(app) == iphone_exp.timestamp()
    assert all_profile_expiry(app) == watch_exp.timestamp()


def test_clean_error_friendly_device_aware_and_redacts_ids():
    assert "iphone is locked" in _clean_error("Device is locked with a passcode").lower()
    assert "apple watch is locked" in _clean_error("Device is locked with a passcode", device="Apple Watch").lower()
    assert "apple watch" in _clean_error("developer mode is disabled", device="Apple Watch").lower()
    assert "apple watch" in _clean_error("timed out", device="Apple Watch").lower()
    assert "Accounts" in _clean_error("No profiles for 'com.rippuhonwan.mygym' were found")
    assert "Apple Watch" in _clean_error("No profiles for 'com.rippuhonwan.mygym.watchkitapp' were found")
    # 3-app limit message stays iPhone-specific even if called with another device label.
    assert "this iPhone" in _clean_error("maximum number of apps for free development profiles", device="Apple Watch")
    cleaned = _clean_error("error: failed for 00008130-001234567890ABCD and 12345678-1234-1234-1234-1234567890AB")
    assert "00008130" not in cleaned and "12345678-1234" not in cleaned and "<device>" in cleaned


def test_signing_refresh_iphone_only_runs_xcodegen_even_when_xcodeproj_exists(client, tmp_path):
    store = client.app.state.store
    app_dir = tmp_path / "app"
    # Pre-create Hexplate.xcodeproj to prove _ensure_project() still regenerates via xcodegen.
    (app_dir / "Hexplate.xcodeproj").mkdir(parents=True)
    (app_dir / "Local.xcconfig").write_text("DEVELOPMENT_TEAM = TESTTEAM\n")
    derived = tmp_path / "derived"
    exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=6, hours=12)
    calls = []

    def fake_run(cmd, **kw):
        calls.append((cmd, kw))
        if cmd[0].endswith("xcodegen"):
            return SimpleNamespace(returncode=0, stdout="Generated project\n", stderr="")
        if "devicectl" in cmd and "list" in cmd:
            out_idx = cmd.index("--json-output") + 1
            Path(cmd[out_idx]).write_text(json.dumps({"result": {"devices": [{
                "identifier": "core-1",
                "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "UDID-1"},
                "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "connected"},
                "deviceProperties": {"name": "Test iPhone", "developerModeStatus": "enabled"},
            }]}}))
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if "xcodebuild" in cmd[0]:
            built = derived / "Build/Products/Debug-iphoneos/Hexplate.app"
            built.mkdir(parents=True, exist_ok=True)
            (built / "embedded.mobileprovision").write_bytes(b"DER" + plistlib.dumps({"ExpirationDate": exp}))
            return SimpleNamespace(returncode=0, stdout="BUILD SUCCEEDED\n", stderr="")
        if "install" in cmd:
            return SimpleNamespace(returncode=0, stdout="Installed\n", stderr="")
        raise AssertionError(cmd)

    signing = Signing(
        store,
        app_dir=app_dir,
        derived_dir=derived,
        runner=fake_run,
        platform="darwin",
        which=lambda name, **kw: "/opt/homebrew/bin/xcodegen" if name == "xcodegen" else None,
    )
    client.app.state.signing = signing
    ok, err = signing.refresh_sync()
    assert ok and err == ""
    assert len(calls) == 4
    assert calls[0][0] == ["/opt/homebrew/bin/xcodegen"]
    assert "-allowProvisioningUpdates" in calls[2][0]
    assert "id=UDID-1" in calls[2][0]
    assert any(arg.startswith("CURRENT_PROJECT_VERSION=2.") for arg in calls[2][0])
    assert "core-1" in calls[3][0]
    st = signing.status()
    assert st["device"] == "Test iPhone" and st["error"] is None and abs(st["expires"] - exp.timestamp()) < 2

    # Bootstrap exposes signing status in English and Chinese.
    en_boot = client.get("/analytics/api/bootstrap").json()
    assert en_boot["signing"]["available"] is True
    assert en_boot["signing"]["device"] == "Test iPhone"
    assert en_boot["signing"]["error"] is None
    assert abs(en_boot["signing"]["expires"] - exp.timestamp()) < 2

    store.set_setting("lang", "zh")
    zh_boot = client.get("/analytics/api/bootstrap").json()
    assert zh_boot["lang"] == "zh" and "Refresh Apple ID signing" in zh_boot["strings"]
    assert zh_boot["signing"]["device"] == "Test iPhone"


def test_signing_refresh_with_paired_watch_provisions_and_installs_both(tmp_path, client):
    store = client.app.state.store
    app_dir = tmp_path / "app"
    (app_dir / "Hexplate.xcodeproj").mkdir(parents=True)
    (app_dir / "Local.xcconfig").write_text("DEVELOPMENT_TEAM = TESTTEAM\n")
    derived = tmp_path / "derived"
    iphone_exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=6, hours=20)
    watch_exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=5, hours=4)
    calls = []

    def fake_run(cmd, **kw):
        calls.append((cmd, kw))
        if cmd[0].endswith("xcodegen"):
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if "devicectl" in cmd and "list" in cmd:
            out_idx = cmd.index("--json-output") + 1
            Path(cmd[out_idx]).write_text(json.dumps({"result": {"devices": [
                {
                    "identifier": "iphone-core",
                    "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "UDID-P"},
                    "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"},
                    "deviceProperties": {"name": "Test iPhone", "developerModeStatus": "enabled"},
                },
                {
                    "identifier": "watch-core",
                    "hardwareProperties": {"reality": "physical", "platform": "watchOS", "deviceType": "appleWatch", "udid": "UDID-W"},
                    "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "connected"},
                    "deviceProperties": {"name": "Test Watch", "developerModeStatus": "enabled"},
                },
            ]}}))
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if "xcodebuild" in cmd[0] and "HexplateWatch" in cmd:
            return SimpleNamespace(returncode=0, stdout="WATCH PROVISIONED\n", stderr="")
        if "xcodebuild" in cmd[0] and "Hexplate" in cmd:
            built_ios = derived / "Build/Products/Debug-iphoneos/Hexplate.app"
            embedded_watch = built_ios / "Watch/HexplateWatch.app"
            built_watch = derived / "Build/Products/Debug-watchos/HexplateWatch.app"
            embedded_watch.mkdir(parents=True, exist_ok=True)
            built_watch.mkdir(parents=True, exist_ok=True)
            (built_ios / "embedded.mobileprovision").write_bytes(b"DER" + plistlib.dumps({"ExpirationDate": iphone_exp}))
            (embedded_watch / "embedded.mobileprovision").write_bytes(b"DER" + plistlib.dumps({"ExpirationDate": watch_exp}))
            return SimpleNamespace(returncode=0, stdout="IOS BUILT\n", stderr="")
        if "install" in cmd:
            return SimpleNamespace(returncode=0, stdout="Installed\n", stderr="")
        raise AssertionError(cmd)

    signing = Signing(
        store,
        app_dir=app_dir,
        derived_dir=derived,
        runner=fake_run,
        platform="darwin",
        which=lambda name, **kw: "/opt/homebrew/bin/xcodegen",
    )
    ok, err = signing.refresh_sync()
    assert ok and err == ""
    assert len(calls) == 6
    watch_build_cmd = calls[2][0]
    ios_build_cmd = calls[3][0]
    ios_install_cmd, _ = calls[4]
    watch_install_cmd, watch_install_kw = calls[5]

    assert "-scheme" in watch_build_cmd and watch_build_cmd[watch_build_cmd.index("-scheme") + 1] == "HexplateWatch"
    assert "id=UDID-W" in watch_build_cmd
    assert "id=UDID-P" in ios_build_cmd

    watch_ver = next(a for a in watch_build_cmd if a.startswith("CURRENT_PROJECT_VERSION=2."))
    ios_ver = next(a for a in ios_build_cmd if a.startswith("CURRENT_PROJECT_VERSION=2."))
    assert watch_ver == ios_ver

    assert "iphone-core" in ios_install_cmd
    assert "watch-core" in watch_install_cmd
    assert str(derived / "Build/Products/Debug-watchos/HexplateWatch.app") in watch_install_cmd
    assert watch_install_kw["timeout"] >= 600

    st = signing.status()
    assert st["device"] == "Test iPhone + Test Watch"
    assert st["error"] is None
    assert abs(st["expires"] - watch_exp.timestamp()) < 2


def test_signing_watch_failures_are_non_fatal_and_visible(tmp_path, client):
    store = client.app.state.store
    app_dir = tmp_path / "app"
    (app_dir / "Hexplate.xcodeproj").mkdir(parents=True)
    (app_dir / "Local.xcconfig").write_text("DEVELOPMENT_TEAM = TESTTEAM\n")
    derived = tmp_path / "derived"
    exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=6, hours=12)
    mode = {"fail_at": "step_a"}

    def fake_run(cmd, **kw):
        if "devicectl" in cmd and "list" in cmd:
            out_idx = cmd.index("--json-output") + 1
            Path(cmd[out_idx]).write_text(json.dumps({"result": {"devices": [
                {
                    "identifier": "iphone-core",
                    "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "UDID-P"},
                    "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"},
                    "deviceProperties": {"name": "Test iPhone", "developerModeStatus": "enabled"},
                },
                {
                    "identifier": "watch-core",
                    "hardwareProperties": {"reality": "physical", "platform": "watchOS", "deviceType": "appleWatch", "udid": "UDID-W"},
                    "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "disconnected"},
                    "deviceProperties": {"name": "Test Watch", "developerModeStatus": "enabled"},
                },
            ]}}))
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if "xcodebuild" in cmd[0] and "HexplateWatch" in cmd:
            if mode["fail_at"] == "step_a":
                raise subprocess.TimeoutExpired(cmd=cmd, timeout=30)
            return SimpleNamespace(returncode=0, stdout="OK\n", stderr="")
        if "xcodebuild" in cmd[0] and "Hexplate" in cmd:
            built_ios = derived / "Build/Products/Debug-iphoneos/Hexplate.app"
            built_watch = derived / "Build/Products/Debug-watchos/HexplateWatch.app"
            built_ios.mkdir(parents=True, exist_ok=True)
            built_watch.mkdir(parents=True, exist_ok=True)
            (built_ios / "embedded.mobileprovision").write_bytes(b"DER" + plistlib.dumps({"ExpirationDate": exp}))
            return SimpleNamespace(returncode=0, stdout="OK\n", stderr="")
        if "install" in cmd and "iphone-core" in cmd:
            return SimpleNamespace(returncode=0, stdout="Installed\n", stderr="")
        if "install" in cmd and "watch-core" in cmd:
            return SimpleNamespace(returncode=1, stdout="", stderr="error: Device is locked with a passcode")
        raise AssertionError(cmd)

    signing = Signing(store, app_dir=app_dir, derived_dir=derived, runner=fake_run, platform="darwin", which=lambda *a, **kw: None)
    client.app.state.signing = signing

    # Case A: Watch unreachable/timed out during Step A -> iPhone still succeeds and updates expiry.
    ok, err = signing.refresh_sync()
    assert ok and err == ""
    st = signing.status()
    assert st["device"] == "Test iPhone (Watch skipped)"
    assert "iPhone refreshed; Watch skipped:" in st["error"] and "Apple Watch" in st["error"]
    assert abs(st["expires"] - exp.timestamp()) < 2

    # Case B: Watch locked during Step C install -> iPhone still succeeds and surfaces Watch lock warning.
    mode["fail_at"] = "step_c"
    ok2, err2 = signing.refresh_sync()
    assert ok2 and err2 == ""
    st2 = signing.status()
    assert st2["device"] == "Test iPhone (Watch skipped)"
    assert "Apple Watch is locked" in st2["error"]
    boot = client.get("/analytics/api/bootstrap").json()
    assert "iPhone refreshed; Watch skipped: Apple Watch is locked" in boot["signing"]["error"]


def test_settings_signing_run_api_starts_and_returns_status(client, monkeypatch):
    started = []
    monkeypatch.setattr(client.app.state.signing, "start", lambda: started.append(True) or True)
    r = client.post("/analytics/api/settings/signing/run", headers={"sec-fetch-site": "same-origin"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True and body["started"] is True
    assert started == [True]


def test_signing_unavailable_on_linux_and_displays_synced_status(client):
    store = client.app.state.store
    # Simulate a stale Linux failure previously saved in the database.
    store.set_setting("signing_error", "app/Local.xcconfig is missing. Add DEVELOPMENT_TEAM = <TEAM_ID> first.")

    linux_signing = Signing(store, platform="linux", runner=lambda *a, **kw: (_ for _ in ()).throw(AssertionError("should not run")))
    client.app.state.signing = linux_signing

    assert linux_signing.available is False
    assert linux_signing.start() is False
    ok, msg = linux_signing.refresh_sync()
    assert not ok and "macOS" in msg

    # Bootstrap reports unavailable on Linux; posting to signing/run returns started=False without running anything.
    boot = client.get("/analytics/api/bootstrap").json()
    assert boot["signing"]["available"] is False and boot["signing"]["running"] is False

    r = client.post("/analytics/api/settings/signing/run", headers={"sec-fetch-site": "same-origin"})
    assert r.status_code == 200
    assert r.json()["ok"] is True and r.json()["started"] is False
    assert r.json()["signing"]["available"] is False

    # Once a Mac syncs fresh signing metadata, bootstrap clears the stale error and surfaces it cleanly in EN and ZH.
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    exp = now + 6.5 * 86400
    linux_signing.record_result(at=now, expires=exp, device="Masashi's iPhone")

    st = linux_signing.status()
    assert st["available"] is False and st["device"] == "Masashi's iPhone" and st["error"] is None

    en_boot = client.get("/analytics/api/bootstrap").json()
    assert en_boot["signing"]["available"] is False
    assert en_boot["signing"]["device"] == "Masashi's iPhone"
    assert en_boot["signing"]["error"] is None
    assert abs(en_boot["signing"]["expires"] - exp) < 2

    store.set_setting("lang", "zh")
    zh_boot = client.get("/analytics/api/bootstrap").json()
    assert zh_boot["lang"] == "zh" and "Apple ID signing" in zh_boot["strings"]
    assert zh_boot["signing"]["device"] == "Masashi's iPhone" and zh_boot["signing"]["available"] is False


def test_signing_cli_set_signing_and_sign_json(tmp_path, monkeypatch, capsys):
    import io
    import sys
    from hexserver import __main__ as cli
    from hexserver.store import Store

    monkeypatch.setenv("HEXPLATE_DATA", str(tmp_path))
    monkeypatch.setenv("HEXPLATE_BACKUP", str(tmp_path / "backup"))

    # Seed a stale error, then clear it via `set-signing --clear-error`.
    Store(tmp_path).set_setting("signing_error", "stale error")
    monkeypatch.setattr(sys, "argv", ["hexserver", "set-signing", "--clear-error"])
    cli.main()
    out = json.loads(capsys.readouterr().out)
    assert out["ok"] is True and out["error"] is None

    # Record synced metadata via `--stdin` (safe for quotes/spaces in device names).
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    exp = now + 7 * 86400
    payload = json.dumps({"at": now, "expires": exp, "device": "Owner's iPhone 16"})
    monkeypatch.setattr(sys, "stdin", io.StringIO(payload))
    monkeypatch.setattr(sys, "argv", ["hexserver", "set-signing", "--stdin"])
    cli.main()
    out2 = json.loads(capsys.readouterr().out)
    assert out2["ok"] is True and out2["device"] == "Owner's iPhone 16"
    assert abs(out2["expires"] - exp) < 1 and out2["error"] is None

    # `sign --json` returns exit code 0 on success and 1 on failure.
    import pytest
    from hexserver.signing import Signing as RealSigning

    monkeypatch.setattr(RealSigning, "refresh_sync", lambda self: (True, ""))
    monkeypatch.setattr(sys, "argv", ["hexserver", "sign", "--json"])
    cli.main()
    out3 = json.loads(capsys.readouterr().out)
    assert out3["ok"] is True and out3["device"] == "Owner's iPhone 16"

    monkeypatch.setattr(RealSigning, "refresh_sync", lambda self: (False, "iPhone is locked."))
    monkeypatch.setattr(sys, "argv", ["hexserver", "sign", "--json"])
    with pytest.raises(SystemExit) as exc:
        cli.main()
    assert exc.value.code == 1
    out4 = json.loads(capsys.readouterr().out)
    assert out4["ok"] is False and "locked" in out4["error"]
