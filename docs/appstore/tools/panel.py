# -*- coding: utf-8 -*-
"""kilde のメニューバーパネル (gui/Sources/ContentView.swift) を HTML/CSS で再現する。
実機キャプチャに差し替えるまでのドラフト用。寸法は SwiftUI 側の値に合わせてある
(パネル幅 380pt / padding 12 / セクション間 14 / 要素間 10)。"""

# --- SF Symbols の代替となるインライン SVG --------------------------------
def sym(name, color="currentColor", size=13):
    p = {
        "record": '<circle cx="8" cy="8" r="7" fill="none" stroke="%s" stroke-width="1.6"/><circle cx="8" cy="8" r="3.6" fill="%s"/>' % (color, color),
        "refresh": '<path d="M13.2 8a5.2 5.2 0 1 1-1.6-3.7" fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round"/><path d="M13.4 2.6V5.4H10.6" fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>' % (color, color),
        "display": '<rect x="1.5" y="2.5" width="13" height="9" rx="1.4" fill="none" stroke="%s" stroke-width="1.4"/><path d="M5.5 14h5" stroke="%s" stroke-width="1.4" stroke-linecap="round"/>' % (color, color),
        "folder": '<path d="M1.5 4.2A1.2 1.2 0 0 1 2.7 3h3.1l1.3 1.5h5.2a1.2 1.2 0 0 1 1.2 1.2v6.1a1.2 1.2 0 0 1-1.2 1.2H2.7a1.2 1.2 0 0 1-1.2-1.2z" fill="none" stroke="%s" stroke-width="1.4" stroke-linejoin="round"/>' % color,
        "keyboard": '<rect x="1" y="3.5" width="14" height="9" rx="1.6" fill="none" stroke="%s" stroke-width="1.4"/><path d="M4 6.4h.01M6.5 6.4h.01M9 6.4h.01M11.5 6.4h.01M4 9h.01M6.5 9h.01M9 9h.01M11.5 9h.01M5.5 11.3h5" stroke="%s" stroke-width="1.5" stroke-linecap="round"/>' % (color, color),
        "film": '<rect x="1.5" y="3" width="13" height="10" rx="1.3" fill="none" stroke="%s" stroke-width="1.4"/><path d="M4.6 3v10M11.4 3v10" stroke="%s" stroke-width="1.2"/>' % (color, color),
        "check": '<circle cx="8" cy="8" r="7" fill="%s"/><path d="M4.8 8.2l2.2 2.2 4.2-4.6" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>' % color,
        "stop": '<rect x="4" y="4" width="8" height="8" rx="1.3" fill="%s"/>' % color,
        "window": '<rect x="1.5" y="2.5" width="13" height="11" rx="1.6" fill="none" stroke="%s" stroke-width="1.4"/><path d="M1.5 5.6h13" stroke="%s" stroke-width="1.4"/>' % (color, color),
    }[name]
    return f'<svg class="sym" width="{size}" height="{size}" viewBox="0 0 16 16" aria-hidden="true">{p}</svg>'


def check(on=True):
    if on:
        return ('<span class="cb on"><svg width="9" height="9" viewBox="0 0 16 16">'
                '<path d="M3 8.4l3.2 3.2L13 4.4" fill="none" stroke="#fff" stroke-width="2.6" '
                'stroke-linecap="round" stroke-linejoin="round"/></svg></span>')
    return '<span class="cb"></span>'


def seg(options, active):
    items = "".join(
        f'<div class="seg-item{" active" if i == active else ""}">{o}</div>'
        for i, o in enumerate(options))
    return f'<div class="seg">{items}</div>'


def section(title, body):
    return f'<div class="sec"><div class="sec-t">{title}</div>{body}</div>'


def row(content, selected=False):
    return f'<div class="row{" sel" if selected else ""}">{content}</div>'


def meter(label, frac, color):
    return (f'<div class="meter"><div class="mlabel">{label}</div>'
            f'<div class="mtrack"><div class="mfill" style="width:{frac*100:.0f}%;background:{color}"></div></div></div>')


def header():
    return (f'<div class="hdr">{sym("record", "#FF3B30", 14)}<span class="hdr-t">kilde</span>'
            f'<span class="spacer"></span><span class="icon-btn">{sym("refresh", "#8A8F98", 13)}</span></div>')


# --- パネルの中身 3 種 -----------------------------------------------------

def panel_setup():
    """録画前の選択フォーム。画面 / システム音声+マイク / 1 トラック合成。"""
    body = header()
    body += section("収録対象", seg(["画面", "ウィンドウ", "音声のみ"], 0) + f'''
      <div class="list">
        {row(f'{sym("display","#C9CED6")}<span>ディスプレイ 0</span><span class="spacer"></span><span class="dim">3456×2234</span>', True)}
        {row(f'{sym("display","#C9CED6")}<span>ディスプレイ 1</span><span class="spacer"></span><span class="dim">2560×1440</span>')}
      </div>''')
    body += section("音声", f'''
      <div class="checks">
        <div class="ck">{check(True)}<span>システム音声 (相手の声・アプリの音)</span></div>
        <div class="ck">{check(True)}<span>マイク (既定の入力デバイス)</span></div>
        <div class="ck">{check(False)}<span>Shure MV7</span></div>
      </div>''')
    body += section("複数の音声ソース", seg(["1 トラックに合成", "ソースごとに分離"], 0))
    body += section("保存先", f'''
      <div class="line">{sym("folder","#C9CED6")}<span>~/Movies/kilde</span><span class="spacer"></span>
        <span class="btn">変更…</span></div>
      <div class="link">この音声・保存先の選択を既定にする</div>''')
    body += '<div class="startwrap">' + \
            f'<div class="start">{sym("record","#fff",15)}<span>録画開始</span></div></div>'
    return body


