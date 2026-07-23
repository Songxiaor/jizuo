import Foundation

public enum FixtureRunner {
  public static func run(directory: URL) throws -> [(String, Bool, String?)] {
    try run(directory: directory, schemaLocator: nil)
  }

  static func run(
    directory: URL,
    schemaLocator: CaptureWireContractSchema.ResourceLocator?
  ) throws -> [(String, Bool, String?)] {
    let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("fixture-manifest.json")))
    return try manifest.fixtures.map { fixture in
      var data = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(fixture.file))) as! [String: Any]
      if let mutation = fixture.mutation { var capture = data["capture"] as! [String: Any]; capture["text"] = String(repeating: mutation.unit, count: mutation.repeatCount ?? 0); capture["characterCount"] = mutation.repeatCount ?? 0; data["capture"] = capture }
      let value = try? JSONSerialization.data(withJSONObject: data)
      let declaredSchema = fixture.schema ?? manifest.schema
      let valid: Bool
      if declaredSchema.hasSuffix("capture-envelope-v1.schema.json") {
        valid = value.flatMap { try? CaptureValidator.decode($0, schemaLocator: schemaLocator) } != nil
      } else if declaredSchema.hasSuffix("capture-envelope-v2.schema.json") {
        valid = value.flatMap { try? CaptureEnvelopeV2Validator.decode($0, schemaLocator: schemaLocator) } != nil
      } else {
        valid = false
      }
      return (fixture.name, valid == (fixture.expect == "valid"), fixture.errorCode)
    }
  }
}
