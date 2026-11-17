import Foundation

@MainActor
enum UpdateSafetySmoke {
  static func run(_ directory: URL) throws {
    let member: (gid_t) -> Bool = { $0 == 80 }
    let writable = { (mode: mode_t, owner: uid_t, group: gid_t) in
      InstallLocation.isWritable(
        mode: mode, owner: owner, group: group, user: 501, isMember: member)
    }
    precondition(writable(0o755, 501, 20))
    precondition(!writable(0o555, 501, 80))
    precondition(writable(0o775, 0, 80))
    precondition(!writable(0o755, 0, 80))
    precondition(!writable(0o775, 0, 0))
    precondition(writable(0o777, 0, 0))
    precondition(
      InstallLocation.isWritable(mode: 0o555, owner: 1, group: 1, user: 0, isMember: member))
    precondition(!InstallLocation.isReplaceable(URL(fileURLWithPath: "/System/Library")))

    let gate = UpdateInstallationGate()
    var replaceable = false
    var installs = 0
    gate.canInstall = { replaceable }
    gate.installWhenIdle { installs += 1 }
    gate.resumeIfIdle(true)
    precondition(installs == 0 && !gate.installationStarted)
    replaceable = true
    gate.resumeIfIdle(true)
    precondition(installs == 1 && gate.installationStarted)

    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let opened = directory.appendingPathComponent("opened")
    let open = directory.appendingPathComponent("open")
    try "#!/bin/sh\necho \"$@\" > '\(opened.path)'\n".write(
      to: open, atomically: true, encoding: .utf8)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
    let environment = ["PATH": "\(directory.path):/usr/bin:/bin"]
    let bundle = URL(fileURLWithPath: "/Applications/Some App.app")

    func guardRun(executable: String) throws -> Bool {
      try? manager.removeItem(at: opened)
      let app = Process()
      app.executableURL = URL(fileURLWithPath: "/bin/sleep")
      app.arguments = ["1"]
      try app.run()
      let relaunch = UpdateRelaunchGuard.start(
        pid: app.processIdentifier, grace: 0, executable: URL(fileURLWithPath: executable),
        bundle: bundle, environment: environment)
      relaunch?.waitUntilExit()
      precondition(!app.isRunning)
      return manager.fileExists(atPath: opened.path)
    }
    let reopened = try guardRun(executable: "/Applications/Some App.app/Contents/MacOS/Missing")
    let arguments = try String(contentsOf: opened, encoding: .utf8)
    precondition(reopened && arguments == "-g \(bundle.path)\n")
    // The guard's own shell stands in for an app the installer relaunched.
    let reopenedRunning = try guardRun(executable: "/bin/sh")
    precondition(!reopenedRunning)
    print(
      "Updates wait for a replaceable app, and a quit without a relaunch reopens the app: OK")
  }
}
