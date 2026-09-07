import XCTest

@testable import LinkDigestAdapters

final class XiaohongshuMetadataParsingTests: XCTestCase {
  func testMetadataAttributeSyntaxAndSelection() {
    struct Case {
      let name: String
      let html: String
      let expected: String?
    }
    let cases: [Case] = [
      .init(
        name: "other-tag-colon", html: #"<meta:custom property="og:description" content="wrong">"#,
        expected: nil),
      .init(
        name: "attribute-at-prefix", html: #"<meta x@property="og:description" content="wrong">"#,
        expected: nil),
      .init(
        name: "standard", html: #"<meta property="og:description" content="caption">"#,
        expected: "caption"),
      .init(
        name: "reordered", html: #"<meta content="caption" property="og:description">"#,
        expected: "caption"),
      .init(
        name: "name-attribute", html: #"<meta content="caption" name="og:description">"#,
        expected: "caption"),
      .init(
        name: "case", html: #"<META PROPERTY="og:description" CONTENT="caption">"#,
        expected: "caption"),
      .init(
        name: "spaces", html: #"<meta property = "og:description" content = "caption">"#,
        expected: "caption"),
      .init(
        name: "apostrophe", html: #"<meta property="og:description" content="It's a caption">"#,
        expected: "It's a caption"),
      .init(
        name: "double-in-single",
        html: #"<meta property='og:description' content='A "quoted" caption'>"#,
        expected: "A \"quoted\" caption"),
      .init(
        name: "greater-before-property", html: #"<meta content="A > B" property="og:description">"#,
        expected: "A > B"),
      .init(
        name: "data-property", html: #"<meta data-property="og:description" content="wrong">"#,
        expected: nil),
      .init(
        name: "data-content", html: #"<meta property="og:description" data-content="wrong">"#,
        expected: nil),
      .init(
        name: "wrong-tag", html: #"<metadata property="og:description" content="wrong">"#,
        expected: nil),
      .init(
        name: "no-cross-tag", html: #"<meta property="og:description"><meta content="wrong">"#,
        expected: nil),
      .init(
        name: "quoted-fake-attribute",
        html: #"<meta title='property="og:description"' content="wrong">"#, expected: nil),
      .init(
        name: "empty-then-valid",
        html:
          #"<meta property="og:description" content=" "><meta property="og:description" content="caption">"#,
        expected: "caption"),
      .init(
        name: "entities",
        html:
          #"<meta property="og:description" content="A &amp; B &lt;x&gt; &quot;y&quot; &#39;z&#39;">"#,
        expected: "A & B <x> \"y\" 'z'"),
      .init(
        name: "self-closing", html: #"<meta content='caption' property='og:description'/>"#,
        expected: "caption"),
      .init(
        name: "property-precedence",
        html:
          #"<meta name="og:description" content="name"><meta property="og:description" content="property">"#,
        expected: "property"),
      .init(
        name: "wrong-property", html: #"<meta property="og:description:other" content="wrong">"#,
        expected: nil),
    ]

    for c in cases {
      XCTAssertEqual(
        XiaohongshuPageParser.metaContent(html: c.html, property: "og:description"), c.expected,
        c.name)
    }
  }

  func testMetadataAttributePermutations() {
    var permutationCount = 0
    for key in ["property", "name"] {
      for spacing in ["=", " = ", "\n=\t"] {
        for quote in ["\"", "'"] {
          for uppercase in [false, true] {
            for reverse in [false, true] {
              let k = uppercase ? key.uppercased() : key
              let c = uppercase ? "CONTENT" : "content"
              let tag = uppercase ? "META" : "meta"
              let one = "\(k)\(spacing)\(quote)og:description\(quote)"
              let two = "\(c)\(spacing)\(quote)真实 &amp; 完整 > 配文\(quote)"
              let html =
                "<\(tag) data-content='wrong' \(reverse ? two + " " + one : one + " " + two)>"
              permutationCount += 1
              XCTAssertEqual(
                XiaohongshuPageParser.metaContent(html: html, property: "og:description"),
                "真实 & 完整 > 配文", "permutation \(permutationCount)")
            }
          }
        }
      }
    }

    XCTAssertEqual(permutationCount, 48)
  }

  func testReorderedMetadataPreservesTitleCaptionAndTrustedCover() {
    let page =
      #"<meta content="真实标题 - 小红书" property="og:title"><meta content="真实配文" property="og:description"><meta content="http://sns-webpic-qc.xhscdn.com/note/cover.jpg" property="og:image">"#
    let parsed = XiaohongshuPageParser.parse(html: page)
    let integration =
      parsed?.title == "真实标题" && parsed?.description == "真实配文"
      && parsed?.imageURL?.absoluteString == "https://sns-webpic-qc.xhscdn.com/note/cover.jpg"

    XCTAssertTrue(integration, "Reordered metadata must retain title, caption and HTTPS cover")
  }
}
