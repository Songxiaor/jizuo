import CryptoKit
import Foundation
import XCTest
@testable import LinkDigestCore

final class BrowserSupportInstallerTests: XCTestCase {
  func testMissingBrowserDirectoriesAreNeverCreatedAndReportUnavailable() async throws {
    try await withFixture { fixture in
      let installer = fixture.installer()
      let statuses = await installer.inspect()
      XCTAssertEqual(statuses.map(\.state), [.unavailable, .unavailable, .unavailable])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("Library").path))
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testChromeAndBraveShareOneActiveTargetAndSecondActionIsNoop() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: true)
      let installer = fixture.installer()

      try await installer.install(.chrome)
      var statuses = await installer.inspect()
      XCTAssertEqual(statuses.map(\.state), [.installed, .installed, .notInstalled])
      let manifest = fixture.manifest(.chrome)
      let before = try Data(contentsOf: manifest)
      let beforeMtime = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date
      let receipt = try fixture.receipt()
      XCTAssertEqual(receipt.entries.count, 1)
      XCTAssertEqual(receipt.entries.first?.target, "chrome")

      try await installer.install(.brave)
      XCTAssertEqual(try Data(contentsOf: manifest), before)
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date, beforeMtime)
      statuses = await installer.inspect()
      XCTAssertEqual(statuses.map(\.state), [.installed, .installed, .notInstalled])
      XCTAssertEqual(try fixture.receipt().entries.map(\.target), ["chrome"])
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testBraveThenChromeUsesTheSameActiveTargetAndSecondActionIsNoop() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
      let installer = fixture.installer()

      try await installer.install(.brave)
      let manifest = fixture.manifest(.chrome)
      let before = try Data(contentsOf: manifest)
      let beforeMtime = try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date
      try await installer.install(.chrome)

      XCTAssertEqual(try Data(contentsOf: manifest), before)
      XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date, beforeMtime)
      let statuses = await installer.inspect()
      XCTAssertEqual(statuses.map(\.state), [.installed, .installed, .unavailable])
      XCTAssertEqual(try fixture.receipt().entries.map(\.target), ["chrome"])
    }
  }

  func testIntegratedIsolatedBrowserMatrixInstallsRepairsAndUninstallsOwnedTargets() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: true)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"chrome\":\"third-party\"}".utf8))
      try fixture.writeUnknownManifest(.edge, data: Data("{\"edge\":\"third-party\"}".utf8))
      let installer = fixture.installer()

      try await confirmReplacement(installer, browser: .chrome)
      try await confirmReplacement(installer, browser: .edge)
      var states = await installer.inspect()
      XCTAssertEqual(states.map(\.state), [.installed, .installed, .installed])

      try fixture.writeUnknownManifest(.brave, data: Data("{\"chrome\":\"drifted\"}".utf8))
      let drifted = await installer.inspect()
      XCTAssertEqual(drifted[0].state, .drifted)
      XCTAssertEqual(drifted[1].state, .drifted)
      try await confirmReplacement(installer, browser: .brave)
      states = await installer.inspect()
      XCTAssertEqual(states.map(\.state), [.installed, .installed, .installed])

      try await installer.uninstall(.brave)
      states = await installer.inspect()
      XCTAssertEqual(states.map(\.state), [.notInstalled, .notInstalled, .installed])
      try await installer.uninstall(.edge)
      states = await installer.inspect()
      XCTAssertEqual(states.map(\.state), [.notInstalled, .notInstalled, .notInstalled])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }
  }

  func testUnknownManifestRequiresConfirmationThenBacksUpAndRestores() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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

      try await confirmReplacement(installer, browser: .brave)
      let installed = await installer.inspect()
      XCTAssertEqual(installed[0].state, .installed)
      XCTAssertEqual(installed[1].state, .installed)
      XCTAssertTrue(installed[0].hasRecoverableBackup)
      XCTAssertEqual(try fixture.backupPayload(.chrome), original)

      try await installer.restoreLatestBackup(.brave)
      let restored = await installer.inspect()
      XCTAssertEqual(restored[0].state, .unknownManifest)
      XCTAssertEqual(restored[1].state, .unknownManifest)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), original)
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testLegacyBraveReceiptAndJournalPreserveLegacyRecoveryWithoutAuthorizingActiveTakeover() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
      let legacy = fixture.legacyBraveManifest
      let legacyData = Data("{\"legacy\":\"brave\"}".utf8)
      try legacyData.write(to: legacy)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path)
      try fixture.writeLegacyBraveReceipt()
      let chromeUnknown = Data("{\"chrome\":\"third-party\"}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: chromeUnknown)
      let installer = fixture.installer()

      let statuses = await installer.inspect()
      XCTAssertEqual(statuses[0].state, .unknownManifest)
      XCTAssertEqual(statuses[1].state, .unknownManifest)
      do {
        try await installer.install(.brave)
        XCTFail("A legacy Brave receipt must not authorize replacing an unknown active Chrome leaf")
      } catch {
        XCTAssertEqual(error as? BrowserSupportInstallerError, .confirmationRequired)
      }
      try await confirmReplacement(installer, browser: .chrome)
      XCTAssertEqual(try Data(contentsOf: legacy), legacyData)
      XCTAssertEqual(try fixture.receipt().entries.map(\.target).sorted(), ["brave", "chrome"])
      let activeChrome = Data("{\"active\":\"chrome\"}".utf8)
      let legacyBefore = Data("{\"legacy\":\"before\"}".utf8)
      let legacyAfter = Data("{\"legacy\":\"after\"}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: activeChrome)
      try fixture.writeLegacyBraveRecoveryJournal(beforeManifest: legacyBefore, afterManifest: legacyAfter)

      let recoveredStatuses = await fixture.installer().inspect()
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), activeChrome)
      XCTAssertEqual(try Data(contentsOf: fixture.legacyBraveManifest), legacyBefore)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
      XCTAssertEqual(try fixture.receipt().entries.map(\.target), ["brave"])
      XCTAssertEqual(recoveredStatuses.map(\.state), [.unknownManifest, .unknownManifest, .unavailable])
    }
  }

  func testReplacementConfirmationFingerprintRejectsChangedManifest() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"before\":true}".utf8))
      let installer = fixture.installer()
      let before = await installer.inspect()
      let fingerprint = try XCTUnwrap(before[0].replacementFingerprint)
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
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.writeUnknownManifest(.edge, data: Data("{\"drifted\":true}".utf8))
      var statuses = await installer.inspect()
      XCTAssertEqual(statuses[2].state, .drifted)

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
      XCTAssertEqual(statuses[2].state, .installed)
      try await installer.uninstall(.edge)
      statuses = await installer.inspect()
      XCTAssertEqual(statuses[2].state, .notInstalled)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testInjectedInterruptionRollsBackManifestAndLeavesNoReceipt() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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
      XCTAssertEqual(statuses[0].state, .notInstalled)
      XCTAssertEqual(try fixture.nonHomeDigest(), fixture.initialNonHomeDigest)
    }
  }

  func testTemplateHashMismatchMakesArtifactUnavailableWithoutFilesystemWrites() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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

      let statuses = await installer.inspect()
      XCTAssertEqual(statuses[0].state, .unavailable)
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
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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
      try fixture.createBrowserDirectories(sharedChrome: true, edge: true)
      let normal = fixture.installer()
      try await normal.install(.edge)
      let edgeManifest = try Data(contentsOf: fixture.manifest(.edge))
      let invalid = Data("{\"formatVersion\":2,\"entries\":[]}".utf8)
      try fixture.writeReceiptRaw(invalid)

      let statuses = await normal.inspect()
      XCTAssertEqual(statuses[0].state, .invalidReceipt)
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
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.replaceReceiptManifestHash(with: String(repeating: "0", count: 64))

      let statuses = await installer.inspect()
      XCTAssertEqual(statuses[2].state, .currentAppUnverified)
      XCTAssertNotNil(statuses[2].replacementFingerprint)
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
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
      let installer = fixture.installer()
      try await installer.install(.chrome)

      let target = fixture.manifest(.chrome)
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: target))
      let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
      try pretty.write(to: target)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

      let statuses = await installer.inspect()
      XCTAssertEqual(statuses[0].state, .currentAppUnverified)
      XCTAssertEqual(statuses[1].state, .currentAppUnverified)
      XCTAssertNotNil(statuses[0].replacementFingerprint)

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
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
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
      XCTAssertEqual(statuses[2].state, .installed)
    }
  }

  func testReceiptCommitFailureDuringRestoreKeepsInstalledManifest() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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
      XCTAssertEqual(statuses[0].state, .installed)
    }
  }

  func testRestoreRejectsBackupWithMismatchedReceiptFilename() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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
      XCTAssertFalse(statuses[0].hasRecoverableBackup)
    }
  }

  func testRestoreRejectsBackupWithMismatchedReceiptHash() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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
      XCTAssertFalse(statuses[0].hasRecoverableBackup)
    }
  }

  func testHostPackageUpdateReportsInstalledAppUpdatedAndRepairRefreshesReceipt() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.mutateHostResource()

      var statuses = await installer.inspect()
      XCTAssertEqual(statuses[2].state, .installedAppUpdated)
      XCTAssertNil(statuses[2].replacementFingerprint)

      // Repairing LinkDigest's own byte-identical manifest refreshes the stale
      // receipt snapshot without demanding a takeover confirmation.
      try await installer.install(.edge)
      statuses = await installer.inspect()
      XCTAssertEqual(statuses[2].state, .installed)
    }
  }

  func testHostPackageUpdateStillAllowsVerifiedUninstall() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try fixture.mutateHostResource()

      let statuses = await installer.inspect()
      XCTAssertEqual(statuses[2].state, .installedAppUpdated)
      try await installer.uninstall(.edge)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(.edge).path))
    }
  }

  func testSubprocessTerminatedInstallRecoversBeforeInspect() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
      let original = Data("{\"unknown\":true}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: original)

      try fixture.runCrashHarness(action: "install", browser: .chrome)
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(statuses[0].state, .unknownManifest)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), original)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessTerminatedUninstallRecoversBeforeInspect() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      let installed = try Data(contentsOf: fixture.manifest(.edge))

      try fixture.runCrashHarness(action: "uninstall", browser: .edge)
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(statuses[2].state, .installed)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.edge)), installed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessTerminatedRestoreRecoversBeforeInspect() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"unknown\":true}".utf8))
      let installer = fixture.installer()
      try await confirmReplacement(installer, browser: .chrome)
      let installed = try Data(contentsOf: fixture.manifest(.chrome))

      try fixture.runCrashHarness(action: "restore", browser: .chrome)
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(statuses[0].state, .installed)
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), installed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessTerminatedAfterJournalPublishLeavesAUsableFreshInstallState() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)

      try fixture.runCrashHarness(action: "install", browser: .chrome, phase: "after-journal-publish")
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(statuses.map(\.state), [.notInstalled, .notInstalled, .unavailable])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessReceiptDetachDuringExistingReceiptRepairRecoversAllTargets() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: true)
      let original = Data("{\"unknown\":true}".utf8)
      try fixture.writeUnknownManifest(.chrome, data: original)
      try await fixture.installer().install(.edge)

      try fixture.runCrashHarness(action: "install", browser: .chrome, phase: "after-receipt-detach-before-publish")
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(statuses.map(\.state), [.unknownManifest, .unknownManifest, .installed])
      XCTAssertEqual(try Data(contentsOf: fixture.manifest(.chrome)), original)
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessReceiptDetachDuringSecondTargetInstallRecoversFirstTarget() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: true)
      let installer = fixture.installer()
      try await installer.install(.chrome)

      try fixture.runCrashHarness(action: "install", browser: .edge, phase: "after-receipt-detach-before-publish")
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(statuses.map(\.state), [.installed, .installed, .notInstalled])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testSubprocessReceiptDetachDuringMultiTargetRestoreRecoversAllTargets() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: true)
      try fixture.writeUnknownManifest(.chrome, data: Data("{\"unknown\":true}".utf8))
      let installer = fixture.installer()
      try await confirmReplacement(installer, browser: .chrome)
      try await installer.install(.edge)

      try fixture.runCrashHarness(action: "restore", browser: .chrome, phase: "after-receipt-detach-before-publish")
      let statuses = await fixture.installer().inspect()
      XCTAssertEqual(statuses.map(\.state), [.installed, .installed, .installed])
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.operationJournalURL.path))
    }
  }

  func testReceiptWithMissingManifestOffersConfirmedRepairInsteadOfDeadEnd() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
      let installer = fixture.installer()
      try await installer.install(.edge)
      try FileManager.default.removeItem(at: fixture.manifest(.edge))

      let drifted = await installer.inspect()
      XCTAssertEqual(drifted[2].state, .drifted)
      let fingerprint = try XCTUnwrap(drifted[2].replacementFingerprint)
      try await installer.confirmReplacement(.edge, expectedFingerprint: fingerprint)
      let repaired = await installer.inspect()
      XCTAssertEqual(repaired[2].state, .installed)
    }
  }

  func testInstallDoesNotOverwriteConcurrentLeafAfterVerifiedDetach() async throws {
    try await withFixture { fixture in
      try fixture.createBrowserDirectories(sharedChrome: true, edge: false)
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
      try fixture.createBrowserDirectories(sharedChrome: false, edge: true)
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
      templates: Dictionary(uniqueKeysWithValues: BrowserSupportBrowser.allCases.map { ($0, data) }),
      templateHashes: Dictionary(uniqueKeysWithValues: BrowserSupportBrowser.allCases.map { ($0, templateHash) }),
      extensionID: "fbpjhlcpfheecigibjghhodhhkgjdgma",
      hostName: "com.syc.linkdigest.v01",
      version: "0.2.0",
      hostExecutableURL: host
    )
    let failAfterManifest: @Sendable (String) -> Bool = { $0 == "after-manifest" }
    let failAtPhase: @Sendable (String) -> Bool = { $0 == failurePhase }
    let injector: (@Sendable (String) -> Bool)? = failAfterManifestWrite ? failAfterManifest : (failurePhase == nil ? nil : failAtPhase)
    return BrowserSupportInstaller(homeRoot: home, artifacts: artifacts, failureInjection: injector, mutationBarrier: mutationBarrier)
  }

  func createBrowserDirectories(sharedChrome: Bool, edge: Bool) throws {
    if sharedChrome {
      try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    if edge {
      try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Microsoft Edge/NativeMessagingHosts"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }

  func manifest(_ browser: BrowserSupportBrowser) -> URL {
    let parent: String = switch browser {
    case .chrome: "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    case .brave: "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    case .edge: "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    }
    return home.appendingPathComponent(parent).appendingPathComponent("com.syc.linkdigest.v01.json")
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
      "--browser", browser.rawValue,
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
    let target: String = switch browser {
    case .chrome, .brave: "chrome"
    case .edge: "edge"
    }
    let entry = try XCTUnwrap(receipt().entries.first(where: { $0.target == target }))
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
