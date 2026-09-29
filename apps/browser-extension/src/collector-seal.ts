/**
 * 「汲」收藏印：保存成功时在弹窗里盖下的那枚章。
 *
 * 画法与 App 的 SealMark 同一套（100 格坐标、略不齐的方框、白文、水纹、印泥颗粒），
 * 只是这里输出 SVG 字符串，交给弹窗塞进 #result。颜色不写死：外层 color 取
 * --seal（朱），字和纹样取 --seal-paper（纸色），深浅色由 index.html 的令牌切换。
 */

let sealCount = 0;

/** 略带手刻不齐的方框：四角各偏一点。inset 为向内缩进的格数。 */
function sealFrame(inset: number): string {
  const a = inset + 3;
  const w = 100 - a * 2;
  const points: Array<[number, number]> = [
    [a + w * 0.01, a],
    [a + w, a + w * 0.015],
    [a + w - w * 0.005, a + w],
    [a, a + w - w * 0.012],
  ];
  return "M" + points.map(([x, y]) => `${x.toFixed(2)} ${y.toFixed(2)}`).join(" L") + " Z";
}

/** 汲 · 水纹：底部两排鱼鳞浪，后一排淡一些。 */
function waterMotif(): string {
  let front = "";
  for (let x = 10; x < 88; x += 13) front += `M${x} 90 q6.5 -8 13 0 `;
  let back = "";
  for (let x = 16.5; x < 82; x += 13) back += `M${x} 83 q6.5 -7 13 0 `;
  return `<path d="${front}"/><path d="${back}" stroke-opacity=".45"/>`;
}

function escapeHTML(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * 白文「汲」印的 SVG。size 是屏幕像素，线宽按它设下限，小印不断线。
 * 每次调用生成新的滤镜 id，同一页面多枚印不会互相引用。
 */
export function collectorSealSVG(size = 40): string {
  const id = `collector-seal-ink-${++sealCount}`;
  const k = 100 / size;
  const frameW = Math.max(5, 0.9 * k);
  const motifW = Math.max(2.2, 0.55 * k);
  const glyph = "汲";
  const seed = glyph.charCodeAt(0);
  const filter =
    `<filter id="${id}" x="-6%" y="-6%" width="112%" height="112%">`
    + `<feTurbulence type="fractalNoise" baseFrequency="0.06" numOctaves="2" seed="${seed % 97}" result="n"/>`
    + `<feDisplacementMap in="SourceGraphic" in2="n" scale="2.6" xChannelSelector="R" yChannelSelector="G" result="d"/>`
    + `<feTurbulence type="fractalNoise" baseFrequency="0.5" numOctaves="1" seed="${seed % 89 + 7}" result="s"/>`
    + `<feColorMatrix in="s" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  -4 0 0 0 3" result="speck"/>`
    + `<feComposite in="d" in2="speck" operator="in"/></filter>`;
  const body =
    `<path d="${sealFrame(0)}" fill="currentColor" stroke="currentColor" stroke-width="${frameW.toFixed(2)}" stroke-linejoin="round"/>`
    + `<g style="color:var(--seal-paper)">`
    + `<path d="${sealFrame(9)}" fill="none" stroke="currentColor" stroke-opacity=".55" stroke-width="${(motifW * 0.6).toFixed(2)}"/>`
    + `<g fill="none" stroke="currentColor" stroke-width="${motifW.toFixed(2)}" stroke-linecap="round" stroke-linejoin="round">${waterMotif()}</g>`
    + `<text x="50" y="50" dy=".36em" text-anchor="middle" font-size="50" font-family="'Noto Serif SC','Songti SC',serif" font-weight="600" fill="currentColor">${glyph}</text>`
    + `</g>`;
  return `<svg width="${size}" height="${size}" viewBox="0 0 100 100" aria-hidden="true" focusable="false">`
    + filter + `<g filter="url(#${id})">${body}</g></svg>`;
}

/**
 * 保存成功提示：印在前、原有文案在后。印本身对读屏是一张名为「汲」的图。
 * 动画与减弱动效的处理在 index.html 的 .collector-seal 样式里。
 */
export function savedNoticeMarkup(message: string): string {
  return stampedSealMarkup(40) + `<span class="result-text">${escapeHTML(message)}</span>`;
}

/** 单独一枚盖下的「汲」印（保存成功卡用大号）。 */
export function stampedSealMarkup(size: number): string {
  return `<span class="collector-seal" role="img" aria-label="汲" data-seal="汲">${collectorSealSVG(size)}</span>`;
}
