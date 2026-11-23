import datetime as dt
import json
import plistlib
from pathlib import Path
from types import SimpleNamespace

from hexserver.signing import Signing, _clean_error, pick_iphone, profile_expiry


def test_pick_iphone_filters_and_prioritizes():
    devices = [
        {"identifier": "sim-1", "hardwareProperties": {"reality": "simulated", "platform": "iOS", "deviceType": "iPhone", "udid": "U-SIM"},
         "connectionProperties": {"pairingState": "paired", "transportType": "sameMachine", "tunnelState": "connected"}, "deviceProperties": {"name": "Sim"}},
        {"identifier": "watch-1", "hardwareProperties": {"reality": "physical", "platform": "watchOS", "deviceType": "appleWatch", "udid": "U-W"},
         "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "connected"}, "deviceProperties": {"name": "Watch"}},
        {"identifier": "wifi-1", "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "U-WIFI"},
         "connectionProperties": {"pairingState": "paired", "transportType": "localNetwork", "tunnelState": "disconnected"},
         "deviceProperties": {"name": "My iPhone", "developerModeStatus": "enabled"}},
        {"identifier": "usb-1", "hardwareProperties": {"reality": "physical", "platform": "iOS", "deviceType": "iPhone", "udid": "U-USB"},
         "connectionProperties": {"pairingState": "paired", "transportType": "wired", "tunnelState": "connected"},
         "deviceProperties": {"name": "USB iPhone", "developerModeStatus": "enabled"}},
    ]
    picked = pick_iphone(devices)
    assert picked["core_id"] == "usb-1" and picked["udid"] == "U-USB"
    picked2 = pick_iphone(devices[:3])
    assert picked2["core_id"] == "wifi-1" and picked2["udid"] == "U-WIFI"
    assert pick_iphone(devices[:2]) is None


def test_profile_expiry_reads_embedded_plist(tmp_path):
    app = tmp_path / "Hexplate.app"
    app.mkdir()
    exp = dt.datetime(2026, 11, 29, 12, 0, 0, tzinfo=dt.timezone.utc)
    xml = plistlib.dumps({"ExpirationDate": exp})
    (app / "embedded.mobileprovision").write_bytes(b"\x30\x82DERHEADER" + xml + b"\x00\x01TRAILER")
    assert profile_expiry(app) == exp.timestamp()


def test_clean_error_friendly_and_redacts_ids():
    assert "locked" in _clean_error("Device is locked with a passcode").lower()
    assert "Accounts" in _clean_error("No profiles for 'com.rippuhonwan.mygym' were found")
    cleaned = _clean_error("error: failed for 00008130-001234567890ABCD and 12345678-1234-1234-1234-1234567890AB")
    assert "00008130" not in cleaned and "12345678-1234" not in cleaned and "<device>" in cleaned


def test_signing_refresh_and_settings_page(client, tmp_path):
    store = client.app.state.store
    app_dir = tmp_path / "app"
    (app_dir / "Hexplate.xcodeproj").mkdir(parents=True)
    (app_dir / "Local.xcconfig").write_text("DEVELOPMENT_TEAM = TESTTEAM\n")
    derived = tmp_path / "derived"
    exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=6, hours=12)
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
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

    signing = Signing(store, app_dir=app_dir, derived_dir=derived, runner=fake_run)
    client.app.state.signing = signing
    # Re-install dashboard reference isn't needed if we test Signing directly + settings via app fixture:
    ok, err = signing.refresh_sync()
    assert ok and err == ""
    assert len(calls) == 3
    assert "-allowProvisioningUpdates" in calls[1]
    assert "id=UDID-1" in calls[1]
    assert "core-1" in calls[2]
    st = signing.status()
    assert st["device"] == "Test iPhone" and st["error"] is None and abs(st["expires"] - exp.timestamp()) < 2

    # Settings page shows status in English and Chinese
    en_html = client.get("/settings").text
    assert "Refresh Apple ID signing" in en_html and "Test iPhone" in en_html and "7 days left" in en_html
    store.set_setting("lang", "zh")
    zh_html = client.get("/settings").text
    assert "更新 Apple ID 驗證" in zh_html and "剩餘 7 天" in zh_html


def test_settings_signing_post_starts_and_redirects(client, monkeypatch):
    started = []
    monkeypatch.setattr(client.app.state.signing, "start", lambda: started.append(True) or True)
    r = client.post("/settings/signing/run", headers={"sec-fetch-site": "same-origin"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/settings"
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

    # /settings on Linux must not show the stale Local.xcconfig error and must not offer a broken run button.
    en_html = client.get("/settings").text
    assert "Local.xcconfig" not in en_html
    assert 'action="/settings/signing/run"' not in en_html
    assert "macOS" in en_html

    # Posting directly to /settings/signing/run on Linux redirects safely without executing anything.
    r = client.post("/settings/signing/run", headers={"sec-fetch-site": "same-origin"}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/settings"

    # Once a Mac syncs fresh signing metadata, Linux /settings displays it cleanly in EN and ZH.
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    exp = now + 6.5 * 86400
    linux_signing.record_result(at=now, expires=exp, device="Masashi's iPhone")

    st = linux_signing.status()
    assert st["available"] is False and st["device"] == "Masashi's iPhone" and st["error"] is None

    en_synced = client.get("/settings").text
    assert "Masashi&#x27;s iPhone" in en_synced and "7 days left" in en_synced
    assert 'action="/settings/signing/run"' not in en_synced

    store.set_setting("lang", "zh")
    zh_synced = client.get("/settings").text
    assert "Masashi&#x27;s iPhone" in zh_synced and "剩餘 7 天" in zh_synced
    assert "Mac" in zh_synced


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
