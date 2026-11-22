#!/usr/bin/env python3
"""PreToolUse safety guard for kilde (kilde-team/kilde).

AGENTS.md §2 / §4 と docs/RELEASE.md の契約を、正規の作業を止めずに守るための
PreToolUse ガード (.agents/hooks.json から呼ばれる)。判定は allow / force_ask
の 2 値 — force_ask は禁止ではなく「意図した操作なら理由を添えて確認の上進める」
ための確認:

1. main ブランチへの直接 push (AGENTS.md §2 — PR 経由でマージする)
2. シークレットの出力 (ASC / notarization の .p8 キーの中身、.env の表示、
   API キー変数の echo / printenv — docs/RELEASE.md §2 / §4)
3. エンジン pin (gui/project.yml の kilde-cli-swift パッケージの exactVersion) の
   単独編集 — release.yml の ref: と同じ PR で揃える契約 (AGENTS.md §4 /
   docs/RELEASE.md「CLI ソースの pin の更新」) のため、単独変更に確認を挟む。
   他パッケージ (Sparkle / firebase-ios-sdk) の exactVersion 更新は確認しない。
   edit_file は適用後の内容で pin を比較し (トークンやコメントによる値の保持を
   不変の証拠にしない)、シェル経由の書き込み (値だけの置換を含む) も確認する。
   読み取りは妨げない
4. 配布 workflow (.github/workflows/mas.yml / release.yml) の編集 — 配布経路の
   要所のため一律に確認を挟む (シェルからの読み取りは妨げない)

Python 標準ライブラリのみで動く (依存追加しない)。hooks のカレントディレクトリが
リポジトリルートと hooks.json の置かれた .agents/ のどちらでも動くように、
リポジトリファイルの参照は cwd から親へ辿って解決する。--self-test で通常操作が
allow、上記パターン各々が force_ask になることを確認できる。
"""

from __future__ import annotations

import json
import os
import re
import sys

# --- main への直接 push ----------------------------------------------------
# 「main」はトークンとして厳密に見る (feature/main-fix や main2 を誤検知しない)。
# 直前が行頭・空白・コロン (HEAD:main)・force 記号の + (refspec の +main) か
# refs/heads/ のみを対象にする
MAIN_PUSH_RE = re.compile(
    r"\bgit\s+push\b[^\n;|&]*(?:(?:^|[\s:+])|refs/heads/)main(?![\w-])"
)

# --- シークレット -----------------------------------------------------------
# kilde で秘匿値を運ぶ環境変数 (docs/RELEASE.md §4 の secrets 群 + ローカル運用の
# 変数名)。notarization 用 (AC_API_KEY*) と App Store 用 (KILDE_ASC_API_KEY* /
# ASC_CI_KEY*) の両方 — CLAUDE.md §5-19 の混線事故の教訓でもある
SECRET_VAR_RE = (
    r"(?:AC_API_KEY_ID|AC_API_ISSUER|AC_API_KEY"
    r"|KILDE_ASC_API_KEY_ID|KILDE_ASC_API_ISSUER|KILDE_ASC_API_KEY"
    r"|ASC_CI_KEY_ID|ASC_CI_ISSUER|ASC_CI_KEY"
    r"|SPARKLE_ED25519_PRIVATE_KEY|KILDE_CLI_SWIFT_TOKEN"
    r"|DEVELOPER_ID_CERTIFICATE_BASE64|DEVELOPER_ID_CERTIFICATE_PASSWORD)"
)
SECRET_PRINT_PATTERNS = [
    # .p8 キーファイルの中身を表示・エンコードで出す (cat 等)
    r"(?:cat|head|tail|less|more|base64|xxd|od|openssl)\s[^;\n|&]*\.p8\b",
    # .env の表示
    r"(?:cat|head|tail|less|more)\s[^;\n|&]*\.env\b",
    # API キー変数の値の echo / printf
    r"(?:echo|printf)\s[^;\n|&]*\$\{?" + SECRET_VAR_RE,
    # printenv (キー名指定 / 引数なしの全環境ダンプの両方)
    r"printenv(?:\s[^;\n|&]*" + SECRET_VAR_RE + r")?\s*(?:$|[;&|])",
]

