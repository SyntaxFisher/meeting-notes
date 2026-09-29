import AppKit

if CommandLine.arguments.contains("--check-teams-mute") {
  let reading = TeamsMuteReader.read()
  let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
  print("Teams meeting title: \(reading.meetingTitle ?? "none")")
  switch reading.state {
  case .muted: print("Teams mic: muted; frontmost app: \(frontmost)")
  case .unmuted: print("Teams mic: unmuted; frontmost app: \(frontmost)")
  case .unavailable(let reason):
    print("Teams mic: unavailable (\(reason.message)); frontmost app: \(frontmost)")
  }
  exit(0)
}

do {
  let store = try StateStore()
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MeetingAppDelegate(store: store)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
} catch {
  AppLog.event("app.startFailed", error.localizedDescription)
  NSLog("Meeting Notes could not start: \(error.localizedDescription)")
  exit(1)
}
