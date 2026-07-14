// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "LinkDigest", platforms: [.macOS(.v15)], products: [
  .library(name: "LinkDigestCore", targets: ["LinkDigestCore"]),
  .library(name: "LinkDigestAdapters", targets: ["LinkDigestAdapters"]),
  .library(name: "LinkDigestTransport", targets: ["LinkDigestTransport"]),
  .executable(name: "LinkDigestApp", targets: ["LinkDigestApp"]),
  .executable(name: "LinkDigestNativeHost", targets: ["LinkDigestNativeHost"])
], targets: [
  .target(name: "LinkDigestCore", resources: [.copy("Resources")]),
  .target(
    name: "LinkDigestAdapters",
    dependencies: ["LinkDigestCore"],
    linkerSettings: [.linkedFramework("Security")]
  ),
  .target(name: "LinkDigestTransport", dependencies: ["LinkDigestCore"]),
  .executableTarget(name: "LinkDigestApp", dependencies: ["LinkDigestCore", "LinkDigestAdapters", "LinkDigestTransport"]),
  .executableTarget(name: "LinkDigestNativeHost", dependencies: ["LinkDigestCore", "LinkDigestTransport"]),
  .testTarget(name: "LinkDigestCoreTests", dependencies: ["LinkDigestCore"]),
  .testTarget(
    name: "LinkDigestAdaptersTests",
    dependencies: ["LinkDigestAdapters"],
    linkerSettings: [.linkedFramework("Network")]
  ),
  .testTarget(name: "LinkDigestAppTests", dependencies: ["LinkDigestApp", "LinkDigestCore"]),
  .testTarget(name: "LinkDigestTransportTests", dependencies: ["LinkDigestTransport"])
])
