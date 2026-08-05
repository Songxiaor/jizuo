import CryptoKit
import Foundation
import XCTest
@testable import LinkDigestCore

final class BrowserSupportInstallerTests: XCTestCase {
  /// 一个浏览器都没装时：什么也不列，更不许顺手把浏览器目录建出来。
  ///
  /// 断言从「三条 unavailable」改成「空」是因为 `inspect()` 现在只报本机装了的浏览器
  /// ——档案表里有十几个，全报出来就是十几行永远灰着的噪音。真正要钉住的那条不变：
  /// **不许创建任何浏览器目录**。
  func testMissingBrowserDirectoriesAreNeverCreatedAndReportUnavailable() async throws {
    try await withFixture { fixture in
      let installer = fixture.installer()
      let statuses = await installer.inspect()
      XCTAssertTrue(statuses.isEmpty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("Library").path))
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  /// Chrome 和 Edge 是两个独立目标，各写各的 manifest。
  ///
  /// 曾经有过相反的实现：一个浏览器被映射到另一个的目录，装一个等于同时装了两个，收据里
  /// 也只有一条。后果是设置页上那一行显示的其实是别人的状态——两行永远一样，而它自己的
  /// `NativeMessagingHosts` 从没被看过。
  func testChromeAndEdgeAreIndependentTargets() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: true)
      let installer = fixture.installer()

