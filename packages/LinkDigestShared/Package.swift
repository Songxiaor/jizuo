// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LinkDigestShared",
  platforms: [
    .macOS(.v15),
    .iOS(.v17),
  ],
  products: [
    .library(name: "LinkDigestShared", targets: ["LinkDigestShared"]),
  ],
  targets: [
    .target(
      name: "LinkDigestShared",
      linkerSettings: [
        .linkedFramework("CloudKit"),
        .linkedFramework("Security"),
      ]
    ),
    .testTarget(
      name: "LinkDigestSharedTests",
      dependencies: ["LinkDigestShared"]
    ),
  ]
)
