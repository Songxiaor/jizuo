import CryptoKit
import Darwin
import Foundation

/// The Browser Support installer owns only LinkDigest's one Native Messaging
/// manifest basename and its receipt.  Its production root is the current
/// user's home directory; tests must inject an isolated root instead.
public enum BrowserSupportBrowser: String, CaseIterable, Codable, Sendable, Equatable, Identifiable {
  case chrome
  case brave
  case edge

  public var id: String { rawValue }
  public var displayName: String {
    switch self {
    case .chrome: "Chrome"
    case .brave: "Brave"
    case .edge: "Edge"
    }
  }
}

public enum BrowserSupportInstallState: Sendable, Equatable {
  case unavailable
  case notInstalled
  case installed
  /// The on-disk manifest is byte-identical to what this app would install and
  /// the receipt binds that exact content; only the recorded host/package
  /// hashes went stale because the app itself was updated. Functionally
  /// healthy — repair merely refreshes the receipt.
  case installedAppUpdated
  case drifted
  case unknownManifest
  case invalidReceipt
  case unavailableArtifact
}

public struct BrowserSupportStatus: Sendable, Equatable, Identifiable {
  public let browser: BrowserSupportBrowser
  public let state: BrowserSupportInstallState
  public let hasRecoverableBackup: Bool
  public let replacementFingerprint: String?

  public var id: BrowserSupportBrowser { browser }
  public init(browser: BrowserSupportBrowser, state: BrowserSupportInstallState, hasRecoverableBackup: Bool, replacementFingerprint: String? = nil) {
    self.browser = browser
    self.state = state
    self.hasRecoverableBackup = hasRecoverableBackup
    self.replacementFingerprint = replacementFingerprint
  }
}

public enum BrowserSupportInstallerError: Error, Sendable, Equatable {
  case browserNotDetected
  case frozenArtifactUnavailable
  case confirmationRequired
  case confirmationStale
  case uninstallRefused
  case restoreRefused
  case unsafeFilesystemState
  case transactionFailed
}

public protocol BrowserSupportInstalling: Sendable {
  func inspect() async -> [BrowserSupportStatus]
  func install(_ browser: BrowserSupportBrowser) async throws
  func confirmReplacement(_ browser: BrowserSupportBrowser, expectedFingerprint: String) async throws
  func uninstall(_ browser: BrowserSupportBrowser) async throws
  func restoreLatestBackup(_ browser: BrowserSupportBrowser) async throws
}

/// Frozen Loop 7 templates plus the embedded Host path.  The template SHA-256
/// values are checked before every install/repair render; an installer never
/// writes a template it cannot bind to the extension artifact.
public struct BrowserSupportFrozenArtifacts: Sendable {
  private struct Integrity: Decodable {
    let extensionID: String
    let formatVersion: Int
    let hostName: String
    let templates: [String: String]
    let version: String
  }

  fileprivate let templates: [BrowserSupportBrowser: Data]
  fileprivate let templateHashes: [BrowserSupportBrowser: String]
  fileprivate let extensionID: String
  fileprivate let hostName: String
  fileprivate let version: String
  fileprivate let hostExecutableURL: URL

  public init(
    templates: [BrowserSupportBrowser: Data],
    templateHashes: [BrowserSupportBrowser: String],
    extensionID: String,
    hostName: String,
    version: String,
    hostExecutableURL: URL
  ) throws {
    guard Set(templates.keys) == Set(BrowserSupportBrowser.allCases),
          Set(templateHashes.keys) == Set(BrowserSupportBrowser.allCases),
          extensionID.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
          !hostName.isEmpty,
          !version.isEmpty
    else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
    for browser in BrowserSupportBrowser.allCases {
      guard Self.sha256(templates[browser]!) == templateHashes[browser] else {
        throw BrowserSupportInstallerError.frozenArtifactUnavailable
      }
    }
    self.templates = templates
    self.templateHashes = templateHashes
    self.extensionID = extensionID
    self.hostName = hostName
    self.version = version
    self.hostExecutableURL = hostExecutableURL.standardizedFileURL
  }

  /// Loads the immutable resources copied into `LinkDigestCore` and the Host
  /// already sealed inside the App bundle.  It does not create any directory.
  public static func appBundled(applicationBundle: Bundle = .main) throws -> BrowserSupportFrozenArtifacts {
    try appBundled(applicationBundle: applicationBundle, resourceBundle: .module)
  }

  static func appBundled(
    applicationBundle: Bundle,
    resourceBundle: Bundle
  ) throws -> BrowserSupportFrozenArtifacts {
    guard
      let integrityURL = resourceBundle.url(forResource: "manifest-integrity", withExtension: "json", subdirectory: "browser-support"),
      let integrity = try? JSONDecoder().decode(Integrity.self, from: Data(contentsOf: integrityURL)),
      integrity.formatVersion == 1,
      Set(integrity.templates.keys) == Set(BrowserSupportBrowser.allCases.map(\.rawValue)),
      let resources = applicationBundle.resourceURL
    else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }

