import AVFoundation
import CoreAudio

enum CaptureSource: String {
  case system, microphone
}

/// Whose playback the system track records. It is chosen once when a recording starts; a
/// microphone-only recording has no scope. It is stored as `teams`, `device-audio` or
/// `app:<bundle id>`.
enum SystemAudioScope: RawRepresentable, Codable, Hashable, Sendable {
  /// Only Teams' processes, so notifications and music stay out of Teams meetings.
  case teams
  /// Everything this Mac plays except Meeting Notes, for calls in any other app.
  case deviceAudio
  /// Only the processes of the app with this bundle ID and its helpers.
  case app(String)

  init?(rawValue: String) {
    switch rawValue {
    case "teams": self = .teams
    case "device-audio": self = .deviceAudio
    default:
      guard rawValue.hasPrefix(Self.appPrefix),
        let bundleID = Self.bundleID(
          String(rawValue.dropFirst(Self.appPrefix.count)))
      else { return nil }
      self = .app(bundleID)
    }
  }

  var rawValue: String {
    switch self {
    case .teams: "teams"
    case .deviceAudio: "device-audio"
    case .app(let bundleID): Self.appPrefix + bundleID
    }
  }

  private static let appPrefix = "app:"

  /// The scope is fixed at recording start. Unknown Teams state captures all device audio,
  /// which includes Teams, so a call is never lost.
  static func forRecording(automatic: Bool, teamsMeeting: TeamsMeetingPresence) -> Self {
    automatic || [.inMeeting, .connecting].contains(teamsMeeting) ? .teams : .deviceAudio
  }

  private static func bundleID(_ text: String) -> String? {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard text.contains("."),
      !text.split(separator: ".", omittingEmptySubsequences: false).contains(""),
      text.unicodeScalars.allSatisfy(allowed.contains)
    else { return nil }
    return text
  }

  /// The bundle IDs whose processes an app tap covers, together with their helpers' bundle IDs
  /// that start with one of them; nil for the global device-audio tap.
  var bundleIDs: [String]? {
    switch self {
    case .teams: [AudioProcessStatus.teamsBundleID]
    case .deviceAudio: nil
    case .app(let bundleID): [bundleID]
    }
  }

  /// Whether a process with this bundle ID plays audio for the scope.
  func covers(_ bundleID: String) -> Bool {
    guard let bundleIDs else { return true }
    return bundleIDs.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
  }

  /// The capture mode in logs.
  var mode: String { "microphone-and-\(rawValue)" }

  /// The system track's name in messages, such as "Zoom audio".
  var label: String {
    switch self {
    case .teams: "Teams audio"
    case .deviceAudio: "device audio"
    case .app(let bundleID): "\(bundleID) audio"
    }
  }
}

typealias AudioCaptureHandler = @Sendable (CapturedAudio, UInt64) -> Void
typealias AudioCaptureFailureHandler = @Sendable (Error) -> Void

protocol AudioCaptureInput: AnyObject {
  var source: CaptureSource { get }
  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler)
    throws
  func stop() throws
}

struct CoreAudioFailure: LocalizedError {
  let operation: String
  let status: OSStatus

  var errorDescription: String? { "\(operation) failed (Core Audio \(status))." }

  static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw Self(operation: operation, status: status) }
  }
}

final class AudioCaptureResources {
  private var cleanup: [() throws -> Void] = []

  func add(_ action: @escaping () throws -> Void) { cleanup.append(action) }

  func release() throws {
    let actions = cleanup.reversed()
    cleanup.removeAll()
    var failure: Error?
    for action in actions {
      do { try action() } catch { failure = failure ?? error }
    }
    if let failure { throw failure }
  }
}

// Delivered samples own their storage and are read-only after submission.
struct CapturedAudio: @unchecked Sendable {
  let buffer: AVAudioPCMBuffer

