import Foundation

/// Whether the current user can replace the app bundle right now. Group membership is read from
/// the directory service instead of the process credentials, which keep the groups from launch
/// time and miss admin rights that were granted or revoked since.
enum InstallLocation {
  static func isReplaceable(_ bundle: URL) -> Bool {
    let user = getuid()
    return [bundle.deletingLastPathComponent(), bundle].allSatisfy { directory in
      var status = stat()
      guard stat(directory.path, &status) == 0 else { return false }
      return isWritable(
        mode: status.st_mode, owner: status.st_uid, group: status.st_gid, user: user,
        isMember: { isMember(user: user, of: $0) })
    }
  }

  static func isWritable(
    mode: mode_t, owner: uid_t, group: gid_t, user: uid_t, isMember: (gid_t) -> Bool
  ) -> Bool {
    if user == 0 { return true }
    if owner == user { return mode & S_IWUSR != 0 }
    if isMember(group) { return mode & S_IWGRP != 0 }
    return mode & S_IWOTH != 0
  }

  private static func isMember(user: uid_t, of group: gid_t) -> Bool {
    guard let account = getpwuid(user) else { return false }
    var count: Int32 = 256
    var groups = [Int32](repeating: 0, count: Int(count))
    guard getgrouplist(account.pointee.pw_name, Int32(account.pointee.pw_gid), &groups, &count) >= 0
    else { return false }
    return groups.prefix(Int(count)).contains(Int32(group))
  }
}

/// Reopens the app when an update installation ends without a running app. Sparkle's installer
/// quits the app before it replaces the bundle and does not relaunch it when that fails.
enum UpdateRelaunchGuard {
  /// Arguments: the app's process ID, the seconds the installer gets to relaunch the app, the
  /// app's executable and its bundle. Command-line invocations of the executable carry a command
  /// and do not count as the running app.
  static let script = """
    while kill -0 "$1" 2>/dev/null; do sleep 1; done
    sleep "$2"
    ps -axo command= | awk -v exe="$3" \
      '$0 == exe || index($0, exe " -") == 1 { found = 1 } END { exit !found }' \
      || open -g "$4"
    """

  @discardableResult
  static func start(
    pid: Int32 = ProcessInfo.processInfo.processIdentifier, grace: Int = 30,
    executable: URL? = Bundle.main.executableURL, bundle: URL = Bundle.main.bundleURL,
    environment: [String: String]? = nil
  ) -> Process? {
    guard let executable else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", script, "sh", String(pid), String(grace), executable.path, bundle.path,
    ]
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      return process
    } catch {
      AppLog.event("update.relaunchGuardFailed", error.localizedDescription)
      return nil
    }
  }
}
