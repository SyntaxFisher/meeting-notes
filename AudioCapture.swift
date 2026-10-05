import AVFoundation
import CoreAudio

enum CaptureSource: String {
  case system, microphone
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

final class TeamsAudioCapture: AudioCaptureInput, @unchecked Sendable {
  static let bundleID = "com.microsoft.teams2"
  let source = CaptureSource.system
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.teams-audio")
  private let resources = AudioCaptureResources()
  private var generation = UUID()
  private var running = false
  private var watchdog: DispatchSourceTimer?
  private var pendingRestart: DispatchWorkItem?
  private var health = TeamsCaptureHealth()
  private var lastProcesses: [AudioProcessStatus]?
  private var bufferRecoveryAttempts = 0

  static func tapDescription() -> CATapDescription {
    let description = CATapDescription()
    description.uuid = UUID()
    description.name = "Meeting Notes Teams audio"
    description.bundleIDs = [bundleID]
    description.isExclusive = false
    description.isMixdown = true
    description.isMono = true
    description.isPrivate = true
    description.isProcessRestoreEnabled = true
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

  static func requestAccess() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let capture = TeamsAudioCapture()
        do {
          try capture.queue.sync {
            try capture.configure(receive: nil, onFailure: { _ in })
          }
          try capture.stop()
          continuation.resume()
        } catch {
          try? capture.stop()
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func configure(
    receive: AudioCaptureHandler?, onFailure: @escaping AudioCaptureFailureHandler
  ) throws {
    generation = UUID()
    let currentGeneration = generation
    try resources.release()
    let description = Self.tapDescription()
    var tap = AudioObjectID(kAudioObjectUnknown)
    try CoreAudioFailure.check(AudioHardwareCreateProcessTap(description, &tap), "Create Teams tap")
    let tapID = tap
    resources.add {
      try CoreAudioFailure.check(AudioHardwareDestroyProcessTap(tapID), "Destroy Teams tap")
    }

    let tapUID = try AudioHardwareInfo.string(tapID, kAudioTapPropertyUID)
    guard !tapUID.isEmpty else { throw MeetingError("The Teams audio tap has no identifier.") }

    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Meeting Notes Teams audio",
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
      "Create Teams audio device")
    let deviceID = aggregate
    resources.add {
      try CoreAudioFailure.check(
        AudioHardwareDestroyAggregateDevice(deviceID), "Destroy Teams audio device")
    }
    let format = try waitForInputFormat(deviceID)
    AppLog.event(
      "capture.teamsFormat", "rate=\(format.sampleRate); channels=\(format.channelCount)")
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
            throw MeetingError("Teams audio has no host timestamp.")
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
            AppLog.event("capture.teamsBufferFailed", error.localizedDescription)
            if self.bufferRecoveryAttempts < 2 {
              self.bufferRecoveryAttempts += 1
              self.scheduleRestart(receive: receive, onFailure: onFailure)
            } else {
              self.fail(error, onFailure: onFailure)
            }
          }
        }
      }, "Create Teams audio callback")
    guard let ioProc else { throw MeetingError("Core Audio did not create an audio callback.") }
    resources.add {
      try CoreAudioFailure.check(
        AudioDeviceDestroyIOProcID(deviceID, ioProc), "Destroy Teams audio callback")
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
    let processes = try AudioHardwareInfo.teamsProcesses()
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
    try CoreAudioFailure.check(AudioDeviceStart(deviceID, ioProc), "Start Teams audio")
    resources.add {
      try CoreAudioFailure.check(AudioDeviceStop(deviceID, ioProc), "Stop Teams audio")
    }
  }

  private func waitForInputFormat(_ deviceID: AudioObjectID) throws -> AVAudioFormat {
    // Being alive does not guarantee that an aggregate has published its input stream yet.
    for _ in 0..<30 {
      if let format = try inputFormat(deviceID) { return format }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw MeetingError("The Teams audio device did not publish a usable input stream.")
  }

  private func inputFormat(_ deviceID: AudioObjectID) throws -> AVAudioFormat? {
    var alive: UInt32 = 0
    try AudioHardwareInfo.read(deviceID, kAudioDevicePropertyDeviceIsAlive, into: &alive)
    guard alive != 0 else { return nil }
    let streams = try AudioHardwareInfo.objects(
      deviceID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    guard let stream = streams.first else { return nil }
    guard streams.count == 1 else {
      throw MeetingError("The Teams audio device has an unexpected input layout.")
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
      let processes = try AudioHardwareInfo.teamsProcesses()
      if processes != lastProcesses {
        AppLog.event("capture.teamsProcesses", processes.map(\.summary).joined(separator: " | "))
        let oldDevices = Set((lastProcesses ?? []).flatMap(\.outputDevices))
        let newDevices = Set(processes.flatMap(\.outputDevices))
        let routeChanged = lastProcesses != nil && !newDevices.isEmpty && newDevices != oldDevices
        lastProcesses = processes
        if routeChanged {
          scheduleRestart(receive: receive, onFailure: onFailure)
          return
        }
      }
      switch health.check(
        outputActive: processes.contains(where: \.outputActive),
        at: ProcessInfo.processInfo.systemUptime)
      {
      case .wait: break
      case .restart:
        AppLog.event("capture.teamsNoBuffers", "restart=\(health.restarts)")
        scheduleRestart(receive: receive, onFailure: onFailure)
      case .fail:
        fail(
          MeetingError(
            "Teams has active audio output, but no Teams audio buffers are arriving. Recording stopped; captured audio is available through Retry Transcription. Check System Audio Recording access and your audio devices before trying again."
          ), onFailure: onFailure)
      }
    } catch { AppLog.event("capture.teamsStatusFailed", error.localizedDescription) }
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
        AppLog.event("capture.teamsRestart", "attempt=\(attempt + 1)")
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
    AppLog.event("capture.teamsFailed", error.localizedDescription)
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
