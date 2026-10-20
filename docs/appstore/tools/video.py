# -*- coding: utf-8 -*-
"""プロモ動画 (60 秒マスター ja/en + App Store プレビュー 30 秒 ja/en) を生成する。

docs/launch/demo-video.md の絵コンテ・文面ルールに基づく。実機撮影の代わりに
build.py と同じモック (panel.py) を 30fps でフレーム単位に描画し、ffmpeg で
H.264 に組み立てる。すべてのアニメーションはフレーム番号 (時刻 t) から
決定論的に計算する — CSS アニメーション (実時間依存) は再現性を壊すので
一切使わない (UI を変えた再生成・CI での同一成果物の両方に効く)。

事前に icon.py と render.py を一度実行して png/icon_1024.png を作っておく
(README §3 の手順)。

使い方:
  python3 video.py --stills                # 各シーンの代表フレームだけ (確認・OCR 検証用)
  python3 video.py                         # 4 本すべて
  python3 video.py --only master-ja        # 1 本だけ
出力先は docs/appstore/video/ (コミットしない — README §2 のとおり素材は
kilde-site 側で管理する)。
"""
import argparse, asyncio, base64, json, pathlib, subprocess, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import panel
from playwright.async_api import async_playwright

HERE = pathlib.Path(__file__).parent
OUT = HERE.parent / "video"          # mp4 とフレーム (中間成果物。コミットしない)
ICON = HERE.parent / "png" / "icon_1024.png"
FPS = 30

# --- タイムライン (秒) -----------------------------------------------------
# 60 秒マスター = demo-video.md のショット 1〜8 (尺は調整)。App Store 版は
# ショット 1〜5 の短縮 + エンドカード (URL ではなくアプリ名のみ — 絵コンテの指定)。
TL_MASTER = [("hook", 4.0), ("nobot", 6.0), ("start", 7.0), ("recording", 8.0),
             ("stop", 7.0), ("transcript", 9.0), ("summary", 7.0), ("export", 6.0),
             ("endcard", 6.0)]
TL_APPSTORE = [("hook", 2.5), ("nobot", 4.0), ("start", 5.0), ("recording", 6.0),
               ("stop", 4.5), ("transcript", 5.0), ("endcard30", 2.9)]
MAKES = {"master": TL_MASTER, "appstore": TL_APPSTORE}

# --- 文言 (ja / en) --------------------------------------------------------
# キャプションは demo-video.md の字幕を踏襲。主張は README / DESIGN.md の
# 保証範囲内のみ («内容が端末外へ出ない» は文字起こし・要約の処理に限定して言う)。
def hl(s):
    return s.replace("<hl>", '<span class="hl">').replace("</hl>", "</span>")

CAPTIONS = {
    "hook": dict(ja=hl('会議も、その声も、<hl>まるごと</hl>。'),
                 en='The whole meeting.<br><span class="hl">Every voice</span>.'),
    "nobot": dict(ja=hl('会議に、<hl>ボットは要らない</hl>。'),
                  en='<span class="hl">No bots</span> in your meetings.'),
    "start": dict(ja=hl('ワンクリックで<hl>録画開始</hl>。<br>システム音声もマイクも。'),
                  en='<span class="hl">One click</span>. System audio and your mic.'),
    "recording": dict(ja=hl('相手の声も自分の声も、<br><hl>1 つのファイル</hl>に。'),
                      en='Their voice and yours, <span class="hl">in one file</span>.'),
    "stop": dict(ja=hl('止めた瞬間に<hl>ファイナライズ</hl>。<br>完成したら通知。'),
                 en='Hit <span class="hl">stop</span> — it finalizes, then tells you.'),
    "transcript": dict(ja=hl('トラックを分けて録ると、<br>文字起こしに<hl>話者ラベル</hl>。'),
                       en='Split tracks, <span class="hl">labeled transcripts</span>.'),
    "summary": dict(ja=hl('要約も自動で、<hl>端末内</hl>。<br>内容は外に出ません。'),
                    en='Summaries too, <span class="hl">on device</span>.'),
    "export": dict(ja=hl('議事録は指定フォルダへ<hl>自動書き出し</hl>。'),
                   en='Minutes <span class="hl">auto-export</span> to your folder.'),
}
# 条件付き機能のキャプションには小さめの注記行を添える — 大きな字幕に OS バージョンを
# 織り込むと読みにくくなるため (cubic レビュー指摘への対応)
CAPTION_NOTES = {
    "transcript": dict(ja="文字起こしには macOS 26 以降が必要です",
                       en="Transcription requires macOS 26 or later"),
    "summary": dict(ja="要約には Apple Intelligence が有効な Mac が必要です",
                    en="Summaries need Apple Intelligence"),
}
TAGLINE = dict(ja="会議を録って、議事録まで。", en="Record the meeting. Keep the minutes.")
# App Store 版エンドカードの文言は製品ページのサブタイトルと同一にする (訴求の統一)
SUBTITLE = dict(ja="システム音声ごと録って文字起こし", en="Record & transcribe meetings")
CONSENT = dict(ja="録画の同意は、あなたの責任で。", en="Recording consent is your responsibility.")

# 文字起こしウィンドウの中身 (ダミー会議 «週次定例›。実在の話題・製品名を出さない —
# demo-video.md の撮影チェックリストと同じ規約)
MD_META = "2026-10-20 · kilde-20261020-143201"
MD_TITLE = dict(ja="議事録 — 週次定例", en="Minutes — Weekly sync")
MD_LINES = {
    "ja": [("相手", "おつかれさまです。今週の進捗から共有します。"),
           ("自分", "新しい収集フローは検証が終わっていて、今週中に切り替えます。"),
           ("相手", "承知しました。切り替え後にログを確認しましょう。"),
           ("自分", "次のマイルストーンは来週のレビューです。"),
           ("相手", "では、次回はそこを中心に進めます。"),
           ("自分", "わかりました。よろしくお願いします。")],
    "en": [("相手", "Hi everyone — let's start with this week's progress."),
           ("自分", "The new collection flow is verified. We switch this week."),
           ("相手", "Sounds good. Let's check the logs right after."),
           ("自分", "The next milestone is next week's review."),
           ("相手", "Then we'll focus there next time."),
           ("自分", "Great, thanks everyone.")],
}
SPK = {"相手": "them", "自分": "me"}
# 話者ラベルの表示文言は言語ごとに変える (en 版で日本語ラベルが残らないように —
# cubic レビュー指摘)。色分け (them/me クラス) は ja/en 共通
SPK_TEXT = {"ja": {"相手": "相手", "自分": "自分"}, "en": {"相手": "Them", "自分": "Me"}}
MD_SUMMARY = {
    "ja": ["収集フローの切り替えを今週中に完了する", "切り替え後にログを確認する",
           "次のマイルストーンは来週のレビュー"],
    "en": ["Finish switching the collection flow this week",
           "Check the logs right after the switch",
           "Next milestone: next week's review"],
}
MD_ONDEVICE = dict(ja="この処理は端末内だけで行われます (macOS 26 以降)",
                   en="Processed on this Mac only (macOS 26 or later)")
