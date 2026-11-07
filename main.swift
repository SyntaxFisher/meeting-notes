import AppKit

let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "transcribe" {
  guard let options = TranscribeCommand.parse(Array(arguments.dropFirst(2))) else {
    FileHandle.standardError.write(Data((TranscribeCommand.usage + "\n").utf8))
    exit(2)
  }
  Task { @MainActor in exit(await TranscribeCommand.run(options)) }
  dispatchMain()
}

// Any first argument that is not a flag is a command; the app itself only receives flags.
if arguments.count > 1, !arguments[1].hasPrefix("-") {
  exit(CommandLineInterface.run(Array(arguments.dropFirst())))
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let delegate = MeetingAppDelegate()
  app.delegate = delegate
  withExtendedLifetime(delegate) { app.run() }
}
