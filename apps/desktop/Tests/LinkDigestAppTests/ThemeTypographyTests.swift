import AppKit
import SwiftUI
import XCTest

@testable import LinkDigestApp

/// 主题排版的不变量。
///
/// 这一套断言的是**规则**，不是具体字体名：换掉某个主题的字体不该让测试变红，
/// 只有破坏下面这些前提时才该红。
final class ThemeTypographyTests: XCTestCase {
  // 系统主题必须留在系统字体上。
  //
  // 它的定位是「跟随 macOS」，而窗口里还有一整片够不到的系统控件（菜单栏、
  // 右键菜单、字体面板、Sparkle 弹窗）只会用系统字体。给它指定字体，那些控件
  // 不跟着变，界面反而更花。
  func testSystemThemeKeepsTheSystemFont() {
    XCTAssertNil(AppearanceTheme.glass.tokens.typography.family)
  }

  // 反过来，其余每个主题都**必须**有自己的字体。
  //
  // 这条是这次改造的初衷：在这之前换主题只换颜色，字体全 App 写死。漏掉一个
  // 主题不会有任何报错，只会是那个主题看起来「没做完」。
  func testEveryNonSystemThemeDeclaresItsOwnFont() {
    for theme in AppearanceTheme.allCases where theme != .glass {
      XCTAssertNotNil(
        theme.tokens.typography.family,
        "\(theme.displayName) 主题没有自己的字体，退回了系统字体"
      )
    }
  }

  // 主题字体必须自带中文字形。
  //
  // 回退路径不做中文标点挤压，表现是每个「，」「。」后面裂开一道缝。纸质主题
  // 早年选 New York 就是栽在这里，别用另一种方式再栽一次。
  func testThemeFontsCanDrawChinese() {
    for theme in AppearanceTheme.allCases {
      guard let family = theme.tokens.typography.family else { continue }
      XCTAssertTrue(
        ReadingFontCatalog.supportsCJK(family),
        "\(theme.displayName) 的 \(family) 没有中文字形"
      )
    }
  }

  // 装不上的字体必须就地退回系统字体，而不是交给 SwiftUI 静默回退。
  //
  // `Font.custom` 遇到不存在的家族不报错，会掉回系统默认——那正是上面那条
  // 标点裂缝的来源。宁可整套退回系统字体，也不要一个半坏的渲染结果。
  func testMissingFamilyFallsBackToSystem() {
    XCTAssertNil(ThemeTypography.family("Definitely Not An Installed Font").family)
    XCTAssertEqual(ThemeTypography.family("PingFang SC").family, "PingFang SC")
  }

  // 具名字体的点数必须和系统语义字号一致。
  //
  // 具名字体没有「语义字号」，只能给点数。对不上的表现是切换主题时整个界面的
  // 尺寸跳一下——那不是换字体，那是换布局。
  func testPointSizesMatchTheSystemTextStyles() {
    let expected: [ThemeTextStyle: NSFont.TextStyle] = [
      .largeTitle: .largeTitle, .title: .title1, .title2: .title2, .title3: .title3,
      .headline: .headline, .body: .body, .callout: .callout,
      .subheadline: .subheadline, .footnote: .footnote,
      .caption: .caption1, .caption2: .caption2,
    ]
    for style in ThemeTextStyle.allCases {
      guard let systemStyle = expected[style] else {
        return XCTFail("新增了 \(style) 却没给它对应的系统语义字号")
      }
      XCTAssertEqual(
        style.pointSize,
        NSFont.preferredFont(forTextStyle: systemStyle).pointSize,
        accuracy: 0.01,
        "\(style) 的点数和系统语义字号对不上，换主题时界面尺寸会跳"
      )
    }
  }

  // headline 在系统语义里自带 semibold。换成具名字体后这个隐含字重会丢，
  // 表现是「小标题和正文一样粗」——层级塌掉，而且不会有任何报错。
  func testHeadlineKeepsItsImplicitSemibold() {
    XCTAssertEqual(ThemeTextStyle.headline.implicitWeight, .semibold)
    for style in ThemeTextStyle.allCases where style != .headline {
      XCTAssertEqual(style.implicitWeight, .regular, "\(style) 不该自带字重")
    }
  }