  private init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  static func copy(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) throws
    -> CapturedAudio
  {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
    guard let first = buffers.first, bytesPerFrame > 0,
      first.mDataByteSize > 0, first.mDataByteSize % bytesPerFrame == 0,
      let output = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: first.mDataByteSize / bytesPerFrame)
    else { throw MeetingError("Captured audio has an invalid buffer format.") }
    output.frameLength = output.frameCapacity
    let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
    guard buffers.count == destination.count else {
      throw MeetingError("Captured audio channel layout changed.")
    }
    for index in buffers.indices {
      guard buffers[index].mDataByteSize == destination[index].mDataByteSize,
        buffers[index].mNumberChannels == destination[index].mNumberChannels,
        let source = buffers[index].mData, let target = destination[index].mData
      else { throw MeetingError("Captured audio has an invalid channel buffer.") }
      memcpy(target, source, Int(buffers[index].mDataByteSize))
    }
    return CapturedAudio(buffer: output)
  }
}

protocol MicrophoneEngine: AnyObject {
  var isRunning: Bool { get }
  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler,
    onConfigurationChange: @escaping @Sendable () -> Void) throws
  func stop()
}

struct MicrophoneInputUnavailable: LocalizedError {
  var errorDescription: String? { "No microphone input is available." }
}

final class NativeMicrophoneEngine: MicrophoneEngine {
  private let engine = AVAudioEngine()
  private var observer: NSObjectProtocol?
  private var tapInstalled = false
  var isRunning: Bool { engine.isRunning }

  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler,
    onConfigurationChange: @escaping @Sendable () -> Void
  ) throws {
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { _ in onConfigurationChange() }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw MicrophoneInputUnavailable()
    }
    input.installTap(onBus: 0, bufferSize: 2_048, format: nil) { buffer, time in
      guard buffer.frameLength > 0 else { return }
      do {
        guard time.isHostTimeValid else {
          throw MeetingError("Microphone audio has no host timestamp.")
        }
        let owned = try CapturedAudio.copy(buffer.audioBufferList, format: buffer.format)
        receive(owned, time.hostTime)
      } catch { onFailure(error) }
    }
    tapInstalled = true
    engine.prepare()
    do {
      try engine.start()
    } catch {
      if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
        throw PermissionRequired(permission: .microphone)
      }
      throw error
    }
    AppLog.event(
      "capture.microphoneFormat", "rate=\(format.sampleRate); channels=\(format.channelCount)")
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    engine.stop()
    if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
    tapInstalled = false
  }
}

final class MicrophoneCapture: AudioCaptureInput, @unchecked Sendable {
  let source = CaptureSource.microphone
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.microphone")
  private let makeEngine: () -> any MicrophoneEngine
  private let retryDelays: [TimeInterval]
  private var engine: (any MicrophoneEngine)?
  private var engineID = UUID()
  private var running = false
  private var restart: DispatchWorkItem?
  private var attempts = 0