def panel_recording():
    """録画中。経過時間・出力サイズ・ソース別レベルメーター・停止。"""
    body = header()
    body += f'''
      <div class="sess">
        <div class="sess-top">
          <span class="dot"></span>
          <span class="elapsed">00:12:34</span>
          <span class="spacer"></span>
          <span class="dim">248.3 MB</span>
        </div>
        <div class="dim sm">kilde-20260916-142201.mp4</div>
        <div class="meters">
          {meter("システム音声", 0.62, "#34C759")}
          {meter("マイク", 0.84, "#FFCC00")}
          {meter("Shure MV7", 0.41, "#34C759")}
        </div>
        <div class="stop">{sym("stop","#fff",14)}<span>停止</span></div>
        <div class="dim sm wrap">ポップオーバーを閉じても録画は続きます。経過時間はメニューバーに表示されます</div>
      </div>'''
    return body


def panel_done():
    """保存完了 + ホットキー + 最近の録画。"""
    body = header()
    body += f'''
      <div class="result">
        <div class="ok">{sym("check","#30D158",14)}<span>保存しました</span></div>
        <div class="dim sm path">~/Movies/kilde/kilde-20260916-142201.mp4</div>
      </div>'''
    body += section("グローバルホットキー", f'''
      <div class="line">{sym("keyboard","#C9CED6")}
        <span class="field">cmd+shift+r</span><span class="btn">適用</span></div>
      <div class="dim sm wrap">他のアプリを使っている間でも、このキーで録画を開始・停止できます</div>''')
    body += section("最近の録画", f'''
      <div class="list plain">
        <div class="rr">{sym("film","#8A8F98")}<span>kilde-20260916-142201.mp4</span></div>
        <div class="rr">{sym("film","#8A8F98")}<span>kilde-20260915-101744.mp4</span></div>
        <div class="rr">{sym("film","#8A8F98")}<span>kilde-20260914-193012.m4a</span></div>
      </div>''')
    # 「アップデート」セクションは描かない — ここは MAS 版スクリーンショットのモックで、
    # 実機 (KildeGUI-AppStore) は更新 UI を持たない (ContentView.swift の #if !APPSTORE。
    # MAS では配信が App Store に一本化されるため)。提出画像が実物と一致しなくなる
    return body


def panel_audio_only():
    """音声のみモード。会議の音声だけを M4A で。"""
    body = header()
    body += section("収録対象", seg(["画面", "ウィンドウ", "音声のみ"], 2) +
                    '<div class="dim sm wrap pad">映像は録らず、音声だけを M4A に保存します</div>')
    body += section("音声", f'''
      <div class="checks">
        <div class="ck">{check(True)}<span>システム音声 (相手の声・アプリの音)</span></div>
        <div class="ck">{check(True)}<span>マイク (既定の入力デバイス)</span></div>
      </div>''')
    body += section("複数の音声ソース", seg(["1 トラックに合成", "ソースごとに分離"], 1))
    body += section("保存先", f'''
      <div class="line">{sym("folder","#C9CED6")}<span>~/Movies/kilde</span><span class="spacer"></span>
        <span class="btn">変更…</span></div>''')
    body += section("起動", f'<div class="ck">{check(True)}<span>ログイン時に kilde を起動する</span></div>')
    body += '<div class="startwrap">' + \
            f'<div class="start">{sym("record","#fff",15)}<span>録音開始</span></div></div>'
    return body


def panel_window():
    """ウィンドウ単位の収録。会議アプリのウィンドウだけを録る。"""
    body = header()
    # 他社の商標をスクリーンショットに写さない (App Store の審査で指摘されうる) ため、
    # ウィンドウ名とバンドル ID は一般名に置き換えてある
    rows = [("週次定例 — ビデオ会議", "com.example.meetings", True),
            ("設計レビュー — ビデオ会議", "com.example.meetings", False),
            ("提案資料 — プレゼンテーション", "com.example.slides", False)]
    lst = "".join(row(
        f'<span class="thumb">{sym("window","#6E747D",12)}</span>'
        f'<span class="wcol"><span class="wt">{t}</span><span class="wb">{b}</span></span>', s)
        for t, b, s in rows)
    body += section("収録対象", seg(["画面", "ウィンドウ", "音声のみ"], 1) + f'<div class="list">{lst}</div>')
    body += section("音声", f'''
      <div class="checks">
        <div class="ck">{check(True)}<span>システム音声 (相手の声・アプリの音)</span></div>
        <div class="ck">{check(True)}<span>マイク (既定の入力デバイス)</span></div>
      </div>
      <div class="dim sm wrap">ウィンドウ収録ではシステム音声もそのアプリの音だけになります</div>''')
    body += '<div class="startwrap">' + \
            f'<div class="start">{sym("record","#fff",15)}<span>録画開始</span></div></div>'
    return body
