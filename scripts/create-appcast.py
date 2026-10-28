"""Generate an appcast for the exact notarized archive signed by Sparkle."""
import os
import plistlib
import re
from pathlib import Path
from xml.sax.saxutils import escape

tag = os.environ["STORAGESCOPE_RELEASE_TAG"]
signature_output = os.environ["SPARKLE_SIGNATURE"]
signature = re.search(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"', signature_output)
length = re.search(r'length="([0-9]+)"', signature_output)
archive = Path("release-assets/StorageScope-arm64.zip")
if not re.fullmatch(r"v\d+\.\d+\.\d+", tag) or not signature or not length or int(length[1]) != archive.stat().st_size:
    raise ValueError("Invalid Sparkle archive signature metadata")
with Path("Packaging/Info.plist").open("rb") as source:
    info = plistlib.load(source)
notes = escape(Path("RELEASE_NOTES.md").read_text(encoding="utf-8"))
url = f"https://github.com/laBrioche97/StorageScope/releases/download/{tag}/StorageScope-arm64.zip"
Path("release-assets/appcast.xml").write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>StorageScope</title><link>https://github.com/laBrioche97/StorageScope</link><description>Mises à jour stables</description>
<item><title>StorageScope {escape(tag)}</title><description>{notes}</description>
<sparkle:version>{escape(info["CFBundleVersion"])}</sparkle:version>
<sparkle:shortVersionString>{escape(info["CFBundleShortVersionString"])}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="{url}" sparkle:edSignature="{signature[1]}" length="{length[1]}" type="application/octet-stream"/>
</item></channel></rss>
''', encoding="utf-8")
