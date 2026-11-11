#!/usr/bin/env python3
"""Builds sources/index.json, the list of sources Ofuq adds by itself.

It lists, in this order:
  1. the links in sources/links.txt (one per line, lines starting with # are notes);
  2. every JSON source file in the sources/ folder.

A JSON file that is not a valid source (broken JSON, or no "apps" list) is skipped with a warning,
so one bad upload never breaks the list for everyone.
"""

import json
import os
import sys
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "sources"
INDEX = SOURCES / "index.json"
LINKS = SOURCES / "links.txt"

REPOSITORY = os.environ.get("GITHUB_REPOSITORY", "ufuq-official/ofuq")
BRANCH = os.environ.get("GITHUB_REF_NAME", "main")
RAW_BASE = f"https://raw.githubusercontent.com/{REPOSITORY}/{BRANCH}/sources/"


def read_links():
    if not LINKS.exists():
        return []
    links = []
    for number, line in enumerate(LINKS.read_text(encoding="utf-8-sig").splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not line.lower().startswith(("https://", "http://")):
            print(f"warning: links.txt line {number} is not a link, skipped: {line}")
            continue
        links.append(line)
    return links


def read_files():
    links = []
    for path in sorted(SOURCES.glob("*.json"), key=lambda p: p.name.lower()):
        if path.name == INDEX.name:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except (ValueError, UnicodeDecodeError) as error:
            print(f"warning: {path.name} is not valid JSON, skipped ({error})")
            continue
        if not isinstance(data, dict) or not isinstance(data.get("apps"), list):
            print(f"warning: {path.name} has no \"apps\" list, so it is not a source, skipped")
            continue
        links.append(RAW_BASE + urllib.parse.quote(path.name))
        print(f"ok: {path.name} ({len(data['apps'])} apps)")
    return links


def main():
    seen = set()
    sources = []
    for link in read_links() + read_files():
        if link not in seen:
            seen.add(link)
            sources.append(link)

    text = json.dumps({"sources": sources}, ensure_ascii=False, indent=2) + "\n"
    if INDEX.exists() and INDEX.read_text(encoding="utf-8") == text:
        print(f"index.json unchanged ({len(sources)} sources)")
        return 0
    INDEX.write_text(text, encoding="utf-8")
    print(f"index.json written ({len(sources)} sources)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