      try await installer.install(.chrome)
      var statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .installed)
      XCTAssertEqual(fixture.state(.edge, in: statuses), .notInstalled, "装 Chrome 不该顺带把 Edge 也算上")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))
      XCTAssertEqual(try fixture.receipt().entries.map(\.target), ["chrome"])

      try await installer.install(.edge)
      statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installed)
      XCTAssertEqual(try fixture.receipt().entries.map(\.target).sorted(), ["chrome", "edge"])
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  /// 对同一个浏览器装第二次是空操作：内容和 mtime 都不动。
  func testSecondInstallOnSameBrowserIsNoop() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let installer = fixture.installer()

      try await installer.install(.chrome)
      let manifest = fixture.manifest(.chrome)
      let before = try Data(contentsOf: manifest)
      let beforeMtime = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date

      try await installer.install(.chrome)
      XCTAssertEqual(try Data(contentsOf: manifest), before)
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date, beforeMtime)
      XCTAssertEqual(try fixture.receipt().entries.map(\.target), ["chrome"])
    }
  }

  /// 每个浏览器各自独立：接管、漂移、修复、卸载都只影响自己那一个目录。
  ///
  /// 曾经有过「两个浏览器共用一个目录」的实现——装一个顺带算另一个装好，改坏一个两行
  /// 一起变。那个耦合是 bug（设置页上那一行显示的其实是别人的状态），所以这条断言必须
  /// 反过来：动一个不能影响另一个。
  func testIntegratedIsolatedBrowserMatrixInstallsRepairsAndUninstallsOwnedTargets() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: true)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"chrome\":\"third-party\"}".utf8))
      let installer = fixture.installer()

      // Chrome 目录里有别人的 manifest，必须走确认接管；Edge 目录是空的，直接装。
      try await confirmReplacement(installer, browser: .chrome)
      try await installer.install(.edge)
      var states = await installer.inspect()
      XCTAssertEqual(states.map(\.state), [.installed, .installed])

      try fixture.writeUnknownManifest(.edge, data: Data("{\"edge\":\"drifted\"}".utf8))
      let drifted = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: drifted), .drifted)
      XCTAssertEqual(fixture.state(.chrome, in: drifted), .installed, "Chrome 不该被 Edge 的改动带下水")
      try await confirmReplacement(installer, browser: .edge)
      states = await installer.inspect()
      XCTAssertEqual(states.map(\.state), [.installed, .installed])

      try await installer.uninstall(.edge)
      states = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: states), .notInstalled)
      XCTAssertEqual(fixture.state(.chrome, in: states), .installed, "卸载 Edge 不该动 Chrome")
      try await installer.uninstall(.chrome)
      states = await installer.inspect()
      XCTAssertEqual(states.map(\.state), [.notInstalled, .notInstalled])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }
  }

  /// App 改名之后，通道断的原因要能说出口。
  ///
  /// manifest 里存的是绝对路径。`LinkDigest.app` 改成「汲作.app」之后，那条路径
  /// 指向一个不存在的文件，浏览器报 `NATIVE_HOST_NOT_FOUND`，而设置页只会说
  /// 「需连接」——用户没法从这三个字推出「因为 App 改过名」。
  ///
  /// 所以 `stalePath` 要在这种情况下有值，且只在**指了个空**时有值：指向另一份
  /// 真实存在的安装是另一回事，不能混为一谈。
  func testDriftCausedByAMovedAppReportsTheStalePath() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let installer = fixture.installer()
      try await installer.install(.chrome)
      let healthy = await installer.inspect()
      XCTAssertNil(fixture.status(.chrome, in: healthy)?.stalePath, "装好的通道没有失效路径可言")

      // 改名/移动之后磁盘上会留下的东西：格式合法，只是 path 指向已不存在的旧位置。
      let goneAppPath = fixture.home
        .appendingPathComponent("Applications/LinkDigest.app/Contents/MacOS/LinkDigestNativeHost")
        .path
      XCTAssertFalse(FileManager.default.fileExists(atPath: goneAppPath))
      try fixture.writeUnknownManifest(.chrome, data: try JSONSerialization.data(
        withJSONObject: [
          "allowed_origins": ["chrome-extension://\(BrowserSupportFixture.extensionID)/"],
          "description": "LinkDigest",
          "name": BrowserSupportFixture.hostName,
          "path": goneAppPath,
          "type": "stdio",
        ],
        options: [.sortedKeys]
      ))

      let status = fixture.status(.chrome, in: await installer.inspect())
      XCTAssertEqual(status?.state, .drifted)
      XCTAssertEqual(status?.stalePath, goneAppPath, "指了个空就要把那条路径报出来")
    }
  }

  func testUnknownManifestRequiresConfirmationThenBacksUpAndRestores() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let original = Data("{\"unknown\":true}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: original)
      let installer = fixture.installer()

      do {
        try await installer.install(.chrome)
        XCTFail("Unknown same-name manifest must require confirmation")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .confirmationRequired)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), original)

      try await confirmReplacement(installer, browser: .chrome)
      let installed = await installer.inspect()
      XCTAssertEqual(fixture.state(.chrome, in: installed), .installed)
      XCTAssertEqual(installed.map(\.browser), [.chrome], "只建了 Chrome 目录，就该只有 Chrome 一行")
      XCTAssertEqual(fixture.status(.chrome, in: installed)?.hasRecoverableBackup, true)
      XCTAssertEqual(try fixture.backupPayload(.chrome), original)

      try await installer.restoreLatestBackup(.chrome)
      let restored = await installer.inspect()
      XCTAssertEqual(fixture.state(.chrome, in: restored), .unknownManifest)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), original)
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  /// 不再提供的浏览器：不列出来，但也**一个字节都不动**。
  ///
  /// Brave 曾在支持面里，所以真人机器上留着两样东西：Brave 目录里一份我们写的 manifest，
  /// 和收据里的 `brave` 条目。收敛支持面时的诱惑是顺手清理掉它们——不能。收据是我们写过
  /// 什么的唯一记录，删掉它就等于把「这个文件是我们放的」这件事抹掉，那份 manifest 从此
  /// 无从解释。留着则完全无害：它只是一个不运行的 JSON。
  ///
  /// 同时保留原有的防线：旧的 brave 收据不得授权接管 Chrome 目录里的未知 manifest。
  func testLegacyBrowserIsNeitherListedNorTouched() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: true, legacyBrave: true)
      let legacy = fixture.legacyBraveManifest
      let legacyData = Data("{\"legacy\":\"brave\"}".utf8)
      try legacyData.write(to: legacy)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path)
      try fixture.writeLegacyBraveReceipt()
      let chromeUnknown = Data("{\"chrome\":\"third-party\"}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: chromeUnknown)
      let installer = fixture.installer()

      // 目录在、manifest 在、收据里有条目——依然不出现在任何一行里。
      let statuses = await installer.inspect()
      XCTAssertEqual(statuses.map(\.browser), [.chrome, .edge])
      XCTAssertNil(fixture.status(.brave, in: statuses))

      // 旧的 brave 条目不得授权接管 Chrome 的未知叶子。
      do {
        try await installer.install(.chrome)
        XCTFail("A legacy receipt entry must not authorize replacing an unknown active leaf")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .confirmationRequired)
      }

      // 走完一次真正的接管之后，Brave 的叶子和它的收据条目都必须原封不动。
      try await confirmReplacement(installer, browser: .chrome)
      XCTAssertEqual(try Data(contentsOf: legacy), legacyData, "接管 Chrome 不该动 Brave 的 manifest")
      XCTAssertEqual(try fixture.receipt().entries.map(\.target).sorted(), ["brave", "chrome"])

      // 卸载也一样：只删自己那一个，旧条目继续留着。
      try await installer.uninstall(.chrome)
      XCTAssertEqual(try Data(contentsOf: legacy), legacyData)
      XCTAssertEqual(try fixture.receipt().entries.map(\.target), ["brave"])
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  /// 一次中断过的旧事务仍然要能恢复到**正确的目录**。
  ///
  /// 这条钉的是「不再提供 ≠ 认不出来」：恢复靠收据里的 target 反查目录，如果 `brave`
  /// 解析不出来，回滚会打到 `Application Support/brave/` 这种不存在的路径上，而真正
  /// 半写完的那个叶子被永远留在中间态。
  func testInterruptedLegacyTransactionStillRecoversToTheRightDirectory() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false, legacyBrave: true)
      let legacyBefore = Data("{\"legacy\":\"before\"}".utf8)
      let legacyAfter = Data("{\"legacy\":\"after\"}".utf8)
      try legacyAfter.write(to: fixture.legacyBraveManifest)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fixture.legacyBraveManifest.path)
      try fixture.writeLegacyBraveReceipt()
      let activeChrome = Data("{\"active\":\"chrome\"}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: activeChrome)
      try fixture.writeLegacyBraveRecoveryJournal(
        beforeManifest: legacyBefore, afterManifest: legacyAfter)

      let statuses = await fixture.installer().inspect()

      XCTAssertEqual(
        try Data(contentsOf: fixture.legacyBraveManifest), legacyBefore, "旧事务必须回滚到自己的目录")
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), activeChrome, "回滚不该碰 Chrome")
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
      XCTAssertEqual(try fixture.receipt().entries.map(\.target), ["brave"])
      XCTAssertEqual(statuses.map(\.browser), [.chrome], "恢复了旧目标，也不会因此列出它")
    }
  }

  /// 打不开目录要分两种：没权限 vs 状态可疑。
  ///
  /// macOS 不让 App 打开别的 App 的数据目录，`openat` 直接 EPERM 且不弹授权框。它跟
  /// 「文件系统状态可疑」共用一个错误码的后果是：用户看到「检测到不安全的文件系统状态」
  /// 这种既吓人又无从下手的话，而实际上他只要选一次文件夹就好了。
  ///
  /// 用 `chmod 111` 真造一个这样的目录，不是打桩：只给执行位时路径能穿过去（所以读得到
  /// 里面的文件、状态判得出来），但 `open(O_DIRECTORY)` 要读权限、会被拒——正是真机上
  /// 那个「能读、写不了」的不对称。`chmod 000` 复现不了：它连读都断了，于是提前被
  /// 「未检测到该浏览器」短路，根本走不到要测的那段。
  func testUnopenableBrowserDirectoryReportsAccessDeniedNotUnsafeState() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let installer = fixture.installer()
      try await installer.install(.chrome)

      let chromeParent = fixture.home
        .appendingPathComponent("Library/Application Support/Google", isDirectory: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: chromeParent.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: chromeParent.path)
      }
      // 前提：状态仍然判得出来，也就是说这不是「没检测到浏览器」。
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .installed)

      // 卸载是一次真正的写事务，会走到逐段打开目录那一步。
      do {
        try await fixture.installer().uninstall(.chrome)
        XCTFail("An unopenable browser directory must not silently succeed")
      } catch let BrowserSupportInstallerError.directoryAccessDenied(path) {
        // 报的必须是**真正被拒的那一段**，不是最终要写的叶子目录。让用户去授权叶子是
        // 没用的：父目录照样打不开，重试还会失败，界面就会反复弹同一个授权框。
        XCTAssertEqual(path, chromeParent.standardizedFileURL.path)
      } catch {
        XCTFail("没权限必须和「状态可疑」分开，实际拿到 \(error)")
      }
    }
  }

  func testReplacementConfirmationFingerprintRejectsChangedManifest() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"before\":true}".utf8))
      let installer = fixture.installer()
      let before = await installer.inspect()
      let fingerprint = try XCTUnwrap(fixture.status(.chrome, in: before)?.replacementFingerprint)
      let changed = Data("{\"changed\":true}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: changed)

      do {
        try await installer.confirmReplacement(.chrome, expectedFingerprint: fingerprint)
        XCTFail("Stale confirmation must not cover a replacement manifest")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .confirmationStale)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), changed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }
  }

  func testDriftRequiresRepairConfirmationAndUninstallRefusesToDeleteIt() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.writeUnknownManifest(.edge, data: Data("{\"drifted\":true}".utf8))
      var statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .drifted)

      do {
        try await installer.uninstall(.edge)
        XCTFail("Drifted manifest must not be deleted")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .uninstallRefused)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))

      do {
        try await installer.install(.edge)
        XCTFail("Repair must require confirmation when replacing a drifted leaf")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .confirmationRequired)
      }
      try await confirmReplacement(installer, browser: .edge)
      statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installed)
      try await installer.uninstall(.edge)
      statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .notInstalled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testInjectedInterruptionRollsBackManifestAndLeavesNoReceipt() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let installer = fixture.installer(failAfterManifestWrite: true)
      do {
        try await installer.install(.chrome)
        XCTFail("Injected interruption must fail the transaction")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .transactionFailed)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.chrome).path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
      let statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .notInstalled)
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testTemplateHashMismatchMakesArtifactUnavailableWithoutFilesystemWrites() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      do {
        _ = try fixture.installer(templateHash: String(repeating: "0", count: 64))
        XCTFail("Tampered frozen template must not construct an installer")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .frozenArtifactUnavailable)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.chrome).path))
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testSymlinkedBrowserTargetIsRejectedBeforeAnyWrite() async throws {
    try await withFixture { fixture in
      let parent = fixture.home.appendingPathComponent("Library/Application Support/Google", isDirectory: true)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let link = parent.appendingPathComponent("Chrome", isDirectory: true)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
      let installer = fixture.installer()

      // 符号链接底下没有 NativeMessagingHosts，所以这个浏览器根本不算装了、不会列出来。
      // 真正要钉的是下面那条：即便硬去装，也必须在写任何东西之前被拒。
      let statuses = await installer.inspect()
      XCTAssertNil(fixture.state(.chrome, in: statuses))
      do {
        try await installer.install(.chrome)
        XCTFail("Symlinked NativeMessagingHosts parent must be rejected")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .browserNotDetected)
      }
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testFIFOManifestIsRejectedWithoutBlockingOrWriting() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let fifo = fixture.manifest(.chrome)
      XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
      let installer = fixture.installer()
      do {
        try await installer.install(.chrome)
        XCTFail("FIFO must never be opened as a manifest")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .unsafeFilesystemState)
      }
      var info = stat()
      XCTAssertEqual(Darwin.lstat(fifo.path, &info), 0)
      XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO)
    }
  }

  func testInvalidReceiptBlocksDirectInstallWithoutReplacingOtherTargetOwnership() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: true)
      let normal = fixture.installer()
      try await normal.install(.edge)
      let edgeManifest = try Data(contentsOf: fixture.manifest(.edge))
      let invalid = Data("{\"formatVersion\":2,\"entries\":[]}".utf8)
      try fixture.writeReceiptRaw(invalid)

      let statuses = await normal.inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .invalidReceipt)
      do {
        try await normal.install(.chrome)
        XCTFail("Invalid receipt must fail closed before a new target is written")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .unsafeFilesystemState)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.edge)), edgeManifest)
      XCTAssertEqual(try Data(contentsOf: fixture.receiptURL), invalid)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.chrome).path))
    }
  }

  func testCurrentAppManifestWithUnboundReceiptStaysUsableButRefusesUninstall() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.replaceReceiptManifestHash(with: String(repeating: "0", count: 64))

      let statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .currentAppUnverified)
      XCTAssertNotNil(fixture.status(.edge, in: statuses)?.replacementFingerprint)
      do {
        try await installer.uninstall(.edge)
        XCTFail("An unbound receipt must refuse deletion")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .uninstallRefused)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testSemanticallyIdenticalPrettyManifestStaysUsableWithoutClaimingOwnership() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let installer = fixture.installer()
      try await installer.install(.chrome)

      let target = fixture.manifest(.chrome)
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: target))
      let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      try pretty.write(to: target)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

      let statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .currentAppUnverified)
      XCTAssertEqual(statuses.map(\.browser), [.chrome], "只建了 Chrome 目录，就该只有 Chrome 一行")
      XCTAssertNotNil(fixture.status(.chrome, in: statuses)?.replacementFingerprint)

      do {
        try await installer.uninstall(.chrome)
        XCTFail("Formatting-equivalent but unbound bytes must still refuse deletion")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .uninstallRefused)
      }
      XCTAssertEqual(try Data(contentsOf: target), pretty)
    }
  }

  func testReceiptCommitFailureDuringUninstallRestoresManifest() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      let normal = fixture.installer()
      try await normal.install(.edge)
      let failing = fixture.installer(failurePhase: "receipt")
      do {
        try await failing.uninstall(.edge)
        XCTFail("Injected receipt failure must abort uninstall")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .transactionFailed)
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))
      let statuses = await normal.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installed)
    }
  }

  func testReceiptCommitFailureDuringRestoreKeepsInstalledManifest() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"before\":true}".utf8))
      let normal = fixture.installer()
      try await confirmReplacement(normal, browser: .chrome)
      let installed = try Data(contentsOf: fixture.manifest(.chrome))
      let failing = fixture.installer(failurePhase: "receipt")
      do {
        try await failing.restoreLatestBackup(.chrome)
        XCTFail("Injected receipt failure must abort restore")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .transactionFailed)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), installed)
      let statuses = await normal.inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .installed)
    }
  }

  func testRestoreRejectsBackupWithMismatchedReceiptFilename() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"before\":true}".utf8))
      let installer = fixture.installer()
      try await confirmReplacement(installer, browser: .chrome)
      let installed = try Data(contentsOf: fixture.manifest(.chrome))
      let boundBackup = try fixture.boundBackupURL(.chrome)
      let renamed = boundBackup.deletingLastPathComponent().appendingPathComponent("com.syc.linkdigest.v01.json.backup-unbound.json")
      try FileManager.default.moveItem(at: boundBackup, to: renamed)

      do {
        try await installer.restoreLatestBackup(.chrome)
        XCTFail("Restore must not select a similarly named backup")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .restoreRefused)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), installed)
      let statuses = await installer.inspect()
      XCTAssertEqual(fixture.status(.chrome, in: statuses)?.hasRecoverableBackup, false)
    }
  }

  func testRestoreRejectsBackupWithMismatchedReceiptHash() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"before\":true}".utf8))
      let installer = fixture.installer()
      try await confirmReplacement(installer, browser: .chrome)
      let installed = try Data(contentsOf: fixture.manifest(.chrome))
      let boundBackup = try fixture.boundBackupURL(.chrome)
      try Data("tampered backup".utf8).write(to: boundBackup, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: boundBackup.path)

      do {
        try await installer.restoreLatestBackup(.chrome)
        XCTFail("Restore must verify the receipt-bound backup hash")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .restoreRefused)
      }
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), installed)
      let statuses = await installer.inspect()
      XCTAssertEqual(fixture.status(.chrome, in: statuses)?.hasRecoverableBackup, false)
    }
  }

  func testHostPackageUpdateReportsInstalledAppUpdatedAndRepairRefreshesReceipt() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.mutateHostResource()

      var statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installedAppUpdated)
      XCTAssertNil(fixture.status(.edge, in: statuses)?.replacementFingerprint)

      // Repairing LinkDigest's own byte-identical manifest refreshes the stale
      // receipt snapshot without demanding a takeover confirmation.
      try await installer.install(.edge)
      statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installed)
    }
  }

  func testHostPackageUpdateStillAllowsVerifiedUninstall() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.mutateHostResource()

      let statuses = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installedAppUpdated)
      try await installer.uninstall(.edge)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))
    }
  }

  func testSubprocessTerminatedInstallRecoversBeforeInspect() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      let original = Data("{\"unknown\":true}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: original)

      try fixture.runCrashHarness(action: "install", browser: .chrome)
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .unknownManifest)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), original)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessTerminatedUninstallRecoversBeforeInspect() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      let installed = try Data(contentsOf: fixture.manifest(.edge))

      try fixture.runCrashHarness(action: "uninstall", browser: .edge)
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installed)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.edge)), installed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessTerminatedRestoreRecoversBeforeInspect() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"unknown\":true}".utf8))
      let installer = fixture.installer()
      try await confirmReplacement(installer, browser: .chrome)
      let installed = try Data(contentsOf: fixture.manifest(.chrome))

      try fixture.runCrashHarness(action: "restore", browser: .chrome)
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .installed)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), installed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessTerminatedAfterJournalPublishLeavesAUsableFreshInstallState() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)

      try fixture.runCrashHarness(action: "install", browser: .chrome, phase: "after-journal-publish")
      let statuses = await fixture.installer().inspect()
      // 只建了 Chrome 一个目录，所以只报一行。按下标断言状态数组会随着支持面变化整片
      // 假失败，所以这里按浏览器断言。
      XCTAssertEqual(statuses.map(\.browser), [.chrome])
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .notInstalled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessReceiptDetachDuringExistingReceiptRepairRecoversAllTargets() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: true)
      let original = Data("{\"unknown\":true}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: original)
      try await fixture.installer().install(.edge)

      try fixture.runCrashHarness(action: "install", browser: .chrome, phase: "after-receipt-detach-before-publish")
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .unknownManifest)
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installed)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), original)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessReceiptDetachDuringSecondTargetInstallRecoversFirstTarget() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: true)
      let installer = fixture.installer()
      try await installer.install(.chrome)

      try fixture.runCrashHarness(action: "install", browser: .edge, phase: "after-receipt-detach-before-publish")
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .installed)
      XCTAssertEqual(fixture.state(.edge, in: statuses), .notInstalled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessReceiptDetachDuringMultiTargetRestoreRecoversAllTargets() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: true)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"unknown\":true}".utf8))
      let installer = fixture.installer()
      try await confirmReplacement(installer, browser: .chrome)
      try await installer.install(.edge)

      try fixture.runCrashHarness(action: "restore", browser: .chrome, phase: "after-receipt-detach-before-publish")
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(fixture.state(.chrome, in: statuses), .installed)
      XCTAssertEqual(fixture.state(.edge, in: statuses), .installed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testReceiptWithMissingManifestOffersConfirmedRepairInsteadOfDeadEnd() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try FileManager.default.removeItem(at: fixture.manifest(.edge))

      let drifted = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: drifted), .drifted)
      let fingerprint = try XCTUnwrap(fixture.status(.edge, in: drifted)?.replacementFingerprint)
      try await installer.confirmReplacement(.edge, expectedFingerprint: fingerprint)
      let repaired = await installer.inspect()
      XCTAssertEqual(fixture.state(.edge, in: repaired), .installed)
    }
  }

  func testInstallDoesNotOverwriteConcurrentLeafAfterVerifiedDetach() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"a\":true}".utf8))
      let target = fixture.manifest(.chrome)
      let concurrent = Data("{\"b\":true}".utf8)
      let barrier: @Sendable (String) -> Void = { phase in
        guard phase == "after-leaf-validated" else { return }
        try? concurrent.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      }
      let installer = fixture.installer(mutationBarrier: barrier)

      do {
        try await confirmReplacement(installer, browser: .chrome)
        XCTFail("Concurrent leaf must make no-overwrite publish fail")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .transactionFailed)
      }
      XCTAssertEqual(try Data(contentsOf: target), concurrent)
    }
  }

  func testUninstallDoesNotDeleteConcurrentLeafAfterVerifiedDetach() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(chrome: false, edge: true)
      try await fixture.installer().install(.edge)
      let target = fixture.manifest(.edge)
      let concurrent = Data("{\"b\":true}".utf8)
      let barrier: @Sendable (String) -> Void = { phase in
        guard phase == "after-leaf-validated" else { return }
        try? concurrent.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      }
      let installer = fixture.installer(mutationBarrier: barrier)

      do {
        try await installer.uninstall(.edge)
        XCTFail("Concurrent leaf must stop uninstall before receipt commit")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .transactionFailed)
      }
      XCTAssertEqual(try Data(contentsOf: target), concurrent)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }
  }
}

