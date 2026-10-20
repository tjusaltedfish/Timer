"""Phone releases: versions, publishing, and token-protected download."""
import hashlib
import json

import pytest
from fastapi.testclient import TestClient

from app import releases
from app.main import create_app


def test_version_parsing_and_source():
    assert releases.parse_version("1.2.3+45") == ("1.2.3", 45)
    for bad in ("1.2.3", "1.2+3", "v1.2.3+4", "", None):
        assert releases.parse_version(bad) is None
    assert releases.parse_version(releases.source_version()) is not None


def test_publish_requires_increasing_builds_and_keeps_two_apks(tmp_path):
    apk = tmp_path / "app.apk"
    data = tmp_path / "data"
    for build in (2, 3, 4):
        apk.write_bytes(f"apk build {build}".encode())
        info = releases.publish(data, apk, f"1.0.0+{build}")
    assert info["build"] == 4 and info["min_build"] == 0
    assert info["sha256"] == hashlib.sha256(b"apk build 4").hexdigest()
    assert sorted(p.name for p in (data / "releases").glob("*.apk")) == ["timer-1.0.0-3.apk", "timer-1.0.0-4.apk"]
    with pytest.raises(ValueError):
        releases.publish(data, apk, "1.0.1+4")  # build numbers never go back
    with pytest.raises(ValueError):
        releases.publish(data, apk, "1.0.1")
    required = releases.publish(data, apk, "1.1.0+5", require=True)
    assert required["min_build"] == 5
    assert releases.publish(data, apk, "1.1.1+6")["min_build"] == 5  # stays until raised again


def test_cli_publishes_into_the_data_directory(tmp_path):
    apk = tmp_path / "app.apk"
    apk.write_bytes(b"cli")
    releases.main(["publish", str(apk), "--version", "2.0.0+9", "--data", str(tmp_path / "d")])
    stored = json.loads((tmp_path / "d" / "releases" / "latest.json").read_text(encoding="utf-8"))
    assert stored["version"] == "2.0.0+9" and stored["file"] == "timer-2.0.0-9.apk"


@pytest.fixture
def client(tmp_path):
    app = create_app(tmp_path, background=False)
    with TestClient(app) as value:
        value.headers["Authorization"] = "Bearer " + app.state.desktop_token
        yield value


def phone(client):
    code = client.post("/api/v1/pairing/code").json()["code"]
    token = client.post("/api/v1/pairing/confirm", json={"code": code, "name": "手机"}).json()["token"]
    return {"Authorization": "Bearer " + token}


def test_download_needs_a_paired_device_and_matches_its_checksum(client, tmp_path):
    assert client.get("/api/v1/app/latest").status_code == 404
    snapshot = client.get("/api/v1/snapshot").json()
    assert snapshot["app_latest"] is None and releases.parse_version(snapshot["server_version"])
    payload = bytes(range(256)) * 4096  # 1 MiB, streamed
    apk = tmp_path / "built.apk"
    apk.write_bytes(payload)
    releases.publish(tmp_path, apk, "1.0.0+7")
    for path in ("/api/v1/app/latest", "/api/v1/app/download"):
        assert client.get(path, headers={"Authorization": "Bearer nope"}).status_code == 401
        assert client.get(path, headers={"Authorization": ""}).status_code == 401
    headers = phone(client)
    latest = client.get("/api/v1/app/latest", headers=headers).json()
    assert (latest["version"], latest["build"], latest["size"]) == ("1.0.0+7", 7, len(payload))
    assert "file" not in latest
    download = client.get("/api/v1/app/download", headers=headers)
    assert download.status_code == 200
    assert download.headers["content-type"] == "application/vnd.android.package-archive"
    assert hashlib.sha256(download.content).hexdigest() == latest["sha256"] == download.headers["x-timer-sha256"]
    assert client.get("/api/v1/snapshot", headers=headers).json()["app_latest"]["build"] == 7
    assert client.get("/health").json()["app_latest"] == "1.0.0+7"


def test_missing_apk_is_not_offered(client, tmp_path):
    apk = tmp_path / "built.apk"
    apk.write_bytes(b"x")
    info = releases.publish(tmp_path, apk, "1.0.0+8")
    (tmp_path / "releases" / info["file"]).unlink()
    assert client.get("/api/v1/app/latest").status_code == 404
