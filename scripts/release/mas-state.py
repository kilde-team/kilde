#!/usr/bin/env python3
"""Read the App Store Connect state for one MAS version/build (read-only).

issue #615 — mas.yml の冪等化のために追加。upload / apply / submit の各段階の
前に ASC の実状態を照会し、既に到達済みの段階をスキップするための判定材料を
GitHub Actions の step outputs 形式 (``key=value`` 行) で出力する。

- **読み取りのみ (GET)**。副作用を持たない。判定の正本はワークフローの
  conclusion ではなく ASC 実状態 — 0.45.0 の提出では «提出自体は成立していたのに
  conclusion だけ見ると失敗に見える» 誤認が起きた (apply run 44795636897 は
  WAITING_FOR_REVIEW の版に build 割当て PATCH を試みて HTTP 409 で失敗)。
  その教訓の機械化がこのスクリプトの目的
- asc-submit (takezou621/asc-submit) の Client / flows を使う。認証は
  asc-submit と同じ環境変数 (ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER)。
  CI では ``PYTHONPATH: asc-submit``、ローカルでは checkout への PYTHONPATH で
  実行する。**CI がピンするコミット (mas.yml の ref) とローカルの最新の両方で
  動く公開 API だけを使う** (require_version は存在しない版で SystemExit するため
  resolve_version を使う — «版が無い» はエラーではなく判定対象の実状態)
- 出力は stdout と ``--output-file`` の両方に書く。stdout は key=value のみ
  (人間向けの説明は stderr へ — ワークフローの poll step が stdout をそのまま
  解析できるようにするため)

出力のキー::

    version_state=PREPARE_FOR_SUBMISSION   # ASC の appStoreState。存在しない場合は absent
    version_editable=true                  # メタデータ・build 割当てが可能な状態か
    build_state=VALID                      # build の processingState。--build 未指定 / 未登録は absent
    build_present=true                     # 指定した build 番号が ASC に存在するか
    build_version_match=true               # その build の cfBundleShortVersionString が --version と一致するか
                                           # (--build 未指定は absent。build 番号は app 全体で一意なため、
                                           # 番号だけの一致は別版の build を拾いうる — 再利用ゲートは
                                           # この一致を見る)

``version_editable`` の集合 (Apple の AppStoreVersionState のうち編集可能なもの):
PREPARE_FOR_SUBMISSION / REJECTED / DEVELOPER_REJECTED / METADATA_REJECTED /
INVALID_BINARY。それ以外 (WAITING_FOR_REVIEW・IN_REVIEW・PENDING_DEVELOPER_RELEASE・
READY_FOR_SALE・RELEASED などの終端) は編集不可 — 編集可能集合に無い状態への
PATCH は 409 で拒否される (0.45.0 の実測。再 dispatch を «失敗» にしないために
この判定でスキップする)。«absent» は editable 扱い — apply が版を作る経路。
"""

from __future__ import annotations

import argparse
import os
import sys

# Apple の AppStoreVersionState のうち、メタデータと build 関係を編集できる状態。
# WAITING_FOR_REVIEW 以降はロックされる — ここに無い状態は «編集不可» として扱う
EDITABLE_VERSION_STATES = frozenset(
    {
        "PREPARE_FOR_SUBMISSION",
        "REJECTED",
        "DEVELOPER_REJECTED",
        "METADATA_REJECTED",
        "INVALID_BINARY",
    }
)

# build (Builds.processingState) のうち、«この番号はもう使えない» が確定している状態。
# FAILED / INVALID の build は同じ番号での再アップロードが許されないため、
# upload モードの再利用判定ではこれらを «再利用せず失敗させる» 対象にする
DEAD_BUILD_STATES = frozenset({"FAILED", "INVALID"})


