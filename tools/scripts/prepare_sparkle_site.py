#!/usr/bin/env python3
"""Build the Pages feed from signed appcasts attached to published stable releases."""
import base64
import json
import re
import sys
from pathlib import Path
from urllib.request import urlopen
from xml.etree import ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
RELEASES = "https://github.com/salishdev/Hex/releases"


def validate_appcast(data, release):
    root = ET.fromstring(data)
    items = root.findall("./channel/item")
    if root.tag != "rss" or len(items) != 1:
        raise ValueError("Expected an RSS appcast with exactly one update")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Missing update enclosure")
    build = item.findtext(f"{SPARKLE}version") or enclosure.get(f"{SPARKLE}version", "")
    version = item.findtext(f"{SPARKLE}shortVersionString") or enclosure.get(f"{SPARKLE}shortVersionString", "")
    if not re.fullmatch(r"[1-9]\d{0,3}", build) or version != release["tag_name"][1:]:
        raise ValueError("Appcast version does not match release")
    archive_name = f"Hex-{version}.dmg"
    archive = next((asset for asset in release["assets"] if asset["name"] == archive_name), None)
    expected_url = f"{RELEASES}/download/{release['tag_name']}/{archive_name}"
    if archive is None or enclosure.get("url") != expected_url or archive["browser_download_url"] != expected_url:
        raise ValueError("Appcast does not point to this release's DMG asset")
    if enclosure.get("length") != str(archive["size"]):
        raise ValueError("Appcast length does not match the uploaded archive")
    signature = base64.b64decode(enclosure.get(f"{SPARKLE}edSignature", ""), validate=True)
    if len(signature) != 64:
        raise ValueError("Missing or invalid EdDSA archive signature")
    return int(build)


def build_site(releases, output, download):
    candidates = []
    for release in releases:
        if release["draft"] or release["prerelease"] or not re.fullmatch(r"v\d+\.\d+\.\d+", release["tag_name"]):
            continue
        asset = next((asset for asset in release["assets"] if asset["name"] == "appcast.xml"), None)
        if asset is None:
            continue  # Releases from before Sparkle was enabled have no appcast.
        expected = f"{RELEASES}/download/{release['tag_name']}/appcast.xml"
        if asset["browser_download_url"] != expected:
            raise ValueError("Unexpected appcast asset URL")
        data = download(expected)
        candidates.append((validate_appcast(data, release), data))
    # Select by Sparkle's build number, so publishing an older release cannot roll back the feed.
    builds = [build for build, _ in candidates]
    if len(builds) != len(set(builds)):
        raise ValueError("Published releases reuse a Sparkle build number")
    output.mkdir(parents=True, exist_ok=True)
    data = max(candidates, key=lambda entry: entry[0])[1] if candidates else (
        b'<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0"><channel>'
        b'<title>Hex Updates</title><link>https://github.com/salishdev/Hex/releases</link>'
        b'<description>Signed Hex updates will appear here.</description></channel></rss>\n'
    )
    (output / "appcast.xml").write_bytes(data)
    (output / ".nojekyll").touch()
    (output / "index.html").write_text(
        '<!doctype html><html lang="en"><meta charset="utf-8"><title>Hex Updates</title>'
        '<h1>Hex Updates</h1><p><a href="https://github.com/salishdev/Hex/releases">'
        'Download Hex and read release notes</a></p></html>\n', encoding="utf-8"
    )
    return max(builds) if builds else None


def download(url):
    with urlopen(url, timeout=60) as response:
        data = response.read(1_000_001)
    if len(data) > 1_000_000:
        raise ValueError("Appcast exceeds 1 MB")
    return data


if __name__ == "__main__":
    pages = json.loads(Path(sys.argv[1]).read_text())
    releases = [release for page in pages for release in page]
    print(f"Published feed build: {build_site(releases, Path(sys.argv[2]), download)}")
