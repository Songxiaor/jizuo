# 这个分支上没有官网源码

我以前在这里放过一份旧页面，和现在线上已经不是同一份。留着我会改错文件：目录叫 `site/`，一改官网就先打开它，改完发现线上没变化。所以那几个文件我删掉了。

## 源在哪

| | 位置 |
|---|---|
| 我改的源码 | 分支 `site/glass-landing` 的 `site/` 目录 |
| 线上 | 分支 `gh-pages` 的仓库根目录 |
| 地址 | https://songxiaor.github.io/linkdigest/ |

两份内容应当一致。现在没有自动发布，是我改完后手工推到 `gh-pages`。`.nojekyll` 要留着。

## 我怎么改官网

```bash
git worktree add ../linkdigest-site site/glass-landing
cd ../linkdigest-site/site
python3 -m http.server 8899   # 先在自己电脑上看一眼
```

看过之后，把 `site/` 下的内容同步到 `gh-pages` 根目录再推。

## 我给自己划的两条线

1. **这两个页面不加载任何外部脚本、字体或统计。** 隐私政策里我是这么写的，必须一直成立。想加外部资源之前，先改那句话。
2. **首页不写死版本号。** 写死就会过期。版本只出现在 GitHub 发布页，首页按钮指向「最新下载」。