  // 主题字体必须能画**完整的简体中文**，不只是「中」这一个字。
  //
  // 这条是补出来的，因为它抓到过一次真事故：暖褐主题一度配了 Klee（日文
  // 教科書体）。它能通过只测「中」的 `supportsCJK`，但实测「这条记录来自
  // 哔哩哔哩」24 个字里有 7 个（这/记/录/哔/为/进）画不出来，逐字回退到
  // Songti SC——一句话里两种字形混排，而当时全套测试是绿的。
  func testThemeFontsCoverSimplifiedChinese() {
    for theme in AppearanceTheme.allCases {
      guard let family = theme.tokens.typography.family else { continue }
      XCTAssertTrue(
        ReadingFontCatalog.supportsSimplifiedChinese(family),
        "\(theme.displayName) 的 \(family) 缺简化字，排中文会逐字回退"
      )
    }
  }

  // 推荐名单里的每一个都必须过同一条门槛。名单是手写的，手写就会错。
  func testRecommendedFontsAllCoverSimplifiedChinese() {
    for family in RecommendedFonts.ui() + RecommendedFonts.reading() {
      XCTAssertTrue(
        ReadingFontCatalog.supportsSimplifiedChinese(family),
        "推荐名单里的 \(family) 缺简化字"
      )
    }
  }

  // 推荐名单不能是空的：门槛写得太严会把所有字体筛光，而表现只是选择器里
  // 「推荐」一档空着——不会有任何报错。
  func testRecommendedListsAreNotEmpty() {
    XCTAssertFalse(RecommendedFonts.ui().isEmpty, "界面字体推荐名单空了")
    XCTAssertFalse(RecommendedFonts.reading().isEmpty, "阅读字体推荐名单空了")
  }

  // 「推荐」和「其它」加起来必须不重不漏，否则选择器里会有字体出现两次，
  // 或者有字体谁都不属于、直接消失。
  func testRecommendedAndOthersPartitionTheCatalog() {
    for recommended in [RecommendedFonts.ui(), RecommendedFonts.reading()] {
      let others = RecommendedFonts.others(excluding: recommended)
      XCTAssertTrue(
        Set(recommended).isDisjoint(with: Set(others)),
        "有字体同时出现在「推荐」和「其它」里"
      )
      let union = Set(recommended).union(others)
      for family in ReadingFontCatalog.cjkCapableFamilies() {
        XCTAssertTrue(union.contains(family), "\(family) 在选择器里两档都不属于")
      }
    }
  }

  // 用户选的界面字体必须盖过主题默认；没选时必须交还主题。
  func testUserSelectionOverridesTheThemeDefault() {
    let themeDefault = AppearanceTheme.paper.tokens.typography
    XCTAssertEqual(
      UIFontSelection(storedValue: UIFontSelection.defaultStoredValue)
        .resolved(themeDefault: themeDefault),
      themeDefault
    )
    XCTAssertEqual(
      UIFontSelection(storedValue: "PingFang SC").resolved(themeDefault: themeDefault).family,
      "PingFang SC"
    )
    // 空串等同「跟随主题」：存量偏好和手工改过的 plist 都可能是空的。
    XCTAssertEqual(UIFontSelection(storedValue: "  ").resolved(themeDefault: themeDefault), themeDefault)
  }

  // 界面字体和阅读字体是两个独立偏好，不能共用一个 key——共用的表现是
  // 改一个另一个跟着变，而用户根本没动它。
  func testUIAndReadingFontsUseSeparateStorageKeys() {
    XCTAssertNotEqual(UIFontSelection.storageKey, ReadingFontSelection.storageKey)
  }

  // 令牌相等性退化成比一个身份串（17 个 Color 逐个比太贵）。代价是身份必须
  // 覆盖所有会影响外观的输入，漏一个的表现是「改了设置但界面不刷新」。
  func testTokenIdentityDistinguishesEveryTheme() {
    let ids = AppearanceTheme.allCases.map(\.tokens.identity)
    XCTAssertEqual(Set(ids).count, ids.count, "有两个主题的令牌身份撞了，切换时不会刷新")
  }

  func testChangingTheUIFontChangesTheTokenIdentity() {
    let base = AppearanceTheme.paper.tokens
    let swapped = base.withTypography(.family("PingFang SC"))
    XCTAssertNotEqual(
      base.identity, swapped.identity,
      "换界面字体没换身份，环境值会被判定为「没变」，下游一个视图都不刷新"
    )
    XCTAssertNotEqual(base, swapped)
    // 同样的字体换两次必须仍然相等，否则每次渲染都白刷一遍。
    XCTAssertEqual(swapped, base.withTypography(.family("PingFang SC")))
  }

  // 令牌按主题只构造一次。重复读必须拿到同一份内容，否则缓存等于没做。
  func testTokensAreStableAcrossReads() {
    for theme in AppearanceTheme.allCases {
      XCTAssertEqual(theme.tokens, theme.tokens)
      XCTAssertEqual(theme.tokens.identity, theme.tokens.identity)
    }
  }
}