  init(
    retryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 2],
    makeEngine: @escaping () -> any MicrophoneEngine = { NativeMicrophoneEngine() }
  ) {
    self.retryDelays = retryDelays
    self.makeEngine = makeEngine
  }

  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler
  )
    throws
  {
    try queue.sync {
      running = true
      attempts = 0
      while true {
        do {
          try openEngine(receive: receive, onFailure: onFailure)
          return
        } catch {
          closeEngine()
          guard Self.isTransient(error), attempts < retryDelays.count else {
            running = false
            throw error
          }
          AppLog.event("capture.microphoneRetry", error.localizedDescription)
          Thread.sleep(forTimeInterval: retryDelays[attempts])
          attempts += 1
        }
      }
    }
  }

  private func openEngine(
    receive: @escaping AudioCaptureHandler,
    onFailure: @escaping AudioCaptureFailureHandler
  ) throws {
    closeEngine()
    let identifier = engineID
    let engine = makeEngine()
    self.engine = engine
    try engine.start(
      receive: { [weak self] buffer, time in
        self?.queue.async { [weak self] in
          guard let self, self.running, self.engineID == identifier else { return }
          self.attempts = 0
          receive(buffer, time)
        }
      },
      onFailure: { [weak self] error in
        self?.queue.async { [weak self] in
          guard let self, self.running, self.engineID == identifier else { return }
          AppLog.event("capture.microphoneFailed", error.localizedDescription)
          onFailure(error)
        }
      },
      onConfigurationChange: { [weak self] in
        self?.queue.async { [weak self] in
          guard let self, self.running, self.engineID == identifier,
            self.engine?.isRunning == false
          else { return }
          self.scheduleRestart(receive: receive, onFailure: onFailure)
        }
      })
  }

  private func scheduleRestart(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler
  ) {
    guard running, restart == nil else { return }
    guard attempts < retryDelays.count else {
      running = false
      onFailure(MeetingError("The microphone could not recover after an audio-device change."))
      return
    }
    let delay = retryDelays[attempts]
    attempts += 1
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.running, self.restart != nil else { return }
      self.restart = nil
      do {
        AppLog.event("capture.microphoneRestart", "attempt=\(self.attempts)")
        try self.openEngine(receive: receive, onFailure: onFailure)
      } catch {
        self.closeEngine()
        AppLog.event("capture.microphoneRetry", error.localizedDescription)
        if Self.isTransient(error), self.attempts < self.retryDelays.count {
          self.scheduleRestart(receive: receive, onFailure: onFailure)
        } else {
          self.running = false
          onFailure(error)
        }
      }
    }
    restart = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private static func isTransient(_ error: Error) -> Bool {
    if error is MicrophoneInputUnavailable { return true }
    let error = error as NSError
    return [NSOSStatusErrorDomain, "com.apple.coreaudio.avfaudio"].contains(error.domain)
      && [
        Int(kAudioUnitErr_FormatNotSupported), Int(kAudioUnitErr_FailedInitialization),
        Int(kAudioUnitErr_NoConnection), Int(kAudioHardwareBadDeviceError),
      ].contains(error.code)
  }

  private func closeEngine() {
    engineID = UUID()
    engine?.stop()
    engine = nil
  }

  func stop() throws {
    queue.sync {
      running = false
      restart?.cancel()
      restart = nil
      closeEngine()
    }
  }
}

/// Captures the system track: the playback of one app (Teams or another), or everything the Mac
/// plays except Meeting Notes.
final class SystemAudioCapture: AudioCaptureInput, @unchecked Sendable {
  let source = CaptureSource.system
  let scope: SystemAudioScope
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.system-audio")
  private let resources = AudioCaptureResources()
  private var generation = UUID()
  private var running = false
  private var watchdog: DispatchSourceTimer?
  private var pendingRestart: DispatchWorkItem?
  private var health = SystemCaptureHealth()
  private var lastProcesses: [AudioProcessStatus]?
  private var tappedProcesses: [AudioObjectID] = []
  private var bufferRecoveryAttempts = 0

  init(scope: SystemAudioScope) {
    self.scope = scope
    label = scope.label
  }

  private let label: String

  /// The app's audio process objects to tap. Taps target process objects rather than bundle
  /// IDs: when several helpers share a bundle ID (for example an idle and an active Teams module
  /// host), a bundle-ID tap can miss the instance that plays the call and deliver nothing.
  static func tapTargets(of scope: SystemAudioScope, in processes: [AudioProcessStatus])
    -> [AudioObjectID]
  {
    Set(processes.filter { scope.covers($0.bundleID) }.map(\.id)).sorted()
  }

  static func needsRestart(
    scope: SystemAudioScope, tappedProcesses: [AudioObjectID], previous: [AudioProcessStatus]?,
    current: [AudioProcessStatus]
  ) -> Bool {
    // A global tap already covers every process on every output, so only an app tap, which
    // does not follow new or replaced processes, is rebuilt when the app's processes change.
    guard scope.bundleIDs != nil else { return false }
    if tapTargets(of: scope, in: current) != tappedProcesses { return true }
    let oldDevices = Set((previous ?? []).flatMap(\.outputDevices))
    let newDevices = Set(current.flatMap(\.outputDevices))
    return previous != nil && !newDevices.isEmpty && newDevices != oldDevices
  }

