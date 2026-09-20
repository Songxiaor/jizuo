var SharePreprocess = function () {};

SharePreprocess.prototype = {
  run: function (arguments) {
    function collapse(text) {
      return String(text || "")
        .replace(/\u00a0/g, " ")
        .replace(/[ \t]+\n/g, "\n")
        .replace(/\n{3,}/g, "\n\n")
        .replace(/[ \t]{2,}/g, " ")
        .trim();
    }

    function stripNoise(root) {
      if (!root || !root.querySelectorAll) return;
      var kill = root.querySelectorAll(
        "script,style,noscript,svg,canvas,iframe,nav,header,footer,aside,form,[role='navigation'],[role='banner'],[role='contentinfo']"
      );
      for (var i = 0; i < kill.length; i++) {
        try {
          kill[i].remove();
        } catch (e) {}
      }
    }

    function textFrom(node) {
      if (!node) return "";
      var clone = node.cloneNode(true);
      stripNoise(clone);
      return collapse(clone.innerText || clone.textContent || "");
    }

    var title =
      collapse(
        (document.querySelector('meta[property="og:title"]') || {}).content ||
          (document.querySelector('meta[name="twitter:title"]') || {}).content ||
          document.title ||
          ""
      ) || "";

    var url = String(document.URL || location.href || "");

    var body = "";
    var selectors = [
      "article",
      "main",
      '[role="main"]',
      "#js_content",
      ".RichText",
      "#v_desc",
      '[itemprop="articleBody"]',
    ];
    for (var s = 0; s < selectors.length; s++) {
      var el = document.querySelector(selectors[s]);
      var t = textFrom(el);
      if (t.length >= 40) {
        body = t;
        break;
      }
    }
    if (!body) {
      body = textFrom(document.body);
    }
    if (!body) {
      body = collapse(
        (document.querySelector('meta[property="og:description"]') || {}).content ||
          (document.querySelector('meta[name="description"]') || {}).content ||
          ""
      );
    }

    // Safari Share Extension 对 dictionary 体积敏感，截断超长正文。
    var maxChars = 120000;
    if (body.length > maxChars) {
      body = body.slice(0, maxChars);
    }

    arguments.completionFunction({
      title: title,
      url: url,
      text: body,
      source: "safari_rendered_dom",
      characterCount: body.length,
    });
  },
};
