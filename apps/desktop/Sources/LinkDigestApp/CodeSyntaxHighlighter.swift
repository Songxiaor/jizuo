import AppKit
import SwiftUI

/// 阅读区代码块的语法着色（2026-09-24 对齐 Tolaria：代码按语言上色）。
///
/// 不引第三方高亮库：阅读区只需要把关键字、字符串、注释、数字分开，读者一眼分得出
/// 结构就够了；逐语言的完整文法是编辑器的事。按行扫一遍，线性时间，结果按内容缓存。
/// 颜色用系统语义色，深浅主题自动跟随。
enum CodeSyntaxHighlighter {
  enum TokenKind: Equatable {
    case keyword, string, comment, number, tag, attribute
  }

  struct Token: Equatable {
    let range: Range<String.Index>
    let kind: TokenKind
  }

  /// 语言别名归一。认不出的语言返回 nil，代码照单色显示。
  static func language(for raw: String?) -> Language? {
    guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    switch raw {
    case "swift": return .swift
    case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx": return .javascript
    case "py", "python", "python3": return .python
    case "go", "golang": return .go
    case "rs", "rust": return .rust
    case "java", "kotlin", "kt", "scala", "cs", "csharp", "c#", "dart": return .java
    case "c", "cpp", "c++", "h", "hpp", "objc", "objective-c", "m", "mm": return .c
    case "sh", "bash", "zsh", "shell", "console", "fish": return .shell
    case "json", "jsonc", "json5": return .json
    case "yaml", "yml", "toml", "ini": return .yaml
    case "sql", "mysql", "postgres", "postgresql", "sqlite": return .sql
    case "html", "xml", "svg", "vue", "plist": return .markup
    case "css", "scss", "less": return .css
    case "rb", "ruby": return .ruby
    case "php": return .php
    case "lua": return .lua
    default: return nil
    }
  }

  enum Language {
    case swift, javascript, python, go, rust, java, c, shell, json, yaml, sql, markup, css, ruby, php, lua

    var keywords: Set<String> {
      switch self {
      case .swift:
        return ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while", "any"]
      case .javascript:
        return ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "readonly", "return", "set", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"]
      case .python:
        return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield", "match", "case"]
      case .go:
        return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"]
      case .rust:
        return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
      case .java:
        return ["abstract", "boolean", "break", "case", "catch", "class", "const", "continue", "data", "default", "do", "else", "enum", "extends", "false", "final", "finally", "for", "fun", "if", "implements", "import", "interface", "is", "new", "null", "object", "override", "package", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "throws", "true", "try", "val", "var", "void", "when", "while", "using", "namespace"]
      case .c:
        return ["auto", "bool", "break", "case", "char", "class", "const", "continue", "default", "define", "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "if", "include", "inline", "int", "long", "namespace", "new", "nullptr", "private", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "true", "typedef", "union", "unsigned", "using", "void", "while", "NULL"]
      case .shell:
        return ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "export", "local", "readonly", "set", "unset", "echo", "cd", "source", "exit", "sudo"]
      case .json:
        return ["true", "false", "null"]
      case .yaml:
        return ["true", "false", "null", "yes", "no", "on", "off"]
      case .sql:
        return ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "null", "is", "in", "like", "distinct", "union", "all", "case", "when", "then", "else", "end", "primary", "key", "foreign", "references", "default", "exists", "with", "count", "asc", "desc"]
      case .markup:
        return []
      case .css:
        return ["important", "media", "import", "keyframes", "from", "to", "root", "hover", "before", "after"]
      case .ruby:
        return ["alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "require", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"]
      case .php:
        return ["abstract", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo", "else", "elseif", "extends", "false", "final", "for", "foreach", "function", "if", "implements", "interface", "namespace", "new", "null", "private", "protected", "public", "return", "static", "switch", "this", "throw", "true", "try", "use", "while"]
      case .lua:
        return ["and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while"]
      }
    }