private struct BrowserSupportFixture {
  let root: URL
  let home: URL
  let host: URL
  let hostResource: URL
  let initialNonHomeDigest: String

  static func make() throws -> BrowserSupportFixture {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("linkdigest-browser-support-tests-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("isolated-home", isDirectory: true)
    let package = root.appendingPathComponent("fixture-native-host-package", isDirectory: true)
    let host = package.appendingPathComponent("LinkDigestNativeHost", isDirectory: false)
    let hostResource = package.appendingPathComponent("LinkDigest_LinkDigestCore.bundle/Resources/marker.txt", isDirectory: false)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: hostResource.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Data("fixture host".utf8).write(to: host)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
    try Data("fixture resource".utf8).write(to: hostResource)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostResource.path)
    return .init(root: root, home: home, host: host, hostResource: hostResource, initialNonHomeDigest: try digestOutsideHome(root: root, home: home))
  }

  func installer(failAfterManifestWrite: Bool = false, failurePhase: String? = nil, mutationBarrier: (@Sendable (String) -> Void)? = nil) -> BrowserSupportInstaller {
    try! installer(templateHash: Self.templateHash, failAfterManifestWrite: failAfterManifestWrite, failurePhase: failurePhase, mutationBarrier: mutationBarrier)
  }

  func installer(templateHash: String, failAfterManifestWrite: Bool = false, failurePhase: String? = nil, mutationBarrier: (@Sendable (String) -> Void)? = nil) throws -> BrowserSupportInstaller {
    let data = Self.template
    let artifacts = try BrowserSupportFrozenArtifacts(
      templates: Dictionary(uniqueKeysWithValues: BrowserSupportBrowser.allKnown.map { ($0, data) }),
      templateHashes: Dictionary(uniqueKeysWithValues: BrowserSupportBrowser.allKnown.map { ($0, templateHash) }),
      extensionID: Self.extensionID,
      hostName: Self.hostName,
      version: "0.2.0",
      hostExecutableURL: host
    )
    let failAfterManifest: @Sendable (String) -> Bool = { $0 == "after-manifest" }
    let failAtPhase: @Sendable (String) -> Bool = { $0 == failurePhase }
    let injector: (@Sendable (String) -> Bool)? = failAfterManifestWrite ? failAfterManifest : (failurePhase == nil ? nil : failAtPhase)
    // 产品当前只提供 Chrome，但事务机制是多目标的。这里显式注入两个目标，让「动一个不
    // 影响另一个」「收据里两条互不干扰」「中断后各自回滚」这些覆盖不随产品收敛而消失。
    return BrowserSupportInstaller(
      homeRoot: home, browsers: Self.fixtureBrowsers, artifacts: artifacts,
      failureInjection: injector, mutationBarrier: mutationBarrier)
  }

