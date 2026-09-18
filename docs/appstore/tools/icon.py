import math

CANVAS = 1024.0
# Big Sur 系の比率: 1024 キャンバスに 824 の角丸四角を中央配置 (上下左右 100 の余白)
SHAPE = 824.0
M = (CANVAS - SHAPE) / 2.0
CX = CY = CANVAS / 2.0

def squircle_path(cx, cy, half, n=5.9, steps=360):
    """Apple の連続角丸に近い超楕円 |x|^n + |y|^n = 1 をパスにする。
    単純な円弧の角丸より、macOS のアイコン形状に近い輪郭になる。"""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = math.copysign(abs(ct) ** (2.0 / n), ct)
        y = math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((cx + x * half, cy + y * half))
    d = "M {:.2f} {:.2f} ".format(*pts[0])
    d += " ".join("L {:.2f} {:.2f}".format(x, y) for x, y in pts[1:])
    return d + " Z"

def arc(cx, cy, r, a0, a1):
    """cx,cy 中心・半径 r の円弧 (度)。音波の弧に使う。"""
    x0 = cx + r * math.cos(math.radians(a0))
    y0 = cy + r * math.sin(math.radians(a0))
    x1 = cx + r * math.cos(math.radians(a1))
    y1 = cy + r * math.sin(math.radians(a1))
    large = 1 if abs(a1 - a0) > 180 else 0
    sweep = 1 if a1 > a0 else 0
    return f"M {x0:.2f} {y0:.2f} A {r:.2f} {r:.2f} 0 {large} {sweep} {x1:.2f} {y1:.2f}"

def build(variant):
    """variant: 'full' (>=128px) / 'mid' (64px) / 'small' (<=32px)
    小さいサイズでは弧を減らし太くする — 細い線は 16px で消えるため。"""
    if variant == "full":
        dot_r, radii, sw, spread = 104.0, [188.0, 268.0, 348.0], 40.0, 46.0
    elif variant == "mid":
        dot_r, radii, sw, spread = 118.0, [214.0, 306.0], 50.0, 48.0
    else:
        dot_r, radii, sw, spread = 140.0, [262.0], 64.0, 52.0

    waves = []
    for i, r in enumerate(radii):
        op = [0.95, 0.60, 0.34][i] if variant == "full" else [0.95, 0.55][i] if variant == "mid" else [0.95][i]
        # 右側の弧 (0 度を中心に ±spread) と、その鏡像である左側の弧
        waves.append(f'<path d="{arc(CX, CY, r, -spread, spread)}" stroke="#FFFFFF" '
                     f'stroke-opacity="{op}" stroke-width="{sw}" stroke-linecap="round" fill="none"/>')
        waves.append(f'<path d="{arc(CX, CY, r, 180 - spread, 180 + spread)}" stroke="#FFFFFF" '
                     f'stroke-opacity="{op}" stroke-width="{sw}" stroke-linecap="round" fill="none"/>')
    waves = "\n      ".join(waves)

    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3A4655"/>
      <stop offset="0.52" stop-color="#252D39"/>
      <stop offset="1" stop-color="#161B23"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
      <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.02"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="dot" cx="0.36" cy="0.32" r="0.85">
      <stop offset="0" stop-color="#FF6A60"/>
      <stop offset="0.55" stop-color="#FF3B30"/>
      <stop offset="1" stop-color="#D92A20"/>
    </radialGradient>
    <filter id="shadow" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="14" stdDeviation="20" flood-color="#000000" flood-opacity="0.34"/>
    </filter>
    <filter id="glow" x="-60%" y="-60%" width="220%" height="220%">
      <feGaussianBlur stdDeviation="22"/>
    </filter>
    <clipPath id="clip"><path d="{squircle_path(CX, CY, SHAPE/2)}"/></clipPath>
  </defs>

  <g filter="url(#shadow)">
    <path d="{squircle_path(CX, CY, SHAPE/2)}" fill="url(#bg)"/>
  </g>
  <g clip-path="url(#clip)">
    <path d="{squircle_path(CX, CY, SHAPE/2)}" fill="url(#sheen)"/>
    <!-- 赤ドットの後光。暗い地に対して録画中であることを強く感じさせる -->
    <circle cx="{CX}" cy="{CY}" r="{dot_r*1.28:.1f}" fill="#FF3B30" opacity="0.20" filter="url(#glow)"/>
      {waves}
    <circle cx="{CX}" cy="{CY}" r="{dot_r:.1f}" fill="url(#dot)"/>
  </g>
  <path d="{squircle_path(CX, CY, SHAPE/2)}" fill="none" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="3"/>
</svg>'''

if __name__ == "__main__":
    import sys, pathlib
    arg = pathlib.Path(sys.argv[1])
    # 相対パスは **スクリプト位置基準** で解決する。カレントディレクトリ基準だと
    # リポジトリルートから実行したときに render.py の入力先 (docs/appstore/icon) 以外へ
    # 書き、PNG の再生成が古いアイコンを処理してしまう (cubic レビュー指摘)。
    # render.py / build.py が既にこの方式 (cubic レビュー指摘)
    out = arg if arg.is_absolute() else pathlib.Path(__file__).resolve().parent / arg
    out.mkdir(parents=True, exist_ok=True)
    for v in ("full", "mid", "small"):
        (out / f"icon-{v}.svg").write_text(build(v))
    print("wrote", [p.name for p in sorted(out.glob("*.svg"))])