    var lineComment: String? {
      switch self {
      case .python, .shell, .yaml, .ruby: return "#"
      case .sql, .lua: return "--"
      case .json, .markup, .css: return nil
      default: return "//"
      }
    }

    var hasBlockComments: Bool {
      switch self {
      case .python, .shell, .yaml, .ruby, .json, .lua: return false
      default: return true
      }
    }

    var keywordsAreCaseInsensitive: Bool { self == .sql }
  }

  static func tokens(in code: String, language: Language) -> [Token] {
    if language == .markup { return markupTokens(in: code) }
    var tokens: [Token] = []
    let keywords = language.keywords
    var index = code.startIndex
    while index < code.endIndex {
      let character = code[index]
      // 注释
      if let marker = language.lineComment, code[index...].hasPrefix(marker),
         !(language == .shell && index > code.startIndex && !code[code.index(before: index)].isWhitespace) {
        let end = code[index...].firstIndex(of: "\n") ?? code.endIndex
        tokens.append(Token(range: index..<end, kind: .comment))
        index = end
        continue
      }
      if language.hasBlockComments, code[index...].hasPrefix("/*") {
        let searchStart = code.index(index, offsetBy: 2, limitedBy: code.endIndex) ?? code.endIndex
        let end = code[searchStart...].range(of: "*/")?.upperBound ?? code.endIndex
        tokens.append(Token(range: index..<end, kind: .comment))
        index = end
        continue
      }
      // 字符串
      if character == "\"" || character == "'" || (character == "`" && language == .javascript) {
        let end = stringEnd(in: code, from: index, quote: character)
        tokens.append(Token(range: index..<end, kind: language == .json && isJSONKey(code, after: end) ? .attribute : .string))
        index = end
        continue
      }
      // 数字
      if character.isNumber, index == code.startIndex || !isIdentifierCharacter(code[code.index(before: index)]) {
        var end = code.index(after: index)
        while end < code.endIndex, code[end].isHexDigit || code[end] == "." || code[end] == "_" || code[end] == "x" {
          end = code.index(after: end)
        }
        tokens.append(Token(range: index..<end, kind: .number))
        index = end
        continue
      }
      // 标识符 / 关键字
      if isIdentifierStart(character) {
        var end = code.index(after: index)
        while end < code.endIndex, isIdentifierCharacter(code[end]) { end = code.index(after: end) }
        let word = String(code[index..<end])
        let isKeyword = language.keywordsAreCaseInsensitive ? keywords.contains(word.lowercased()) : keywords.contains(word)
        if isKeyword {
          tokens.append(Token(range: index..<end, kind: .keyword))
        } else if language == .yaml, end < code.endIndex, code[end] == ":", isLineLeading(code, index) {
          tokens.append(Token(range: index..<end, kind: .attribute))
        }
        index = end
        continue
      }
      index = code.index(after: index)
    }
    return tokens
  }

  private static func markupTokens(in code: String) -> [Token] {
    var tokens: [Token] = []
    var index = code.startIndex
    while index < code.endIndex {
      if code[index...].hasPrefix("<!--") {
        let end = code[index...].range(of: "-->")?.upperBound ?? code.endIndex
        tokens.append(Token(range: index..<end, kind: .comment))
        index = end
        continue
      }
      if code[index] == "<" {
        var cursor = code.index(after: index)
        if cursor < code.endIndex, code[cursor] == "/" || code[cursor] == "?" || code[cursor] == "!" { cursor = code.index(after: cursor) }
        let nameStart = cursor
        while cursor < code.endIndex, isIdentifierCharacter(code[cursor]) || code[cursor] == "-" || code[cursor] == ":" {
          cursor = code.index(after: cursor)
        }
        if cursor > nameStart {
          tokens.append(Token(range: index..<cursor, kind: .tag))
          // 标签内部的属性与值
          while cursor < code.endIndex, code[cursor] != ">" {
            if code[cursor] == "\"" || code[cursor] == "'" {
              let end = stringEnd(in: code, from: cursor, quote: code[cursor])
              tokens.append(Token(range: cursor..<end, kind: .string))
              cursor = end
            } else if isIdentifierStart(code[cursor]) {
              var end = code.index(after: cursor)
              while end < code.endIndex, isIdentifierCharacter(code[end]) || code[end] == "-" || code[end] == ":" {
                end = code.index(after: end)
              }
              tokens.append(Token(range: cursor..<end, kind: .attribute))
              cursor = end
            } else {
              cursor = code.index(after: cursor)
            }
          }
          index = cursor
          continue
        }
      }
      index = code.index(after: index)
    }
    return tokens
  }