  /// 装出来的 manifest 里那两个固定字段。提到这里是因为用例也要照着拼一份
  /// 「格式合法但路径失效」的 manifest——两处各写一遍字面量，改一处就会得到
  /// 一个假通过的用例。
  static let extensionID = "fbpjhlcpfheecigibjghhodhhkgjdgma"
  static let hostName = "com.syc.linkdigest.v01"

  /// `legacyBrave` 建的是一个**不再被支持**的浏览器目录：Brave 曾在档案表里，真人机器上
  /// 还留着我们写进去的 manifest。它必须存在于测试环境里，才能钉住「不支持了 ≠ 会去动它」。
  static let fixtureBrowsers: [BrowserSupportBrowser] = [.chrome, .edge]

  func createBrowserDirectories(chrome: Bool, edge: Bool, legacyBrave: Bool = false) throws {
    if chrome {
      try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    if legacyBrave {
      try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    if edge {
      try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Microsoft Edge/NativeMessagingHosts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }

  /// 每个浏览器读写自己的目录——Brave 以前被映射到 Chrome 的目录，那是个 bug。
  func manifest(_ browser: BrowserSupportBrowser) -> URL {
    home.appendingPathComponent(browser.nativeMessagingRelativePath)
      .appendingPathComponent("com.syc.linkdigest.v01.json")
  }

  /// 按浏览器取状态。`inspect()` 现在覆盖档案表里所有已知浏览器，靠下标位置断言
  /// 会随着表里加一个浏览器就整片假失败。
  func state(_ browser: BrowserSupportBrowser, in statuses: [BrowserSupportStatus]) -> BrowserSupportInstallState? {
    status(browser, in: statuses)?.state
  }

  func status(_ browser: BrowserSupportBrowser, in statuses: [BrowserSupportStatus]) -> BrowserSupportStatus? {
    statuses.first { $0.browser == browser }
  }

  var receiptURL: URL { home.appendingPathComponent("Library/Application Support/LinkDigest/BrowserSupport/receipt-v1.json") }
  var operationJournalURL: URL { home.appendingPathComponent("Library/Application Support/LinkDigest/BrowserSupport/operation-v1.json") }
  var legacyBraveManifest: URL { home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.syc.linkdigest.v01.json") }

  func runCrashHarness(action: String, browser: BrowserSupportBrowser, phase: String = "after-manifest-before-receipt") throws {
    // SwiftPM's `--scratch-path` deliberately moves build products away from
    // `apps/desktop/.build`.  The xctest bundle and this executable are peers
    // in the active debug product directory, so use that runtime fact rather
    // than cwd/HOME/default-build-path assumptions.
    let debugProducts = Bundle(for: BrowserSupportInstallerTests.self)
      .bundleURL
      .deletingLastPathComponent()
    let executable = debugProducts.appendingPathComponent("LinkDigestBrowserSupportCrashHarness")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "crash harness must be built beside the active xctest bundle")
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "--home", home.path,
      "--host", host.path,
      "--action", action,
      "--browser", browser.id,
      "--phase", phase,
    ]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 86)
  }

  func receipt() throws -> FixtureReceipt {
    try JSONDecoder().decode(FixtureReceipt.self, from: Data(contentsOf: receiptURL))
  }

  func writeUnknownManifest(_ browser: BrowserSupportBrowser, data: Data) throws {
    try data.write(to: manifest(browser))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest(browser).path)
  }

