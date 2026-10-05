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

final class MicrophoneCapture: AudioCaptureInput, @unchecked Sendable {
  let source = CaptureSource.microphone
  private let queue = DispatchQueue(label: "com.jona.meeting-notes.microphone")
  private var engine: AVAudioEngine?
  private var observer: NSObjectProtocol?
  private var tapInstalled = false

  func start(
    receive: @escaping AudioCaptureHandler, onFailure: @escaping AudioCaptureFailureHandler
  )
    throws
  {
    try queue.sync {
      let engine = AVAudioEngine()
      self.engine = engine
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self, weak engine] _ in
        guard let self, let engine else { return }
        self.queue.async {
          guard self.engine === engine else { return }
          do {
            try self.configure(engine, receive: receive, onFailure: onFailure)
          } catch {
            onFailure(error)
          }
        }
      }
      try configure(engine, receive: receive, onFailure: onFailure)
    }
  }

  private func configure(
    _ engine: AVAudioEngine, receive: @escaping AudioCaptureHandler,
    onFailure: @escaping AudioCaptureFailureHandler
  ) throws {
    engine.stop()
    if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
    tapInstalled = false
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw MeetingError("No microphone input is available.")
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
  }

  func stop() throws {
    queue.sync {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      engine?.stop()
      if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
      tapInstalled = false
      engine = nil
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

    let format = try readFormat(tapID)

    let aggregateDescription: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Meeting Notes Teams audio",
      kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapUIDKey: description.uuid.uuidString,
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
    try waitUntilAlive(deviceID)
    var ioProc: AudioDeviceIOProcID?
    try CoreAudioFailure.check(
      AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, nil) { _, data, time, _, _ in
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
          receive(owned, time.pointee.mHostTime)
        } catch { onFailure(error) }
      }, "Create Teams audio callback")
    guard let ioProc else { throw MeetingError("Core Audio did not create an audio callback.") }
    resources.add {
      try CoreAudioFailure.check(
        AudioDeviceDestroyIOProcID(deviceID, ioProc), "Destroy Teams audio callback")
    }

    let restart: (Bool) -> Void = { [weak self] formatOnly in
      self?.queue.async { [weak self] in
        guard let self, self.running, self.generation == currentGeneration else { return }
        do {
          if formatOnly, try self.readFormat(tapID) == format { return }
          try self.configure(receive: receive, onFailure: onFailure)
        } catch { onFailure(error) }
      }
    }
    try listen(object: tapID, selector: kAudioTapPropertyFormat) { _, _ in restart(true) }
    try listen(
      object: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDefaultOutputDevice
    ) { _, _ in restart(false) }
    try CoreAudioFailure.check(AudioDeviceStart(deviceID, ioProc), "Start Teams audio")
    resources.add {
      try CoreAudioFailure.check(AudioDeviceStop(deviceID, ioProc), "Stop Teams audio")
    }
  }

  private func readFormat(_ tapID: AudioObjectID) throws -> AVAudioFormat {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var streamFormat = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try CoreAudioFailure.check(
      AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamFormat), "Read Teams format"
    )
    guard let format = AVAudioFormat(streamDescription: &streamFormat),
      format.sampleRate > 0, format.channelCount > 0
    else { throw MeetingError("Teams audio has an unsupported format.") }
    return format
  }

  private func waitUntilAlive(_ deviceID: AudioObjectID) throws {
    // Aggregate devices can be published before their input streams are ready.
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    for _ in 0..<30 {
      var alive: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      try CoreAudioFailure.check(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive),
        "Read Teams audio device readiness")
      if alive != 0 { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw MeetingError("The Teams audio device did not become ready.")
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
      generation = UUID()
      try resources.release()
    }
  }
}
