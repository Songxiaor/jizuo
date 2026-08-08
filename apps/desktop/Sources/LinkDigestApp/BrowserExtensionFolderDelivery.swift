import Foundation

/// 把 App 内冻结的浏览器扩展复制到用户可直接选择的固定目录。
///
/// Chrome 的“加载已解压的扩展程序”面板不会把 `.app` 当普通文件夹展开；即使扩展
/// 已经放在 App bundle 里，用户也选不到。因此按钮不能只 reveal bundle 内资源，
/// 而要先交付到 Application Support，再在 Finder 中显示那个稳定目录。
struct BrowserExtensionFolderDelivery {
  static let bundledDirectoryName = "BrowserExtension"
  static let deliveredDirectoryName = "汲作浏览器扩展"

  let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func bundledSource(in bundle: Bundle = .main) -> URL? {
    bundle.resourceURL?.appendingPathComponent(Self.bundledDirectoryName, isDirectory: true)
  }

  func defaultDestinationParent() throws -> URL {
    guard let applicationSupport = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw DeliveryError.applicationSupportUnavailable
    }
    return applicationSupport.appendingPathComponent("LinkDigest", isDirectory: true)
  }

  /// 使用同目录 staging + rename，避免复制到一半就把残缺目录展示给 Chrome。
  /// 已有目录也只在新副本完整通过 manifest/symlink 校验后才替换；替换失败会恢复旧目录。
  func deliver(source: URL, destinationParent: URL) throws -> URL {
    try validateExtensionDirectory(source)
    if destinationParent.isFileURL == false {
      throw DeliveryError.unsafeDestination
    }
    try fileManager.createDirectory(
      at: destinationParent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755]
    )

    let destination = destinationParent.appendingPathComponent(
      Self.deliveredDirectoryName,
      isDirectory: true
    )
    let token = UUID().uuidString
    let staging = destinationParent.appendingPathComponent(
      ".\(Self.deliveredDirectoryName).staging-\(token)",
      isDirectory: true
    )
    let previous = destinationParent.appendingPathComponent(
      ".\(Self.deliveredDirectoryName).previous-\(token)",
      isDirectory: true
    )

    defer {
      try? fileManager.removeItem(at: staging)
      try? fileManager.removeItem(at: previous)
    }
    try fileManager.copyItem(at: source, to: staging)
    try validateExtensionDirectory(staging)

    if fileManager.fileExists(atPath: destination.path) {
      let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw DeliveryError.unsafeDestination
      }
      try fileManager.moveItem(at: destination, to: previous)
      do {
        try fileManager.moveItem(at: staging, to: destination)
      } catch {
        try? fileManager.moveItem(at: previous, to: destination)
        throw error
      }
      try fileManager.removeItem(at: previous)
    } else {
      try fileManager.moveItem(at: staging, to: destination)
    }

    try validateExtensionDirectory(destination)
    return destination
  }

  func validateExtensionDirectory(_ directory: URL) throws {
    let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw DeliveryError.invalidExtensionDirectory
    }
    let manifest = directory.appendingPathComponent("manifest.json", isDirectory: false)
    let manifestValues = try manifest.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true else {
      throw DeliveryError.missingManifest
    }

    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isSymbolicLinkKey],
      options: [],
      errorHandler: { _, _ in false }
    ) else {
      throw DeliveryError.invalidExtensionDirectory
    }
    for case let entry as URL in enumerator {
      if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        throw DeliveryError.symbolicLinkFound
      }
    }
  }

  enum DeliveryError: LocalizedError {
    case applicationSupportUnavailable
    case invalidExtensionDirectory
    case missingManifest
    case symbolicLinkFound
    case unsafeDestination

    var errorDescription: String? {
      switch self {
      case .applicationSupportUnavailable:
        "系统没有返回 Application Support 目录。"
      case .invalidExtensionDirectory:
        "内置扩展不是可读取的真实文件夹。"
      case .missingManifest:
        "内置扩展缺少 manifest.json。"
      case .symbolicLinkFound:
        "内置扩展包含不安全的符号链接。"
      case .unsafeDestination:
        "扩展交付位置不是可安全替换的真实文件夹。"
      }
    }
  }
}