def _load_asc_submit():
    """Import asc-submit's public API, with a clear error when missing."""
    try:
        from asc_submit import auth, flows  # noqa: PLC0415 — 実行時に PYTHONPATH を見るため
        from asc_submit.client import ApiError, Client  # noqa: PLC0415
    except ImportError as err:
        print(
            "asc-submit を import できません: "
            f"{err} — PYTHONPATH に asc-submit の checkout を指定してください "
            "(mas.yml では PYTHONPATH: asc-submit。ローカルでは "
            "PYTHONPATH=$HOME/dev/asc-submit など)",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return auth, flows, ApiError, Client


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="App Store Connect の app id (例 6812783176)")
    parser.add_argument("--version", required=True, help="MAS のバージョン (例 0.46.0)")
    parser.add_argument("--build", default="", help="build 番号 (例 50)。指定すると存在と状態も見る")
    parser.add_argument("--output-file", default="", help="key=value を追記するファイル (省略可)")
    args = parser.parse_args()

    auth, flows, ApiError, Client = _load_asc_submit()

    # asc-submit と同じ 3 つの環境変数を使う (mas.yml の decode step が展開する)
    key_path = os.environ.get("ASC_KEY_PATH", "")
    key_id = os.environ.get("ASC_KEY_ID", "")
    issuer = os.environ.get("ASC_ISSUER", "")
    missing = [name for name, value in (("ASC_KEY_PATH", key_path), ("ASC_KEY_ID", key_id), ("ASC_ISSUER", issuer)) if not value]
    if missing:
        print(f"環境変数 {', '.join(missing)} が未設定です (asc-submit と同じ鍵の環境変数が必要)", file=sys.stderr)
        return 2
    if not os.path.isfile(key_path):
        print(f"API キーが見つかりません: {key_path}", file=sys.stderr)
        return 2

    client = Client(token=auth.make_token(key_id, issuer, key_path))

    # 版の実状態。resolve_version は存在しなければ None を返す (SystemExit しない)。
    # «版が無い» は upload / apply の初回に普通に起こる状態で、エラーではなく
    # «これから作る» 判定の材料
    version = flows.resolve_version(client, args.app, args.version)
    if version is None:
        version_state = "absent"
        # 版が無い状態は apply (版の作成) が可能 — editable 扱いにする
        version_editable = True
    else:
        version_state = version.get("attributes", {}).get("appStoreState", "unknown")
        version_editable = version_state in EDITABLE_VERSION_STATES

    # build の実状態。build は版ごとではなく app 全体の一覧で扱う
    # (ASC API に version→builds の include が無いため — asc-submit の実装と同じ)。
    # «同じ番号の build が既に載っている» なら upload は再アーカイブせず再利用する
    build_state = "absent"
    build_present = False
    build_version_match = "absent"  # --build 未指定
    if args.build:
        # «この番号の build がどの配布バージョンで焼かれたか» は builds の fields
        # では取れない (cfBundleShortVersionString / appVersion は fields に渡すと
        # HTTP 400 — asc-submit の実測メモ «fields[builds] は version +
        # processingState» どおり)。build 番号は app 全体で一意なため «番号が一致
        # する build» を見つけた後で、その build の preReleaseVersion リレーション
        # (attributes.version = CFBundleShortVersionString) を個別に照会して
        # --version と一致するかを見る。番号だけの一致は、別バージョンで焼かれた
        # build (番号の打ち間違い・旧コマンドの再実行) を誤って再利用しうる
        builds = client.get_all(
            f"/v1/apps/{args.app}/builds",
            {"fields[builds]": "version,processingState"},
        )
        for build in builds:
            attrs = build.get("attributes", {})
            if str(attrs.get("version")) != str(args.build):
                continue
            build_state = attrs.get("processingState", "unknown")
            build_present = True
            pre = client.get(f"/v1/builds/{build['id']}/preReleaseVersion")
            pre_version = (pre.get("data", {}).get("attributes") or {}).get("version")
            build_version_match = "true" if pre_version == args.version else "false"
            break

    result = {
        "version_state": version_state,
        "version_editable": "true" if version_editable else "false",
        "build_state": build_state,
        "build_present": "true" if build_present else "false",
        "build_version_match": build_version_match,
    }

    # 人間向けの説明は stderr へ。key=value の stdout は
    # GITHUB_OUTPUT / poll step の解析に使う
    print(f"mas-state: version {args.version} state={version_state} editable={'yes' if version_editable else 'no'}", file=sys.stderr)
    if args.build:
        print(
            f"mas-state: build {args.build} state={build_state} present={'yes' if build_present else 'no'} "
            f"version_match={build_version_match}",
            file=sys.stderr,
        )
    if version_state not in ("absent",) and not version_editable:
        print(
            f"mas-state: version {args.version} は提出済み以降の状態 ({version_state}) のため、"
            "メタデータ・build 割当て・再提出は実行しても 409 で拒否されます (冪等スキップの対象)",
            file=sys.stderr,
        )
    if build_present and build_version_match == "false":
        print(
            f"mas-state: build {args.build} はバージョン {args.version} とは別の版の build です "
            "(preReleaseVersion の version が不一致) — この番号は再利用できません。build 番号を増やしてください",
            file=sys.stderr,
        )
    if build_present and build_state in DEAD_BUILD_STATES:
        print(
            f"mas-state: build {args.build} は {build_state} — 同じ番号での再アップロードはできません。"
            "次の build 番号で upload をやり直してください",
            file=sys.stderr,
        )

    lines = [f"{key}={value}" for key, value in result.items()]
    text = "\n".join(lines) + "\n"
    if args.output_file:
        with open(args.output_file, "a", encoding="utf-8") as handle:
            handle.write(text)
    print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