# 要約の前提 (Apple Intelligence) はバッジではなく字幕下の注記行で伝える —
# バッジに全条件を詰めると 1 行に収まらず折り返して読みにくくなるため

# --- パネルの文言 (ja / en) -------------------------------------------------
# panel.py のモックは日本語固定のため、動画では言語切り替え可能な版をここに持つ
# (en は gui/Sources/ContentView.swift のローカライズ (#138) の文言に合わせる)。
T = {
    "ja": dict(cap="収録対象", screen="画面", window="ウィンドウ", audioonly="音声のみ",
               disp=lambda i: f"ディスプレイ {i}", audio="音声",
               sysaudio="システム音声 (相手の声・アプリの音)", mic="マイク (既定の入力デバイス)",
               extmic="外部マイク (USB)", multisrc="複数の音声ソース", mix="1 トラックに合成",
               sep="ソースごとに分離", saveto="保存先", change="変更…",
               remember="この音声・保存先の選択を既定にする", start="録画開始",
               m_sys="システム音声", m_mic="マイク", stop="停止",
               note="ポップオーバーを閉じても録画は続きます。経過時間はメニューバーに表示されます",
               fin="仕上げ中…", finder="Finder", m_file="ファイル", m_edit="編集", m_view="表示"),
    "en": dict(cap="Capture", screen="Screen", window="Window", audioonly="Audio only",
               disp=lambda i: f"Display {i}", audio="Audio",
               sysaudio="System audio (their voice, app audio)", mic="Microphone (default input)",
               extmic="External mic (USB)", multisrc="Multiple audio sources", mix="Mix into one track",
               sep="Separate per source", saveto="Save to", change="Change…",
               remember="Make this audio and save location the default", start="Start Recording",
               m_sys="System audio", m_mic="Microphone", stop="Stop",
               note="Recording continues when the panel closes. Elapsed time stays in the menu bar",
               fin="Finalizing…", finder="Finder", m_file="File", m_edit="Edit", m_view="View"),
}


def panel_setup(lang):
    t = T[lang]
    body = panel.header()
    body += panel.section(t["cap"], panel.seg([t["screen"], t["window"], t["audioonly"]], 0) + f'''
      <div class="list">
        {panel.row(f'{panel.sym("display","#C9CED6")}<span>{t["disp"](0)}</span><span class="spacer"></span><span class="dim">3456×2234</span>', True)}
        {panel.row(f'{panel.sym("display","#C9CED6")}<span>{t["disp"](1)}</span><span class="spacer"></span><span class="dim">2560×1440</span>')}
      </div>''')
    body += panel.section(t["audio"], f'''
      <div class="checks">
        <div class="ck">{panel.check(True)}<span>{t["sysaudio"]}</span></div>
        <div class="ck">{panel.check(True)}<span>{t["mic"]}</span></div>
        <div class="ck">{panel.check(False)}<span>{t["extmic"]}</span></div>
      </div>''')
    body += panel.section(t["multisrc"], panel.seg([t["mix"], t["sep"]], 0))
    body += panel.section(t["saveto"], f'''
      <div class="line">{panel.sym("folder","#C9CED6")}<span>~/Movies</span><span class="spacer"></span>
        <span class="btn">{t["change"]}</span></div>
      <div class="link">{t["remember"]}</div>''')
    body += '<div class="startwrap">' + \
            f'<div class="start">{panel.sym("record","#fff",15)}<span>{t["start"]}</span></div></div>'
    return body


# --- 録画中パネル (panel.py に無い動的要素つきの再構成) ----------------------
def panel_recording_dyn(lang):
    """panel.panel_recording() と同じ見た目で、タイマー・サイズ・メーターを
    id 付きにした版 (毎フレーム JS から書き換える)。実機の 3 系統メーターの
    うち外部マイク行は端折る — 動画では画面の誤読を避けるため情報を絞る。"""
    t = T[lang]
    b = panel.header()
    b += f'''
      <div class="sess">
        <div class="sess-top">
          <span class="dot"></span>
          <span class="elapsed" id="rec-elapsed">00:00:03</span>
          <span class="spacer"></span>
          <span class="dim" id="rec-size">12.4 MB</span>
        </div>
        <div class="dim sm">kilde-20261020-143201.mp4</div>
        <div class="meters">
          <div class="meter"><div class="mlabel">{t["m_sys"]}</div>
            <div class="mtrack"><div class="mfill" id="m-sys" style="width:44%;background:#34C759"></div></div></div>
          <div class="meter"><div class="mlabel">{t["m_mic"]}</div>
            <div class="mtrack"><div class="mfill" id="m-mic" style="width:58%;background:#FFCC00"></div></div></div>
        </div>
        <div class="stop" id="btn-stop">{panel.sym("stop", "#fff", 14)}<span>{t["stop"]}</span></div>
        <div class="dim sm wrap">{t["note"]}</div>
      </div>'''
    return b

def panel_finalizing(lang):
    """停止を押した直後の「仕上げ中」状態 (実機のファイナライズ表示を単純化したもの)。"""
    b = panel.header()
    b += f'''
      <div class="sess" style="align-items:center;padding:30px 0 26px">
        <div class="spin"></div>
        <div style="margin-top:14px;font-size:14px">{T[lang]["fin"]}</div>
        <div class="dim sm" style="margin-top:4px">kilde-20261020-143201.mp4</div>
      </div>'''
    return b

# --- 出力ファイル名 (kilde-site に持っていく名前と揃える) ---------------------
OUTPUT_NAMES = {("master", "ja"): "kilde-demo-60s-ja.mp4",
                ("master", "en"): "kilde-demo-60s-en.mp4",
                ("appstore", "ja"): "kilde-demo-appstore-ja.mp4",
                ("appstore", "en"): "kilde-demo-appstore-en.mp4"}