  /// A tap of one app's processes. `scope` must name an app.
  static func appTapDescription(scope: SystemAudioScope, processes: [AudioProcessStatus])
    -> CATapDescription
  {
    let description = CATapDescription()
    description.uuid = UUID()
    description.name = "Meeting Notes \(scope.label)"
    let targets = tapTargets(of: scope, in: processes)
    if targets.isEmpty {
      // An app has no audio process object until it first opens audio, and it may not even be
      // running yet; the health check switches to process targets as soon as one appears.
      description.bundleIDs = scope.bundleIDs ?? []
      description.isProcessRestoreEnabled = true
    } else {
      description.processes = targets
    }
    description.isExclusive = false
    description.isMixdown = true
    description.isMono = true
    description.isPrivate = true
    description.muteBehavior = .unmuted
    return description
  }

  /// A global tap of every process except Meeting Notes, so Library playback during a recording
  /// stays out of it. It needs no permission beyond System Audio Recording.
  static func deviceTapDescription(ownProcess: AudioObjectID?) -> CATapDescription {
    let excluded = ownProcess.map { [$0] } ?? []
    let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
    description.uuid = UUID()
    description.name = "Meeting Notes device audio"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    return description
  }

  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler
  )
    throws
  {
    try queue.sync {
      running = true
      try configure(receive: receive, onFailure: onFailure)
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + 2, repeating: 2)
      timer.setEventHandler { [weak self] in
        self?.checkHealth(receive: receive, onFailure: onFailure)
      }
      watchdog = timer
      timer.resume()
    }
  }

  /// The processes whose output the tap covers: the app's processes, or all others.
  private func processes() throws -> [AudioProcessStatus] {
    switch scope {
    case .teams, .app: return try AudioHardwareInfo.processes { [scope] in scope.covers($0) }
    case .deviceAudio:
      let own = ProcessInfo.processInfo.processIdentifier
      return try AudioHardwareInfo.processes { _ in true }.filter { $0.pid != own }
    }
  }

  private func configure(
    receive: AudioCaptureHandler?, onFailure: @escaping AudioCaptureFailureHandler
  ) throws {
    generation = UUID()
    let currentGeneration = generation
    try resources.release()
    let processes = try processes()
    let description: CATapDescription
    var ownProcess: AudioObjectID?
    switch scope {
    case .teams, .app:
      description = Self.appTapDescription(scope: scope, processes: processes)
    case .deviceAudio:
      ownProcess = try? AudioHardwareInfo.processObject(
        pid: ProcessInfo.processInfo.processIdentifier)
      if ownProcess == nil {
        AppLog.event("capture.ownProcessUnknown", "Meeting Notes playback is not excluded")
      }
      description = Self.deviceTapDescription(ownProcess: ownProcess)
    }
    var tap = AudioObjectID(kAudioObjectUnknown)
    try CoreAudioFailure.check(
      AudioHardwareCreateProcessTap(description, &tap), "Create \(label) tap")
    let tapID = tap
    let label = label
    resources.add {
      try CoreAudioFailure.check(AudioHardwareDestroyProcessTap(tapID), "Destroy \(label) tap")
    }

    let tapUID = try AudioHardwareInfo.string(tapID, kAudioTapPropertyUID)
    guard !tapUID.isEmpty else { throw MeetingError("The \(label) tap has no identifier.") }

    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Meeting Notes \(label)",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapUIDKey: tapUID,
          kAudioSubTapDriftCompensationKey: true,
        ]
      ],
    ]
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    try CoreAudioFailure.check(
      AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
      "Create \(label) device")
    let deviceID = aggregate
    resources.add {
      try CoreAudioFailure.check(
        AudioHardwareDestroyAggregateDevice(deviceID), "Destroy \(label) device")
    }
    let format = try waitForInputFormat(deviceID)
    AppLog.event(
      "capture.systemFormat",
      "\(scope.rawValue); rate=\(format.sampleRate); channels=\(format.channelCount)")
    var ioProc: AudioDeviceIOProcID?
    try CoreAudioFailure.check(
      AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, nil) {
        [weak self] _, data, time, _, _ in
        // Permission setup starts the device without consuming any audio samples.
        guard let receive else { return }
        guard data.pointee.mNumberBuffers > 0, data.pointee.mBuffers.mDataByteSize > 0 else {
          return
        }
        do {
          guard time.pointee.mFlags.contains(.hostTimeValid) else {
            throw MeetingError("System audio has no host timestamp.")
          }
          let owned = try CapturedAudio.copy(data, format: format)
          let hostTime = time.pointee.mHostTime
          self?.queue.async { [weak self] in
            guard let self, self.running, self.generation == currentGeneration else { return }
            self.health.receivedBuffer()
            self.bufferRecoveryAttempts = 0
            receive(owned, hostTime)
          }
        } catch {
          self?.queue.async { [weak self] in
            guard let self, self.running, self.generation == currentGeneration else { return }
            guard self.pendingRestart == nil else { return }
            AppLog.event("capture.systemBufferFailed", error.localizedDescription)
            if self.bufferRecoveryAttempts < 2 {
              self.bufferRecoveryAttempts += 1
              self.scheduleRestart(receive: receive, onFailure: onFailure)
            } else {
              self.fail(error, onFailure: onFailure)
            }
          }
        }
      }, "Create \(label) callback")
    guard let ioProc else { throw MeetingError("Core Audio did not create an audio callback.") }
    resources.add {
      try CoreAudioFailure.check(
        AudioDeviceDestroyIOProcID(deviceID, ioProc), "Destroy \(label) callback")
    }

    let restart: (Bool) -> Void = { [weak self] formatOnly in
      self?.queue.async { [weak self] in
        guard let self, self.running, self.generation == currentGeneration else { return }
        if formatOnly, let current = try? self.inputFormat(deviceID), current == format { return }
        self.scheduleRestart(receive: receive, onFailure: onFailure)
      }
    }
    try listen(object: tapID, selector: kAudioTapPropertyFormat) { _, _ in restart(true) }
    try listen(
      object: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDefaultOutputDevice
    ) { _, _ in restart(false) }
    try listen(
      object: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDefaultInputDevice
    ) { _, _ in restart(false) }
    var devices = Set(processes.flatMap(\.outputDevices))
    let output = try AudioHardwareInfo.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let input = try AudioHardwareInfo.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    AppLog.event("capture.routes", "defaultInput=\(input); defaultOutput=\(output)")
    devices.insert(output)
    devices.insert(input)
    devices.remove(AudioObjectID(kAudioObjectUnknown))
    for device in devices.sorted() {
      AudioHardwareInfo.logDevice(device)
      try listen(object: device, selector: kAudioDevicePropertyNominalSampleRate) { _, _ in
        restart(false)
      }
    }
    try CoreAudioFailure.check(AudioDeviceStart(deviceID, ioProc), "Start \(label)")
    switch scope {
    case .teams, .app:
      tappedProcesses = description.processes
      let targets = processes.filter { tappedProcesses.contains($0.id) }
        .map { "\($0.bundleID)[\($0.pid)]" }
      let summary = targets.isEmpty ? description.bundleIDs : targets
      AppLog.event(
        "capture.systemTargets", "\(scope.rawValue); \(summary.joined(separator: ","))")
    case .deviceAudio:
      tappedProcesses = []
      AppLog.event(
        "capture.systemTargets",
        "device-audio; all processes except Meeting Notes (process object \(ownProcess.map(String.init) ?? "unknown"))"
      )
    }
    resources.add {
      try CoreAudioFailure.check(AudioDeviceStop(deviceID, ioProc), "Stop \(label)")
    }
  }

  private func waitForInputFormat(_ deviceID: AudioObjectID) throws -> AVAudioFormat {
    // Being alive does not guarantee that an aggregate has published its input stream yet.
    for _ in 0..<30 {
      if let format = try inputFormat(deviceID) { return format }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw MeetingError("The \(label) device did not publish a usable input stream.")
  }

  private func inputFormat(_ deviceID: AudioObjectID) throws -> AVAudioFormat? {
    var alive: UInt32 = 0
    try AudioHardwareInfo.read(deviceID, kAudioDevicePropertyDeviceIsAlive, into: &alive)
    guard alive != 0 else { return nil }
    let streams = try AudioHardwareInfo.objects(
      deviceID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    guard let stream = streams.first else { return nil }
    guard streams.count == 1 else {
      throw MeetingError("The \(label) device has an unexpected input layout.")
    }
    var description = AudioStreamBasicDescription()
    try AudioHardwareInfo.read(stream, kAudioStreamPropertyVirtualFormat, into: &description)
    guard description.mSampleRate > 0, description.mChannelsPerFrame > 0 else { return nil }
    return AVAudioFormat(streamDescription: &description)
  }

  private func checkHealth(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler
  ) {
    guard running, pendingRestart == nil else { return }
    do {
      let processes = try processes()
      let needsRestart = Self.needsRestart(
        scope: scope, tappedProcesses: tappedProcesses, previous: lastProcesses,
        current: processes)
      if scope.bundleIDs != nil, processes != lastProcesses {
        AppLog.event(
          "capture.appProcesses",
          "\(scope.rawValue); \(processes.map(\.summary).joined(separator: " | "))")
      }
      lastProcesses = processes
      if needsRestart {
        scheduleRestart(receive: receive, onFailure: onFailure)
        return
      }
      switch health.check(
        outputActive: processes.contains(where: \.outputActive),
        at: ProcessInfo.processInfo.systemUptime)
      {
      case .wait: break
      case .restart:
        AppLog.event("capture.systemNoBuffers", "\(scope.rawValue); restart=\(health.restarts)")
        scheduleRestart(receive: receive, onFailure: onFailure)
      case .fail:
        let playing =
          switch scope {
          case .teams: "Teams has active audio output"
          case .app(let bundleID):
            "\(bundleID) has active audio output"
          case .deviceAudio: "Audio is playing"
          }
        fail(
          MeetingError(
            "\(playing), but no \(label) buffers are arriving. Recording stopped; captured audio is available through Retry Transcription. Check System Audio Recording access and your audio devices before trying again."
          ), onFailure: onFailure)
      }
    } catch { AppLog.event("capture.systemStatusFailed", error.localizedDescription) }
  }

  private func scheduleRestart(
    receive: AudioCaptureHandler?, onFailure: @escaping AudioCaptureFailureHandler,
    attempt: Int = 0
  ) {
    guard running, pendingRestart == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.running, self.pendingRestart != nil else { return }
      self.pendingRestart = nil
      do {
        AppLog.event("capture.systemRestart", "\(self.scope.rawValue); attempt=\(attempt + 1)")
        try self.configure(receive: receive, onFailure: onFailure)
      } catch {
        try? self.resources.release()
        if PermissionAccess.deniedPermission(for: error) == nil, attempt < 2 {
          self.scheduleRestart(receive: receive, onFailure: onFailure, attempt: attempt + 1)
        } else {
          self.fail(error, onFailure: onFailure)
        }
      }
    }
    pendingRestart = work
    queue.asyncAfter(deadline: .now() + 0.25 * Double(attempt + 1), execute: work)
  }

  private func fail(_ error: Error, onFailure: AudioCaptureFailureHandler) {
    guard running else { return }
    running = false
    watchdog?.cancel()
    watchdog = nil
    pendingRestart?.cancel()
    pendingRestart = nil
    AppLog.event("capture.systemFailed", error.localizedDescription)
    onFailure(error)
  }

  private func listen(
    object: AudioObjectID, selector: AudioObjectPropertySelector,
    changed: @escaping AudioObjectPropertyListenerBlock
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    try CoreAudioFailure.check(
      AudioObjectAddPropertyListenerBlock(object, &address, queue, changed), "Watch audio device")
    let listenerQueue = queue
    resources.add {
      var address = AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      try CoreAudioFailure.check(
        AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, changed),
        "Remove audio device listener")
    }
  }

  func stop() throws {
    try queue.sync {
      running = false
      watchdog?.cancel()
      watchdog = nil
      pendingRestart?.cancel()
      pendingRestart = nil
      generation = UUID()
      try resources.release()
    }
  }
}
