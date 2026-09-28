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


# 生成済み HTML は \x00数字\x00 のプレースホルダで退避する — 後続の置換が
# コード span の内容やリンクの href を再解釈しないようにするため
_PLACEHOLDER = re.compile(r"\x00(\d+)\x00")


def inline(text: str) -> str:
    # 先に HTML エスケープしてから markdown 記法を置換する。URL 中の " は
    # ここで &quot; になるため、後段の <a href="…"> 挿入で属性を破れない
    s = html.escape(text, quote=True)
    protected: list[str] = []

    def stash(fragment: str) -> str:
        protected.append(fragment)
        return f"\x00{len(protected) - 1}\x00"

    # 1) コード span を最初に退避する (内容に ** や URL があっても
    #    太字化・リンク化されない)
    s = re.sub(r"`([^`]+)`", lambda m: stash(f"<code>{m.group(1)}</code>"), s)

    # 2) markdown リンク。href は生成後に退避し、本文中で二重に
    #    リンク化されないようにする。ラベルには太字だけを適用する
    #    (ラベル内の URL は既に <a> の中 — 自動リンクしない)。
    #    href の括弧は 1 段のバランスを許す (Wikipedia の
    #    «…_(言語)» 形式の URL を壊さないため)
    def markdown_link(m: re.Match) -> str:
        label = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", m.group(1))
        return stash(f'<a href="{m.group(2)}">{label}</a>')

    s = re.sub(
        r"\[([^\]]+)\]\((https?://[^()\s]*(?:\([^()\s]*\)[^()\s]*)*)\)",
        markdown_link,
        s,
    )

    # 3) 太字 (残りの素のテキストが対象)。生成した <strong> タグも退避する —
    #    タグの中の «/» «>» は URL の文字クラスに含まれるため、退避しないと
    #    直後の URL 自動リンクが閉じタグを呑み込む («**詳細: https://…**»)
    s = re.sub(
        r"\*\*([^*]+)\*\*",
        lambda m: stash("<strong>") + m.group(1) + stash("</strong>"),
        s,
    )

    # 4) ベア URL の自動リンク。この時点で生成済み HTML はプレースホルダに
    #    なっているため、href やリンクラベルを再走査しない。
    #    URL 本体は印字可能 ASCII に限る — 日本語文 («…path。次の文») が
    #    空白を挟まず URL に続いても、そこで URL が止まる
    def autolink(m: re.Match) -> str:
        url = m.group(0)
        trail = ""
        # 末尾の句読点は文の一部で URL に含まれないことが多い — 分離する。
        # 括弧は対応する開き括弧が URL 内に無い場合だけ分離する
        # (Wikipedia の «…_(言語)» のような URL を壊さないため)
        while url:
            last = url[-1]
            if last in ".,;:!?":
                trail = last + trail
                url = url[:-1]
            elif last in ")]" and url.count(last) > url.count("(" if last == ")" else "["):
                trail = last + trail
                url = url[:-1]
            else:
                break
        if not url:
            url, trail = m.group(0), ""
        return f'<a href="{url}">{url}</a>{trail}'

    s = re.sub(r"https?://[\x21-\x7e]+", autolink, s)

    return _PLACEHOLDER.sub(lambda m: protected[int(m.group(1))], s)


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

    # XML 1.0 で要素内容に書けない制御文字 (タブ・改行・復帰以外) を拒否する —
    # そのまま appcast に入ると整形式でない XML が生成され、Sparkle の
    # 更新フィード全体が壊れる
    FORBIDDEN_XML_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")

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

    if (bad := FORBIDDEN_XML_CHARS.search(md_text)) is not None:
        print(
            f"error: リリースノートに XML で使えない制御文字 (0x{ord(bad.group(0)):02x}) が"
            f"含まれています: {args.file} — 該当文字を削除してください",
            file=sys.stderr,
        )
        return 65

    print(xml_escape(render_markdown(md_text)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
