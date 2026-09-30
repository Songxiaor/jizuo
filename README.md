# 汲作官网

线上地址：https://songxiaor.github.io/jizuo/

**这个 `gh-pages` 分支就是官网源码本身**，根目录直接发布，没有构建步骤。以前的 `site/glass-landing`、`site/polish-2026-08` 分支已经过时，不要再从那里改。`.nojekyll` 要留着。

## 文件

| 文件 | 作用 |
|---|---|
| `index.html` | 首页 |
| `privacy.html` | 隐私政策 |
| `styles.css` | 两页共用的样式，设计令牌在最上面 |
| `_og.html` | 分享图 `assets/og.jpg` 的模板，带 noindex，站内不链接 |
| `tools/update-sprite.py` | 把 App 的篆书字形同步进页面里的印章 |

## 怎么改

```bash
git worktree add ../jizuo-site gh-pages
cd ../jizuo-site
python3 -m http.server 8899   # 先在自己电脑上看一眼
```

文字直接改 HTML。改完推 `gh-pages` 就上线。

**App 的印章字形变了**（`apps/desktop/Sources/LinkDigestApp/SealGlyphData.swift`）：

```bash
python3 tools/update-sprite.py <App 仓库>/apps/desktop/Sources/LinkDigestApp/SealGlyphData.swift
```

它只替换页面里那一块印章符号；页面里必须恰好有一处，否则不改任何文件。

**改了分享图**：用浏览器按 1200×630、浅色模式打开 `_og.html` 截图，存成 `assets/og.jpg`。

## 视觉规范

跟 App 一致，来源是 App 本身：素纸底、墨色字、靛青强调；**朱色只给印和朱批**，不当按钮色、不当报错色；正文用宋体。印章不用图片，是页内 `<symbol>`，画法与 App 的 `SealMark` 相同：作与工序印白文、汲圆朱文、印位虚线、侧栏墨线小印、两字印右汲左作（古法右起）。每一屏只盖一处归属印。

## 三条线

1. **不加载任何外部脚本、字体或统计。** 隐私政策里这么写了，必须一直成立。想加外部资源之前，先改那句话。整页目前一行 JavaScript 都没有。
2. **首页不写死版本号。** 下载按钮一律指向 `releases/latest`，版本只出现在 GitHub 发布页。
3. **界面示意用示例内容。** 不放任何真实资料库的截图，里面的文章、数字都是编的。
