import CoreAudio
import Foundation

struct TeamsCaptureHealth {
  enum Action { case wait, restart, fail }
  private var waitingSince: TimeInterval?
  private(set) var restarts = 0

  mutating func receivedBuffer() {
    waitingSince = nil
    restarts = 0
  }

  mutating func check(outputActive: Bool, at time: TimeInterval) -> Action {
    guard outputActive else {
      waitingSince = nil
      restarts = 0
      return .wait
    }
    guard let waitingSince else {
      self.waitingSince = time
      return .wait
    }
    guard time - waitingSince >= 5 else { return .wait }
    self.waitingSince = time
    guard restarts < 2 else { return .fail }
    restarts += 1
    return .restart
  }
}

struct CaptureSignalStatistics {
  private(set) var buffers = 0
  private(set) var frames: Int64 = 0
  private(set) var mutedFrames: Int64 = 0
  private(set) var inputPeak: Float = 0
  private(set) var recordedPeak: Float = 0

  mutating func received(frames: Int64, peak: Float, muted: Bool) {
    buffers += 1
    self.frames += frames
    inputPeak = max(inputPeak, peak)
    if muted {
      mutedFrames += frames
    } else {
      recordedPeak = max(recordedPeak, peak)
    }
  }

  var summary: String {
    "buffers=\(buffers); frames=\(frames); mutedFrames=\(mutedFrames); inputPeak=\(inputPeak); recordedPeak=\(recordedPeak)"
  }
}

struct AudioProcessStatus: Equatable {
  let id: AudioObjectID
  let pid: Int32
  let bundleID: String
  let outputActive: Bool
  let outputDevices: [AudioObjectID]

  var summary: String {
    "pid=\(pid); bundle=\(bundleID); outputActive=\(outputActive); devices=\(outputDevices)"
  }
}

enum AudioHardwareInfo {
  static func read<T>(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T
  ) throws {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &value) {
      try CoreAudioFailure.check(
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0),
        "Read audio property \(selector)")
    }
  }

  static func objects(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try CoreAudioFailure.check(
      AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Read audio property size")
    guard size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try objects.withUnsafeMutableBytes {
      try CoreAudioFailure.check(
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!),
        "Read audio objects")
    }
    return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  }

  static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws
    -> String
  {
    var value: Unmanaged<CFString>?
    try read(object, selector, into: &value)
    return value?.takeRetainedValue() as String? ?? ""
  }

  static func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
    var device = AudioObjectID(kAudioObjectUnknown)
    try read(AudioObjectID(kAudioObjectSystemObject), selector, into: &device)
    return device
  }

  static func teamsProcesses() throws -> [AudioProcessStatus] {
    let objects = try objects(
      AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    return objects.compactMap { object in
      // A process can exit between enumeration and reading its properties.
      guard let bundle = try? string(object, kAudioProcessPropertyBundleID),
        bundle == TeamsAudioCapture.bundleID || bundle.hasPrefix(TeamsAudioCapture.bundleID + ".")
      else { return nil }
      var pid: Int32 = 0
      var active: UInt32 = 0
      do {
        try read(object, kAudioProcessPropertyPID, into: &pid)
        try read(object, kAudioProcessPropertyIsRunningOutput, into: &active)
        let devices = try self.objects(
          object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        return AudioProcessStatus(
          id: object, pid: pid, bundleID: bundle, outputActive: active != 0,
          outputDevices: devices)
      } catch { return nil }
    }.sorted { $0.pid < $1.pid }
  }

  static func logDevice(_ id: AudioObjectID) {
    do {
      let name = try string(id, kAudioObjectPropertyName)
      var rate: Float64 = 0
      var transport: UInt32 = 0
      try read(id, kAudioDevicePropertyNominalSampleRate, into: &rate)
      try read(id, kAudioDevicePropertyTransportType, into: &transport)
      AppLog.event("capture.device", "id=\(id); name=\(name); rate=\(rate); transport=\(transport)")
    } catch { AppLog.event("capture.deviceReadFailed", error.localizedDescription) }
  }
}
