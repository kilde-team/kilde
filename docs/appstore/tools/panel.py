# -*- coding: utf-8 -*-
"""kilde のメニューバーパネル (gui/Sources/ContentView.swift) と設定ウィンドウ
(gui/Sources/SettingsPaneView.swift) を HTML/CSS で再現する。
実機キャプチャに差し替えるまでのドラフト用。寸法は SwiftUI 側の値に合わせてある
(パネル幅 380pt / padding 12 / セクション間 14。設定ウィンドウは 400x560、
中身は width 340 + padding 12 / trailing 16)。

issue #478 でパネルが «日常操作» に絞られ、«1 回設定すればよい» 機能は設定
ウィンドウへ移設されたため、モックはパネルと設定ウィンドウの 2 種。描くのは
MAS ビルド (KildeGUI-AppStore) の実機と一致させる範囲だけ — 更新セクション
(#if !APPSTORE) のような直接配布版にしか無い UI は描かない。"""

# --- SF Symbols の代替となるインライン SVG --------------------------------
def sym(name, color="currentColor", size=13):
    p = {
        "record": '<circle cx="8" cy="8" r="7" fill="none" stroke="%s" stroke-width="1.6"/><circle cx="8" cy="8" r="3.6" fill="%s"/>' % (color, color),
        "refresh": '<path d="M13.2 8a5.2 5.2 0 1 1-1.6-3.7" fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round"/><path d="M13.4 2.6V5.4H10.6" fill="none" stroke="%s" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>' % (color, color),
        "gear": '<circle cx="8" cy="8" r="2.4" fill="none" stroke="%s" stroke-width="1.5"/><path d="M8 1.7l.8 1.9 2.1-.4.9 1.9 2 .6-.4 2 1.4 1.5-1.4 1.5.4 2-2 .6-.9 1.9-2.1-.4-.8 1.9-.8-1.9-2.1.4-.9-1.9-2-.6.4-2L1.5 8 2.9 6.5l-.4-2 2-.6.9-1.9 2.1.4z" fill="none" stroke="%s" stroke-width="1.1" stroke-linejoin="round"/>' % (color, color),
        "display": '<rect x="1.5" y="2.5" width="13" height="9" rx="1.4" fill="none" stroke="%s" stroke-width="1.4"/><path d="M5.5 14h5" stroke="%s" stroke-width="1.4" stroke-linecap="round"/>' % (color, color),
        "folder": '<path d="M1.5 4.2A1.2 1.2 0 0 1 2.7 3h3.1l1.3 1.5h5.2a1.2 1.2 0 0 1 1.2 1.2v6.1a1.2 1.2 0 0 1-1.2 1.2H2.7a1.2 1.2 0 0 1-1.2-1.2z" fill="none" stroke="%s" stroke-width="1.4" stroke-linejoin="round"/>' % color,
        "keyboard": '<rect x="1" y="3.5" width="14" height="9" rx="1.6" fill="none" stroke="%s" stroke-width="1.4"/><path d="M4 6.4h.01M6.5 6.4h.01M9 6.4h.01M11.5 6.4h.01M4 9h.01M6.5 9h.01M9 9h.01M11.5 9h.01M5.5 11.3h5" stroke="%s" stroke-width="1.5" stroke-linecap="round"/>' % (color, color),
        "film": '<rect x="1.5" y="3" width="13" height="10" rx="1.3" fill="none" stroke="%s" stroke-width="1.4"/><path d="M4.6 3v10M11.4 3v10" stroke="%s" stroke-width="1.2"/>' % (color, color),
        "check": '<circle cx="8" cy="8" r="7" fill="%s"/><path d="M4.8 8.2l2.2 2.2 4.2-4.6" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>' % color,
        "stop": '<rect x="4" y="4" width="8" height="8" rx="1.3" fill="%s"/>' % color,
        "window": '<rect x="1.5" y="2.5" width="13" height="11" rx="1.6" fill="none" stroke="%s" stroke-width="1.4"/><path d="M1.5 5.6h13" stroke="%s" stroke-width="1.4"/>' % (color, color),
        "lock": '<rect x="3.5" y="6.5" width="9" height="7.5" rx="1.6" fill="none" stroke="%s" stroke-width="1.5"/><path d="M5.5 6.5V5a2.5 2.5 0 0 1 5 0v1.5" fill="none" stroke="%s" stroke-width="1.5"/>' % (color, color),
        "app": '<rect x="2.5" y="2.5" width="11" height="11" rx="2.6" fill="none" stroke="%s" stroke-width="1.4"/><circle cx="8" cy="8" r="2" fill="%s"/>' % (color, color),
    }[name]
    return f'<svg class="sym" width="{size}" height="{size}" viewBox="0 0 16 16" aria-hidden="true">{p}</svg>'


def check(on=True):
    if on:
        return ('<span class="cb on"><svg width="9" height="9" viewBox="0 0 16 16">'
                '<path d="M3 8.4l3.2 3.2L13 4.4" fill="none" stroke="#fff" stroke-width="2.6" '
                'stroke-linecap="round" stroke-linejoin="round"/></svg></span>')
    return '<span class="cb"></span>'


