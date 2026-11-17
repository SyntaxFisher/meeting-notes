import Foundation

@MainActor
final class UpdateInstallationGate {
  private var pendingInstallation: (() -> Void)?
  private(set) var installationStarted = false
  /// Whether an installation started now could replace the app. A pending installation waits
  /// while this is false, because starting it quits the app.
  var canInstall: () -> Bool = { true }

  func installWhenIdle(_ install: @escaping () -> Void) {
    pendingInstallation = install
  }

  func postpone(whileBusy busy: Bool, install: @escaping () -> Void) -> Bool {
    guard busy else {
      installationStarted = true
      return false
    }
    installWhenIdle(install)
    return true
  }

  func resumeIfIdle(_ idle: Bool) {
    if idle && pendingInstallation != nil && canInstall() { installNow() }
  }

  func installNow() {
    guard let install = pendingInstallation else { return }
    pendingInstallation = nil
    installationStarted = true
    install()
  }

  func reset() {
    pendingInstallation = nil
    installationStarted = false
  }
}
