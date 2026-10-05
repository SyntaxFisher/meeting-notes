import Foundation

@MainActor
final class UpdateInstallationGate {
  private var pendingInstallation: (() -> Void)?
  private(set) var installationStarted = false

  func postpone(whileBusy busy: Bool, install: @escaping () -> Void) -> Bool {
    guard busy else {
      installationStarted = true
      return false
    }
    pendingInstallation = install
    return true
  }

  func resumeIfIdle(_ idle: Bool) {
    guard idle, let install = pendingInstallation else { return }
    pendingInstallation = nil
    installationStarted = true
    install()
  }

  func reset() {
    pendingInstallation = nil
    installationStarted = false
  }
}