# --- 配布 workflow ----------------------------------------------------------
WORKFLOW_FILE_RE = re.compile(r"(?:^|/)\.github/workflows/(?:mas|release)\.yml$")
WORKFLOW_SHELL_WRITE_RE = re.compile(
    r"(?:>>?|sed\s+-i|perl\s+-\w*i|tee\s)"  # リダイレクト / in-place 編集の合図
)

# --- エンジン pin -----------------------------------------------------------
PIN_FILE_RE = re.compile(r"(?:^|/)gui/project\.yml$")
# gui/project.yml へのシェル経由の書き込みの合図 (リダイレクト / in-place 編集 /
# plutil による値の置換)。«値だけ» の pin 書き換え (sed 's/0.27.2/0.28.0/') も
# 拾うため exactVersion トークンは要求しない。読み取り (grep 等) は対象外
PIN_SHELL_WRITE_RE = re.compile(r"(?:>>?|sed\s+-i|perl\s+-\w*i|tee\s|plutil\s+-replace)")
PACKAGE_KEY_RE = re.compile(r"^  ([A-Za-z][\w-]*):\s*(?:#.*)?$")
EXACT_VERSION_RE = re.compile(r"^\s*exactVersion:\s*([\w.-]+)\s*(?:#.*)?$", re.MULTILINE)
ENGINE_PACKAGE_HINT = "kilde-cli-swift"


def _pin_values(text: str | None) -> tuple[str, ...] | None:
    """テキスト中の kilde-cli-swift パッケージの exactVersion 値のタプルを返す。

    帰属は yaml のパッケージキー (2 スペースインデントの `name:`) で行う —
    comment ブロックにも «kilde-cli-swift» という語は現れるため、行の近さでなく
    ブロック構造で見ないと Sparkle / firebase-ios-sdk を誤帰属する。
    text が None (渡されなかった) なら None、テキストはあるがエンジン pin が
    見つからなければ空タプルを返す。
    """
    if text is None:
        return None
    current_package: str | None = None
    values: list[str] = []
    for line in text.splitlines():
        key = PACKAGE_KEY_RE.match(line)
        if key is not None:
            current_package = key.group(1)
            continue
        ver = EXACT_VERSION_RE.match(line)
        if ver is not None and current_package is not None:
            if ENGINE_PACKAGE_HINT in current_package:
                values.append(ver.group(1))
    return tuple(values)


def _first_str(args: dict, keys: tuple[str, ...]) -> str | None:
    """引数辞書から最初に見つかった文字列値を返す (大文字小文字の揺れを吸収)。"""
    lowered = {k.lower(): v for k, v in args.items() if isinstance(v, str)}
    for key in keys:
        value = lowered.get(key.lower())
        if value:
            return value
    return None


def _read_repo_file(rel_path: str) -> str | None:
    """リポジトリルート起点で対象ファイルを読む。

    相対パスは cwd から親へ最大 4 段階探す — hooks のカレントがリポジトリルートと
    hooks.json の置かれた .agents/ のどちらでも同じファイルに解決する。
    絶対パスは同マシンの実ファイルとしてそのまま読む。
    読めなければ None (呼び出し側が保守的に扱う)。
    """
    if not rel_path:
        return None
    if os.path.isabs(rel_path):
        if os.path.isfile(rel_path):
            try:
                with open(rel_path, "r", encoding="utf-8") as handle:
                    return handle.read()
            except OSError:
                return None
        return None
    candidate = os.getcwd()
    for _ in range(5):
        probe = os.path.join(candidate, rel_path)
        if os.path.isfile(probe):
            try:
                with open(probe, "r", encoding="utf-8") as handle:
                    return handle.read()
            except OSError:
                return None
        parent = os.path.dirname(candidate)
        if parent == candidate:
            return None
        candidate = parent
    return None