# --- HTML ------------------------------------------------------------------
CSS = """
* { box-sizing: border-box; margin: 0; padding: 0; }
html,body { width: 1440px; height: 810px; overflow: hidden;
  font-family: "Noto Sans JP", "Noto Sans CJK JP", "Hiragino Sans", "Helvetica Neue", sans-serif;
  -webkit-font-smoothing: antialiased; }
.stage { position: relative; width: 1440px; height: 810px; overflow: hidden;
  background: linear-gradient(155deg, #2C3543 0%, #1B222C 45%, #10151C 100%); }
.stage::before { content:""; position:absolute; width:860px; height:860px; left:-220px; top:-320px;
  background: radial-gradient(circle, rgba(255,59,48,.20) 0%, rgba(255,59,48,0) 66%); }
.stage::after { content:""; position:absolute; width:800px; height:800px; right:-260px; bottom:-300px;
  background: radial-gradient(circle, rgba(90,140,255,.16) 0%, rgba(90,140,255,0) 68%); }

/* --- 左のキャプション ---------------------------------------------------- */
.copy { position: absolute; left: 84px; top: 0; height: 810px; width: 500px; z-index: 5;
  display:flex; flex-direction:column; justify-content:center; }
.eyebrow { display:inline-flex; align-items:center; gap:10px; margin-bottom: 20px;
  font-size: 15px; letter-spacing:.14em; color:#98A0AC; font-weight:600; }
.eyebrow img { width: 30px; height: 30px; }
h1 { font-size: 42px; line-height: 1.42; color: #F5F7FA; font-weight: 700; letter-spacing:-.01em;
  word-break: keep-all; line-break: strict; }
h1 .hl { color: #FF6259; }
.subline { margin-top: 18px; font-size: 15px; line-height: 1.7; color: #98A0AC;
  word-break: keep-all; line-break: strict; }

/* --- Mac 画面のモック ----------------------------------------------------- */
.mac { position:absolute; left: 640px; top: 112px; width: 740px; height: 586px;
  border-radius: 14px; overflow: hidden; background: linear-gradient(160deg,#5C6B86,#33405A 60%,#222C40);
  box-shadow: 0 40px 90px rgba(0,0,0,.52), 0 0 0 1px rgba(255,255,255,.09); }
.menubar { height: 30px; background: rgba(22,26,33,.72); display:flex; align-items:center;
  padding: 0 14px; gap: 16px; font-size: 13px; color: #E4E7EC;
  border-bottom: 1px solid rgba(255,255,255,.07); position: relative; z-index: 6; }
.menubar .mb-app { font-weight: 700; }
.menubar .spacer { flex: 1; }
.mb-k { display:flex; align-items:center; gap:5px; padding: 2px 8px; border-radius: 5px; }
.mb-k.idle { background: rgba(255,255,255,.16); }
.mb-k.rec { background: rgba(255,59,48,.25); font-variant-numeric: tabular-nums; }
.mb-k img { width: 15px; height: 15px; }
.mb-dot { width:8px; height:8px; border-radius:50%; background:#FF3B30; }
.desk { position:absolute; inset: 30px 0 0 0; background:
  radial-gradient(120% 90% at 20% 10%, #3A465E 0%, #262f42 55%, #1B2232 100%); }

/* --- 会議ウィンドウ (ダミー «週次定例› — 実在サービスを映さない) ------------ */
.meetwin { position:absolute; left: 16px; top: 36px; width: 280px; height: 322px;
  background: #20242C; border-radius: 10px; overflow: hidden;
  box-shadow: 0 18px 46px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.08); }
.wtitle { height: 30px; display:flex; align-items:center; gap:6px; padding: 0 10px;
  background: rgba(255,255,255,.05); font-size: 11.5px; color:#C9CED6;
  border-bottom: 1px solid rgba(255,255,255,.06); }
.tl { display:flex; gap:6px; } .tl i { width:9px; height:9px; border-radius:50%; }
.tl i:nth-child(1){background:#FF5F57} .tl i:nth-child(2){background:#FEBC2E} .tl i:nth-child(3){background:#28C840}
.wtitle span.wt-label { flex:1; text-align:center; margin-right:42px; white-space:nowrap;
  overflow:hidden; text-overflow:ellipsis; }
.tiles { display:grid; grid-template-columns: 1fr 1fr; gap: 7px; padding: 9px; }
.tile { aspect-ratio: 16/10; border-radius: 7px; background:#2B313B; position:relative;
  display:flex; align-items:center; justify-content:center; }
.avatar { width: 38px; height: 38px; border-radius: 50%; background:#4A5568; color:#E8EAEE;
  display:flex; align-items:center; justify-content:center; font-size: 13px; font-weight:600; }
.tile.speaking { box-shadow: inset 0 0 0 2.5px #30D158; }
.tile .nm { position:absolute; left:6px; bottom:5px; font-size:9.5px; color:#C9CED6;
  background: rgba(0,0,0,.4); padding:1px 5px; border-radius:4px; white-space:nowrap; }
.mctrl { position:absolute; left:0; right:0; bottom:0; height: 42px; display:flex;
  align-items:center; justify-content:center; gap: 13px; background: rgba(12,14,18,.82); }
.mctrl i { width: 24px; height:24px; border-radius:50%; background:#3A414D; }
.mctrl i.end { background:#E7352B; width: 32px; }

/* --- 文字起こし (.md) ウィンドウ ------------------------------------------ */
.docwin { position:absolute; left: 20px; top: 28px; width: 420px; height: 434px;
  background: #23272F; border-radius: 10px; overflow: hidden;
  box-shadow: 0 18px 46px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.08); }
.docscroll { position:absolute; inset: 30px 0 0 0; overflow: hidden; }
.docpad { padding: 14px 18px 22px; color:#D6DAE1; }
.docpad .mh { font-size: 17px; font-weight: 700; color:#F0F2F5; }
.docpad .mmeta { font-size: 11.5px; color:#8A8F98; margin-top: 3px; margin-bottom: 10px; }
.docpad h2 { font-size: 13px; color:#9AA3AF; margin: 12px 0 7px; font-weight:600; }
.tl-line { font-size: 12px; line-height: 1.6; margin-bottom: 6px; display:flex; gap:7px;
  opacity: 0; }
.sp { flex:none; font-size: 10.5px; font-weight: 700; padding: 1.5px 7px; border-radius: 4px; margin-top:2px; }
.sp.them { background: rgba(52,199,89,.18); color: #3DD666; }
.sp.me { background: rgba(255,204,0,.16); color: #FFD84D; }
.sum-li { font-size: 12px; line-height: 1.65; margin-bottom: 5px; padding-left: 15px; position:relative;
  opacity: 0; }
.sum-li::before { content:""; position:absolute; left:2px; top:8px; width:6px; height:6px;
  border-radius:50%; background:#FF3B30; }
.badge { display:inline-block; margin-top: 10px; font-size: 10.5px; color:#98A0AC;
  border:1px solid rgba(255,255,255,.16); border-radius: 6px; padding: 4px 10px; opacity: 0; }

/* --- 書き出し先フォルダ (export シーン) ----------------------------------- */
.folderwin { position:absolute; right: 12px; top: 56px; width: 286px; background:#23272F;
  border-radius: 10px; overflow:hidden; box-shadow: 0 18px 46px rgba(0,0,0,.5), 0 0 0 1px rgba(255,255,255,.08); }
.folderwin .rows { padding: 9px 10px 11px; }
.frow { display:flex; align-items:center; gap:8px; padding: 7px 8px; border-radius: 7px; font-size: 11.5px; color:#C9CED6; }
.frow.hl { background: rgba(10,110,255,.32); color:#fff; }
.frow .fname { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.fchip { font-size: 10px; background: rgba(48,209,88,.2); color:#3DD666; padding: 1.5px 7px; border-radius: 4px; flex:none; }

/* --- ポップオーバー (panel.py の CSS を流用 + 動画用の調整) ---------------- */
.pop { position:absolute; right: 14px; top: 12px; width: 380px; height: 466px; zoom: 1.1;
  background: rgba(40,44,52,.975); border-radius: 12px;
  color: #E8EAEE; font-size: 13px; z-index: 4; opacity: 0;
  box-shadow: 0 22px 52px rgba(0,0,0,.55), 0 0 0 .5px rgba(255,255,255,.14); }
.pop::before { content:""; position:absolute; top:-7px; right: 40px; width:16px; height:16px;
  background: rgba(40,44,52,.975); transform: rotate(45deg); border-radius:3px; }
.pstate { position:absolute; left: 12px; right: 12px; top: 12px; opacity: 0; }
.spin { width: 30px; height:30px; border-radius:50%;
  border:3px solid rgba(255,255,255,.18); border-top-color:#0A6EFF; }
/* ここから下は build.py のパネル CSS と同じ定義 (.pop スコープ) */
.pop .sym { flex: none; display:block; }
.pop .spacer { flex: 1; }
.pop .hdr { display:flex; align-items:center; gap:7px; margin-bottom: 12px; }
.pop .hdr-t { font-size: 14px; font-weight: 700; }
.pop .icon-btn { opacity:.85; }
.pop .sec { margin-bottom: 14px; }
.pop .sec-t { font-size: 11px; color:#8A8F98; font-weight:600; margin-bottom: 6px; }
.pop .seg { display:flex; background: rgba(255,255,255,.08); border-radius: 7px; padding: 2px; gap:2px; }
.pop .seg-item { flex:1; text-align:center; padding: 4px 2px; border-radius: 5px; font-size: 12px; color:#C7CCD4; }
.pop .seg-item.active { background: #6B7280; color:#fff; box-shadow: 0 1px 2px rgba(0,0,0,.3); }
.pop .list { margin-top: 7px; display:flex; flex-direction:column; gap: 3px; }
.pop .row { display:flex; align-items:center; gap:7px; padding: 5px 7px; border-radius: 6px; }
.pop .row.sel { background: rgba(10,110,255,.85); }
.pop .row.sel .dim { color: rgba(255,255,255,.8); }
.pop .dim { color:#8A8F98; }
.pop .sm { font-size: 11px; }
.pop .wrap { line-height: 1.55; margin-top: 5px; }
.pop .pad { padding: 4px 2px 0; }
.pop .checks { display:flex; flex-direction:column; gap:6px; }
.pop .ck { display:flex; align-items:center; gap:7px; }
.pop .cb { width:13px; height:13px; border-radius:3.5px; border:1px solid #7C838E; flex:none;
  display:flex; align-items:center; justify-content:center; }
.pop .cb.on { background:#0A6EFF; border-color:#0A6EFF; }
.pop .line { display:flex; align-items:center; gap:7px; }
.pop .btn { padding: 3px 9px; border-radius: 6px; background: rgba(255,255,255,.14); font-size:12px; }
.pop .field { flex:1; padding: 3px 8px; border-radius: 6px; background: rgba(0,0,0,.28);
  border: 1px solid rgba(255,255,255,.14); font-size:12px; }
.pop .link { margin-top: 6px; font-size: 11px; color:#4EA1FF; }
.pop .startwrap { margin-top: 4px; }
.pop .start, .pop .stop { display:flex; align-items:center; justify-content:center; gap:7px;
  padding: 8px; border-radius: 8px; font-size: 14px; font-weight: 600; color:#fff; }
.pop .start { background: linear-gradient(#FF4A40,#E7352B); box-shadow: 0 1px 3px rgba(0,0,0,.35); }
.pop .stop  { background: linear-gradient(#3B8BFF,#0A6EFF); box-shadow: 0 1px 3px rgba(0,0,0,.35); }
.pop .press { transform: scale(.965); filter: brightness(.88); }
.pop .sess { display:flex; flex-direction:column; gap: 10px; }
.pop .sess-top { display:flex; align-items:center; gap:9px; }
.pop .sess-top .dot { width:10px; height:10px; border-radius:50%; background:#FF3B30; flex:none; }
.pop .elapsed { font-size: 28px; font-weight: 500;
  font-family: "DejaVu Sans Mono", ui-monospace, "SF Mono", Menlo, monospace; font-variant-numeric: tabular-nums; }
.pop .meters { display:flex; flex-direction:column; gap:5px; }
.pop .meter { display:flex; align-items:center; gap:6px; }
.pop .mlabel { width: 110px; font-size: 11px; color:#C7CCD4; }
.pop .mtrack { flex:1; height: 8px; border-radius: 3px; background: rgba(255,255,255,.16); overflow:hidden; }
.pop .mfill { height:100%; border-radius: 3px; }

/* --- 通知 (macOS 風) ------------------------------------------------------ */
.notif { position:absolute; right: 12px; top: 10px; width: 300px; z-index: 7;
  background: rgba(38,42,50,.92); border-radius: 13px; padding: 11px 13px;
  display:flex; gap: 10px; align-items:flex-start;
  box-shadow: 0 14px 40px rgba(0,0,0,.5), 0 0 0 .5px rgba(255,255,255,.14);
  transform: translateX(340px); opacity: 0; }
.notif img { width: 30px; height: 30px; border-radius: 7px; margin-top: 1px; }
.notif .nt { font-size: 12.5px; font-weight: 700; color:#F0F2F5; }
.notif .nb { font-size: 11px; color:#A7AFBB; margin-top:2px; line-height:1.5;
  font-variant-numeric: tabular-nums; word-break: break-all; }

/* --- エンドカード ---------------------------------------------------------- */
.endcard { position:absolute; inset:0; z-index: 9; background:#0D1218;
  display:flex; flex-direction:column; align-items:center; justify-content:center;
  opacity: 0; }
.endcard img { width: 118px; height: 118px; border-radius: 26px;
  box-shadow: 0 24px 70px rgba(0,0,0,.6); }
.endcard .word { margin-top: 26px; font-size: 62px; font-weight: 700; color:#F5F7FA; letter-spacing:-.01em; }
.endcard .tag { margin-top: 12px; font-size: 21px; color:#A7AFBB; }
.endcard .url { margin-top: 34px; font-size: 19px; color:#4EA1FF; font-weight:600; }
.endcard .consent { position:absolute; bottom: 26px; font-size: 13px; color:#6E747D; }

/* --- カーソルとクリック ---------------------------------------------------- */
.cursor { position:absolute; left:0; top:0; z-index: 8; opacity: 0; }
.clickring { position:absolute; width: 34px; height: 34px; border-radius: 50%;
  border: 2.5px solid rgba(255,255,255,.9); z-index: 8; opacity: 0;
  margin: -17px 0 0 -17px; }
"""

