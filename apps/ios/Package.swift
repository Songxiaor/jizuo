// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LinkDigestIOS",
  platforms: [
    .iOS(.v17),
    .macOS(.v15),
  ],
  products: [
    .library(name: "LinkDigestIOS", targets: ["LinkDigestIOS"]),
  ],
  dependencies: [
    .package(path: "../../packages/LinkDigestShared"),
  ],
  targets: [
    .target(
      name: "LinkDigestIOS",
      dependencies: [
        .product(name: "LinkDigestShared", package: "LinkDigestShared"),
      ],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("Speech"),
        .linkedFramework("WebKit"),
      ]
    ),
    // Mac 上可先跑通 UI；真机/模拟器仍需用 Xcode 打开本目录并加 iOS App Target。
    .executableTarget(
      name: "LinkDigestIOSDevApp",
      dependencies: ["LinkDigestIOS"],
      path: "App",
      exclude: [
        "Info.plist",
        "LinkDigestIOS.entitlements",
        "LinkDigestIOS.CloudKit.entitlements",
      ]
    ),
    .testTarget(
      name: "LinkDigestIOSTests",
      dependencies: ["LinkDigestIOS"]
    ),
  ]
)
