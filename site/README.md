# 这里没有官网源码

官网的源码**不在这个分支**。这个目录以前放过一份 v0.2.9 时代的 `index.html`，
和线上早已不是同一个东西（线上是玻璃主题 + 独立 `styles.css`，这里是内联样式的旧版），
留着只会让人改错文件——改完发现线上没反应。所以那几个文件已经删掉了。

## 真正的源在哪

| | 位置 |
|---|---|
| 源码 | 分支 `site/glass-landing` 的 `site/` 目录 |
| 线上 | 分支 `gh-pages` 的仓库根目录 |
| 地址 | https://songxiaor.github.io/linkdigest/ |

两者内容逐字节相同，**没有任何 CI 在部署它**——是手工把 `site/` 下的内容
平铺到 `gh-pages` 根目录再推上去的。`.nojekyll` 必须保留。

## 改官网的正确做法

```bash
git worktree add ../linkdigest-site site/glass-landing
cd ../linkdigest-site/site
python3 -m http.server 8899   # 本地预览
```

改完后把 `site/` 下的内容同步到 `gh-pages` 根目录。

## 两条别踩的线

1. **零外部资源**。这两个页面不加载任何第三方脚本、字体或统计代码——
   隐私政策页里白纸黑字这么写着，那句话必须一直为真。
   加任何 `<script src>` 或外链字体之前，先去改那句话。
2. **不写死版本号**。写死必然过期（线上曾长期停在 v0.2.11 而实际已发 v0.2.12）。
   版本号只出现在 GitHub 发布页，首页徽标是指向发布页的链接。