  private static func stringEnd(in code: String, from start: String.Index, quote: Character) -> String.Index {
    var cursor = code.index(after: start)
    while cursor < code.endIndex {
      let character = code[cursor]
      if character == "\\" {
        cursor = code.index(cursor, offsetBy: 2, limitedBy: code.endIndex) ?? code.endIndex
        continue
      }
      if character == quote { return code.index(after: cursor) }
      // 普通引号字符串不跨行：没闭合就收在行尾，免得一个撇号把后面整段都染成字符串。
      if character == "\n", quote != "`" { return cursor }
      cursor = code.index(after: cursor)
    }
    return code.endIndex
  }

  private static func isJSONKey(_ code: String, after end: String.Index) -> Bool {
    var cursor = end
    while cursor < code.endIndex, code[cursor] == " " || code[cursor] == "\t" { cursor = code.index(after: cursor) }
    return cursor < code.endIndex && code[cursor] == ":"
  }

  private static func isLineLeading(_ code: String, _ index: String.Index) -> Bool {
    var cursor = index
    while cursor > code.startIndex {
      let previous = code.index(before: cursor)
      if code[previous] == "\n" { return true }
      if !(code[previous] == " " || code[previous] == "\t" || code[previous] == "-") { return false }
      cursor = previous
    }
    return true
  }

  private static func isIdentifierStart(_ character: Character) -> Bool {
    character == "_" || character == "$" || character == "@" || (character.isLetter && character.isASCII)
  }

  private static func isIdentifierCharacter(_ character: Character) -> Bool {
    character == "_" || character == "$" || ((character.isLetter || character.isNumber) && character.isASCII)
  }

  static func color(for kind: TokenKind) -> Color {
    switch kind {
    case .keyword: return Color(nsColor: .systemPink)
    case .string: return Color(nsColor: .systemRed)
    case .comment: return Color(nsColor: .secondaryLabelColor)
    case .number: return Color(nsColor: .systemPurple)
    case .tag: return Color(nsColor: .systemBlue)
    case .attribute: return Color(nsColor: .systemTeal)
    }
  }

  /// 着色后的代码。按「语言 + 内容」缓存：阅读区重绘时代码卡的 body 会被反复求值。
  @MainActor
  static func highlighted(_ code: String, language raw: String?) -> AttributedString {
    let key = "\(raw ?? "")\u{0}\(code)"
    if let cached = cache[key] { return cached }
    var result = AttributedString(code)
    if let language = language(for: raw), code.utf8.count <= maximumHighlightedBytes {
      for token in tokens(in: code, language: language) {
        guard let lower = AttributedString.Index(token.range.lowerBound, within: result),
              let upper = AttributedString.Index(token.range.upperBound, within: result)
        else { continue }
        result[lower..<upper].foregroundColor = color(for: token.kind)
        if token.kind == .comment { result[lower..<upper].inlinePresentationIntent = .emphasized }
      }
    }
    if cache.count > 64 { cache.removeAll() }
    cache[key] = result
    return result
  }

  /// 超长代码（比如整份压缩后的脚本）不上色，照单色显示。
  static let maximumHighlightedBytes = 200_000
  @MainActor private static var cache: [String: AttributedString] = [:]
}
