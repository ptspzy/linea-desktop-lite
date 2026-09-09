#!/usr/bin/env bash
set -euo pipefail

# Writes JSON to stdout only. Uploading the DMG and manifest is a separate, manual step.
exec /usr/bin/python3 - "$@" <<'PY'
import hashlib
import json
import pathlib
import re
import sys
import urllib.parse


def fail(message):
    raise SystemExit(message)


if len(sys.argv) not in (4, 5):
    fail("usage: create-update-manifest.sh DMG VERSION HTTPS_DOWNLOAD_URL [MINIMUM_MACOS_VERSION]")

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
download_url = sys.argv[3]
minimum = sys.argv[4] if len(sys.argv) == 5 else "13.0"
numeric_version = r"(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){0,2}"
if not all(re.fullmatch(numeric_version, value) for value in (version, minimum)):
    fail("Versions require one to three numeric components, without leading zeros.")

try:
    url = urllib.parse.urlsplit(download_url)
    host = (url.hostname or "").lower()
    labels = host.split(".")
    decoded_path = urllib.parse.unquote(url.path, errors="strict")
    valid_url = (
        len(download_url.encode("utf-8")) <= 8192
        and all(33 <= ord(c) <= 126 and c != "\\" for c in download_url)
        and url.scheme == "https" and (url.port is None or 1 <= url.port <= 65535)
        and url.username is None and url.password is None and "#" not in download_url
        and len(host) <= 253
        and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels)
        and re.fullmatch(r"[a-z]+", labels[-1])
        and labels[-1] not in ("localhost", "local", "invalid")
        and not any(c in decoded_path for c in ("\\", "%"))
        and all(ord(c) >= 32 and ord(c) != 127 for c in decoded_path)
        and not any(part in (".", "..") for part in decoded_path.split("/"))
        and not decoded_path.endswith("/")
        and pathlib.PurePosixPath(decoded_path).suffix.lower() == ".dmg"
    )
except (ValueError, UnicodeError):
    valid_url = False
if not valid_url:
    fail("Download URL must be HTTPS on a DNS host, with a .dmg path and no credentials, fragment, or unsafe path.")
if path.suffix.lower() != ".dmg" or not path.is_file():
    fail("Input must be a regular .dmg file.")

digest = hashlib.sha256()
count = 0
with path.open("rb") as source:
    size = source.seek(0, 2)
    if not 512 <= size <= 1024 * 1024 * 1024:
        fail("DMG must be between 512 bytes and 1 GiB.")
    source.seek(-512, 2)
    if source.read(4) != b"koly":
        fail("Input must be a UDIF DMG with a koly trailer.")
    source.seek(0)
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        count += len(chunk)
        if count > 1024 * 1024 * 1024:
            fail("DMG exceeds 1 GiB.")
        digest.update(chunk)
    if count != size:
        fail("DMG size changed during hashing; retry with a stable release artifact.")

print(json.dumps({
    "schemaVersion": 1,
    "version": version,
    "minimumSystemVersion": minimum,
    "downloadURL": download_url,
    "sha256": digest.hexdigest(),
    "byteCount": count,
}, indent=2))
PY
