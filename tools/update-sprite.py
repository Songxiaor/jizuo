#!/usr/bin/env python3
"""把 App 的篆书字形同步进官网页面里的印章 <symbol>。

用法（在官网工作区根目录）：
    python3 tools/update-sprite.py <汲作 App 仓库>/apps/desktop/Sources/LinkDigestApp/SealGlyphData.swift

它会替换 index.html、_og.html 里完整的印章块，以及 privacy.html 里只含两字印的精简块。
画法与 App 的 SealMark / BrandSealMark 一致：白文朱底镂空、「汲」圆朱文、印位虚线、墨线小印。
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def frame(inset):
    a = inset + 3; w = 100 - a * 2
    p = [(a + w*0.01, a), (a + w, a + w*0.015), (a + w - w*0.005, a + w), (a, a + w - w*0.012)]
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in p) + " Z"
NAMES = {"作": "zuo", "汲": "ji", "录": "lu", "校": "jiao", "评": "ping", "摘": "zhai", "译": "yi", "图": "tu"}
def build(paths):
    out = []
    for ch, slug in NAMES.items():
        out.append(f'<path id="g-{slug}" d="{paths[ch]}"/>')
    for key, slug in (("brand-zuo", "bzuo"), ("brand-ji", "bji")):
        out.append(f'<path id="g-{slug}" d="{paths[key]}"/>')
    for ch, slug in NAMES.items():
        d = f'#g-{slug}'
        if ch == "汲":   # 圆朱文：朱框朱字
            stamped = (f'<path d="{frame(1.2)}" fill="none" stroke="var(--seal)" stroke-width="2.6" stroke-linejoin="round"/>'
                       f'<use href="{d}" fill="var(--seal)" stroke="var(--seal)" stroke-width="0.5" stroke-linejoin="round"/>')
        else:           # 白文：朱底，字见纸
            w = 3.0 if ch == "作" else 2.0
            stamped = (f'<path d="{frame(0)}" fill="var(--seal)"/>'
                       f'<use href="{d}" fill="var(--seal-cut)" stroke="var(--seal-cut)" stroke-width="{w}" stroke-linejoin="round"/>')
        out.append(f'<symbol id="s-{slug}" viewBox="0 0 100 100">{stamped}</symbol>')
        pending = (f'<path d="{frame(0)}" fill="none" stroke="var(--seal)" stroke-opacity=".7" stroke-width="2.4" stroke-dasharray="7 5" stroke-linejoin="round"/>'
                   f'<use href="{d}" fill="none" stroke="var(--seal)" stroke-opacity=".7" stroke-width="1.3" stroke-linejoin="round"/>')
        out.append(f'<symbol id="p-{slug}" viewBox="0 0 100 100">{pending}</symbol>')
        line = (f'<path d="{frame(0)}" fill="none" stroke="currentColor" stroke-width="5" stroke-linejoin="round"/>'
                f'<use href="{d}" fill="currentColor"/>')
        out.append(f'<symbol id="l-{slug}" viewBox="0 0 100 100">{line}</symbol>')
    # 两字印（右汲朱文、左作白文，古法右起），与 BrandSealMark 同一画法
    brand = ('<symbol id="s-brand" viewBox="0 0 100 100">'
             '<rect x="3.5" y="3.5" width="47.1" height="93" rx="1.5" fill="var(--seal)"/>'
             '<use href="#g-bzuo" fill="var(--seal-cut)" stroke="var(--seal-cut)" stroke-width="1.4" stroke-linejoin="round"/>'
             '<path d="M50.6 5.2 L94.8 5.2 L94.8 94.8 L50.6 94.8" fill="none" stroke="var(--seal)" stroke-width="3.4" stroke-linejoin="round"/>'
             '<use href="#g-bji" fill="var(--seal)" stroke="var(--seal)" stroke-width="0.84" stroke-linejoin="round"/>'
             '</symbol>')
    out.append(brand)

    full = '<svg class="sprite" aria-hidden="true" focusable="false"><defs>' + "".join(out) + '</defs></svg>'
    mini = ('<svg class="sprite" aria-hidden="true" focusable="false"><defs>'
            + "".join(x for x in out if 'id="g-bzuo"' in x or 'id="g-bji"' in x or 'id="s-brand"' in x) + '</defs></svg>')
    return full, mini


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__); return 2
    paths = dict(re.findall(r'"([^"]+)": "([^"]+)"', Path(sys.argv[1]).read_text(encoding="utf-8")))
    full, mini = build(paths)
    block = re.compile(r'<svg class="sprite".*?</defs></svg>', re.S)
    for name, sprite in (("index.html", full), ("_og.html", full), ("privacy.html", mini)):
        page = ROOT / name
        text = page.read_text(encoding="utf-8")
        # 必须恰好一处：注释里若也写了这段标记，正则会从注释一路吞到印章块末尾。
        if len(block.findall(text)) != 1 or text.count('<svg class="sprite"') != 1:
            raise SystemExit(f"{name} 里的印章块不是恰好一处，没有改动任何文件")
        page.write_text(block.sub(lambda _: sprite, text, count=1), encoding="utf-8")
        print(f"已更新 {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
