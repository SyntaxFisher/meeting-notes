import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
  let installation = UpdateInstallationGate()
  var isBusy: () -> Bool = { false }
  private let enabled = Bundle.main.object(forInfoDictionaryKey: "MNEnableUpdater") as? Bool == true
  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

  func start() {
    if enabled { controller.startUpdater() }
  }

  func addMenuItems(to menu: NSMenu) {
    guard enabled else { return }
    menu.addItem(.separator())
    let check = NSMenuItem(
      title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    check.target = self
    check.isEnabled = controller.updater.canCheckForUpdates && !isBusy()
    menu.addItem(check)
    let automatic = NSMenuItem(
      title: "Automatic Updates", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
    automatic.target = self
    automatic.state =
      controller.updater.automaticallyChecksForUpdates
        && controller.updater.automaticallyDownloadsUpdates ? .on : .off
    menu.addItem(automatic)
    menu.addItem(.separator())
  }

  @objc private func checkForUpdates() { controller.checkForUpdates(nil) }

  @objc private func toggleAutomaticUpdates() {
    let updater = controller.updater
    let enabled = !(updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates)
    updater.automaticallyDownloadsUpdates = enabled
    updater.automaticallyChecksForUpdates = enabled
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
    AppLog.event(
      "update.found", "version=\(item.displayVersionString); build=\(item.versionString)")
  }

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
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
    installation.postpone(whileBusy: isBusy(), install: installHandler)
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