CURSOR_SVG = '''<svg width="23" height="29" viewBox="0 0 23 29">
<path d="M4 1.5 L4 23.5 L9.3 18.6 L13 27 L16.4 25.4 L12.7 17.2 L19.8 16.8 Z"
fill="#fff" stroke="#1a1a1a" stroke-width="1.4" stroke-linejoin="round"/></svg>'''


def meeting_window(lang):
    nm = dict(ja=["Y. 中村", "K. 佐藤", "T. 森"], en=["Y. Nakamura", "K. Sato", "T. Mori"])
    ini = ["YN", "KS", "TM"]
    tiles = ""
    for i in range(3):
        tiles += (f'<div class="tile" id="tile{i}"><div class="avatar">{ini[i]}</div>'
                  f'<span class="nm">{nm[lang][i]}</span></div>')
    title = "週次定例 — ビデオ会議" if lang == "ja" else "Weekly sync — Video call"
    return f'''<div class="meetwin" id="meetwin">
      <div class="wtitle"><span class="tl"><i></i><i></i><i></i></span><span class="wt-label">{title}</span></div>
      <div class="tiles">{tiles}</div>
      <div class="mctrl"><i></i><i></i><i class="end"></i></div>
    </div>'''


def doc_window(lang):
    lines = ""
    for i, (sp, tx) in enumerate(MD_LINES[lang]):
        lines += (f'<div class="tl-line" id="tl{i}"><span class="sp {SPK[sp]}">{SPK_TEXT[lang][sp]}</span>'
                  f'<span>{tx}</span></div>')
    sums = "".join(f'<div class="sum-li" id="sum{i}">{s}</div>' for i, s in enumerate(MD_SUMMARY[lang]))
    tr = "文字起こし" if lang == "ja" else "Transcript"
    sm = "要約" if lang == "ja" else "Summary"
    return f'''<div class="docwin" id="docwin">
      <div class="wtitle"><span class="tl"><i></i><i></i><i></i></span><span class="wt-label">kilde-20261020-143201.md</span></div>
      <div class="docscroll" id="docscroll"><div class="docpad" id="docpad">
        <div class="mh" id="doc-h">{MD_TITLE[lang]}</div>
        <div class="mmeta" id="doc-m">{MD_META}</div>
        <h2 id="doc-tr">{tr}</h2>
        {lines}
        <div id="sumblock">
          <h2 id="doc-sm">{sm}</h2>
          {sums}
          <span class="badge" id="doc-badge">{MD_ONDEVICE[lang]}</span>
        </div>
      </div></div>
    </div>'''


