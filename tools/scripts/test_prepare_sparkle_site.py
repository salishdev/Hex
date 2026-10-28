import base64
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from prepare_sparkle_site import build_site, validate_appcast, RELEASES


def fixture(version="0.9.1", build=94):
    tag = f"v{version}"
    archive_url = f"{RELEASES}/download/{tag}/Hex-{version}.dmg"
    feed_url = f"{RELEASES}/download/{tag}/appcast.xml"
    release = {"tag_name": tag, "draft": False, "prerelease": False, "assets": [
        {"name": f"Hex-{version}.dmg", "browser_download_url": archive_url, "size": 123},
        {"name": "appcast.xml", "browser_download_url": feed_url},
    ]}
    signature = base64.b64encode(b"x" * 64).decode()
    data = (f'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f'<channel><item><sparkle:version>{build}</sparkle:version>'
            f'<sparkle:shortVersionString>{version}</sparkle:shortVersionString>'
            f'<enclosure url="{archive_url}" length="123" sparkle:edSignature="{signature}"/>'
            '</item></channel></rss>').encode()
    return release, data


class SiteTests(unittest.TestCase):
    def test_highest_build_wins_regardless_of_release_order(self):
        old, old_data = fixture()
        new, new_data = fixture("0.9.2", 95)
        feeds = {old["assets"][1]["browser_download_url"]: old_data, new["assets"][1]["browser_download_url"]: new_data}
        with TemporaryDirectory() as directory:
            output = Path(directory)
            self.assertEqual(build_site([new, old], output, feeds.__getitem__), 95)
            self.assertEqual((output / "appcast.xml").read_bytes(), new_data)

    def test_drafts_and_prereleases_never_reach_feed(self):
        release, _ = fixture()
        for field in ("draft", "prerelease"):
            release[field] = True
            with TemporaryDirectory() as directory:
                self.assertIsNone(build_site([release], Path(directory), lambda _: self.fail("Unexpected download")))
            release[field] = False

    def test_bootstrap_for_releases_without_sparkle(self):
        release, _ = fixture()
        release["assets"] = []
        with TemporaryDirectory() as directory:
            self.assertIsNone(build_site([release], Path(directory), lambda _: self.fail("Unexpected download")))
            self.assertNotIn(b"<item>", (Path(directory) / "appcast.xml").read_bytes())

    def test_rejects_wrong_version_url_size_and_signature(self):
        release, data = fixture()
        for broken in (data.replace(b"0.9.1", b"0.9.2"), data.replace(b"https://github.com", b"https://example.com"),
                       data.replace(b'length="123"', b'length="124"'), data.replace(base64.b64encode(b"x" * 64), b"")):
            with self.assertRaises(ValueError):
                validate_appcast(broken, release)

    def test_duplicate_build_numbers_fail_instead_of_arbitrary_selection(self):
        old, old_data = fixture()
        new, new_data = fixture("0.9.2", 94)
        feeds = {old["assets"][1]["browser_download_url"]: old_data, new["assets"][1]["browser_download_url"]: new_data}
        with TemporaryDirectory() as directory, self.assertRaises(ValueError):
            build_site([new, old], Path(directory), feeds.__getitem__)


if __name__ == "__main__":
    unittest.main()
