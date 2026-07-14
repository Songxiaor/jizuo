import Foundation

public enum FixtureRunner {
  public static func run(directory: URL) throws -> [(String, Bool, String?)] {
    let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: directory.appendingPathComponent("fixture-manifest.json")))
    return try manifest.fixtures.map { fixture in
      var data = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(fixture.file))) as! [String: Any]
      if let mutation = fixture.mutation { var capture = data["capture"] as! [String: Any]; capture["text"] = String(repeating: mutation.unit, count: mutation.repeatCount ?? 0); capture["characterCount"] = mutation.repeatCount ?? 0; data["capture"] = capture }
      let value = try? JSONSerialization.data(withJSONObject: data)
      let valid = value.flatMap { try? CaptureValidator.decode($0) } != nil
      return (fixture.name, valid == (fixture.expect == "valid"), fixture.errorCode)
    }
  }
}