def folder_window(lang):
    title = "書き出し先" if lang == "ja" else "Exports to"
    auto = "自動保存" if lang == "ja" else "Auto-saved"
    return f'''<div class="folderwin" id="folderwin">
      <div class="wtitle"><span class="tl"><i></i><i></i><i></i></span><span class="wt-label">{title} · ~/Meetings</span></div>
      <div class="rows">
        <div class="frow">{panel.sym("film", "#8A8F98")}<span class="fname">kilde-20261020-143201.mp4</span></div>
        <div class="frow hl">{panel.sym("check", "#30D158")}<span class="fname">kilde-20261020-143201.md</span><span class="fchip">{auto}</span></div>
        <div class="frow">{panel.sym("film", "#8A8F98")}<span class="fname">kilde-20261019-093012.mp4</span></div>
      </div>
    </div>'''


def notification(lang):
    saved = "保存しました" if lang == "ja" else "Saved"
    done = "書き込みを完了しました" if lang == "ja" else "Recording finalized"
    return f'''<div class="notif" id="notif"><img id="notif-icon" alt="">
      <div><div class="nt">kilde — {saved}</div>
      <div class="nb">{done}<br>kilde-20261020-143201.mp4 · 8:12 · 214.6 MB</div></div>
    </div>'''


def endcard(lang, with_url):
    # 同意の注意は URL の有無に関係なく常に出す — どちらの版も会議録画を勧める
    # 文面を含むため (docs/launch/README.md の文面ルール)
    consent = f'<div class="consent">{CONSENT[lang]}</div>'
    url = '<div class="url" id="ec-url">kilde.site</div>' if with_url else ""
    tag = SUBTITLE[lang] if not with_url else TAGLINE[lang]
    return f'''<div class="endcard" id="endcard">
      <img id="ec-icon" alt=""><div class="word" id="ec-word">kilde</div>
      <div class="tag" id="ec-tag">{tag}</div>{url}{consent}
    </div>'''


