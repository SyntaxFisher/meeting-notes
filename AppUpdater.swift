import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
  let installation = UpdateInstallationGate()
  var isBusy: () -> Bool = { false }
  /// Called when the user chose to install and relaunch while the app is busy.
  var confirmRelaunch: () -> Void = {}
  private static let attemptedBuildKey = "attemptedUpdateBuild"
  private let enabled = Bundle.main.object(forInfoDictionaryKey: "MNEnableUpdater") as? Bool == true
  private var offeredBuild: String?
  private var reportedWaiting = false
  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

  func start() {
    installation.canInstall = { [weak self] in
      let replaceable = InstallLocation.isReplaceable(Bundle.main.bundleURL)
      if let self, !replaceable, !self.reportedWaiting {
        self.reportedWaiting = true
        AppLog.event("update.waiting", "The app cannot be replaced without admin rights")
      }
      return replaceable
    }
    if enabled { controller.startUpdater() }
  }

  var isEnabled: Bool { enabled }
  var canCheckForUpdates: Bool { enabled && controller.updater.canCheckForUpdates && !isBusy() }

  var automaticUpdates: Bool {
    get {
      enabled && controller.updater.automaticallyChecksForUpdates
        && controller.updater.automaticallyDownloadsUpdates
    }
    set {
      guard enabled else { return }
      controller.updater.automaticallyDownloadsUpdates = newValue
      controller.updater.automaticallyChecksForUpdates = newValue
    }
  }

  func checkForUpdates() {
    if canCheckForUpdates { controller.checkForUpdates(nil) }
  }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard !isBusy() else {
      AppLog.event("update.deferred", "App is busy")
      throw NSError(
        domain: "com.jona.meeting-notes.update", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Updates wait until recording and transcription finish."
        ])
    }
    AppLog.event("update.check", "type=\(updateCheck.rawValue)")
  }

  func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
    AppLog.event("update.scheduled", "delay=\(Int(delay)) seconds")
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    offeredBuild = item.versionString
    AppLog.event(
      "update.found", "version=\(item.displayVersionString); build=\(item.versionString)")
  }

  /// Runs whenever the installer is about to quit the app, for every way an update installs.
  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    UserDefaults.standard.set(offeredBuild, forKey: Self.attemptedBuildKey)
    UpdateRelaunchGuard.start()
  }

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    // A build whose installation already quit the app once without replacing it is left to
    // Sparkle's installation on quit, so a failing installation cannot quit the app repeatedly.
    guard UserDefaults.standard.string(forKey: Self.attemptedBuildKey) != item.versionString else {
      AppLog.event("update.skipped", "build=\(item.versionString); installs on quit")
      return false
    }
    reportedWaiting = false
    AppLog.event("update.ready", "build=\(item.versionString); waiting for idle")
    installation.installWhenIdle {
      AppLog.event("update.installing", "build=\(item.versionString)")
      immediateInstallHandler()
    }
    return true
  }

  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    guard installation.postpone(whileBusy: isBusy(), install: installHandler) else { return false }
    AppLog.event("update.relaunchPostponed", "build=\(item.versionString)")
    confirmRelaunch()
    return true
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    installation.reset()
    let error = error as NSError
    if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
      AppLog.event("update.current", error.localizedDescription)
    } else {
      AppLog.event(
        "update.aborted", "\(error.domain); code=\(error.code); \(error.localizedDescription)")
    }
  }
}