  func replaceReceiptManifestHash(with hash: String) throws {
    var value = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [String: Any]
    var entries = value["entries"] as! [[String: Any]]
    entries[0]["manifestSHA256"] = hash
    value["entries"] = entries
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try data.write(to: receiptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
  }

  func writeReceiptRaw(_ data: Data) throws {
    try data.write(to: receiptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
  }

  func writeLegacyBraveReceipt() throws {
    try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try legacyBraveReceiptData().write(to: receiptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
  }

  func writeLegacyBraveRecoveryJournal(beforeManifest: Data, afterManifest: Data) throws {
    try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let beforeReceipt = try legacyBraveReceiptData(version: "0.2.0")
    let afterReceipt = try legacyBraveReceiptData(version: "0.2.1")
    try beforeReceipt.write(to: receiptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    try afterManifest.write(to: legacyBraveManifest)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyBraveManifest.path)
    let operationID = "9f7c3d2a-7a67-4e51-9e4d-62107a63a11d"
    let journal: [String: Any] = [
      "formatVersion": 1,
      "operationID": operationID,
      "action": "install",
      "target": "brave",
      "beforeReceipt": beforeReceipt.base64EncodedString(),
      "afterReceipt": afterReceipt.base64EncodedString(),
      "beforeManifest": beforeManifest.base64EncodedString(),
      "afterManifest": afterManifest.base64EncodedString(),
      "backup": NSNull(),
      "quarantineFilename": NSNull(),
      "receiptQuarantineFilename": "operation-v1.json.receipt-\(operationID).json",
      "receiptQuarantineSHA256": sha256(beforeReceipt),
      "manifestSHA256": sha256(afterManifest),
      "backupSHA256": NSNull(),
    ]
    try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: operationJournalURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: operationJournalURL.path)
  }

  private func legacyBraveReceiptData(version: String = "0.2.0") throws -> Data {
    let digest = String(repeating: "0", count: 64)
    let value: [String: Any] = [
      "formatVersion": 1,
      "entries": [[
        "target": "brave",
        "manifestSHA256": digest,
        "hostSHA256": digest,
        "hostPackageSHA256": digest,
        "version": version,
      ]],
    ]
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }

  func backupPayload(_ browser: BrowserSupportBrowser) throws -> Data {
    try Data(contentsOf: boundBackupURL(browser))
  }

  func boundBackupURL(_ browser: BrowserSupportBrowser) throws -> URL {
    let entry = try XCTUnwrap(receipt().entries.first(where: { $0.target == browser.id }))
    let backup = try XCTUnwrap(entry.backup)
    XCTAssertEqual(backup.sha256.count, 64)
    return manifest(browser).deletingLastPathComponent().appendingPathComponent(backup.filename)
  }

  func mutateHostResource() throws {
    try Data("changed fixture resource".utf8).write(to: hostResource, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostResource.path)
  }

  func nonHomeDigest() throws -> String { try Self.digestOutsideHome(root: root, home: home) }

  static let template = Data("""
  {"allowed_origins":["chrome-extension://fbpjhlcpfheecigibjghhodhhkgjdgma/"],"description":"LinkDigest Native Messaging Host","name":"com.syc.linkdigest.v01","path":"__LINKDIGEST_NATIVE_HOST_PATH__","type":"stdio"}
  """.utf8)
  static let templateHash = sha256(template)

  private static func digestOutsideHome(root: URL, home: URL) throws -> String {
    var values: [String] = []
    func appendTree(_ item: URL, relativePath: String) throws {
      var info = stat()
      guard Darwin.lstat(item.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
      if (info.st_mode & S_IFMT) == S_IFDIR {
        values.append("D:\\(relativePath)")
        for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
          try appendTree(child, relativePath: relativePath + "/" + child.lastPathComponent)
        }
      } else {
        values.append("F:\\(relativePath)")
        values.append(sha256(try Data(contentsOf: item)))
      }
    }
    let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0 != home }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    for item in contents {
      try appendTree(item, relativePath: item.lastPathComponent)
    }
    return values.joined(separator: "|")
  }
}

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct FixtureReceipt: Decodable {
  struct Backup: Decodable {
    let filename: String
    let sha256: String
  }
  struct Entry: Decodable {
    let target: String
    let backup: Backup?
  }
  let entries: [Entry]
}

private func withFixture(_ body: (BrowserSupportFixture) async throws -> Void) async throws {
  let fixture = try BrowserSupportFixture.make()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  try await body(fixture)
}

private func confirmReplacement(_ installer: BrowserSupportInstaller, browser: BrowserSupportBrowser) async throws {
  let statuses = await installer.inspect()
  let fingerprint = try XCTUnwrap(statuses.first(where: { $0.browser == browser })?.replacementFingerprint)
  try await installer.confirmReplacement(browser, expectedFingerprint: fingerprint)
}
