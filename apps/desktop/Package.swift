// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LinkDigest",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "LinkDigestCore", targets: ["LinkDigestCore"]),
    .library(name: "LinkDigestAdapters", targets: ["LinkDigestAdapters"]),
    .library(name: "LinkDigestTransport", targets: ["LinkDigestTransport"]),
    .library(name: "LinkDigestPersistence", targets: ["LinkDigestPersistence"]),
    .executable(name: "LinkDigestApp", targets: ["LinkDigestApp"]),
    .executable(name: "LinkDigestNativeHost", targets: ["LinkDigestNativeHost"]),
    .executable(name: "LinkDigestHistoryBenchmark", targets: ["LinkDigestHistoryBenchmark"]),
    .executable(name: "LinkDigestManualSampleVerifier", targets: ["LinkDigestManualSampleVerifier"]),
    .executable(name: "LinkDigestBrowserSupportCrashHarness", targets: ["LinkDigestBrowserSupportCrashHarness"]),
    .executable(name: "LinkDigestLoopV1Verifier", targets: ["LinkDigestLoopV1Verifier"])
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
  ],
  targets: [
  .target(name: "LinkDigestCore", resources: [.copy("Resources")]),
  .target(
    name: "LinkDigestAdapters",
    dependencies: ["LinkDigestCore"],
    linkerSettings: [
      .linkedFramework("Security"),
      .linkedFramework("CFNetwork"),
      .linkedFramework("AVFoundation"),
      .linkedFramework("Speech"),
      .linkedFramework("Vision"),
      .linkedFramework("WebKit"),
    ]
  ),
  .target(name: "LinkDigestTransport", dependencies: ["LinkDigestCore"]),
  .target(
    name: "LinkDigestPersistence",
    dependencies: ["LinkDigestCore", .product(name: "GRDB", package: "GRDB.swift")]
  ),
  .executableTarget(
    name: "LinkDigestApp",
    dependencies: ["LinkDigestCore", "LinkDigestAdapters", "LinkDigestTransport", "LinkDigestPersistence"],
    linkerSettings: [.linkedFramework("AVKit")]
  ),
  .executableTarget(name: "LinkDigestNativeHost", dependencies: ["LinkDigestCore", "LinkDigestTransport"]),
  .executableTarget(
    name: "LinkDigestHistoryBenchmark",
    dependencies: ["LinkDigestCore", "LinkDigestPersistence"],
    swiftSettings: [.define("LINKDIGEST_RELEASE_BENCHMARK", .when(configuration: .release))]
  ),
  .executableTarget(
    name: "LinkDigestManualSampleVerifier",
    dependencies: ["LinkDigestCore", "LinkDigestAdapters"]
  ),
  .executableTarget(name: "LinkDigestBrowserSupportCrashHarness", dependencies: ["LinkDigestCore"]),
  .executableTarget(
    name: "LinkDigestLoopV1Verifier",
    dependencies: ["LinkDigestCore", "LinkDigestAdapters", "LinkDigestPersistence"]
  ),
  .testTarget(name: "LinkDigestCoreTests", dependencies: ["LinkDigestCore"]),
  .testTarget(
    name: "LinkDigestAdaptersTests",
    dependencies: ["LinkDigestAdapters"],
    resources: [.copy("Fixtures")],
    linkerSettings: [.linkedFramework("Network")]
  ),
  .testTarget(name: "LinkDigestAppTests", dependencies: ["LinkDigestApp", "LinkDigestAdapters", "LinkDigestCore", "LinkDigestPersistence"]),
  .testTarget(name: "LinkDigestNativeHostTests", dependencies: ["LinkDigestNativeHost"]),
  .testTarget(name: "LinkDigestTransportTests", dependencies: ["LinkDigestTransport"]),
  .testTarget(name: "LinkDigestPersistenceTests", dependencies: ["LinkDigestCore", "LinkDigestPersistence", .product(name: "GRDB", package: "GRDB.swift")])
])