def build_html(timeline, lang, icon_uri):
    scenes, t = [], 0.0
    for key, dur in timeline:
        scenes.append(dict(key=key, start=round(t, 3), end=round(t + dur, 3)))
        t += dur
    meta = dict(scenes=scenes, total=round(t, 3), lang=lang)

    states = f'''
      <div class="pstate" id="p-setup">{panel_setup(lang)}</div>
      <div class="pstate" id="p-rec">{panel_recording_dyn(lang)}</div>
      <div class="pstate" id="p-fin">{panel_finalizing(lang)}</div>'''

    m = T[lang]
    html = f'''<html><head><meta charset="utf-8"><style>{CSS}</style></head><body>
<div class="stage" id="stage">
  <div class="copy" id="copy">
    <div class="eyebrow"><img id="eb-icon" alt="">KILDE for macOS</div>
    <h1 id="cap-h1"></h1>
    <p class="subline" id="cap-sub"></p>
  </div>
  <div class="mac" id="mac">
    <div class="menubar"><span class="mb-app">{m["finder"]}</span><span>{m["m_file"]}</span><span>{m["m_edit"]}</span><span>{m["m_view"]}</span>
      <span class="spacer"></span>
      <span class="mb-k idle" id="mb-icon"><img alt=""></span>
      <span class="mb-k rec" id="mb-rec" style="display:none"><span class="mb-dot"></span><span id="mb-elapsed">00:00:00</span></span>
      <span>100%</span><span>14:22</span></div>
    <div class="desk" id="desk">
      {meeting_window(lang)}
      {doc_window(lang)}
      {folder_window(lang)}
      <div class="pop" id="pop">{states}</div>
      {notification(lang)}
    </div>
  </div>
  {endcard(lang, with_url=(timeline is TL_MASTER))}
  <div class="clickring" id="ring"></div>
  <div class="cursor" id="cursor">{CURSOR_SVG}</div>
</div>
<script>
const META = {json.dumps(meta)};
// CAPTIONS は「シーン → 言語ごとの文言」の入れ子 — この言語で平坦化しておく
const CAPS = Object.fromEntries(Object.entries({json.dumps(CAPTIONS, ensure_ascii=False)})
  .map(([k, v]) => [k, v[META.lang]]));
// 条件付き機能の注記行 (無いシーンは空文字) — CAPTIONS と同じ入れ子なので平坦化する
const CAPNOTES = Object.fromEntries(Object.entries({json.dumps(CAPTION_NOTES, ensure_ascii=False)})
  .map(([k, v]) => [k, v[META.lang]]));
const el = id => document.getElementById(id);
const clamp01 = x => Math.max(0, Math.min(1, x));
const easeOut = x => 1 - Math.pow(1 - clamp01(x), 3);
const easeIO = x => (x = clamp01(x)) < .5 ? 2*x*x : 1 - Math.pow(-2*x+2, 2)/2;
const fmt = s => {{
  s = Math.max(0, Math.floor(s));
  const h = String(Math.floor(s/3600)).padStart(2,"0"),
        m = String(Math.floor(s%3600/60)).padStart(2,"0"),
        x = String(s%60).padStart(2,"0");
  return h+":"+m+":"+x;
}};
function center(id) {{
  const r = el(id).getBoundingClientRect();
  return [r.left + r.width/2, r.top + r.height/2];
}}
function centerSel(sel) {{
  const n = document.querySelector(sel); if (!n) return [0,0];
  const r = n.getBoundingClientRect();
  return [r.left + r.width/2, r.top + r.height/2];
}}
function setCursor(x, y) {{
  el("cursor").style.transform = "translate(" + (x-3) + "px," + (y-3) + "px)";
  el("cursor").style.opacity = 1;
}}
function clickRing(x, y, p) {{  // p: 0..1 (クリックから 0.45 秒の進行度)
  const r = el("ring");
  r.style.left = x + "px"; r.style.top = y + "px";
  r.style.opacity = p < 1 ? 0.9*(1-p) : 0;
  r.style.transform = "scale(" + (0.4 + 0.9*easeOut(p)) + ")";
}}
// パネル状態の不透明度を直接制御する (シーン間でクロスフェードさせるため)
function panels(op_setup, op_rec, op_fin) {{
  el("p-setup").style.opacity = op_setup;
  el("p-rec").style.opacity = op_rec;
  el("p-fin").style.opacity = op_fin;
}}
function meters(sysFrac, micFrac) {{
  el("m-sys").style.width = Math.round(clamp01(sysFrac)*100) + "%";
  el("m-mic").style.width = Math.round(clamp01(micFrac)*100) + "%";
}}
// パネルの状態ごとの自然な高さ (中身 + 上下 padding 12)。実ポップオーバーと同じく
// 中身が変われば箱も追従させる — 固定にすると短いパネルの下に大きな余白が残る
const PH = {{}};
for (const [k, id] of [["setup", "p-setup"], ["rec", "p-rec"], ["fin", "p-fin"]])
  PH[k] = el(id).scrollHeight + 24;
function setPopH(px) {{ el("pop").style.height = Math.round(px) + "px"; }}

// ——— 毎フレーム冪等に全体を設定し直す (前フレームの残りが出ない) ———
function setFrame(t) {{
  let sc = META.scenes[META.scenes.length-1];
  for (const s of META.scenes) if (t < s.end) {{ sc = s; break; }}
  const tau = t - sc.start, L = sc.end - sc.start, key = sc.key;

  // 既定値
  el("endcard").style.opacity = 0;
  el("notif").style.opacity = 0;
  el("notif").style.transform = "translateX(340px)";
  el("folderwin").style.opacity = 0;
  el("folderwin").style.transform = "translateX(60px)";
  el("cursor").style.opacity = 0;
  clickRing(0, 0, 1);
  panels(0, 0, 0);
  el("pop").style.opacity = 0;
  el("meetwin").style.opacity = 1;
  el("docwin").style.opacity = 0;
  el("docwin").style.transform = "translateX(0) scale(1)";
  el("docpad").style.transform = "translateY(0)";
  el("btn-stop").classList.remove("press");
  const startBtn = document.querySelector("#p-setup .start");
  if (startBtn) startBtn.classList.remove("press");
  el("mb-rec").style.display = "none";
  el("mb-icon").style.display = "flex";
  setPopH(PH.setup);
  for (let i = 0; i < 3; i++) el("tile" + i).classList.remove("speaking");

  // キャプション (各シーン冒頭 0.6 秒でフェードイン)。条件付き機能の注記行も
  // 大きな字幕の直下に小さく添える (CAPTION_NOTES)
  el("cap-h1").innerHTML = CAPS[key] || "";
  el("cap-sub").innerHTML = CAPNOTES[key] || "";
  const cin = easeOut(tau / 0.6);
  el("copy").style.opacity = cin;
  el("copy").style.transform = "translateY(" + ((1-cin)*26) + "px)";

  // フックは全体をわずかにズームインから戻す (動きのきっかけ)
  const zoomAll = key === "hook" ? 1.035 - 0.035 * easeIO(tau / L) : 1.0;
  el("stage").style.transform = "scale(" + zoomAll + ")";

  if (key === "hook") {{
    // (左キャプションと会議ウィンドウを見せるだけ)
  }}
  else if (key === "nobot") {{
    // カーソルがメニューバーの kilde アイコンをクリック → ポップオーバーが開く
    el("tile1").classList.add("speaking");
    const x0 = 1180, y0 = 690, pt = center("mb-icon");
    const p = easeIO(tau / 1.0);
    setCursor(x0 + (pt[0]-x0)*p, y0 + (pt[1]-y0)*p);
    if (tau > 1.0) clickRing(pt[0], pt[1], (tau - 1.0) / 0.45);
    el("pop").style.opacity = tau < 1.0 ? 0 : easeOut((tau - 1.0) / 0.35);
    panels(1, 0, 0);
    setPopH(PH.setup);
  }}
  else if (key === "start") {{
    // «録画開始» をクリック → 録画中パネルへ (0.35 秒クロスフェード)
    const from = center("mb-icon"), to = centerSel("#p-setup .start");
    const p = easeIO(tau / 1.25);
    setCursor(from[0] + (to[0]-from[0])*p, from[1] + (to[1]-from[1])*p);
    if (tau > 1.3) {{ clickRing(to[0], to[1], (tau - 1.3) / 0.45);
                     if (startBtn) startBtn.classList.add("press"); }}
    const rec = easeOut((tau - 1.35) / 0.35);
    panels(1 - rec, rec, 0);
    el("pop").style.opacity = 1;
    setPopH(PH.setup + (PH.rec - PH.setup) * rec);
    const started = tau >= 1.4;
    el("mb-rec").style.display = started ? "flex" : "none";
    el("mb-icon").style.display = started ? "none" : "flex";
    // 録画開始直後は実時間で少しだけ進め (3 → 4 秒)、次の recording シーンの
    // タイムラプス (4 → 492 秒) に連続で接続する — 境界でタイマーが戻らないため
    const prog = Math.max(0, tau - 1.4) / Math.max(0.1, L - 1.4);
    el("rec-elapsed").textContent = fmt(3 + prog);
    el("mb-elapsed").textContent = fmt(3 + prog);
    el("rec-size").textContent = (12.4 + 0.6 * prog).toFixed(1) + " MB";
    meters(0.36 + 0.14*Math.sin(prog*2.2), 0.5 + 0.16*Math.sin(prog*1.8 + 2));
  }}
  else if (key === "recording") {{
    // タイムラプス: 00:00:04 (start シーンの終わり) → 00:08:12 へ線形に進める。
    // 完了通知 «8:12 · 214.6 MB» と画面が完全に整合し、30 秒版でも録画終了時に
    // タイマーがジャンプしない (開始値・終了値は start シーンと対にしている)
    const T = 4 + 488 * (tau / L);
    el("rec-elapsed").textContent = fmt(T);
    el("mb-elapsed").textContent = fmt(T);
    el("rec-size").textContent = (13.0 + 201.6 * (tau / L)).toFixed(1) + " MB";
    meters(0.44 + 0.30 * Math.sin(T*0.9) * Math.sin(T*0.37),
           0.56 + 0.26 * Math.sin(T*0.8 + 2.1) * Math.sin(T*0.29));
    el("mb-rec").style.display = "flex";
    el("mb-icon").style.display = "none";
    el("pop").style.opacity = 1;
    panels(0, 1, 0);
    setPopH(PH.rec);
    // 話者が交互に発話 (グリーンの枠 = 相手 / 自分)
    const spk = Math.floor(tau / 1.7) % 2;
    for (let i = 0; i < 3; i++) el("tile" + i).classList.toggle("speaking", i === spk);
  }}
  else if (key === "stop") {{
    const from = [1180, 660], to = center("btn-stop");
    const p = easeIO(tau / 0.95);
    if (tau < 1.15) setCursor(from[0] + (to[0]-from[0])*p, from[1] + (to[1]-from[1])*p);
    if (tau > 1.05) {{ clickRing(to[0], to[1], (tau - 1.05) / 0.45);
                       el("btn-stop").classList.add("press"); }}
    const fin = easeOut((tau - 1.15) / 0.3);
    panels(0, 1 - fin, fin);
    setPopH(PH.rec + (PH.fin - PH.rec) * fin);
    el("pop").style.opacity = tau > 4.6 ? Math.max(0, 1 - (tau - 4.6) / 0.6) : 1;
    // メーターは減衰、通知は 2.3 秒からスライドイン
    const decay = Math.max(0, 1 - (tau - 1.1) / 0.7);
    meters(0.4 * decay, 0.55 * decay);
    const np = easeOut((tau - 2.3) / 0.5);
    el("notif").style.opacity = np;
    el("notif").style.transform = "translateX(" + ((1-np)*340) + "px)";
    if (tau > 1.15) {{ el("mb-rec").style.display = "none"; el("mb-icon").style.display = "flex"; }}
    el("rec-elapsed").textContent = fmt(492);
    el("rec-size").textContent = "214.6 MB";
  }}
  else if (key === "transcript") {{
    // 画面を .md エディタへ切替、話者ラベル行が順に現れる
    const mp = easeIO(tau / 0.5);
    el("meetwin").style.opacity = 1 - mp;
    el("docwin").style.opacity = mp;
    el("docwin").style.transform = "translateX(" + ((1-mp)*36) + "px)";
    const items = ["doc-h", "doc-m", "doc-tr"];
    for (let i = 0; i < 6; i++) items.push("tl" + i);
    // 行の表示間隔はシーン長に合わせて縮める (30 秒版は 5 秒しかないため)
    const step = Math.min(0.72, (L - 1.5) / 9.5);
    items.forEach((id, i) => {{
      const p = easeOut((tau - (0.7 + i * step)) / 0.4);
      const n = el(id); if (!n) return;
      n.style.opacity = p;
      n.style.transform = "translateY(" + ((1-p)*10) + "px)";
    }});
    const bp = tau > 3.0 ? easeOut((tau - 3.0) / 0.4) : 0;
    el("doc-badge").style.opacity = bp;
  }}
  else if (key === "summary") {{
    el("docwin").style.opacity = 1;
    el("meetwin").style.opacity = 0;
    // 要約ブロックまでスクロール (オフセットは実要素から計算 — 文面が変わっても追従)
    const win = el("docscroll").getBoundingClientRect();
    const blk = el("sumblock").getBoundingClientRect();
    const dy = Math.max(0, blk.top - win.top - 30);
    const sp = easeIO(Math.min(1, tau / 1.3));
    el("docpad").style.transform = "translateY(" + (-dy*sp) + "px)";
    for (let i = 0; i < 3; i++) {{
      const p = easeOut((tau - (1.5 + i * 0.55)) / 0.4);
      const n = el("sum" + i);
      n.style.opacity = p;
      n.style.transform = "translateY(" + ((1-p)*10) + "px)";
    }}
    const bp = tau > 3.2 ? easeOut((tau - 3.2) / 0.4) : 0;
    el("doc-badge").style.opacity = bp;
  }}
  else if (key === "export") {{
    el("docwin").style.opacity = 1;
    el("meetwin").style.opacity = 0;
    const ep = easeIO(tau / 0.7);
    el("docwin").style.transform = "translateX(" + (-ep*56) + "px) scale(" + (1 - ep*0.05) + ")";
    el("folderwin").style.opacity = ep;
    el("folderwin").style.transform = "translateX(" + ((1-ep)*60) + "px)";
  }}
  else if (key === "endcard" || key === "endcard30") {{
    const p = easeOut(tau / 0.7);
    el("endcard").style.opacity = p;
    ["ec-icon", "ec-word", "ec-tag", "ec-url"].forEach((id, i) => {{
      const n = el(id); if (!n) return;
      const q = easeOut((tau - (0.25 + i * 0.22)) / 0.5);
      n.style.opacity = q;
      n.style.transform = "translateY(" + ((1-q)*16) + "px)";
    }});
  }}
}}
</script></body></html>'''
    for pat, rep in [('<img id="eb-icon" alt="">', f'<img id="eb-icon" alt="" src="{icon_uri}">'),
                     ('<img id="ec-icon" alt="">', f'<img id="ec-icon" alt="" src="{icon_uri}">'),
                     ('<img id="notif-icon" alt="">', f'<img id="notif-icon" alt="" src="{icon_uri}">'),
                     ('<span class="mb-k idle" id="mb-icon"><img alt="">',
                      f'<span class="mb-k idle" id="mb-icon"><img alt="" src="{icon_uri}">')]:
        assert pat in html, f"アイコン差し込みポイントが見つかりません: {pat}"
        html = html.replace(pat, rep)
    return html


