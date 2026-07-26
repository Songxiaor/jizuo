import Foundation
import XCTest
@testable import LinkDigestApp
import LinkDigestCore

private actor BrowserSupportBarrier {
  private var entered = false
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var observers: [CheckedContinuation<Void, Never>] = []

  func suspend() async {
    entered = true
    let pending = observers
    observers.removeAll()
    pending.forEach { $0.resume() }
    guard !released else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}

private actor BrowserSupportMockInstaller: BrowserSupportInstalling {
  enum Call: Equatable { case install(BrowserSupportBrowser), confirm(BrowserSupportBrowser), uninstall(BrowserSupportBrowser), restore(BrowserSupportBrowser) }

  private var values: [BrowserSupportStatus]
  private let installBarrier: BrowserSupportBarrier?
  private var calls: [Call] = []

  init(values: [BrowserSupportStatus], installBarrier: BrowserSupportBarrier? = nil) {
    self.values = values
    self.installBarrier = installBarrier
  }

  func inspect() async -> [BrowserSupportStatus] { values }

  func install(_ browser: BrowserSupportBrowser) async throws {
    calls.append(.install(browser))
    if let installBarrier { await installBarrier.suspend() }
    markInstalled(browser)
  }

  func confirmReplacement(_ browser: BrowserSupportBrowser, expectedFingerprint _: String) async throws {
    calls.append(.confirm(browser))
    markInstalled(browser)
  }

  func uninstall(_ browser: BrowserSupportBrowser) async throws {
    calls.append(.uninstall(browser))
  }

  func restoreLatestBackup(_ browser: BrowserSupportBrowser) async throws {
    calls.append(.restore(browser))
  }

  func recordedCalls() -> [Call] { calls }

  private func markInstalled(_ browser: BrowserSupportBrowser) {
    if browser == .chrome || browser == .brave {
      values = values.map {
        ($0.browser == .chrome || $0.browser == .brave)
          ? .init(browser: $0.browser, state: .installed, hasRecoverableBackup: $0.hasRecoverableBackup)
          : $0
      }
    } else {
      values = values.map {
        $0.browser == browser ? .init(browser: browser, state: .installed, hasRecoverableBackup: $0.hasRecoverableBackup) : $0
      }
    }
  }
}

@MainActor
final class BrowserSupportViewModelTests: XCTestCase {
  func testUnknownManifestStopsAtConfirmationUntilUserExplicitlyConfirms() async {
    let installer = BrowserSupportMockInstaller(values: statuses(chrome: .unknownManifest))
    let model = BrowserSupportViewModel(installer: installer)
    await model.load()

    await model.requestInstall(.chrome)
    var calls = await installer.recordedCalls()
    XCTAssertEqual(calls, [])
    XCTAssertEqual(model.pendingConfirmation?.action, .repair)
    XCTAssertEqual(model.pendingConfirmation?.browser, .chrome)
    guard case let .confirmation(pending) = model.presentation else {
      return XCTFail("repair must route the confirmation through the single presented alert")
    }
    XCTAssertEqual(pending.fingerprint, "fixture-confirmation")
    XCTAssertNil(model.result)

    model.presentation = nil // SwiftUI dismisses the Alert binding before running its async button action.
    await model.confirmReplacement(pending)
    calls = await installer.recordedCalls()
    XCTAssertEqual(calls, [.confirm(.chrome)])
    XCTAssertNil(model.pendingConfirmation)
    guard case let .result(result) = model.presentation else {
      return XCTFail("successful confirmation must route the result through the same alert")
    }
    XCTAssertEqual(result.browser, .chrome)
    XCTAssertEqual(result.kind, .repaired)
  }

  func testCancellingPresentedRepairConfirmationPerformsNoFilesystemOperation() async {
    let installer = BrowserSupportMockInstaller(values: statuses(chrome: .drifted))
    let model = BrowserSupportViewModel(installer: installer)
    await model.load()

    await model.requestInstall(.chrome)
    XCTAssertNotNil(model.pendingConfirmation)
    model.cancelPendingReplacement()

    XCTAssertNil(model.presentation)
    let calls = await installer.recordedCalls()
    XCTAssertEqual(calls, [])
  }

  func testCurrentAppUnverifiedIsUsableButStillRequiresOwnershipConfirmation() async {
    let installer = BrowserSupportMockInstaller(values: statuses(chrome: .currentAppUnverified))
    let model = BrowserSupportViewModel(installer: installer)
    await model.load()

    XCTAssertTrue(model.canRepair(.chrome))
    XCTAssertFalse(model.canUninstall(.chrome))
    await model.requestInstall(.chrome)

    XCTAssertEqual(model.pendingConfirmation?.browser, .chrome)
    let calls = await installer.recordedCalls()
    XCTAssertEqual(calls, [])
  }

  func testDirectActionDuringAnotherInstallDoesNotQueueSecondFilesystemOperation() async {
    let barrier = BrowserSupportBarrier()
    let installer = BrowserSupportMockInstaller(values: statuses(), installBarrier: barrier)
    let model = BrowserSupportViewModel(installer: installer)
    await model.load()

    let first = Task { await model.requestInstall(.chrome) }
    await barrier.waitUntilEntered()
    XCTAssertEqual(model.activeBrowser, .chrome)
    await model.requestInstall(.edge)
    let calls = await installer.recordedCalls()
    XCTAssertEqual(calls, [.install(.chrome)])

    await barrier.release()
    await first.value
    XCTAssertNil(model.activeBrowser)
  }

  func testChromeActionRefreshesBraveSharedTargetStatus() async {
    let installer = BrowserSupportMockInstaller(values: statuses())
    let model = BrowserSupportViewModel(installer: installer)
    await model.load()

    await model.requestInstall(.chrome)
    XCTAssertEqual(model.status(for: .chrome).state, .installed)
    XCTAssertEqual(model.status(for: .brave).state, .installed)
    XCTAssertEqual(model.status(for: .edge).state, .notInstalled)
  }

  func testLoadingStateRejectsDirectActionEntryPoint() async {
    let barrier = BrowserSupportBarrier()
    let installer = BrowserSupportMockInstaller(values: statuses(), installBarrier: barrier)
    let model = BrowserSupportViewModel(installer: installer)
    // The first load returns promptly; use a real active transaction to prove
    // the same entry guard that protects buttons also protects direct calls.
    await model.load()
    let first = Task { await model.requestInstall(.edge) }
    await barrier.waitUntilEntered()
    XCTAssertFalse(model.canInstall(.chrome))
    await model.requestInstall(.chrome)
    let calls = await installer.recordedCalls()
    XCTAssertEqual(calls, [.install(.edge)])
    await barrier.release()
    await first.value
  }

  private func statuses(chrome: BrowserSupportInstallState = .notInstalled) -> [BrowserSupportStatus] {
    let fingerprint = [.currentAppUnverified, .drifted, .unknownManifest].contains(chrome)
      ? "fixture-confirmation"
      : nil
    return [
      .init(browser: .chrome, state: chrome, hasRecoverableBackup: false, replacementFingerprint: fingerprint),
      .init(browser: .brave, state: chrome, hasRecoverableBackup: false, replacementFingerprint: fingerprint),
      .init(browser: .edge, state: .notInstalled, hasRecoverableBackup: false),
    ]
  }
}
