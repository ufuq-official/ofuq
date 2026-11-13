#!/usr/bin/env python3
"""Builds banners/index.json, the pictures Ofuq shows at the top of the Today tab.

Every picture in the banners/ folder is listed, ordered by file name with numbers in order
(1.jpg, 2.jpg … 10.jpg). banners/links.txt can give a picture a link that opens when it is tapped:
one line per picture, the file name then the link ("1.jpg https://t.me/ofuq_store").

Each picture's link ends with ?v= and a short fingerprint of the file, so replacing a picture with
a new one under the same name shows the new one in the app instead of the old cached one.
"""

import hashlib
import json
import os
import re
import sys
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BANNERS = ROOT / "banners"
INDEX = BANNERS / "index.json"
LINKS = BANNERS / "links.txt"

REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ufuq-official/ofuq")
BRANCH = os.environ.get("GITHUB_REF_NAME", "main")
RAW_BASE = f"https://raw.githubusercontent.com/{REPOSITORY}/{BRANCH}/banners/"

PICTURES = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".gif"}
# Bigger files make the Today tab slow to show on mobile data.
LARGE = 3 * 1024 * 1024


def natural(name):
    return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", name.lower())]


def read_links(names):
    if not LINKS.exists():
        return {}
    links = {}
    lowered = {name.lower(): name for name in names}
    for number, line in enumerate(LINKS.read_text(encoding="utf-8-sig").splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            print(f"warning: links.txt line {number} needs a picture name and a link, skipped: {line}")
            continue
        name, link = parts[0], parts[1].strip()
        if name.lower() not in lowered:
            print(f"warning: links.txt line {number}: there is no picture named {name}, skipped")
            continue
        if not re.match(r"^[a-z][a-z0-9+.-]*://", link, re.IGNORECASE):
            print(f"warning: links.txt line {number}: {link} is not a link, skipped")
            continue
        links[lowered[name.lower()]] = link
    return links


def main():
    BANNERS.mkdir(exist_ok=True)
    pictures = sorted(
        (path for path in BANNERS.iterdir() if path.is_file() and path.suffix.lower() in PICTURES),
        key=lambda path: natural(path.name),
    )
    links = read_links([path.name for path in pictures])

    banners = []
    for path in pictures:
        data = path.read_bytes()
        fingerprint = hashlib.sha1(data).hexdigest()[:12]
        if len(data) > LARGE:
            print(f"warning: {path.name} is {len(data) // 1024} KB, a picture under 1 MB loads faster")
        banner = {"image": f"{RAW_BASE}{urllib.parse.quote(path.name)}?v={fingerprint}"}
        if path.name in links:
            banner["link"] = links[path.name]
        banners.append(banner)
        print(f"ok: {path.name}" + (f" -> {links[path.name]}" if path.name in links else ""))

    text = json.dumps({"banners": banners}, ensure_ascii=False, indent=2) + "\n"
    if INDEX.exists() and INDEX.read_text(encoding="utf-8") == text:
        print(f"index.json unchanged ({len(banners)} pictures)")
        return 0
    INDEX.write_text(text, encoding="utf-8")
    print(f"index.json written ({len(banners)} pictures)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
