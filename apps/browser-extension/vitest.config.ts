import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

/**
 * 测试跑的是源码，而源码里有构建期注入的常量。
 *
 * `wxt.config.ts` 的 `define` 只作用于 wxt 的构建，vitest 用的是自己这一份配置——
 * 少了这里，`__PRODUCT_DISPLAY_NAME__` 在测试里就是未定义，整个测试文件在加载期
 * 就 ReferenceError（表现是「一个文件失败、断言却全过」）。
 *
 * 两处都读同一份 product-display.json：真相源仍然只有那一个文件。
 */
const productDisplay = JSON.parse(
  readFileSync(
    fileURLToPath(
      new URL("../desktop/Sources/LinkDigestCore/Resources/product-display.json", import.meta.url)
    ),
    "utf8"
  )
) as { displayName: string; formatVersion: number };

if (productDisplay.formatVersion !== 1) {
  throw new Error("product-display.json 的 formatVersion 不是 1");
}

export default defineConfig({
  define: {
    __PRODUCT_DISPLAY_NAME__: JSON.stringify(productDisplay.displayName)
  }
});
