#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build an asc-submit spec.json from the App Store metadata in this repo.

The generated spec feeds `asc-submit run` (takezou621/asc-submit), which
creates the App Store version, uploads What's New / descriptions / review
notes / screenshots and submits for review. The metadata source of truth is:

- docs/appstore/metadata/metadata-*.md   What's New and Description per locale
- docs/appstore/review-notes.md          App Review notes (English section)
- docs/appstore/screenshots/*.png        screenshots in display order

Usage:

    python3 scripts/release/appstore-spec.py --version 0.7.0 [--build 9] [--output PATH]

The What's New copy for the target version MUST already exist as a
"What's New (<version>)" section in every metadata file — this script fails
if it is missing, so the release cannot proceed with stale copy.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent.parent
META_DIR = ROOT_DIR / "docs/appstore/metadata"
NOTES_FILE = ROOT_DIR / "docs/appstore/review-notes.md"
SHOTS_DIR = ROOT_DIR / "docs/appstore/screenshots"

# locale -> metadata file name. The locale strings are the ones App Store
# Connect uses for the app record (en-US, zh-Hans, es-ES, ...).
LOCALES = {
    "ja": "metadata-ja.md",
    "en-US": "metadata-en.md",
    "zh-Hans": "metadata-zh-Hans.md",
    "ko": "metadata-ko.md",
    "es-ES": "metadata-es.md",
}

APP_ID = "6812783176"  # com.takezou621.KildeGUI

# Headings that carry the Description code block, per metadata file dialect.
DESCRIPTION_HEADING = re.compile(r"description|説明|설명|描述|descripción", re.IGNORECASE)
# Headings that carry this release's What's New block.
WHATSNEW_HEADING = re.compile(r"what.?s.new|新着情報|새로운 기능|新功能|novedades", re.IGNORECASE)
# The English section of review-notes.md that gets pasted into ASC.
NOTES_SECTION = re.compile(
    r"## English \(paste into App Review Notes\)\n(.*?)\n---", re.S
)


def code_blocks(text: str) -> list[tuple[str, str]]:
    """Return (first heading line, code block content) pairs in document order.

    Only the heading's first line is kept on purpose: the ``##`` heading and
    the fenced block may be separated by prose (the What's New sections carry
    editorial notes), and letting ``.+?`` swallow that prose would make
    version matching below see version strings from the notes.
    """
    return [
        (m.group(1).strip().split("\n", 1)[0], m.group(2))
        for m in re.finditer(r"## (.+?)\n+```text\n(.*?)\n```", text, re.S)
    ]


def unwrap(block: str) -> str:
    """Join intra-paragraph line wraps.

    The metadata files wrap the description at ~80 columns for review, but
    App Store Connect renders newlines literally — paragraphs are separated
    by blank lines and must keep their breaks.
    """
    paragraphs = re.split(r"\n\s*\n", block.strip())
    return "\n\n".join(" ".join(p.split("\n")).strip() for p in paragraphs)


def section_for_version(headings: list[tuple[str, str]], version: str, locale: str) -> str:
    """Find the What's New code block whose heading names this version.

    Matching happens on the heading's first line against the exact
    ``(version)`` token, so editorial prose elsewhere in the file cannot make
    e.g. ``--version 0.5.0`` match the 0.6.0 section.
    """
    token = f"({version})"
    matches = [
        block
        for heading, block in headings
        if WHATSNEW_HEADING.search(heading) and token in heading
    ]
    if len(matches) == 1:
        return matches[0].strip()
    if not matches:
        raise SystemExit(
            f"{locale}: no \"What's New ({version})\" section in {LOCALES[locale]}. "
            f"Write the release copy into the metadata file before generating the spec."
        )
    raise SystemExit(
        f"{locale}: {len(matches)} What's New sections mention {version!r} in "
        f"{LOCALES[locale]}; keep exactly one"
    )


def build_spec(version: str, build: str | None) -> dict:
    whats_new: dict[str, str] = {}
    descriptions: dict[str, str] = {}
    for locale, fname in LOCALES.items():
        path = META_DIR / fname
        if not path.is_file():
            raise SystemExit(f"metadata file not found: {path}")
        headings = code_blocks(path.read_text(encoding="utf-8"))
        whats_new[locale] = section_for_version(headings, version, locale)

        desc = [block for heading, block in headings if DESCRIPTION_HEADING.search(heading)]
        if len(desc) != 1:
            raise SystemExit(
                f"{locale}: expected exactly one Description block in {fname}, found {len(desc)}"
            )
        descriptions[locale] = unwrap(desc[0])

    if not NOTES_FILE.is_file():
        raise SystemExit(f"review notes not found: {NOTES_FILE}")
    notes_match = NOTES_SECTION.search(NOTES_FILE.read_text(encoding="utf-8"))
    if not notes_match:
        raise SystemExit(
            f"could not find the English section in {NOTES_FILE} "
            "(expected a '## English (paste into App Review Notes)' heading followed by '---')"
        )

    screenshots = sorted(SHOTS_DIR.glob("*.png"))
    if not screenshots:
        raise SystemExit(f"no screenshots in {SHOTS_DIR}")

    # Deliberately no "submit" key: submitting is controlled by the
    # `asc-submit run --submit` flag alone, so a stale spec can never submit
    # on its own.
    spec: dict = {
        "version": version,
        "releaseType": "AFTER_APPROVAL",
        "screenshotDisplayType": "APP_DESKTOP",
        "screenshotsReplace": True,
        "whatsNew": whats_new,
        "descriptions": descriptions,
        "reviewNotes": notes_match.group(1).strip(),
        "screenshots": {"ja": [str(p) for p in screenshots]},
    }
    if build:
        spec["build"] = build
    return spec


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate an asc-submit spec.json from docs/appstore metadata."
    )
    parser.add_argument("--version", required=True, help="release version, e.g. 0.7.0")
    parser.add_argument("--build", help="build number already uploaded to App Store Connect")
    parser.add_argument(
        "--output",
        help=f"output path (default: dist/appstore/release-<version>.json)",
    )
    args = parser.parse_args()

    output = Path(args.output) if args.output else ROOT_DIR / f"dist/appstore/release-{args.version}.json"
    spec = build_spec(args.version, args.build)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(spec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"spec written: {output}")
    print(f"  whatsNew locales : {', '.join(sorted(spec['whatsNew']))}")
    print(f"  description chars: { {k: len(v) for k, v in spec['descriptions'].items()} }")
    print(f"  review notes     : {len(spec['reviewNotes'])} chars")
    print(f"  screenshots (ja) : {len(spec['screenshots']['ja'])} files")
    print("next: asc-submit run 6812783176 --spec " + str(output) + " [--submit]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
