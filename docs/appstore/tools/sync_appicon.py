# -*- coding: utf-8 -*-
"""render.py が書き出した png/ を gui/Resources/Assets.xcassets/AppIcon.appiconset/ へ同期する。

`icon.py` → `render.py` はアイコンの SVG と PNG を作るだけで、**ビルドに入る
asset catalog は更新しない**。同期を忘れるとアイコンを作り直したつもりで
MAS 成果物が旧版のままになる (cubic / CodeRabbit レビュー指摘)。

**アイコンの意匠を作り直したときにだけ実行すること。** リポジトリに入っている
PNG は納品物 `kilde-appicon.zip` の書き出し (README §1) で、`tools/` のサイズ別
バリアントとは別物 — 実行すると後者で置き換わる。

    python3 icon.py ../icon && python3 render.py && python3 sync_appicon.py
"""
import json
import os
import pathlib
import shutil
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
# 入力は render.py の出力先、出力はビルドが読む asset catalog。どちらも
# スクリプト位置基準で解決する (render.py / build.py と同じ方針)
PNG = HERE.parent / "png"
ICONSET = HERE.parents[2] / "gui" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"


def main() -> int:
    contents_path = ICONSET / "Contents.json"
    if not contents_path.exists():
        print(f"error: {contents_path} が見つかりません", file=sys.stderr)
        return 1
    images = json.loads(contents_path.read_text(encoding="utf-8"))["images"]
    # **先に全部そろっているか確かめる。** 1 枚ずつコピーしながら不足を記録すると、
    # 終了コード 1 で止まっても asset catalog は新旧が混ざった状態で残り、次の MAS
    # ビルドに «一部だけ新しいアイコン» が入る (cubic レビュー指摘)
    plan = []
    missing = []
    for image in images:
        filename = image.get("filename")
        if not filename:
            continue
        # 実ピクセル数は size ("16x16") の一辺 × scale ("2x")。
        # 16/32/64/128/256/512/1024 は render.py の PLAN と過不足なく一致する
        pixels = int(image["size"].split("x")[0]) * int(image["scale"].rstrip("x"))
        source = PNG / f"icon_{pixels}.png"
        if source.exists():
            plan.append((source, filename))
        else:
            missing.append(source.name)
    if missing:
        print("error: PNG が足りません: " + ", ".join(sorted(set(missing)))
              + " (先に icon.py と render.py を実行してください。"
              + "asset catalog は変更していません)", file=sys.stderr)
        return 1
    # **一時ディレクトリへ全部書いてから置き換える。** 直接 1 枚ずつ上書きすると、
    # 途中の I/O エラーで asset catalog が新旧混在のまま残り、次の MAS ビルドに
    # 不完全なアイコンが入る (cubic レビュー指摘)。置き換えは os.replace —
    # 同一ボリューム内では原子的
    # (一時ディレクトリを gui/Resources 配下に作るのは同じボリュームに置くため。
    #  Assets.xcassets の中には作らない — カタログの構造に一時物を混ぜないため)
    #
    # **1 枚ずつの os.replace が原子的でも、10 枚全体は原子的にならない。** 5 枚目で
    # 落ちれば先頭 4 枚だけ新しくなる。既存ファイルを退避しておき、失敗したら
    # 置換済みを全部戻す (Codex レビュー指摘)
    with tempfile.TemporaryDirectory(dir=ICONSET.parents[1]) as staging:
        staging_path = pathlib.Path(staging)
        staged = []
        for source, filename in plan:
            temporary = staging_path / filename
            shutil.copyfile(source, temporary)
            staged.append((source.name, temporary, ICONSET / filename))
        backup = staging_path / "_backup"
        backup.mkdir()
        # (target, 元から存在したか) — **存在しなかった target を消すために必要**。
        # backup が無いことをもって「戻すものが無い」と素通しすると、欠けていた
        # アイコンを作った状態で catalog が残る (Codex レビュー指摘)。このスクリプトは
        # 欠けた catalog の補修にも使えるので、その経路を塞いでおく
        replaced = []
        try:
            for source_name, temporary, target in staged:
                existed = target.exists()
                if existed:
                    shutil.copyfile(target, backup / target.name)
                os.replace(temporary, target)
                replaced.append((target, existed))
                print(f"{source_name} -> {target.name}")
        except Exception:
            for target, existed in replaced:
                if existed:
                    os.replace(backup / target.name, target)
                else:
                    target.unlink(missing_ok=True)
            print("error: 置換に失敗したため、元のアイコンに戻しました", file=sys.stderr)
            raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
