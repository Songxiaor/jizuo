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
    .executable(name: "LinkDigestMCP", targets: ["LinkDigestMCP"]),
    .executable(name: "LinkDigestNativeHost", targets: ["LinkDigestNativeHost"]),
    .executable(name: "LinkDigestHistoryBenchmark", targets: ["LinkDigestHistoryBenchmark"]),
    .executable(name: "LinkDigestManualSampleVerifier", targets: ["LinkDigestManualSampleVerifier"]),
    .executable(name: "LinkDigestBrowserSupportCrashHarness", targets: ["LinkDigestBrowserSupportCrashHarness"]),
    .executable(name: "LinkDigestLoopV1Verifier", targets: ["LinkDigestLoopV1Verifier"])
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5"),
    // 本机说话人分离（2026-09-23 Syc 批准）。代码 Apache-2.0；分离模型 CC-BY-4.0，
    // 首次使用时从 HuggingFace 下载到本机，之后离线运行，录音不出本机。
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.16.1"),
    .package(path: "../../packages/LinkDigestShared"),
  ],
  targets: [
  .target(
    name: "LinkDigestCore",
    dependencies: [
      .product(name: "LinkDigestShared", package: "LinkDigestShared"),
    ],
    resources: [.copy("Resources")]
  ),
  .target(
    name: "LinkDigestAdapters",
    dependencies: ["LinkDigestCore", .product(name: "FluidAudio", package: "FluidAudio")],
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
  .target(name: "LinkDigestMCPKit"),
  .executableTarget(name: "LinkDigestMCP", dependencies: ["LinkDigestMCPKit", "LinkDigestTransport"]),
  .testTarget(name: "LinkDigestMCPKitTests", dependencies: ["LinkDigestMCPKit"]),
  .target(
    name: "LinkDigestPersistence",
    dependencies: ["LinkDigestCore", .product(name: "GRDB", package: "GRDB.swift")]
  ),
  .executableTarget(
    name: "LinkDigestApp",
    dependencies: [
      "LinkDigestMCPKit",
      "LinkDigestCore",
      "LinkDigestAdapters",
      "LinkDigestTransport",
      "LinkDigestPersistence",
      .product(name: "LinkDigestShared", package: "LinkDigestShared"),
      .product(name: "Sparkle", package: "Sparkle"),
    ],
    linkerSettings: [
      .linkedFramework("AVKit"),
      .linkedFramework("CloudKit"),
    ]
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
  .testTarget(name: "LinkDigestCoreTests", dependencies: ["LinkDigestCore", .product(name: "LinkDigestShared", package: "LinkDigestShared")], resources: [.copy("Fixtures")]),
  .testTarget(
    name: "LinkDigestAdaptersTests",
    dependencies: ["LinkDigestAdapters"],
    resources: [.copy("Fixtures")],
    linkerSettings: [.linkedFramework("Network")]
  ),
  .testTarget(name: "LinkDigestAppTests", dependencies: ["LinkDigestApp", "LinkDigestAdapters", "LinkDigestCore", "LinkDigestPersistence", .product(name: "LinkDigestShared", package: "LinkDigestShared")]),
  .testTarget(name: "LinkDigestNativeHostTests", dependencies: ["LinkDigestNativeHost"]),
  .testTarget(name: "LinkDigestTransportTests", dependencies: ["LinkDigestTransport"]),
  .testTarget(name: "LinkDigestPersistenceTests", dependencies: ["LinkDigestCore", "LinkDigestPersistence", .product(name: "GRDB", package: "GRDB.swift")])
])
