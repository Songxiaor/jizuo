import CoreFoundation
import Foundation

enum JSONSchemaValidationError: Error, Equatable {
  case invalid(String)
}

struct JSONSchemaValidator {
  private let root: [String: Any]

  init(schemaData: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
      throw JSONSchemaValidationError.invalid("schema root is not an object")
    }
    self.root = root
  }

  func validate(_ value: Any) throws {
    try validate(value, against: root, path: "$")
  }

  func validateDefinition(_ name: String, value: Any) throws {
    try validate(value, against: try resolve("#/$defs/\(name)"), path: "$.\(name)")
  }

  private func validate(_ value: Any, against schema: [String: Any], path: String) throws {
    if let reference = schema["$ref"] as? String {
      try validate(value, against: try resolve(reference), path: path)
      return
    }

    if let alternatives = schema["oneOf"] as? [[String: Any]] {
      let matches = alternatives.filter { (try? validate(value, against: $0, path: path)) != nil }
      guard matches.count == 1 else { throw JSONSchemaValidationError.invalid("\(path) does not match exactly one schema") }
    }
    if let forbidden = schema["not"] as? [String: Any], (try? validate(value, against: forbidden, path: path)) != nil {
      throw JSONSchemaValidationError.invalid("\(path) matches a forbidden schema")
    }

    if let types = schemaTypes(schema), !types.contains(where: { matchesType($0, value: value) }) {
      throw JSONSchemaValidationError.invalid("\(path) has the wrong type")
    }

    if let constant = schema["const"], !jsonEqual(constant, value) {
      throw JSONSchemaValidationError.invalid("\(path) does not match const")
    }
    if let values = schema["enum"] as? [Any], !values.contains(where: { jsonEqual($0, value) }) {
      throw JSONSchemaValidationError.invalid("\(path) is outside enum")
    }

    if let string = value as? String {
      let length = string.unicodeScalars.count
      if let minimum = integer(schema["minLength"]), length < minimum { throw JSONSchemaValidationError.invalid("\(path) is too short") }
      if let maximum = integer(schema["maxLength"]), length > maximum { throw JSONSchemaValidationError.invalid("\(path) is too long") }
      if let pattern = schema["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil { throw JSONSchemaValidationError.invalid("\(path) does not match pattern") }
      if let format = schema["format"] as? String { try validateFormat(format, string: string, path: path) }
    }

    if let number = value as? NSNumber, !isBoolean(number) {
      let numeric = number.doubleValue
      if let minimum = (schema["minimum"] as? NSNumber)?.doubleValue, numeric < minimum { throw JSONSchemaValidationError.invalid("\(path) is below minimum") }
      if let maximum = (schema["maximum"] as? NSNumber)?.doubleValue, numeric > maximum { throw JSONSchemaValidationError.invalid("\(path) is above maximum") }
    }

    if let object = value as? [String: Any] {
      if let required = schema["required"] as? [String] {
        for key in required where object[key] == nil { throw JSONSchemaValidationError.invalid("\(path).\(key) is required") }
      }
      if let properties = schema["properties"] as? [String: Any] {
        for (key, child) in object {
          if let childSchema = properties[key] as? [String: Any] {
            try validate(child, against: childSchema, path: "\(path).\(key)")
          } else if schema["additionalProperties"] as? Bool == false {
            throw JSONSchemaValidationError.invalid("\(path).\(key) is not allowed")
          }
        }
      }
    }
  }

  private func resolve(_ reference: String) throws -> [String: Any] {
    guard reference.hasPrefix("#/") else { throw JSONSchemaValidationError.invalid("external refs are unsupported") }
    var current: Any = root
    for component in reference.dropFirst(2).split(separator: "/") {
      let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
      guard let object = current as? [String: Any], let next = object[key] else { throw JSONSchemaValidationError.invalid("unresolved ref \(reference)") }
      current = next
    }
    guard let schema = current as? [String: Any] else { throw JSONSchemaValidationError.invalid("ref is not a schema") }
    return schema
  }

  private func schemaTypes(_ schema: [String: Any]) -> [String]? {
    if let type = schema["type"] as? String { return [type] }
    return schema["type"] as? [String]
  }

  private func matchesType(_ type: String, value: Any) -> Bool {
    switch type {
    case "object": return value is [String: Any]
    case "array": return value is [Any]
    case "string": return value is String
    case "null": return value is NSNull
    case "boolean": return (value as? NSNumber).map(isBoolean) == true
    case "number": return (value as? NSNumber).map { !isBoolean($0) } == true
    case "integer": return (value as? NSNumber).map { !isBoolean($0) && $0.doubleValue.rounded() == $0.doubleValue } == true
    default: return false
    }
  }

  private func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private func integer(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  private func jsonEqual(_ left: Any, _ right: Any) -> Bool {
    guard let left = left as? NSObject, let right = right as? NSObject else { return false }
    return left.isEqual(right)
  }

  private func validateFormat(_ format: String, string: String, path: String) throws {
    switch format {
    case "date-time":
      let standard = ISO8601DateFormatter()
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions.insert(.withFractionalSeconds)
      guard standard.date(from: string) != nil || fractional.date(from: string) != nil else { throw JSONSchemaValidationError.invalid("\(path) is not date-time") }
    case "uri":
      guard let components = URLComponents(string: string), components.scheme != nil else { throw JSONSchemaValidationError.invalid("\(path) is not an absolute URI") }
    default:
      break
    }
  }
}

// Forward-compatible wire schema: unknown optional fields are accepted.
// Strict persisted invariants live in Migration/Repository checks.
enum CaptureWireContractSchema {
  static let resourceBundleName = "LinkDigest_LinkDigestCore.bundle"
  static let schemaRelativePath = "Resources/contracts/capture-envelope-v1.schema.json"
  static let schemaV2RelativePath = "Resources/contracts/capture-envelope-v2.schema.json"

  enum ResourceMode: Equatable {
    case application(resourceURL: URL?)
    case executable(executableURL: URL?)
    case test(moduleResourceURL: URL?)
  }

  struct ResourceLocator {
    let mode: ResourceMode

    func schemaURL(version: Int = 1, fileManager: FileManager = .default) throws -> URL {
      let relativePath = version == 2 ? schemaV2RelativePath : schemaRelativePath
      let schemaURL: URL?
      switch mode {
      case let .application(resourceURL):
        schemaURL = resourceURL?
          .appendingPathComponent(resourceBundleName, isDirectory: true)
          .appendingPathComponent(relativePath, isDirectory: false)
      case let .executable(executableURL):
        schemaURL = executableURL?
          .deletingLastPathComponent()
          .appendingPathComponent(resourceBundleName, isDirectory: true)
          .appendingPathComponent(relativePath, isDirectory: false)
      case let .test(moduleResourceURL):
        // Bundle.module is intentionally reachable only through this explicit
        // test mode. Production App/Host lookup can never fall back to a
        // compile-time SwiftPM .build path. Bundle.resourceURL already points
        // at the bundle's Resources directory, unlike the two bundle-root
        // production paths above.
        schemaURL = moduleResourceURL?
          .appendingPathComponent(
            version == 2 ? "contracts/capture-envelope-v2.schema.json" : "contracts/capture-envelope-v1.schema.json",
            isDirectory: false
          )
      }

      guard let schemaURL else {
        throw JSONSchemaValidationError.invalid("bundled capture schema location is unavailable")
      }
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: schemaURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw JSONSchemaValidationError.invalid("bundled capture schema is missing")
      }
      return schemaURL
    }
  }

  static func runtimeLocator(
    mainBundle: Bundle = .main,
    executableURL: URL? = Bundle.main.executableURL
  ) -> ResourceLocator {
    if mainBundle.bundleURL.pathExtension == "app" {
      return ResourceLocator(mode: .application(resourceURL: mainBundle.resourceURL))
    }
    if mainBundle.bundleURL.pathExtension == "xctest" || NSClassFromString("XCTestCase") != nil {
      // XCTest is the only runtime allowed to select the explicit module
      // fallback. A standard .app never reaches this branch.
      return testLocator()
    }
    return ResourceLocator(mode: .executable(executableURL: executableURL))
  }

  static func testLocator(moduleResourceURL: URL? = Bundle.module.resourceURL) -> ResourceLocator {
    ResourceLocator(mode: .test(moduleResourceURL: moduleResourceURL))
  }

  static func validator(locator: ResourceLocator? = nil) throws -> JSONSchemaValidator {
    try validator(version: 1, locator: locator)
  }

  static func validator(version: Int, locator: ResourceLocator? = nil) throws -> JSONSchemaValidator {
    let locator = locator ?? runtimeLocator()
    let url = try locator.schemaURL(version: version)
    guard let data = try? Data(contentsOf: url) else {
      throw JSONSchemaValidationError.invalid("bundled capture schema is missing")
    }
    return try JSONSchemaValidator(schemaData: data)
  }
}
