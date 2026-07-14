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

  private func validate(_ value: Any, against schema: [String: Any], path: String) throws {
    if let reference = schema["$ref"] as? String {
      try validate(value, against: try resolve(reference), path: path)
      return
    }

    if let alternatives = schema["oneOf"] as? [[String: Any]] {
      let matches = alternatives.filter { (try? validate(value, against: $0, path: path)) != nil }
      guard matches.count == 1 else { throw JSONSchemaValidationError.invalid("\(path) does not match exactly one schema") }
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

enum CaptureContractSchema {
  static func validator() throws -> JSONSchemaValidator {
    guard let url = Bundle.module.url(forResource: "capture-envelope-v1.schema", withExtension: "json", subdirectory: "Resources/contracts") else {
      throw JSONSchemaValidationError.invalid("bundled capture schema is missing")
    }
    return try JSONSchemaValidator(schemaData: Data(contentsOf: url))
  }
}
