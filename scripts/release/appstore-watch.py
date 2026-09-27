#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Watch the newest App Store version's review state (issue #160).

App Store Connect has no webhooks, so the review outcome is detected by
polling the version state. This script classifies the **watched** version
(see below) and reports:

- ``quiet``    — nothing to act on (in review, draft, or nothing submitted)
- ``rejected`` — REJECTED / METADATA_REJECTED / DEVELOPER_REJECTED
- ``approved`` — READY_FOR_SALE

Exit codes: 0 = quiet/approved-handled, 10 = rejected, 20 = approved.
The mas-watch workflow turns 10 into a failing job (GitHub email) plus an
idempotent issue, and 20 into an issue reminding the metrics update.

**Which version is watched**: the newest version (parsed version string)
among the non-draft ones. Drafts (PREPARE_FOR_SUBMISSION / PLANNED) are
ignored, so a rejection stays detectable even after the next version has
been created. Consequence: once the newest live version reaches an
approved state the "approved" report keeps firing until a newer version is
created — the workflow's issue deduplication (open **and** closed issues)
keeps that to a single issue (Apple's webhook notifications would need a
hosted endpoint we don't operate, so polling is the pragmatic choice).

Usage:

    export ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER=…   # same as asc-submit
    PYTHONPATH=/path/to/asc-submit python3 scripts/release/appstore-watch.py --app 6812783176
    python3 scripts/release/appstore-watch.py --selftest   # offline, no auth
"""

from __future__ import annotations

import argparse
import os
import sys

#ASC にログインしない自己診断モード用の期待値 (decide の仕様をここに固定する)
SELFTEST_CASES = [
    # (states, expected kind, expected watched version)
    ({"0.8.1": "WAITING_FOR_REVIEW", "0.6.0": "READY_FOR_SALE"}, "quiet", "0.8.1"),
    ({"0.8.1": "IN_REVIEW", "0.6.0": "READY_FOR_SALE"}, "quiet", "0.8.1"),
    ({"0.8.1": "REJECTED", "0.6.0": "READY_FOR_SALE"}, "rejected", "0.8.1"),
    ({"0.8.1": "METADATA_REJECTED", "0.6.0": "READY_FOR_SALE"}, "rejected", "0.8.1"),
    ({"0.8.1": "DEVELOPER_REJECTED", "0.6.0": "READY_FOR_SALE"}, "rejected", "0.8.1"),
    ({"0.8.1": "READY_FOR_SALE", "0.6.0": "READY_FOR_SALE"}, "approved", "0.8.1"),
    # MANUAL リリースの場合は承認後いったん PENDING_DEVELOPER_RELEASE になる
    ({"0.8.1": "PENDING_DEVELOPER_RELEASE", "0.6.0": "READY_FOR_SALE"}, "approved", "0.8.1"),
    # 次バージョンのドラフトがあっても判別対象はドラフト以外の最新
    ({"0.8.1": "REJECTED", "0.9.0": "PREPARE_FOR_SUBMISSION"}, "rejected", "0.8.1"),
    ({"0.8.1": "READY_FOR_SALE", "0.9.0": "PREPARE_FOR_SUBMISSION"}, "approved", "0.8.1"),
    ({"0.9.0": "PREPARE_FOR_SUBMISSION", "0.8.1": "WAITING_FOR_REVIEW"}, "quiet", "0.8.1"),
]

REJECTED_STATES = {"REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED"}
DRAFT_STATES = {"PREPARE_FOR_SUBMISSION", "PLANNED"}


def _version_key(version: str):
    """'0.10.2' を比較可能なタプルにする。数値でない部分は文字列扱いで最後尾。"""
    parts = []
    for chunk in version.split("."):
        if chunk.isdigit():
            parts.append((0, int(chunk), ""))
        else:
            parts.append((1, 0, chunk))
    return tuple(parts)


def decide(states: dict[str, str]) -> tuple[str, str, str]:
    """{version: state} から (kind, watched_version, state) を返す。

    判別対象はドラフト以外の最新バージョン。候補が無ければ
    ("quiet", "", "")。
    """
    candidates = {v: s for v, s in states.items() if s not in DRAFT_STATES}
    if not candidates:
        return ("quiet", "", "")
    watched = max(candidates, key=_version_key)
    state = candidates[watched]
    if state in REJECTED_STATES:
        return ("rejected", watched, state)
    # PENDING_DEVELOPER_RELEASE は「承認済み・リリース待ち」(MANUAL リリース時)。
    # kilde は AFTER_APPROVAL なので通常 READY_FOR_SALE に直行するが、
    # リリース方式を変えても通知が欠けないように承認扱いにする
    if state in ("READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE"):
        return ("approved", watched, state)
    return ("quiet", watched, state)


def fetch_states(app_id: str) -> dict[str, str]:
    """ASC API から MAC_OS の全バージョンの状態を取得する (読み取りのみ)。"""
    try:
        from asc_submit import flows
        from asc_submit.auth import make_token
        from asc_submit.client import Client
    except ImportError:
        sys.exit(
            "asc_submit が import できません。ワークフローと同じく "
            "PYTHONPATH を asc-submit の checkout へ通してください"
        )
    token = make_token(
        os.environ.get("ASC_KEY_ID", ""),
        os.environ.get("ASC_ISSUER", ""),
        os.environ.get("ASC_KEY_PATH", ""),
    )
    client = Client(token=token)
    states = {}
    for v in flows.list_versions(client, app_id):
        attrs = v["attributes"]
        if attrs.get("platform") != "MAC_OS":
            continue
        states[attrs["versionString"]] = attrs["appStoreState"]
    if not states:
        sys.exit(f"app {app_id} に MAC_OS のバージョンが見つかりません")
    return states


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", help="Apple ID of the app")
    parser.add_argument("--selftest", action="store_true", help="run offline assertions")
    args = parser.parse_args()

    if args.selftest:
        for i, (states, want_kind, want_version) in enumerate(SELFTEST_CASES):
            got_kind, got_version, _ = decide(states)
            assert (got_kind, got_version) == (want_kind, want_version), (
                f"case {i}: {states} -> {(got_kind, got_version)}, "
                f"expected {(want_kind, want_version)}"
            )
        print(f"selftest OK ({len(SELFTEST_CASES)} cases)")
        return 0

    if not args.app:
        parser.error("--app is required (or use --selftest)")

    states = fetch_states(args.app)
    kind, version, state = decide(states)
    print(f"KIND={kind}")
    print(f"VERSION={version}")
    print(f"STATE={state}")
    return {"quiet": 0, "rejected": 10, "approved": 20}[kind]


if __name__ == "__main__":
    sys.exit(main())