# --- レンダリング -----------------------------------------------------------
def timeline_scenes(timeline):
    out, t = [], 0.0
    for key, dur in timeline:
        out.append(dict(key=key, start=t, dur=dur))
        t += dur
    return out


async def render_one(pw, cut, lang, timeline, icon_uri, outdir, stills_only=False, keep=False):
    frames_dir = outdir / f"frames-{cut}-{lang}"
    frames_dir.mkdir(parents=True, exist_ok=True)
    total = sum(d for _, d in timeline)
    n_frames = int(round(total * FPS))
    label = f"{cut}-{lang}"

    browser = await pw.chromium.launch()
    page = await browser.new_page(viewport={"width": 1440, "height": 810},
                                  device_scale_factor=2)
    await page.set_content(build_html(timeline, lang, icon_uri))
    await page.wait_for_timeout(250)
    # build.py と同じ理由でフォント差を検査する — 字幅が変わると字幕の折り返しと
    # パネルのレイアウトが変わるため (黙って別物を作らない。cubic レビュー指摘)
    probe = ('(async () => {'
             '  try { await new FontFace("ProbeJP", \'local("Noto Sans JP")\').load(); return true; }'
             '  catch (e) { return false; }'
             '})()')
    if not await page.evaluate(probe):
        print(f"[{label}] warning: \"Noto Sans JP\" が見つかりません — 字形と折り返しが"
              "この環境の成果物と変わります", file=sys.stderr)

    if stills_only:
        # 各シーンの中間地点 1 フレーム (OCR 検証・目視確認用。動画は作らない)
        stills = frames_dir / "stills"
        stills.mkdir(exist_ok=True)
        for s in timeline_scenes(timeline):
            t = s["start"] + min(s["dur"] * 0.62, s["dur"] - 0.15)
            await page.evaluate(f"setFrame({t})")
            await page.screenshot(path=str(stills / f"{s['key']}.jpg"), type="jpeg", quality=92)
        await browser.close()
        print(f"[{label}] stills -> {stills}")
        return

    for i in range(n_frames):
        await page.evaluate(f"setFrame({i / FPS:.4f})")
        await page.screenshot(path=str(frames_dir / ("f_%05d.jpg" % i)), type="jpeg", quality=95)
        if i % 150 == 0:
            print(f"[{label}] {i}/{n_frames}", flush=True)
    await browser.close()

    out_mp4 = outdir / OUTPUT_NAMES[(cut, lang)]
    vf = "scale=1920:1080:flags=lanczos,format=yuv420p"
    if cut == "appstore":
        # Apple の App Preview 仕様: H.264 (High / L4.0) 10〜12 Mbps・30fps・AAC 256k ステレオ
        # (音は無いため無音 AAC を敷く — 「ステレオ音声」の欄がある前提で検証を通す)
        cmd = ["ffmpeg", "-y", "-v", "error", "-framerate", str(FPS), "-i", str(frames_dir / "f_%05d.jpg"),
               "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
               "-t", f"{n_frames / FPS:.3f}",
               "-vf", vf, "-c:v", "libx264", "-profile:v", "high", "-level", "4.0",
               "-b:v", "10M", "-maxrate", "12M", "-bufsize", "20M",
               "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
               "-movflags", "+faststart", str(out_mp4)]
    else:
        cmd = ["ffmpeg", "-y", "-v", "error", "-framerate", str(FPS), "-i", str(frames_dir / "f_%05d.jpg"),
               "-vf", vf, "-c:v", "libx264", "-preset", "slow", "-crf", "21",
               "-movflags", "+faststart", "-an", str(out_mp4)]
    # 同期 subprocess のまま呼ぶと asyncio.gather のもう一方のレンダリングまで
    # ブロックする (実質直列になる) ので、スレッドに逃がす (cubic レビュー指摘)
    await asyncio.to_thread(subprocess.run, cmd, check=True)
    if not keep:
        for f in frames_dir.glob("f_*.jpg"):
            f.unlink()
    probe = await asyncio.to_thread(
        subprocess.run,
        ["ffprobe", "-v", "error", "-show_entries",
         "format=duration,size:stream=codec_name,width,height,avg_frame_rate",
         "-of", "json", str(out_mp4)],
        capture_output=True, text=True, check=True)
    j = json.loads(probe.stdout)
    print(f"[{label}] {out_mp4.name}: {j['format']['duration']}s "
          f"{int(j['format']['size'])/1e6:.1f}MB " +
          ", ".join(f"{s['codec_name']}:{s.get('width','') or s.get('codec_name','')}"
                    for s in j["streams"]))


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="例: master-ja / appstore-en (省略で 4 本全部)")
    ap.add_argument("--stills", action="store_true", help="動画でなく代表フレームだけ出す")
    ap.add_argument("--keep", action="store_true", help="フレーム jpg を消さずに残す")
    args = ap.parse_args()

    if not ICON.exists():
        sys.exit("png/icon_1024.png がありません — 先に `python3 icon.py ../icon && python3 render.py` を実行してください")
    icon_uri = "data:image/png;base64," + base64.b64encode(ICON.read_bytes()).decode()

    sel = [(cut, lang) for (cut, lang) in OUTPUT_NAMES if args.only in (None, f"{cut}-{lang}")]
    if not sel:
        sys.exit(f"--only の指定が不正です: {args.only}")

    OUT.mkdir(exist_ok=True)
    async with async_playwright() as pw:
        # 2 本ずつ並列 (ブラウザ 2 つ。それ以上はメモリと CPU の割に合わない)
        for i in range(0, len(sel), 2):
            await asyncio.gather(*(render_one(pw, cut, lang, MAKES[cut], icon_uri, OUT,
                                              stills_only=args.stills, keep=args.keep)
                                   for cut, lang in sel[i:i+2]))

# import で誤って数分のレンダリングが走らないよう、実行は明示的にガードする
# (build.py と違い本スクリプトは 1 回に数分かかる)
if __name__ == "__main__":
    asyncio.run(main())
