import asyncio, pathlib
from playwright.async_api import async_playwright

HERE = pathlib.Path(__file__).parent
# SVG は icon.py の出力先 (docs/appstore/icon)、PNG は build.py が読む場所
# (docs/appstore/png)。実行時のカレントディレクトリに依存させない —
# README §3 の手順をどこから実行しても同じ場所を読み書きするため
SRC = HERE.parent / "icon"
OUT = HERE.parent / "png"
OUT.mkdir(exist_ok=True)

# ピクセルサイズ -> 使う SVG 版。小さいほど簡略版を使う
PLAN = {16:"small", 32:"small", 64:"mid", 128:"full", 256:"full", 512:"full", 1024:"full"}

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        for size, variant in PLAN.items():
            svg = (SRC / f"icon-{variant}.svg").read_text()
            html = f'<html><body style="margin:0;padding:0"><div style="width:{size}px;height:{size}px">{svg.replace(chr(34)+"1024"+chr(34), chr(34)+str(size)+chr(34), 2)}</div></body></html>'
            page = await b.new_page(viewport={"width": size, "height": size}, device_scale_factor=1)
            await page.set_content(html)
            await page.screenshot(path=str(OUT / f"icon_{size}.png"), omit_background=True)
            await page.close()
        await b.close()
    print(sorted(p.name for p in OUT.glob("*.png")))

asyncio.run(main())