def check_run_command(cmd: str) -> tuple[str, str | None]:
    # 1. main への直接 push
    if MAIN_PUSH_RE.search(cmd):
        return (
            "force_ask",
            "main ブランチへの直接 push は AGENTS.md §2 で禁止されています "
            "(PR 経由でマージしてください)。本当に実行しますか？",
        )

    # 2. シークレットの出力
    for pattern in SECRET_PRINT_PATTERNS:
        if re.search(pattern, cmd):
            return (
                "force_ask",
                "シークレット (.p8 キー / .env / API キー) がログへ出力される恐れが"
                "あります (docs/RELEASE.md §2 / §4)。本当に実行しますか？",
            )

    # 3. エンジン pin ファイルへの書き込み系コマンド。«値だけ» の置換
    # (sed 's/0.27.2/0.28.0/' のような exactVersion トークンの無い書き換え) も
    # 拾う。grep などの読み取りは妨げない
    normalized_cmd = cmd.replace("\\", "/")
    if "gui/project.yml" in normalized_cmd and PIN_SHELL_WRITE_RE.search(cmd):
        return (
            "force_ask",
            "エンジン pin (gui/project.yml の exactVersion) への変更の可能性が"
            "あります。release.yml の ref: を同じ PR で揃えていますか "
            "(docs/RELEASE.md「CLI ソースの pin の更新」)？",
        )

    # 4. 配布 workflow の書き込み系コマンド (grep などの読み取りは allow)
    if re.search(r"\.github/workflows/(?:mas|release)\.yml", normalized_cmd) and (
        WORKFLOW_SHELL_WRITE_RE.search(cmd)
    ):
        return (
            "force_ask",
            ".github/workflows/ の配布経路 (mas.yml / release.yml) への書き込みの"
            "可能性があります。配布経路の要所のため編集は確認の上で行ってください。"
            "本当に実行しますか？",
        )

    return ("allow", None)


def check_file_write(
    path: str,
    new_text: str | None,
    old_text: str | None,
    disk_text: str | None,
) -> tuple[str, str | None]:
    normalized = path.replace("\\", "/")

    # 4. 配布 workflow の編集 — 一律に確認を挟む (禁止ではなく確認)
    if WORKFLOW_FILE_RE.search(normalized):
        return (
            "force_ask",
            ".github/workflows/ の配布経路 (mas.yml / release.yml) の編集です。"
            "配布経路の要所のため確認します。本当に変更しますか？",
        )

    # 3. エンジン pin (gui/project.yml) の編集
    if PIN_FILE_RE.search(normalized):
        if old_text is not None and new_text is not None:
            disk_pin = _pin_values(disk_text)
            # 第一判断: ディスクの現在内容に差分を適用した**結果**で pin を比較する。
            # トークンの有無・«値だけ» の置換・«# previously …» によるトークンの保持は
            # いずれも適用後の pin を見れば判定できる (トークンの保持を pin 不変の
            # 証拠にはしない)。複数箇所で一致したら全部を適用して見る — 誤検知は
            # 確認に倒れる安全側の方向
            if disk_text is not None and old_text in disk_text:
                result_pin = _pin_values(disk_text.replace(old_text, new_text))
                if result_pin != disk_pin:
                    return (
                        "force_ask",
                        "エンジン pin (gui/project.yml の exactVersion) が "
                        f"{'+'.join(disk_pin or ())} → {'+'.join(result_pin or ())} "
                        "に変わります。release.yml の ref: を同じ PR で揃えていますか "
                        "(docs/RELEASE.md「CLI ソースの pin の更新」)？",
                    )
                return ("allow", None)
            # フォールバック: ディスクから適用結果を再現できない (未読・不一致) ときは
            # 文字列ベースで判定し、pin に触れる可能性のある編集は確認に倒す
            if "exactVersion" not in old_text and "exactVersion" not in new_text:
                removed = (set(re.findall(r"[\w.-]+", old_text))
                           - set(re.findall(r"[\w.-]+", new_text)))
                if any(value in (disk_pin or ()) for value in removed):
                    return (
                        "force_ask",
                        "gui/project.yml の値の置換がエンジン pin "
                        f"({'+'.join(disk_pin or ())}) に一致します。exactVersion を"
                        "単独で変えていないか確認します — release.yml の ref: と"
                        "同じ PR で揃える契約があります。本当に変更しますか？",
                    )
                if disk_text is None:
                    return (
                        "force_ask",
                        "gui/project.yml の現在値を読めず pin を検証できません。"
                        "エンジン pin を単独で変えていないか確認します。"
                        "本当に変更しますか？",
                    )
                return ("allow", None)
            old_pin = _pin_values(old_text)
            new_pin = _pin_values(new_text)
            if old_pin and new_pin:
                # 両辺ともパッケージ文脈ごと取れている → 直接比較できる
                if old_pin != new_pin:
                    return (
                        "force_ask",
                        "エンジン pin (gui/project.yml の exactVersion) が変わります。"
                        "release.yml の ref: を同じ PR で揃えていますか "
                        "(docs/RELEASE.md「CLI ソースの pin の更新」)？",
                    )
                return ("allow", None)
            return (
                "force_ask",
                "gui/project.yml の exactVersion を含む編集です。エンジン pin "
                "(kilde-cli-swift) を単独で変えていないか確認します — release.yml の "
                "ref: と同じ PR で揃える契約があります。本当に変更しますか？",
            )
        # write_file (ファイル全体の書き込み): 新しい内容とディスクの現在値を比較
        new_pin = _pin_values(new_text)
        if new_text is None or new_pin is None:
            return (
                "force_ask",
                "gui/project.yml への書き込みです (内容が取得できず pin を検証できません)。"
                "エンジン pin (kilde-cli-swift の exactVersion) を壊していないか確認します。"
                "本当に変更しますか？",
            )
        if not new_pin:
            # フル書き込みなのに kilde-cli-swift 依存が無い — pin の取り消しの恐れ
            return (
                "force_ask",
                "書き込み後の gui/project.yml に kilde-cli-swift の exactVersion が"
                "見つかりません。エンジン依存の削除・書き漏れの可能性があります。"
                "本当に変更しますか？",
            )
        disk_pin = _pin_values(disk_text)
        if disk_pin is not None:
            if disk_pin != new_pin:
                return (
                    "force_ask",
                    "エンジン pin (gui/project.yml の exactVersion) が "
                    f"{'+'.join(disk_pin)} → {'+'.join(new_pin)} に変わります。"
                    "release.yml の ref: を同じ PR で揃えていますか "
                    "(docs/RELEASE.md「CLI ソースの pin の更新」)？",
                )
            return ("allow", None)
        return (
            "force_ask",
            "gui/project.yml の現在値を読めず pin を検証できません。"
            "エンジン pin (kilde-cli-swift の exactVersion) を単独で変えていないか"
            "確認します。本当に変更しますか？",
        )

    return ("allow", None)


