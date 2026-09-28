#!/usr/bin/env python3
"""リリースノート (markdown) を appcast の <description sparkle:format="html"> 用 HTML に変換する (issue #283)。

出力は Sparkle がそのまま要素内容にできる形 (**XML エスケープ済み** の HTML フラグメント)。
Sparkle 2 は releaseNotesLink 無しの場合に description の HTML を更新ダイアログの
Web ビューへ表示する (SUUpdateAlert.m — sparkle:format の既定は html)。
GitHub のリリースページを releaseNotesLink に指すと
ダイアログに GitHub UI 全体が読み込まれるため、リリースノートは appcast に
直接埋め込む (sign.sh から呼ばれる。単体でも動作確認できる)。

対応する markdown の subset (docs/release-notes/v<VERSION>.md の書き味):

- 見出し `#` / `##` / `###`
- 箇条書き `- ` (ネストは非対応)
- フェンスコードブロック ``` … ```
- 水平線 `---`
- インライン: **強調** / `コード` / [リンク](https://…) / ベア URL の自動リンク

使い方:

    render-release-notes.py [--fallback-message 文言] <markdown のパス>

- ファイルが無い場合 (workflow_dispatch の dry-run など) は --fallback-message を
  表示して成功で終わる — sign.sh を失敗させないため
- ファイルが空の場合は失敗する — 書き忘れ (空ファイルのコミット) を黙って
  通さないため。空の更新ダイアログよりリリースを止めて気付ける方がよい
"""

import argparse
import html
import re
import sys

# XML エスケープは最後に一回だけかける。中間の HTML は通常の HTML として
# 正しいこと (テキスト中の & < > は html_escape 済み) を保つ — Sparkle が
# XML を unescape したときに Web ビューへ渡るのはこの中間 HTML になる


def xml_escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def inline(text: str) -> str:
    # 先に HTML エスケープしてから markdown 記法を置換する。URL 中の " は
    # ここで &quot; になるため、後段の <a href="…"> 挿入で属性を破れない
    s = html.escape(text, quote=True)
    # インラインコードを先に処理する (コード内容に ** があっても強調しない)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', s)
    # 残ったベア URL の自動リンク。直前が " / = / < / > の URL (href 属性の中、
    # または既にリンク化済みのテキスト) は二重にリンクしない。\w を除外条件に
    # 入れない — 日本語の直後の URL («…はhttps://…») もリンク対象にするため
    s = re.sub(r'(?<!["=<>])(https?://[^\s<]+)', r'<a href="\1">\1</a>', s)
    return s


def render_markdown(md_text: str) -> str:
    out: list[str] = []
    in_list = False
    in_code = False
    code_fence_length = 0
    code_lines: list[str] = []
    para: list[str] = []

    def flush_para() -> None:
        if para:
            out.append("<p>" + inline("\n".join(para)) + "</p>")
            para.clear()

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    def close_code() -> None:
        # 未閉鎖のフェンスも黙って出力する (変換の失敗でリリースを止めない)
        nonlocal in_code
        if in_code:
            out.append("<pre><code>" + html.escape("\n".join(code_lines)) + "</code></pre>")
            code_lines.clear()
            in_code = False

    for raw_line in md_text.splitlines():
        line = raw_line.strip()
        if in_code:
            # 閉じフェンスは «開きフェンスと同数以上のバッククォートだけの行»
            # (CommonMark)。startswith で判定すると ```js のような内容行を
            # 閉じと誤認して、以降の行がコード外に出てしまう
            if re.fullmatch(rf"`{{{code_fence_length},}}", line):
                out.append("<pre><code>" + html.escape("\n".join(code_lines)) + "</code></pre>")
                code_lines.clear()
                in_code = False
            else:
                code_lines.append(raw_line)
            continue
        if line.startswith("```"):
            flush_para()
            close_list()
            code_fence_length = len(line) - len(line.lstrip("`"))
            in_code = True
            continue
        heading = re.match(r"^(#{1,3})\s+(.*)$", line)
        if heading:
            flush_para()
            close_list()
            level = len(heading.group(1))
            out.append(f"<h{level}>" + inline(heading.group(2)) + f"</h{level}>")
            continue
        item = re.match(r"^[-*]\s+(.*)$", line)
        if item:
            flush_para()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>" + inline(item.group(1)) + "</li>")
            continue
        if re.match(r"^-{3,}$", line):
            flush_para()
            close_list()
            out.append("<hr>")
            continue
        if line == "":
            flush_para()
            close_list()
            continue
        para.append(line)
    close_code()
    flush_para()
    close_list()
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="リリースノート (markdown) を XML エスケープ済み HTML に変換して stdout へ出力する")
    parser.add_argument("file", nargs="?", help="リリースノート (markdown) のパス")
    parser.add_argument(
        "--fallback-message",
        help="file が存在しないときに代わりに表示する文言 (URL は自動リンクになる)")
    args = parser.parse_args()

    if args.file is None:
        parser.print_usage(sys.stderr)
        return 64

    try:
        with open(args.file, encoding="utf-8") as f:
            md_text = f.read()
    except FileNotFoundError:
        if args.fallback_message is None:
            print(f"error: リリースノートが見つかりません: {args.file}", file=sys.stderr)
            return 66
        # ファイル無しは想定内 (dry-run、またはノートを書かないリリース) —
        # フォールバック文を表示して続行する
        print(xml_escape("<p>" + inline(args.fallback_message) + "</p>"))
        return 0

    if not md_text.strip():
        print(f"error: リリースノートが空です: {args.file}", file=sys.stderr)
        return 65

    print(xml_escape(render_markdown(md_text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
