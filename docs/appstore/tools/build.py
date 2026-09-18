# -*- coding: utf-8 -*-
"""Mac App Store 用スクリーンショット (2880x1800) を組み立てる。
1440x900 の CSS ピクセルで作り、device_scale_factor=2 で 2x 出力する。"""
import asyncio, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import panel
from playwright.async_api import async_playwright

HERE = pathlib.Path(__file__).parent
# スクリーンショットは README §2 が管理する screenshots/ へ直接書き出す
# (カレントディレクトリに依存しない)。コミット前に 256 色へ最適化する手順は README §3
OUT = HERE.parent / "screenshots"
OUT.mkdir(exist_ok=True)
ICON = HERE.parent / "png" / "icon_1024.png"

CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
body { width: 1440px; height: 900px; overflow: hidden;
  font-family: "Noto Sans CJK JP", "Helvetica Neue", sans-serif;
  -webkit-font-smoothing: antialiased; }
.stage { position: relative; width: 1440px; height: 900px;
  background: linear-gradient(155deg, #2C3543 0%, #1B222C 45%, #10151C 100%); overflow: hidden; }
/* 背景の淡い赤いにじみ — アイコンの録画ドットと呼応させる */
.stage::before { content:""; position:absolute; width:900px; height:900px; left:-220px; top:-340px;
  background: radial-gradient(circle, rgba(255,59,48,.20) 0%, rgba(255,59,48,0) 66%); }
.stage::after { content:""; position:absolute; width:820px; height:820px; right:-260px; bottom:-320px;
  background: radial-gradient(circle, rgba(90,140,255,.16) 0%, rgba(90,140,255,0) 68%); }
.copy { position: absolute; left: 92px; top: 0; height: 900px; width: 620px; z-index: 5;
  display:flex; flex-direction:column; justify-content:center; }
.eyebrow { display:inline-flex; align-items:center; gap:10px; margin-bottom: 22px;
  font-size: 15px; letter-spacing:.14em; color:#98A0AC; font-weight:600; }
.eyebrow img { width: 30px; height: 30px; }
h1 { font-size: 46px; line-height: 1.32; color: #F5F7FA; font-weight: 700; letter-spacing:-.01em;
  word-break: keep-all; line-break: strict; overflow-wrap: normal; }
h1 .hl { color: #FF6259; }
p.sub { margin-top: 24px; font-size: 19px; line-height: 1.8; color: #A7AFBB; font-weight: 400; word-break: keep-all; line-break: strict; }
ul.pts { margin-top: 30px; list-style:none; }
ul.pts li { font-size: 17px; color:#C2C9D3; margin-bottom: 13px; padding-left: 28px; position: relative; }
ul.pts li::before { content:""; position:absolute; left:4px; top:8px; width:8px; height:8px;
  border-radius:50%; background:#FF3B30; }

/* --- デスクトップのモック ------------------------------------------- */
.mac { position:absolute; right: 70px; top: 50%; transform: translateY(-50%); width: 622px;
  border-radius: 14px; overflow: hidden; background: linear-gradient(160deg,#5C6B86,#33405A 60%,#222C40);
  box-shadow: 0 40px 90px rgba(0,0,0,.52), 0 0 0 1px rgba(255,255,255,.09); }
.menubar { height: 26px; background: rgba(22,26,33,.72); backdrop-filter: blur(12px);
  display:flex; align-items:center; padding: 0 12px; gap: 16px;
  font-size: 12px; color: #E4E7EC; border-bottom: 1px solid rgba(255,255,255,.07); }
.menubar .mb-app { font-weight: 700; }
.menubar .spacer { flex: 1; }
.menubar .mb-k { display:flex; align-items:center; gap:5px; padding: 2px 7px; border-radius: 5px;
  background: rgba(255,255,255,.16); font-variant-numeric: tabular-nums; }
.menubar .mb-k img { width: 14px; height: 14px; }
.menubar .mb-dot { width:7px; height:7px; border-radius:50%; background:#FF3B30; }

/* --- ポップオーバー (ContentView, 幅 380pt) --------------------------- */
.desk { padding: 30px 26px 40px; display:flex; justify-content:flex-end; }
.pop { position:relative; width: 380px; zoom: 1.16;
  background: rgba(40,44,52,.975); border-radius: 12px; padding: 12px;
  color: #E8EAEE; font-size: 13px;
  box-shadow: 0 22px 52px rgba(0,0,0,.55), 0 0 0 .5px rgba(255,255,255,.14); }
.pop::before { content:""; position:absolute; top:-7px; right: 40px; width:16px; height:16px;
  background: rgba(40,44,52,.975); transform: rotate(45deg); border-radius:3px; }
.sym { flex: none; display:block; }
.spacer { flex: 1; }
.hdr { display:flex; align-items:center; gap:7px; margin-bottom: 12px; }
.hdr-t { font-size: 14px; font-weight: 700; }
.icon-btn { opacity:.85; }
.sec { margin-bottom: 14px; }
.sec-t { font-size: 11px; color:#8A8F98; font-weight:600; margin-bottom: 6px; }
.seg { display:flex; background: rgba(255,255,255,.08); border-radius: 7px; padding: 2px; gap:2px; }
.seg-item { flex:1; text-align:center; padding: 4px 2px; border-radius: 5px; font-size: 12px; color:#C7CCD4; }
.seg-item.active { background: #6B7280; color:#fff; box-shadow: 0 1px 2px rgba(0,0,0,.3); }
.list { margin-top: 7px; display:flex; flex-direction:column; gap: 3px; }
.row { display:flex; align-items:center; gap:7px; padding: 5px 7px; border-radius: 6px; }
.row.sel { background: rgba(10,110,255,.85); }
.row.sel .dim, .row.sel .wb { color: rgba(255,255,255,.8); }
.dim { color:#8A8F98; }
.sm { font-size: 11px; }
.wrap { line-height: 1.55; margin-top: 5px; }
.pad { padding: 4px 2px 0; }
.checks { display:flex; flex-direction:column; gap:6px; }
.ck { display:flex; align-items:center; gap:7px; }
.cb { width:13px; height:13px; border-radius:3.5px; border:1px solid #7C838E; flex:none;
  display:flex; align-items:center; justify-content:center; }
.cb.on { background:#0A6EFF; border-color:#0A6EFF; }
.line { display:flex; align-items:center; gap:7px; }
.btn { padding: 3px 9px; border-radius: 6px; background: rgba(255,255,255,.14); font-size:12px; }
.field { flex:1; padding: 3px 8px; border-radius: 6px; background: rgba(0,0,0,.28);
  border: 1px solid rgba(255,255,255,.14); font-size:12px; }
.link { margin-top: 6px; font-size: 11px; color:#4EA1FF; }
.startwrap { margin-top: 4px; }
.start, .stop { display:flex; align-items:center; justify-content:center; gap:7px;
  padding: 8px; border-radius: 8px; font-size: 14px; font-weight: 600; color:#fff; }
.start { background: linear-gradient(#FF4A40,#E7352B); box-shadow: 0 1px 3px rgba(0,0,0,.35); }
.stop  { background: linear-gradient(#3B8BFF,#0A6EFF); box-shadow: 0 1px 3px rgba(0,0,0,.35); }
/* 録画中 */
.sess { display:flex; flex-direction:column; gap: 10px; }
.sess-top { display:flex; align-items:center; gap:9px; }
.sess-top .dot { width:10px; height:10px; border-radius:50%; background:#FF3B30; flex:none; }
.elapsed { font-size: 28px; font-weight: 500;
  font-family: "DejaVu Sans Mono", ui-monospace, monospace; font-variant-numeric: tabular-nums; }
.meters { display:flex; flex-direction:column; gap:5px; }
.meter { display:flex; align-items:center; gap:6px; }
.mlabel { width: 110px; font-size: 11px; color:#C7CCD4; }
.mtrack { flex:1; height: 8px; border-radius: 3px; background: rgba(255,255,255,.16); overflow:hidden; }
.mfill { height:100%; border-radius: 3px; }
/* 結果 */
.result { margin-bottom: 14px; display:flex; flex-direction:column; gap:3px; }
.ok { display:flex; align-items:center; gap:7px; color:#30D158; font-weight:600; }
.path { word-break: break-all; }
.list.plain { gap: 4px; }
.rr { display:flex; align-items:center; gap:7px; padding: 2px 0; }
.thumb { width: 42px; height: 26px; border-radius: 4px; background: rgba(255,255,255,.13);
  display:flex; align-items:center; justify-content:center; flex:none; }
.wcol { display:flex; flex-direction:column; gap:1px; min-width:0; }
.wt { font-size: 12.5px; }
.wb { font-size: 10.5px; color:#8A8F98; }
"""

def page(eyebrow, h1, sub, points, body, icon_uri, menubar_recording=False):
    mb = (f'<span class="mb-k"><span class="mb-dot"></span>00:12:34</span>'
          if menubar_recording else
          f'<span class="mb-k"><img src="{icon_uri}"></span>')
    pts = "".join(f"<li>{p}</li>" for p in points)
    return f"""<html><head><meta charset="utf-8"><style>{CSS}</style></head><body>
<div class="stage">
  <div class="copy">
    <div class="eyebrow"><img src="{icon_uri}">KILDE for macOS</div>
    <h1>{h1}</h1>
    <p class="sub">{sub}</p>
    <ul class="pts">{pts}</ul>
  </div>
  <div class="mac">
    <div class="menubar">
      <span class="mb-app">Finder</span><span>ファイル</span><span>編集</span><span>表示</span>
      <span class="spacer"></span>{mb}<span>100%</span><span>14:22</span>
    </div>
    <div class="desk"><div class="pop">{body}</div></div>
  </div>
</div></body></html>"""


SHOTS = [
    dict(name="01-capture-system-and-mic",
         h1='システム音声とマイクを、<br><span class="hl">1 本のファイル</span>に。',
         sub="QuickTime では録れない「相手の声」を、自分の声と一緒に。メニューバーからワンクリックで。",
         points=["画面・ウィンドウ・音声のみを選んで収録",
                 "1 トラック合成／ソースごとに分離を切り替え",
                 "選んだ音声と保存先は次回も保持"],
         body=panel.panel_setup()),
    dict(name="02-recording",
         h1='録画中も、<br><span class="hl">メニューバーだけ</span>。',
         sub="経過時間・ファイルサイズ・ソースごとの入力レベルをその場で確認。パネルを閉じても録画は続きます。",
         points=["ソース別レベルメーターで録り逃しを防ぐ",
                 "経過時間はメニューバーに常時表示",
                 "グローバルホットキーで他アプリからでも停止"],
         body=panel.panel_recording(), menubar_recording=True),
    dict(name="03-window-capture",
         h1='会議アプリの<br><span class="hl">ウィンドウだけ</span>を録る。',
         sub="収録したいウィンドウを選べば、そのアプリの音声だけがきれいに入ります。デスクトップ全体を映す必要はありません。",
         points=["ウィンドウ一覧はサムネイル付き",
                 "そのアプリの音声だけを収録",
                 "デスクトップ全体を映さずに共有できる"],
         body=panel.panel_window()),
    dict(name="04-audio-only",
         h1='音声だけを、<br><span class="hl">M4A</span> で残す。',
         sub="打ち合わせの記録や文字起こし用途なら、映像を録らずに音声のみ。ファイルは小さく、扱いやすく。",
         points=["映像なし・音声のみの収録モード",
                 "ソースごとに分離して書き出せる",
                 "ログイン時に自動起動して録り逃さない"],
         body=panel.panel_audio_only()),
    dict(name="05-safe-finish",
         h1='停止しても終了しても、<br><span class="hl">壊れたファイルを残さない</span>。',
         sub="停止ボタンでも、メニューからの終了でも。書き込み中のファイルは仕上げてから終了します。",
         points=["停止・アプリ終了のどちらでもファイナライズ",
                 "最近の録画から Finder へワンクリック",
                 "オープンソース (MIT) / データ収集なし"],
         body=panel.panel_done()),
]


async def main():
    import base64
    icon_uri = "data:image/png;base64," + base64.b64encode(ICON.read_bytes()).decode()
    async with async_playwright() as p:
        b = await p.chromium.launch()
        pg = await b.new_page(viewport={"width": 1440, "height": 900}, device_scale_factor=2)
        # 描画フォントは実行環境に依存する (CSS の font-family は "Noto Sans CJK JP" →
        # "Helvetica Neue" → sans-serif)。入っていない環境で再生成すると字幅と改行が
        # 変わり、同じ絵にならない。**黙って別物を作らない**ために警告を出す
        # (cubic レビュー指摘)。リポジトリ同梱は Noto CJK が 16MB 級で割に合わないため、
        # 「気づける」ことで担保する
        # `document.fonts.check()` は **フォントが無くても true を返す** のが仕様
        # (W3C CSS Font Loading §3.3)。実測でも、このフォントが入っていない Mac で
        # 警告が出なかった。`FontFace` で local() を実際にロードして判定する
        # (Codex レビュー指摘)
        await pg.set_content('<html><body>x</body></html>')
        probe = '''(async () => {
          try { await new FontFace('ProbeCJK', 'local("Noto Sans CJK JP")').load(); return true; }
          catch (e) { return false; }
        })()'''
        if not await pg.evaluate(probe):
            print('warning: "Noto Sans CJK JP" が見つかりません — 字形と改行が'
                  'コミット済みのスクリーンショットと変わります', file=sys.stderr)
        for s in SHOTS:
            await pg.set_content(page(None, s["h1"], s["sub"], s["points"], s["body"],
                                      icon_uri, s.get("menubar_recording", False)))
            await pg.wait_for_timeout(180)
            await pg.screenshot(path=str(OUT / f"{s['name']}.png"))
        await b.close()
    print([p.name for p in sorted(OUT.glob("*.png"))])

asyncio.run(main())