def decide(payload: dict, disk_text: str | None = None) -> tuple[str, str | None]:
    """hook の標準入力 1 件分から判定を返す (セルフテストからも呼ぶ)。"""
    tool_call = payload.get("toolCall") or {}
    name = str(tool_call.get("name") or "")
    args = tool_call.get("args") or {}
    if not isinstance(args, dict):
        args = {}

    if name == "run_command":
        cmd = _first_str(args, ("CommandLine", "commandLine", "command", "cmd")) or ""
        return check_run_command(cmd)

    if name in ("write_file", "edit_file"):
        path = _first_str(args, ("Path", "path", "file_path", "filePath")) or ""
        new_text = _first_str(args, ("new_string", "NewContent", "content", "newText"))
        old_text = _first_str(args, ("old_string", "OldContent", "oldText"))
        if disk_text is None:
            disk_text = _read_repo_file(path)
        return check_file_write(path, new_text, old_text, disk_text)

    return ("allow", None)


def emit(decision: str, reason: str | None = None) -> None:
    payload: dict[str, str] = {"decision": decision}
    if reason:
        payload["reason"] = reason
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")


def self_test() -> int:
    """通常操作は allow、検知対象は force_ask になることを確認する。

    ファイル系のケースはディスクの中身を注入して判定するため、どの checkout でも
    同じ結果になる。全ケース PASS なら 0、失敗があれば 1 を返す。
    """
    def run(name: str, args: dict, disk: str | None = None) -> tuple[str, str | None]:
        return decide({"toolCall": {"name": name, "args": args}}, disk_text=disk)

    engine_yml_disk = (
        "packages:\n"
        "  kilde-cli-swift:\n"
        "    url: https://github.com/kilde-team/kilde-cli-swift.git\n"
        "    exactVersion: 0.27.2\n"
        "  Sparkle:\n"
        "    url: https://github.com/sparkle-project/Sparkle.git\n"
        "    exactVersion: 2.10.0\n"
    )
    engine_yml_new_pin = engine_yml_disk.replace("exactVersion: 0.27.2", "exactVersion: 0.28.0")
    engine_yml_no_pin = engine_yml_disk.replace(
        "    exactVersion: 0.27.2\n", ""
    )

    cases: list[tuple[str, str, tuple[str, str | None]]] = [
        # --- allow: 通常操作 ---
        ("allow: ls", "allow", run("run_command", {"CommandLine": "ls docs"})),
        ("allow: workflow の読み取り (grep)", "allow", run("run_command", {"CommandLine": 'grep -n "ref:" .github/workflows/release.yml'})),
        ("allow: workflow の YAML 検証", "allow", run("run_command", {"CommandLine": 'ruby -ryaml -e \'YAML.load_file(".github/workflows/release.yml")\''})),
        ("allow: git status", "allow", run("run_command", {"CommandLine": "git status"})),
        ("allow: feature ブランチの push", "allow", run("run_command", {"CommandLine": "git push origin feature/628-agents-orchestrator"})),
        ("allow: main を含まない push (main-site)", "allow", run("run_command", {"CommandLine": "git push origin feature/main-site"})),
        ("allow: キー変数への設定 (出力ではない)", "allow", run("run_command", {"CommandLine": "export KILDE_ASC_API_KEY=~/private/AuthKey_ABC123.p8"})),
        ("allow: GUI ビルド", "allow", run("run_command", {"CommandLine": "(cd gui && xcodegen && xcodebuild -project KildeGUI.xcodeproj -scheme KildeGUI build CODE_SIGNING_ALLOWED=NO)"})),
        ("allow: project.yml のコメント編集 (pin 行外)", "allow", run("edit_file", {"Path": "gui/project.yml", "old_string": "# GUI の自動更新 (issue #122)", "new_string": "# GUI の自動更新 (issue #122、コメントを整形)"})),
        ("allow: pin と同値を含む旧コメント行の削除", "allow", run("edit_file", {"Path": "gui/project.yml", "old_string": "# v0.27.2 の注記", "new_string": "# 注記は削除済み"}, disk=engine_yml_disk)),
        ("allow: grep による project.yml の読み取り", "allow", run("run_command", {"CommandLine": "grep exactVersion gui/project.yml"})),
        ("ask: pin の値だけの置換 (トークン無し)", "force_ask", run("edit_file", {"Path": "gui/project.yml", "old_string": ": 0.27.2", "new_string": ": 0.28.0"}, disk=engine_yml_disk)),
        ("ask: 値だけの pin 書き換えをシェルで実行", "force_ask", run("run_command", {"CommandLine": "sed -i '' 's/0.27.2/0.28.0/' gui/project.yml"})),
        ("ask: トークンを保持した値の置換 («# previously»)", "force_ask", run("edit_file", {"Path": "gui/project.yml", "old_string": ": 0.27.2", "new_string": ": 0.28.0 # previously 0.27.2"}, disk=engine_yml_disk)),
        ("allow: 他パッケージの値だけの置換 (Sparkle)", "allow", run("edit_file", {"Path": "gui/project.yml", "old_string": ": 2.10.0", "new_string": ": 2.11.0"}, disk=engine_yml_disk)),
        ("allow: Sparkle の exactVersion bump (エンジン pin 外)", "allow", run("edit_file", {"Path": "gui/project.yml", "old_string": "exactVersion: 2.10.0", "new_string": "exactVersion: 2.11.0"}, disk=engine_yml_disk)),
        ("allow: project.yml 全体再書き込み (pin 不変)", "allow", run("write_file", {"Path": "gui/project.yml", "content": engine_yml_disk}, disk=engine_yml_disk)),
        ("allow: 他ファイルの書き込み", "allow", run("write_file", {"Path": "docs/RELEASE.md", "content": "# リリース署名と notarization\n"})),
        # --- force_ask: main 直接 push ---
        ("ask: main への直接 push", "force_ask", run("run_command", {"CommandLine": "git push origin main"})),
        ("ask: HEAD:main への push", "force_ask", run("run_command", {"CommandLine": "git push origin HEAD:main"})),
        ("ask: refs/heads/main への push", "force_ask", run("run_command", {"CommandLine": "git push origin refs/heads/main"})),
        ("ask: force 記号つき refspec (+main) への push", "force_ask", run("run_command", {"CommandLine": "git push origin +main"})),
        # --- force_ask: シークレット出力 ---
        ("ask: .p8 キーの cat", "force_ask", run("run_command", {"CommandLine": "cat ~/Downloads/AuthKey_2DB7ZRS4N4.p8"})),
        ("ask: .p8 キーの base64", "force_ask", run("run_command", {"CommandLine": "base64 -i ~/.klide-asc/AuthKey_G9C3BAFJDQ.p8"})),
        ("ask: .env の表示", "force_ask", run("run_command", {"CommandLine": "cat .env"})),
        ("ask: ASC CI キー変数の echo", "force_ask", run("run_command", {"CommandLine": 'echo "$ASC_CI_ISSUER"'})),
        ("ask: notarization キー変数の echo", "force_ask", run("run_command", {"CommandLine": 'echo "key: $AC_API_KEY"'})),
        ("ask: Sparkle 秘密鍵の printenv", "force_ask", run("run_command", {"CommandLine": "printenv SPARKLE_ED25519_PRIVATE_KEY"})),
        ("ask: 引数なし printenv (全環境ダンプ)", "force_ask", run("run_command", {"CommandLine": "printenv"})),
        # --- force_ask: エンジン pin の単独編集 ---
        ("ask: sed による exactVersion 書き換え", "force_ask", run("run_command", {"CommandLine": "sed -i '' 's/exactVersion: 0.27.2/exactVersion: 0.28.0/' gui/project.yml"})),
        ("ask: project.yml の pin 編集 (差分のみ)", "force_ask", run("edit_file", {"Path": "gui/project.yml", "old_string": "exactVersion: 0.27.2", "new_string": "exactVersion: 0.28.0"}, disk=engine_yml_disk)),
        ("ask: project.yml の pin 編集 (文脈つき)", "force_ask", run("edit_file", {"Path": "gui/project.yml", "old_string": "url: https://github.com/kilde-team/kilde-cli-swift.git\n    exactVersion: 0.27.2", "new_string": "url: https://github.com/kilde-team/kilde-cli-swift.git\n    exactVersion: 0.28.0"}, disk=engine_yml_disk)),
        ("ask: project.yml 全体再書き込み (pin 変更)", "force_ask", run("write_file", {"Path": "gui/project.yml", "content": engine_yml_new_pin}, disk=engine_yml_disk)),
        ("ask: project.yml 全体再書き込み (pin 消滅)", "force_ask", run("write_file", {"Path": "gui/project.yml", "content": engine_yml_no_pin}, disk=engine_yml_disk)),
        # --- force_ask: 配布 workflow の編集 ---
        ("ask: release.yml のシェルからの in-place 編集", "force_ask", run("run_command", {"CommandLine": "sed -i '' 's/ref: v0.27.2/ref: v0.28.0/' .github/workflows/release.yml"})),
        ("ask: mas.yml へのリダイレクト書き込み", "force_ask", run("run_command", {"CommandLine": "echo foo > .github/workflows/mas.yml"})),
        ("ask: release.yml の write_file", "force_ask", run("write_file", {"Path": ".github/workflows/release.yml", "content": "name: Release\n"})),
        ("ask: mas.yml の edit_file", "force_ask", run("edit_file", {"Path": ".github/workflows/mas.yml", "old_string": "mode:\n", "new_string": "mode2:\n"})),
        # --- 枝葉: 判定不能入力は保守側で allow (hook で作業を止めない) ---
        ("allow: 空入力", "allow", decide({}, disk_text=None)),
    ]

    failures = 0
    for label, expected, (decision, _reason) in cases:
        ok = decision == expected
        status = "PASS" if ok else "FAIL"
        if not ok:
            failures += 1
        print(f"[{status}] {label}: expected={expected} actual={decision}")

    # 絶対パスのファイルが disk として読めること (hooks の cwd に依存しない解決)
    import tempfile
    probe_handle = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    probe_handle.write("pin-probe")
    probe_handle.close()
    abs_ok = _read_repo_file(probe_handle.name) == "pin-probe"
    os.unlink(probe_handle.name)
    status = "PASS" if abs_ok else "FAIL"
    if not abs_ok:
        failures += 1
    print(f"[{status}] meta: 絶対パスのファイルを disk として読める")

    total = len(cases) + 1
    print(f"\n{total - failures}/{total} cases PASS")
    if failures:
        print("SELF-TEST FAILED")
    else:
        print("SELF-TEST: ALL PASS")
    return 1 if failures else 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            emit("allow")
            return 0
        data = json.loads(raw)
    except Exception:
        # 判定不能の入力では作業を止めない (fail-open)
        emit("allow")
        return 0

    try:
        decision, reason = decide(data if isinstance(data, dict) else {})
    except Exception:
        decision, reason = "allow", None
    emit(decision, reason)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
