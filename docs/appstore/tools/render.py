import asyncio, pathlib, sys
from playwright.async_api import async_playwright

SRC = pathlib.Path("svg")
OUT = pathlib.Path("png"); OUT.mkdir(exist_ok=True)

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