def tog(label, on=True):
    """チェックボックスのトグル行 (SwiftUI の Toggle .checkbox)。"""
    return f'<div class="ck">{check(on)}<span>{label}</span></div>'


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


def lockrow(label):
    """Pro のロック行 (summaryLockRow / composerInstructionsLockRow)。
    lock アイコン + ラベル + 右端の «Pro» バッジ。クリックで購入導線が開く。"""
    return (f'<div class="lockrow">{sym("lock", "#8A8F98", 12)}<span>{label}</span>'
            f'<span class="spacer"></span><span class="probadge">Pro</span></div>')


def header(recording=False):
    """ヘッダー。録画中は一覧更新 (refresh) を出さない (ContentView の !recording.isActive)。"""
    refresh = "" if recording else f'<span class="icon-btn">{sym("refresh", "#8A8F98", 13)}</span>'
    return (f'<div class="hdr">{sym("record", "#FF3B30", 14)}<span class="hdr-t">kilde</span>'
            f'<span class="spacer"></span>{refresh}'
            f'<span class="icon-btn">{sym("gear", "#8A8F98", 13)}</span></div>')


# --- パネルの中身 ----------------------------------------------------------

def panel_setup():
    """録画前の選択フォーム (issue #478 でスリム化)。画面 / システム音声+マイク /
    文字起こしトグル / 保存先。«複数の音声ソース» は設定ウィンドウへ移設済み。"""
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
        <div class="ck appmenu">{sym("app", "#C9CED6", 13)}<span>アプリの音声を選ぶ…</span><span class="spacer"></span><span class="dim sm">▾</span></div>
      </div>''')
    body += section("文字起こし", f'''
      <div class="checks">
        <div class="ck">{check(True)}<span>録画後に文字起こし</span></div>
      </div>
      <div class="dim sm wrap">録画が終わると自動で文字起こしします</div>''')
    body += section("保存先", f'''
      <div class="line">{sym("folder","#C9CED6")}<span>~/Movies</span><span class="spacer"></span>
        <span class="btn">変更…</span></div>
      <div class="link">この音声・保存先の選択を既定にする</div>''')
    body += '<div class="startwrap">' +             f'<div class="start">{sym("record","#fff",15)}<span>録画開始</span></div></div>'
    return body


def panel_recording():
    """録画中。経過時間・出力サイズ・ソース別レベルメーター・停止。
    パネルを閉じても録画は続く (メニューバーに経過時間)。"""
    body = header(recording=True)
    body += f'''
      <div class="sess">
        <div class="sess-top">
          <span class="dot"></span>
          <span class="elapsed">00:12:34</span>
          <span class="spacer"></span>
          <span class="dim">248.3 MB</span>
        </div>
        <div class="dim sm">kilde-20261101-142201.mp4</div>
        <div class="meters">
          {meter("システム音声", 0.62, "#34C759")}
          {meter("マイク", 0.84, "#FFCC00")}
        </div>
        <div class="stop">{sym("stop","#fff",14)}<span>停止</span></div>
        <div class="dim sm wrap">ポップオーバーを閉じても録画は続きます。経過時間はメニューバーに表示されます</div>
      </div>'''
    return body


def panel_done():
    """保存完了 + 最近の録画。ホットキーは設定ウィンドウへ移設された (issue #478)。"""
    body = header()
    # «フォルダを開く» と行右端のフォルダアイコンは resultView / recentRecordings
    # (gui/Sources/ContentView.swift) の issue #296 での追加を再現する
    body += f'''
      <div class="result">
        <div class="ok">{sym("check","#30D158",14)}<span>保存しました</span></div>
        <div class="dim sm path">~/Movies/kilde-20261101-142201.mp4</div>
        <div class="link">フォルダを開く</div>
      </div>'''
    body += section("最近の録画", f'''
      <div class="list plain">
        <div class="rr">{sym("film","#8A8F98")}<span>kilde-20261101-142201.mp4</span><span class="spacer"></span>{sym("folder","#8A8F98",12)}</div>
        <div class="rr">{sym("film","#8A8F98")}<span>kilde-20261031-101744.mp4</span><span class="spacer"></span>{sym("folder","#8A8F98",12)}</div>
        <div class="rr">{sym("film","#8A8F98")}<span>kilde-20261030-193012.m4a</span><span class="spacer"></span>{sym("folder","#8A8F98",12)}</div>
      </div>''')
    # 「アップデート」セクションは描かない — ここは MAS 版スクリーンショットのモックで、
    # 実機 (KildeGUI-AppStore) は更新 UI を持たない (ContentView.swift の #if !APPSTORE。
    # MAS では配信が App Store に一本化されるため)。提出画像が実物と一致しなくなる
    return body


def panel_transcribe():
    """録画直後。保存完了 + 自動文字起こしの完了 (.md サイドカー) + 文字起こしと
    Pro のロック行。文字起こしの詳細 (言語・形式) は設定ウィンドウへ移設済み
    (issue #478)。MAS + 未購入の実機に合わせ、要約とカスタム指示は «Pro» バッジの
    ロック行で描く (ロック行のクリックで購入導線が開く)。
    訴求は実装の保証範囲内に留める: 自動文字起こしは macOS 26 以降
    (Transcriber.isSupported)、処理は端末内 (review-notes.md の記載と一致)。"""
    body = header()
    body += f'''
      <div class="result">
        <div class="ok">{sym("check","#30D158",14)}<span>保存しました</span></div>
        <div class="dim sm path">~/Movies/kilde-20261101-142201.mp4</div>
        <div class="link">フォルダを開く</div>
      </div>'''
    # transcriptionStatusView の lastCompletion。録画ファイルの隣に .md が同步する
    body += f'''
      <div class="line">{sym("check","#30D158",13)}<span class="sm">kilde-20261101-142201.md</span>
        <span class="spacer"></span><span class="link" style="margin-top:0">Finder で表示</span></div>'''
    body += section("文字起こし", f'''
      <div class="checks">
        <div class="ck">{check(True)}<span>録画後に文字起こし</span></div>
      </div>
      {lockrow("録画後に要約も作る")}
      {lockrow("要約とフォローアップのカスタム指示")}
      <div class="dim sm wrap">録画が終わると自動で文字起こしします</div>''')
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
    body += section("文字起こし", f'''
      <div class="checks">
        <div class="ck">{check(False)}<span>録画後に文字起こし</span></div>
      </div>''')
    body += '<div class="startwrap">' +             f'<div class="start">{sym("record","#fff",15)}<span>録画開始</span></div></div>'
    return body


def panel_audio_only():
    """音声のみモード。会議の音声だけを M4A で。«起動» (ログイン時起動) は
    設定ウィンドウへ移設されたため描かない (issue #478)。"""
    body = header()
    body += section("収録対象", seg(["画面", "ウィンドウ", "音声のみ"], 2) +
                    '<div class="dim sm wrap pad">映像は録らず、音声だけを M4A に保存します</div>')
    body += section("音声", f'''
      <div class="checks">
        <div class="ck">{check(True)}<span>システム音声 (相手の声・アプリの音)</span></div>
        <div class="ck">{check(True)}<span>マイク (既定の入力デバイス)</span></div>
      </div>''')
    body += section("保存先", f'''
      <div class="line">{sym("folder","#C9CED6")}<span>~/Movies</span><span class="spacer"></span>
        <span class="btn">変更…</span></div>''')
    body += '<div class="startwrap">' +             f'<div class="start">{sym("record","#fff",15)}<span>録音開始</span></div></div>'
    return body


# --- 設定ウィンドウ (SettingsPaneView、ライト外観) --------------------------

def _win_pick(label, value):
    return (f'<div class="wline"><span class="wlab">{label}</span>'
            f'<span class="wpick">{value}<span class="car">▾</span></span></div>')


def settings_pane():
    """設定ウィンドウの中身 (SettingsPaneView.swift の再現)。«1 回設定すればよい»
    項目の集約先。実ウィンドウ (560pt) はスクロールするため、ドラフトは主要セクション
    のみを描く — README «モックは全セクションを描かない» の方針。«録音の告知文» と
    «アプリを応援» は縦に長い / 商品名が ASC の取得値のため省略した。"""
    b = section("録音", seg(["1 トラックに合成", "ソースごとに分離"], 0) +
                '<div class="dim sm wrap">ソースごとに分離すると、システム音声・マイク・入力デバイスが別トラックで保存されます</div>')
    b += section("文字起こしの詳細", (
        _win_pick("言語", "端末の言語設定")
        + _win_pick("出力形式", "Markdown (.md)")
        + '<div class="wline"><span class="wlab">議事録の書き出し先</span><span class="spacer"></span>'
          '<span class="dim">なし</span><span class="btn light">変更…</span></div>'
        + '<div class="wdisc"><span class="car2">▸</span> カスタム指示</div>'
        + '<div class="dim sm wrap">要約とフォローアップの下書きの生成に反映されます (端末内処理)</div>'))
    b += section("グローバルホットキー", f'''
      <div class="wline">{sym("keyboard", "#6E747D", 14)}
        <span class="wfield">cmd+shift+r</span><span class="btn light">適用</span></div>
      <div class="dim sm wrap">他のアプリを使っている間でも、このキーで録画を開始・停止できます</div>''')
    b += section("起動", tog("ログイン時に kilde を起動する", True))
    b += section("会議の自動録画", f'''
      <div class="ck2">
        <div class="ck">{check(True)}<span>会議を検知したら会議ウィンドウを自動で録画する</span></div>
        <div class="ck sub">{check(False)}<span>カレンダーの予定名を録画ファイル名に使う</span></div>
      </div>
      <div class="dim sm wrap">会議アプリでマイクが使われ始めたら、その会議ウィンドウだけを録画し、ウィンドウを閉じると停止します</div>''')
    b += section("プライバシー", tog("アプリの利用統計とクラッシュレポートを送信する", True) +
                 '<div class="dim sm wrap">録画や文字起こしの内容・ファイル名は含まれません</div>')
    return b