    var templates: [BrowserSupportBrowser: Data] = [:]
    var hashes: [BrowserSupportBrowser: String] = [:]
    for browser in BrowserSupportBrowser.allCases {
      guard
        let url = resourceBundle.url(forResource: browser.rawValue, withExtension: "json", subdirectory: "browser-support/native-host-manifests"),
        let data = try? Data(contentsOf: url),
        let hash = integrity.templates[browser.rawValue]
      else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
      templates[browser] = data
      hashes[browser] = hash
    }
    let host = resources
      .appendingPathComponent("NativeHost", isDirectory: true)
      .appendingPathComponent("LinkDigestNativeHost-0.2.0-macos-arm64", isDirectory: true)
      .appendingPathComponent("LinkDigestNativeHost", isDirectory: false)
    return try .init(
      templates: templates,
      templateHashes: hashes,
      extensionID: integrity.extensionID,
      hostName: integrity.hostName,
      version: integrity.version,
      hostExecutableURL: host
    )
  }

  fileprivate static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public actor BrowserSupportInstaller: BrowserSupportInstalling {
  private static let manifestBasename = "com.syc.linkdigest.v01.json"
  private static let receiptRelativePath = "Library/Application Support/LinkDigest/BrowserSupport/receipt-v1.json"
  private static let receiptDirectoryRelativePath = "Library/Application Support/LinkDigest/BrowserSupport"
  private static let transactionLockBasename = ".browser-support.lock"
  private static let operationJournalBasename = "operation-v1.json"

  private enum TargetKey: String, Codable, Sendable, CaseIterable {
    case chrome
    case brave
    case edge
  }

  private struct Receipt: Codable {
    struct Backup: Codable, Equatable {
      /// This is a basename, never a path.  A restore must match both this name
      /// and this digest; it must not guess from timestamp-like backup names.
      let filename: String
      let sha256: String
    }

    struct Entry: Codable, Equatable {
      let target: TargetKey
      let manifestSHA256: String
      let hostSHA256: String
      /// Older receipts do not have this field.  They fail closed as drifted,
      /// rather than claiming a package with unbound resources is healthy.
      let hostPackageSHA256: String?
      let backup: Backup?
      let version: String
    }
    let formatVersion: Int
    var entries: [Entry]
  }

  private enum ReceiptRead {
    case missing
    case valid(Receipt, Data)
    case invalid
  }

  /// The live receipt is the operation commit point.  Before it matches
  /// `afterReceipt`, recovery rolls the manifest back to `beforeManifest`; once
  /// it matches, recovery only finalizes the already-committed operation.
  private enum OperationAction: String, Codable {
    case install
    case uninstall
    case restore
  }

  private struct OperationJournal: Codable {
    let formatVersion: Int
    let operationID: String
    let action: OperationAction
    let target: TargetKey
    let beforeReceipt: Data?
    let afterReceipt: Data?
    let beforeManifest: Data?
    let afterManifest: Data?
    /// An install/repair moves a pre-existing leaf here before verification.
    /// It is both the candidate user backup and the only permitted rollback
    /// source for a process interrupted between leaf move and receipt commit.
    let backup: Receipt.Backup?
    let quarantineFilename: String?
    /// A receipt replacement detaches the old canonical receipt before a new
    /// one can be no-overwrite published.  This binding makes that otherwise
    /// transient leaf recoverable after process termination.
    let receiptQuarantineFilename: String?
    let receiptQuarantineSHA256: String?
    let manifestSHA256: String?
    let backupSHA256: String?
  }

  private struct NativeHostTemplate: Codable {
    let allowed_origins: [String]
    let description: String
    let name: String
    let path: String
    let type: String
  }

  private final class DirectoryAnchor: @unchecked Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { _ = Darwin.close(descriptor) }
  }

  private let homeRoot: URL
  private let artifacts: BrowserSupportFrozenArtifacts
  private let failureInjection: (@Sendable (String) -> Bool)?
  /// Test seams are only supplied by isolated `/private/tmp` fixtures.  The
  /// production composition root never passes either closure.
  private let terminationInjection: (@Sendable (String) -> Bool)?
  private let mutationBarrier: (@Sendable (String) -> Void)?

  /// `homeRoot` is intentionally injectable.  The app passes the real current
  /// user home only when Syc invokes a product action; all automated tests pass
  /// a unique `/private/tmp` clean-room home instead.
  public init(
    homeRoot: URL,
    artifacts: BrowserSupportFrozenArtifacts,
    failureInjection: (@Sendable (String) -> Bool)? = nil,
    terminationInjection: (@Sendable (String) -> Bool)? = nil,
    mutationBarrier: (@Sendable (String) -> Void)? = nil
  ) {
    self.homeRoot = homeRoot.standardizedFileURL
    self.artifacts = artifacts
    self.failureInjection = failureInjection
    self.terminationInjection = terminationInjection
    self.mutationBarrier = mutationBarrier
  }

  public static func appBundled() throws -> BrowserSupportInstaller {
    try .init(
      homeRoot: FileManager.default.homeDirectoryForCurrentUser,
      artifacts: .appBundled()
    )
  }

  public func inspect() async -> [BrowserSupportStatus] {
    do {
      try recoverBeforeInspection()
    } catch {
      return BrowserSupportBrowser.allCases.map {
        .init(browser: $0, state: .invalidReceipt, hasRecoverableBackup: false)
      }
    }
    return BrowserSupportBrowser.allCases.map { browser in
      let key = Self.activeTargetKey(for: browser)
      let backup = (try? recoverableBackup(for: key)) != nil
      do {
        let state = try state(for: browser)
        let fingerprint = [.drifted, .unknownManifest].contains(state) ? try replacementFingerprint(for: browser) : nil
        return .init(browser: browser, state: state, hasRecoverableBackup: backup, replacementFingerprint: fingerprint)
      } catch {
        return .init(browser: browser, state: .unavailableArtifact, hasRecoverableBackup: backup)
      }
    }
  }

  public func install(_ browser: BrowserSupportBrowser) async throws {
    try installOrRepair(browser, expectedFingerprint: nil)
  }

  public func confirmReplacement(_ browser: BrowserSupportBrowser, expectedFingerprint: String) async throws {
    try installOrRepair(browser, expectedFingerprint: expectedFingerprint)
  }

  public func uninstall(_ browser: BrowserSupportBrowser) async throws {
    try withMutationLock { try uninstallLocked(browser) }
  }

  private func uninstallLocked(_ browser: BrowserSupportBrowser) throws {
    guard try [.installed, .installedAppUpdated].contains(state(for: browser)) else { throw BrowserSupportInstallerError.uninstallRefused }
    let key = Self.activeTargetKey(for: browser)
    let target = try manifestURL(for: key)
    let receiptURL = try self.receiptURL()
    guard case let .valid(receiptValue, receiptData) = try receiptRead(at: receiptURL),
          let entry = receiptValue.entries.first(where: { $0.target == key })
    else { throw BrowserSupportInstallerError.uninstallRefused }
    let expected = try renderedManifest(for: Self.activeTemplateBrowser(for: browser))
    guard entry.manifestSHA256 == BrowserSupportFrozenArtifacts.sha256(expected), try regularFileData(at: target) == expected else {
      throw BrowserSupportInstallerError.uninstallRefused
    }
    let journal = makeJournal(
      action: .uninstall,
      target: key,
      beforeReceipt: receiptData,
      afterReceipt: try receiptRemovingEntry(from: receiptValue, key: key),
      beforeManifest: expected,
      afterManifest: nil,
      backup: nil,
      quarantineFilename: operationQuarantineFilename()
    )
    try performOperation(journal) {
      try moveExpectedLeaf(at: target, expected: expected, quarantineName: journal.quarantineFilename!)
      try ensureLeafAbsent(at: target)
      try interruptionPoint("after-manifest-before-receipt")
      try publishReceipt(journal, at: receiptURL)
    }
  }

  /// Restoring is deliberately narrower than repair: the current manifest must
  /// still be proven LinkDigest-owned by its receipt before a backup replaces it.
  public func restoreLatestBackup(_ browser: BrowserSupportBrowser) async throws {
    try withMutationLock { try restoreLatestBackupLocked(browser) }
  }

  private func restoreLatestBackupLocked(_ browser: BrowserSupportBrowser) throws {
    guard try [.installed, .installedAppUpdated].contains(state(for: browser)) else { throw BrowserSupportInstallerError.restoreRefused }
    let key = Self.activeTargetKey(for: browser)
    let receiptURL = try self.receiptURL()
    guard case let .valid(receiptValue, receiptData) = try receiptRead(at: receiptURL),
          let entry = receiptValue.entries.first(where: { $0.target == key }),
          let backup = try boundBackup(for: key, receiptBackup: entry.backup)
    else { throw BrowserSupportInstallerError.restoreRefused }
    let target = try manifestURL(for: key)
    let prior = try regularFileData(at: target)
    let backupData = try regularFileData(at: backup)
    let journal = makeJournal(
      action: .restore,
      target: key,
      beforeReceipt: receiptData,
      afterReceipt: try receiptRemovingEntry(from: receiptValue, key: key),
      beforeManifest: prior,
      afterManifest: backupData,
      backup: entry.backup,
      quarantineFilename: operationQuarantineFilename()
    )
    try performOperation(journal) {
      try moveExpectedLeaf(at: target, expected: prior, quarantineName: journal.quarantineFilename!)
      try createAtomically(backupData, at: target)
      try interruptionPoint("after-manifest-before-receipt")
      try publishReceipt(journal, at: receiptURL)
    }
  }

  private func installOrRepair(_ browser: BrowserSupportBrowser, expectedFingerprint: String?) throws {
    try withMutationLock { try installOrRepairLocked(browser, expectedFingerprint: expectedFingerprint) }
  }

  private func installOrRepairLocked(_ browser: BrowserSupportBrowser, expectedFingerprint: String?) throws {
    let currentState = try state(for: browser)
    guard currentState != .unavailable else { throw BrowserSupportInstallerError.browserNotDetected }
    guard currentState != .unavailableArtifact else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
    guard currentState != .invalidReceipt else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    if currentState == .installed { return }
    let key = Self.activeTargetKey(for: browser)
    let target = try manifestURL(for: key)
    let expected = try renderedManifest(for: Self.activeTemplateBrowser(for: browser))
    let prior = try existingRegularFileData(at: target)
    // A prior leaf that is byte-identical to our render and already bound by a
    // receipt entry is LinkDigest's own install; refreshing it takes over
    // nothing, so no replacement confirmation is demanded.
    let refreshesOwnInstall = try prior == expected && receiptHasEntry(for: key)
    if prior != nil, !refreshesOwnInstall {
      guard let expectedFingerprint else { throw BrowserSupportInstallerError.confirmationRequired }
      guard try replacementFingerprint(for: browser) == expectedFingerprint else { throw BrowserSupportInstallerError.confirmationStale }
      // `atomicWrite` receives `prior` below and therefore refuses any leaf
      // that changed after this snapshot; confirmation cannot authorize B when
      // the user saw A.
    } else if expectedFingerprint != nil {
      // A receipt with a missing manifest is a recoverable legacy interruption
      // state.  Its fingerprint binds the receipt and an explicit missing-leaf
      // sentinel, so it cannot authorize a newly appeared manifest.
      guard try receiptHasEntry(for: key) else { throw BrowserSupportInstallerError.confirmationStale }
    }
    let receiptSnapshot = try receiptSnapshot()
    let backup: Receipt.Backup? = prior.map {
      .init(filename: backupFilename(), sha256: BrowserSupportFrozenArtifacts.sha256($0))
    }
    let journal = makeJournal(
      action: .install,
      target: key,
      beforeReceipt: receiptSnapshot.data,
      afterReceipt: try receiptReplacingEntry(
        from: receiptSnapshot.receipt,
        key: key,
        manifest: expected,
        backup: backup
      ),
      beforeManifest: prior,
      afterManifest: expected,
      backup: backup,
      quarantineFilename: backup?.filename
    )
    try performOperation(journal) {
      if let prior {
        try moveExpectedLeaf(at: target, expected: prior, quarantineName: journal.quarantineFilename!)
      }
      try createAtomically(expected, at: target)
      try interruptionPoint("after-manifest-before-receipt")
      try publishReceipt(journal, at: try receiptURL(createDirectory: true))
    }
  }

  private func state(for browser: BrowserSupportBrowser) throws -> BrowserSupportInstallState {
    try validateFrozenArtifacts()
    let key = Self.activeTargetKey(for: browser)
    let directory = targetDirectory(for: key)
    guard try isSafeDirectory(directory) else { return .unavailable }
    let target = directory.appendingPathComponent(Self.manifestBasename, isDirectory: false)
    let existing = try existingRegularFileData(at: target)
    let receiptURL = try self.receiptURL()
    let receipt = try receiptRead(at: receiptURL)
    if case .invalid = receipt { return .invalidReceipt }
    let entry: Receipt.Entry? = switch receipt {
    case let .valid(value, _): value.entries.first(where: { $0.target == key })
    case .missing, .invalid: nil
    }
    guard let existing else { return entry == nil ? .notInstalled : .drifted }
    guard let entry else { return .unknownManifest }
    let expected = try renderedManifest(for: Self.activeTemplateBrowser(for: browser))
    let hostHash = try hostSHA256()
    let packageHash = try hostPackageSHA256()
    if entry.version == artifacts.version
      && entry.manifestSHA256 == BrowserSupportFrozenArtifacts.sha256(existing)
      && entry.hostSHA256 == hostHash
      && entry.hostPackageSHA256 == packageHash
      && existing == expected {
      return .installed
    }
    // Distinguish an updated app from a tampered target: when the manifest is
    // still exactly what this app would install and the receipt binds that
    // content, only the receipt snapshot is stale — not the install itself.
    if existing == expected, entry.manifestSHA256 == BrowserSupportFrozenArtifacts.sha256(existing) {
      return .installedAppUpdated
    }
    return .drifted
  }

  private func replacementFingerprint(for browser: BrowserSupportBrowser) throws -> String? {
    let key = Self.activeTargetKey(for: browser)
    let target = try manifestURL(for: key)
    let manifest = try existingRegularFileData(at: target)
    let receipt = try receiptRead(at: receiptURL())
    let receiptBytes: Data
    switch receipt {
    case .missing: receiptBytes = Data("missing".utf8)
    case let .valid(_, raw): receiptBytes = raw
    case .invalid: return nil
    }
    var payload = Data("browser-support-confirmation-v1\0".utf8)
    if let manifest {
      payload.append(manifest)
    } else {
      payload.append(Data("missing-manifest-v1".utf8))
    }
    payload.append(0)
    payload.append(receiptBytes)
    return BrowserSupportFrozenArtifacts.sha256(payload)
  }

  private func validateFrozenArtifacts() throws {
    guard try isSafeRegularFile(artifacts.hostExecutableURL), FileManager.default.isExecutableFile(atPath: artifacts.hostExecutableURL.path) else {
      throw BrowserSupportInstallerError.frozenArtifactUnavailable
    }
    for browser in BrowserSupportBrowser.allCases {
      guard let data = artifacts.templates[browser], let expectedHash = artifacts.templateHashes[browser], BrowserSupportFrozenArtifacts.sha256(data) == expectedHash else {
        throw BrowserSupportInstallerError.frozenArtifactUnavailable
      }
    }
  }

  private func renderedManifest(for browser: BrowserSupportBrowser) throws -> Data {
    guard let raw = artifacts.templates[browser] else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
    guard
      let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      Set(object.keys) == ["allowed_origins", "description", "name", "path", "type"],
      let template = try? JSONDecoder().decode(NativeHostTemplate.self, from: raw),
      template.allowed_origins == ["chrome-extension://\(artifacts.extensionID)/"],
      template.name == artifacts.hostName,
      template.path == "__LINKDIGEST_NATIVE_HOST_PATH__",
      template.type == "stdio"
    else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
    let rendered: [String: Any] = [
      "allowed_origins": template.allowed_origins,
      "description": template.description,
      "name": template.name,
      "path": artifacts.hostExecutableURL.path,
      "type": template.type,
    ]
    guard JSONSerialization.isValidJSONObject(rendered) else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
    return try JSONSerialization.data(withJSONObject: rendered, options: [.sortedKeys])
  }

  private func updateReceipt(for key: TargetKey, manifest: Data, backup: Receipt.Backup?) throws {
    let receiptURL = try self.receiptURL(createDirectory: true)
    let priorReceipt = try receiptRead(at: receiptURL)
    let existingReceipt: Data?
    var receipt: Receipt
    switch priorReceipt {
    case .missing:
      existingReceipt = nil
      receipt = Receipt(formatVersion: 1, entries: [])
    case let .valid(value, raw):
      existingReceipt = raw
      receipt = value
    case .invalid:
      throw BrowserSupportInstallerError.unsafeFilesystemState
    }
    receipt.entries.removeAll { $0.target == key }
    receipt.entries.append(.init(
      target: key,
      manifestSHA256: BrowserSupportFrozenArtifacts.sha256(manifest),
      hostSHA256: try hostSHA256(),
      hostPackageSHA256: try hostPackageSHA256(),
      backup: backup,
      version: artifacts.version
    ))
    receipt.entries.sort { $0.target.rawValue < $1.target.rawValue }
    if let existingReceipt {
      try replaceAtomically(try canonicalJSON(receipt), at: receiptURL, expectedExisting: existingReceipt)
    } else {
      try createAtomically(try canonicalJSON(receipt), at: receiptURL)
    }
  }

  private func hostSHA256() throws -> String {
    guard let data = try? Data(contentsOf: artifacts.hostExecutableURL) else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
    return BrowserSupportFrozenArtifacts.sha256(data)
  }

  /// Binds the complete sealed Native Host package, including resource bundles,
  /// instead of treating the executable as the whole artifact.  Paths and file
  /// bytes are both hashed so a resource addition, removal, or replacement is
  /// observable.  Symlinks and special files are rejected rather than followed.
  private func hostPackageSHA256() throws -> String {
    let root = artifacts.hostExecutableURL.deletingLastPathComponent().standardizedFileURL
    var rootInfo = stat()
    guard Darwin.lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
      throw BrowserSupportInstallerError.frozenArtifactUnavailable
    }
    var hasher = SHA256()
    func append(_ value: String) {
      hasher.update(data: Data(value.utf8))
    }
    func visit(_ directory: URL, relativePath: String) throws {
      let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ).sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
      for child in children {
        let relative = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
        var info = stat()
        guard Darwin.lstat(child.path, &info) == 0 else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
          append("D\\0\(relative)\\0")
          try visit(child, relativePath: relative)
        case S_IFREG:
          guard let data = try? Data(contentsOf: child) else { throw BrowserSupportInstallerError.frozenArtifactUnavailable }
          append("F\\0\(relative)\\0\(BrowserSupportFrozenArtifacts.sha256(data))\\0")
        default:
          throw BrowserSupportInstallerError.frozenArtifactUnavailable
        }
      }
    }
    append("browser-support-host-package-v1\\0")
    try visit(root, relativePath: "")
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private struct ReceiptSnapshot {
    let receipt: Receipt?
    let data: Data?
  }

  private func receiptSnapshot() throws -> ReceiptSnapshot {
    switch try receiptRead(at: receiptURL()) {
    case .missing: .init(receipt: nil, data: nil)
    case let .valid(receipt, data): .init(receipt: receipt, data: data)
    case .invalid: throw BrowserSupportInstallerError.unsafeFilesystemState
    }
  }

  private func receiptHasEntry(for key: TargetKey) throws -> Bool {
    switch try receiptSnapshot().receipt {
    case let .some(receipt): receipt.entries.contains(where: { $0.target == key })
    case .none: false
    }
  }

  private func receiptReplacingEntry(
    from before: Receipt?,
    key: TargetKey,
    manifest: Data,
    backup: Receipt.Backup?
  ) throws -> Data {
    var receipt = before ?? .init(formatVersion: 1, entries: [])
    receipt.entries.removeAll { $0.target == key }
    receipt.entries.append(.init(
      target: key,
      manifestSHA256: BrowserSupportFrozenArtifacts.sha256(manifest),
      hostSHA256: try hostSHA256(),
      hostPackageSHA256: try hostPackageSHA256(),
      backup: backup,
      version: artifacts.version
    ))
    receipt.entries.sort { $0.target.rawValue < $1.target.rawValue }
    return try canonicalJSON(receipt)
  }

  private func receiptRemovingEntry(from before: Receipt, key: TargetKey) throws -> Data? {
    var receipt = before
    receipt.entries.removeAll { $0.target == key }
    return receipt.entries.isEmpty ? nil : try canonicalJSON(receipt)
  }

  private func makeJournal(
    action: OperationAction,
    target: TargetKey,
    beforeReceipt: Data?,
    afterReceipt: Data?,
    beforeManifest: Data?,
    afterManifest: Data?,
    backup: Receipt.Backup?,
    quarantineFilename: String?
  ) -> OperationJournal {
    let operationID = UUID().uuidString.lowercased()
    return .init(
      formatVersion: 1,
      operationID: operationID,
      action: action,
      target: target,
      beforeReceipt: beforeReceipt,
      afterReceipt: afterReceipt,
      beforeManifest: beforeManifest,
      afterManifest: afterManifest,
      backup: backup,
      quarantineFilename: quarantineFilename,
      receiptQuarantineFilename: beforeReceipt.map { _ in receiptQuarantineFilename(operationID: operationID) },
      receiptQuarantineSHA256: beforeReceipt.map(BrowserSupportFrozenArtifacts.sha256),
      manifestSHA256: afterManifest.map(BrowserSupportFrozenArtifacts.sha256),
      backupSHA256: backup?.sha256
    )
  }

  private func operationJournalURL(createDirectory: Bool = false) throws -> URL {
    try validateHomeRoot()
    let directory = homeRoot.appendingPathComponent(Self.receiptDirectoryRelativePath, isDirectory: true)
    if createDirectory { try ensureOwnedReceiptDirectory(directory) }
    return directory.appendingPathComponent(Self.operationJournalBasename, isDirectory: false)
  }

  private func operationJournalRead() throws -> (OperationJournal, Data)? {
    let url = try operationJournalURL()
    guard let data = try existingRegularFileData(at: url) else { return nil }
    guard let journal = try? JSONDecoder().decode(OperationJournal.self, from: data),
          journal.formatVersion == 1,
          UUID(uuidString: journal.operationID) != nil,
          (journal.action != .install
            || journal.beforeManifest.map(BrowserSupportFrozenArtifacts.sha256) == journal.backupSHA256
            || journal.backupSHA256 == nil),
          journal.afterManifest.map(BrowserSupportFrozenArtifacts.sha256) == journal.manifestSHA256 || journal.manifestSHA256 == nil,
          journal.quarantineFilename.map(isSafeOperationFilename) ?? true,
          journalReceiptQuarantineIsValid(journal)
    else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    return (journal, data)
  }

  private func journalReceiptQuarantineIsValid(_ journal: OperationJournal) -> Bool {
    switch (journal.beforeReceipt, journal.receiptQuarantineFilename, journal.receiptQuarantineSHA256) {
    case (nil, nil, nil):
      return true
    case (let before?, let name?, let hash?):
      return isSafeReceiptQuarantineFilename(name, operationID: journal.operationID)
        && hash == BrowserSupportFrozenArtifacts.sha256(before)
    default:
      return false
    }
  }

  /// The journal is deliberately publish-once.  Its initial before/after
  /// snapshots are the whole recovery contract; phase is not a decision input
  /// and must never create a second journal-replacement crash window.
  private func writeJournal(_ journal: OperationJournal) throws {
    let data = try canonicalJSON(journal)
    let url = try operationJournalURL(createDirectory: true)
    try createAtomically(data, at: url)
  }

  private func publishReceipt(_ journal: OperationJournal, at url: URL) throws {
    if failureInjection?("receipt") == true { throw BrowserSupportInstallerError.transactionFailed }
    switch (journal.beforeReceipt, journal.afterReceipt) {
    case (nil, let after?): try createAtomically(after, at: url)
    case (let before?, let after?):
      try detachReceiptBeforePublish(journal, expected: before, at: url)
      do {
        try createAtomically(after, at: url)
      } catch {
        try? restoreReceiptQuarantine(journal, at: url)
        throw error
      }
    case (let before?, nil):
      try detachReceiptBeforePublish(journal, expected: before, at: url)
    case (nil, nil): throw BrowserSupportInstallerError.unsafeFilesystemState
    }
  }

  private func performOperation(_ journal: OperationJournal, body: () throws -> Void) throws {
    try writeJournal(journal)
    do {
      try interruptionPoint("after-journal-publish")
      try body()
      try finalizeCommittedOperation(journal)
    } catch {
      // Normal Swift errors use the same durable recovery path as a restart.
      // SIGKILL never reaches this catch; its next inspect/mutation does.
      try? recoverLocked()
      throw error
    }
  }

  private func finalizeCommittedOperation(_ journal: OperationJournal) throws {
    guard let (current, raw) = try operationJournalRead(), current.operationID == journal.operationID else {
      throw BrowserSupportInstallerError.unsafeFilesystemState
    }
    guard try liveReceiptData() == journal.afterReceipt,
          try liveManifestData(for: journal.target) == journal.afterManifest
    else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    try cleanupQuarantine(for: current, keepInstallBackup: true)
    try cleanupReceiptQuarantine(current)
    try removeAtomically(at: operationJournalURL(), expectedExisting: raw)
  }

  private func recoverBeforeInspection() throws {
    let directory = homeRoot.appendingPathComponent(Self.receiptDirectoryRelativePath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try withExistingMutationLock { try recoverLocked() }
  }

  private func recoverLocked() throws {
    let journalURL = try operationJournalURL()
    guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
    guard let (journal, raw) = try operationJournalRead() else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    var receipt = try liveReceiptData()
    // A receipt replacement is deliberately a no-overwrite publish.  If this
    // process ended after detaching the old receipt but before publishing the
    // new one, the immutable journal tells us exactly which old receipt may be
    // restored.  A missing receipt is otherwise never guessed at.
    if receipt == nil, journal.beforeReceipt != nil, journal.afterReceipt != nil {
      try restoreReceiptQuarantine(journal, at: try receiptURL(createDirectory: true))
      receipt = try liveReceiptData()
    }
    if receipt == journal.afterReceipt {
      guard try liveManifestData(for: journal.target) == journal.afterManifest else {
        throw BrowserSupportInstallerError.unsafeFilesystemState
      }
      try cleanupQuarantine(for: journal, keepInstallBackup: true)
      try cleanupReceiptQuarantine(journal)
      try removeAtomically(at: journalURL, expectedExisting: raw)
      return
    }
    guard receipt == journal.beforeReceipt else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    try restoreManifestBeforeCommit(journal)
    try cleanupQuarantine(for: journal, keepInstallBackup: false)
    try cleanupReceiptQuarantine(journal)
    try removeAtomically(at: journalURL, expectedExisting: raw)
  }

  private func liveReceiptData() throws -> Data? {
    let url = try receiptURL()
    guard let data = try existingRegularFileData(at: url) else { return nil }
    guard decodeReceipt(data) != nil else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    return data
  }

  private func liveManifestData(for key: TargetKey) throws -> Data? {
    let directory = targetDirectory(for: key)
    guard try isSafeDirectory(directory) else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    return try existingRegularFileData(at: directory.appendingPathComponent(Self.manifestBasename))
  }

  private func restoreManifestBeforeCommit(_ journal: OperationJournal) throws {
    let target = try manifestURL(for: journal.target)
    let current = try existingRegularFileData(at: target)
    if current == journal.beforeManifest { return }
    guard current == journal.afterManifest || current == nil else {
      throw BrowserSupportInstallerError.unsafeFilesystemState
    }
    if let current {
      let cleanup = operationQuarantineFilename()
      try moveExpectedLeaf(at: target, expected: current, quarantineName: cleanup)
      try removeDetachedLeaf(named: cleanup, from: target.deletingLastPathComponent(), expected: current)
    }
    if let before = journal.beforeManifest { try createAtomically(before, at: target) }
  }

  private func cleanupQuarantine(for journal: OperationJournal, keepInstallBackup: Bool) throws {
    guard let name = journal.quarantineFilename else { return }
    if keepInstallBackup && journal.action == .install { return }
    let directory = targetDirectory(for: journal.target)
    let url = directory.appendingPathComponent(name)
    guard let data = try existingRegularFileData(at: url) else { return }
    guard data == journal.beforeManifest else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    try removeDetachedLeaf(named: name, from: directory, expected: data)
  }

  private func detachReceiptBeforePublish(_ journal: OperationJournal, expected: Data, at url: URL) throws {
    guard let name = journal.receiptQuarantineFilename,
          journal.receiptQuarantineSHA256 == BrowserSupportFrozenArtifacts.sha256(expected)
    else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    try moveExpectedLeaf(at: url, expected: expected, quarantineName: name)
    // This is the receipt commit boundary.  The journal was fsynced before any
    // target change, and binds the exact detached receipt by basename and hash.
    try interruptionPoint("after-receipt-detach-before-publish")
  }

  private func restoreReceiptQuarantine(_ journal: OperationJournal, at url: URL) throws {
    guard let name = journal.receiptQuarantineFilename,
          let expectedHash = journal.receiptQuarantineSHA256,
          let before = journal.beforeReceipt,
          expectedHash == BrowserSupportFrozenArtifacts.sha256(before)
    else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    let directory = url.deletingLastPathComponent()
    let detached = directory.appendingPathComponent(name, isDirectory: false)
    guard try existingRegularFileData(at: url) == nil,
          try regularFileData(at: detached) == before,
          BrowserSupportFrozenArtifacts.sha256(before) == expectedHash
    else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    try restoreDetachedLeaf(named: name, to: url)
  }

  private func cleanupReceiptQuarantine(_ journal: OperationJournal) throws {
    guard let name = journal.receiptQuarantineFilename else { return }
    guard let expected = journal.beforeReceipt,
          journal.receiptQuarantineSHA256 == BrowserSupportFrozenArtifacts.sha256(expected)
    else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    let directory = try receiptURL(createDirectory: true).deletingLastPathComponent()
    let detached = directory.appendingPathComponent(name, isDirectory: false)
    guard let data = try existingRegularFileData(at: detached) else { return }
    guard data == expected else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    try removeDetachedLeaf(named: name, from: directory, expected: expected)
  }

  private func interruptionPoint(_ phase: String) throws {
    if terminationInjection?(phase) == true { Darwin._exit(86) }
    if failureInjection?(phase) == true || failureInjection?("after-manifest") == true {
      throw BrowserSupportInstallerError.transactionFailed
    }
  }

  private func receiptURL(createDirectory: Bool = false) throws -> URL {
    try validateHomeRoot()
    let directory = homeRoot.appendingPathComponent(Self.receiptDirectoryRelativePath, isDirectory: true)
    if createDirectory {
      try ensureOwnedReceiptDirectory(directory)
    }
    return homeRoot.appendingPathComponent(Self.receiptRelativePath, isDirectory: false)
  }

  private func manifestURL(for key: TargetKey) throws -> URL {
    let directory = targetDirectory(for: key)
    guard try isSafeDirectory(directory) else { throw BrowserSupportInstallerError.browserNotDetected }
    return directory.appendingPathComponent(Self.manifestBasename, isDirectory: false)
  }

  private func targetDirectory(for key: TargetKey) -> URL {
    let relative: String = switch key {
    case .chrome: "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    case .brave: "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
    case .edge: "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    }
    return homeRoot.appendingPathComponent(relative, isDirectory: true)
  }

  /// Brave currently resolves the macOS user Native Messaging root through
  /// Chromium's Google/Chrome directory.  Keep `.brave` in `TargetKey` solely
  /// to decode and recover older receipts/journals; no new UI operation may
  /// treat that legacy leaf as the active Brave installation.
  private static func activeTargetKey(for browser: BrowserSupportBrowser) -> TargetKey {
    switch browser {
    case .chrome: .chrome
    case .brave: .chrome
    case .edge: .edge
    }
  }

  /// The frozen templates are presently byte-identical, but selecting Chrome
  /// here makes the shared physical target explicit and prevents a future
  /// Brave-only template drift from making the two UI rows disagree.
  private static func activeTemplateBrowser(for browser: BrowserSupportBrowser) -> BrowserSupportBrowser {
    browser == .brave ? .chrome : browser
  }

  /// Finds only the backup named and hashed by the currently valid receipt.
  /// Timestamp ordering is intentionally not a recovery policy.
  private func recoverableBackup(for key: TargetKey) throws -> URL? {
    let receiptURL = try self.receiptURL()
    guard case let .valid(receipt, _) = try receiptRead(at: receiptURL),
          let entry = receipt.entries.first(where: { $0.target == key })
    else { return nil }
    return try boundBackup(for: key, receiptBackup: entry.backup)
  }

  private func boundBackup(for key: TargetKey, receiptBackup: Receipt.Backup?) throws -> URL? {
    guard let receiptBackup,
          receiptBackup.filename == URL(fileURLWithPath: receiptBackup.filename).lastPathComponent,
          receiptBackup.filename.hasPrefix(Self.manifestBasename + ".backup-"),
          receiptBackup.filename.hasSuffix(".json"),
          isSHA256(receiptBackup.sha256)
    else { return nil }
    let directory = targetDirectory(for: key)
    guard try isSafeDirectory(directory) else { return nil }
    let candidate = directory.appendingPathComponent(receiptBackup.filename, isDirectory: false)
    guard try isSafeRegularFile(candidate),
          BrowserSupportFrozenArtifacts.sha256(try regularFileData(at: candidate)) == receiptBackup.sha256
    else { return nil }
    return candidate
  }

  private func writeBackup(_ data: Data, for key: TargetKey) throws -> Receipt.Backup {
    let directory = targetDirectory(for: key)
    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let filename = "\(Self.manifestBasename).backup-\(timestamp)-\(UUID().uuidString).json"
    let backup = directory.appendingPathComponent(filename, isDirectory: false)
    try createAtomically(data, at: backup)
    return .init(filename: filename, sha256: BrowserSupportFrozenArtifacts.sha256(data))
  }

  private func receiptRead(at url: URL) throws -> ReceiptRead {
    guard let data = try existingRegularFileData(at: url) else { return .missing }
    guard let receipt = decodeReceipt(data) else { return .invalid }
    return .valid(receipt, data)
  }

  private func decodeReceipt(_ data: Data) -> Receipt? {
    guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.formatVersion == 1,
          Set(receipt.entries.map(\.target)).count == receipt.entries.count,
          receipt.entries.allSatisfy({
            isSHA256($0.manifestSHA256)
              && isSHA256($0.hostSHA256)
              && ($0.hostPackageSHA256.map(isSHA256) ?? true)
              && $0.backup.map { backup in
                backup.filename == URL(fileURLWithPath: backup.filename).lastPathComponent
                  && isSHA256(backup.sha256)
              } ?? true
              && !$0.version.isEmpty
          })
    else { return nil }
    return receipt
  }

  private func isSHA256(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
  }

  private func validateHomeRoot() throws {
    guard homeRoot.isFileURL, try isSafeDirectory(homeRoot) else { throw BrowserSupportInstallerError.unsafeFilesystemState }
  }

  private func ensureOwnedReceiptDirectory(_ directory: URL) throws {
    _ = try directoryAnchor(for: directory, createMissing: true)
  }

  private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
    let receiptDirectory = homeRoot.appendingPathComponent(Self.receiptDirectoryRelativePath, isDirectory: true)
    try ensureOwnedReceiptDirectory(receiptDirectory)
    return try withReceiptLock(in: receiptDirectory) {
      try recoverLocked()
      return try body()
    }
  }

  private func withExistingMutationLock<T>(_ body: () throws -> T) throws -> T {
    let receiptDirectory = homeRoot.appendingPathComponent(Self.receiptDirectoryRelativePath, isDirectory: true)
    guard try isSafeDirectory(receiptDirectory) else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    return try withReceiptLock(in: receiptDirectory, body)
  }

  private func withReceiptLock<T>(in receiptDirectory: URL, _ body: () throws -> T) throws -> T {
    let anchor = try directoryAnchor(for: receiptDirectory)
    let descriptor = Darwin.openat(anchor.descriptor, Self.transactionLockBasename, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    defer { _ = Darwin.close(descriptor) }
    var info = stat()
    guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else {
      throw BrowserSupportInstallerError.unsafeFilesystemState
    }
    guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else { throw BrowserSupportInstallerError.transactionFailed }
    defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
    return try body()
  }

  private func isSafeDirectory(_ url: URL) throws -> Bool {
    guard try hasNoSymlinkComponentsWithinHome(to: url) else { return false }
    var info = stat()
    guard Darwin.lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFDIR
  }

  private func isSafeRegularFile(_ url: URL) throws -> Bool {
    guard try hasNoSymlinkComponentsWithinHome(to: url) else { return false }
    var info = stat()
    guard Darwin.lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1
  }

  /// A leaf `lstat` alone is not enough: a replacement of `Library` or a
  /// browser target parent with a symlink would otherwise redirect a later
  /// `Data`/rename call.  Paths outside the injected HOME are only used for the
  /// sealed App Host, never as write targets.
  private func hasNoSymlinkComponentsWithinHome(to url: URL) throws -> Bool {
    let target = url.standardizedFileURL
    let homePath = homeRoot.path
    guard target.path == homePath || target.path.hasPrefix(homePath + "/") else { return true }
    var info = stat()
    guard Darwin.lstat(homePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
    let relative = String(target.path.dropFirst(homePath.count)).split(separator: "/").map(String.init)
    var current = homeRoot
    for component in relative {
      current.appendPathComponent(component)
      var child = stat()
      if Darwin.lstat(current.path, &child) != 0 {
        return errno == ENOENT
      }
      if (child.st_mode & S_IFMT) == S_IFLNK { return false }
    }
    return true
  }

  private func existingRegularFileData(at url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try regularFileData(at: url)
  }

  private func regularFileData(at url: URL) throws -> Data {
    guard try isSafeRegularFile(url), let data = try? Data(contentsOf: url) else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    return data
  }

  private func createAtomically(_ data: Data, at target: URL) throws {
    try writeNewLeaf(data, at: target)
  }

  private func replaceAtomically(_ data: Data, at target: URL, expectedExisting: Data) throws {
    let quarantine = operationQuarantineFilename()
    try moveExpectedLeaf(at: target, expected: expectedExisting, quarantineName: quarantine)
    do {
      try writeNewLeaf(data, at: target)
      try removeDetachedLeaf(named: quarantine, from: target.deletingLastPathComponent(), expected: expectedExisting)
    } catch {
      try? restoreDetachedLeaf(named: quarantine, to: target)
      throw error
    }
  }

  /// Opens every path component beneath the injected HOME through the previous
  /// directory descriptor.  Once this returns, subsequent leaf operations use
  /// only `*at` calls; a same-UID rename/symlink swap cannot redirect them.
  private func directoryAnchor(for directory: URL, createMissing: Bool = false) throws -> DirectoryAnchor {
    try validateHomeRoot()
    let target = directory.standardizedFileURL
    let prefix = homeRoot.path + "/"
    guard target.path.hasPrefix(prefix) else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    let relative = String(target.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
    guard !relative.isEmpty, relative.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw BrowserSupportInstallerError.unsafeFilesystemState
    }
    let homeDescriptor = Darwin.open(homeRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard homeDescriptor >= 0 else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    var anchor = DirectoryAnchor(homeDescriptor)
    for component in relative {
      var child = Darwin.openat(anchor.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if child < 0 && createMissing && errno == ENOENT {
        guard Darwin.mkdirat(anchor.descriptor, component, 0o700) == 0 else { throw BrowserSupportInstallerError.transactionFailed }
        child = Darwin.openat(anchor.descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard child >= 0 else { throw BrowserSupportInstallerError.unsafeFilesystemState }
      var info = stat()
      guard Darwin.fstat(child, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
        _ = Darwin.close(child)
        throw BrowserSupportInstallerError.unsafeFilesystemState
      }
      anchor = DirectoryAnchor(child)
    }
    return anchor
  }

  private func anchoredRegularFileData(_ name: String, in directory: DirectoryAnchor) throws -> Data? {
    let descriptor = Darwin.openat(directory.descriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw BrowserSupportInstallerError.unsafeFilesystemState
    }
    var info = stat()
    guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else {
      _ = Darwin.close(descriptor)
      throw BrowserSupportInstallerError.unsafeFilesystemState
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      let data = try handle.readToEnd() ?? Data()
      try handle.close()
      return data
    } catch {
      try? handle.close()
      throw BrowserSupportInstallerError.transactionFailed
    }
  }

  private func removeAtomically(at target: URL, expectedExisting: Data) throws {
    let quarantine = operationQuarantineFilename()
    try moveExpectedLeaf(at: target, expected: expectedExisting, quarantineName: quarantine)
    try removeDetachedLeaf(named: quarantine, from: target.deletingLastPathComponent(), expected: expectedExisting)
  }

  /// Publishes a new leaf without ever replacing an existing name.  `linkat`
  /// is the final compare-and-publish operation: a concurrent B causes EEXIST
  /// and leaves B untouched.
  private func writeNewLeaf(_ data: Data, at target: URL) throws {
    let anchor = try directoryAnchor(for: target.deletingLastPathComponent())
    let leaf = target.lastPathComponent
    let temporary = ".\(leaf).\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(anchor.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw BrowserSupportInstallerError.transactionFailed }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard Darwin.linkat(anchor.descriptor, temporary, anchor.descriptor, leaf, 0) == 0 else { throw BrowserSupportInstallerError.transactionFailed }
      guard Darwin.unlinkat(anchor.descriptor, temporary, 0) == 0 else { throw BrowserSupportInstallerError.transactionFailed }
      try synchronizeDirectory(anchor)
    } catch {
      try? handle.close()
      _ = Darwin.unlinkat(anchor.descriptor, temporary, 0)
      throw error
    }
  }

  private func moveExpectedLeaf(at target: URL, expected: Data, quarantineName: String) throws {
    guard isSafeOperationFilename(quarantineName) else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    let anchor = try directoryAnchor(for: target.deletingLastPathComponent())
    let leaf = target.lastPathComponent
    guard try renameNoReplace(from: leaf, to: quarantineName, in: anchor) else {
      throw BrowserSupportInstallerError.transactionFailed
    }
    guard try anchoredRegularFileData(quarantineName, in: anchor) == expected else {
      _ = try? renameNoReplace(from: quarantineName, to: leaf, in: anchor)
      throw BrowserSupportInstallerError.confirmationStale
    }
    mutationBarrier?("after-leaf-validated")
  }

  private func restoreDetachedLeaf(named name: String, to target: URL) throws {
    let anchor = try directoryAnchor(for: target.deletingLastPathComponent())
    guard try renameNoReplace(from: name, to: target.lastPathComponent, in: anchor) else {
      throw BrowserSupportInstallerError.transactionFailed
    }
  }

  private func removeDetachedLeaf(named name: String, from directory: URL, expected: Data) throws {
    let anchor = try directoryAnchor(for: directory)
    guard try anchoredRegularFileData(name, in: anchor) == expected else { throw BrowserSupportInstallerError.unsafeFilesystemState }
    guard Darwin.unlinkat(anchor.descriptor, name, 0) == 0 else { throw BrowserSupportInstallerError.transactionFailed }
    try synchronizeDirectory(anchor)
  }

  private func ensureLeafAbsent(at target: URL) throws {
    let anchor = try directoryAnchor(for: target.deletingLastPathComponent())
    guard try anchoredRegularFileData(target.lastPathComponent, in: anchor) == nil else {
      throw BrowserSupportInstallerError.transactionFailed
    }
  }

  private func renameNoReplace(from: String, to: String, in anchor: DirectoryAnchor) throws -> Bool {
    let result = from.withCString { source in
      to.withCString { destination in
        Darwin.renameatx_np(anchor.descriptor, source, anchor.descriptor, destination, UInt32(RENAME_EXCL))
      }
    }
    if result == 0 {
      try synchronizeDirectory(anchor)
      return true
    }
    if errno == EEXIST { return false }
    if errno == ENOENT { return false }
    throw BrowserSupportInstallerError.unsafeFilesystemState
  }

  private func synchronizeDirectory(_ anchor: DirectoryAnchor) throws {
    guard Darwin.fsync(anchor.descriptor) == 0 else { throw BrowserSupportInstallerError.transactionFailed }
  }

  private func backupFilename() -> String {
    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return "\(Self.manifestBasename).backup-\(timestamp)-\(UUID().uuidString).json"
  }

  private func operationQuarantineFilename() -> String {
    "\(Self.manifestBasename).operation-\(UUID().uuidString).json"
  }

  private func receiptQuarantineFilename(operationID: String) -> String {
    "\(Self.operationJournalBasename).receipt-\(operationID).json"
  }

  private func isSafeOperationFilename(_ value: String) -> Bool {
    value == URL(fileURLWithPath: value).lastPathComponent
      && (
        value.hasPrefix(Self.manifestBasename + ".backup-")
          || value.hasPrefix(Self.manifestBasename + ".operation-")
          || value.hasPrefix(Self.operationJournalBasename + ".receipt-")
      )
      && value.hasSuffix(".json")
  }

  private func isSafeReceiptQuarantineFilename(_ value: String, operationID: String) -> Bool {
    value == receiptQuarantineFilename(operationID: operationID)
      && value == URL(fileURLWithPath: value).lastPathComponent
  }

  private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}
