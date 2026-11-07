import Foundation
import whisper

/// whisper large-v3-turbo through whisper.cpp, running on the GPU with Metal.
final class WhisperRecognizer {
  /// Audio frames the language detector encodes: the first 10.24 seconds instead of 30, which
  /// makes detection about three times cheaper than a full window.
  static let detectionAudioContext: Int32 = 512

  private let context: OpaquePointer
  /// A separate decoder state for language detection. whisper.cpp detects with the audio context
  /// of the state's previous full run, so this state is primed once with the short context and
  /// then only ever detects.
  private let detection: OpaquePointer

  init(model: URL) throws {
    Whisper.silenceLogs()
    var parameters = whisper_context_default_params()
    parameters.use_gpu = true
    parameters.flash_attn = true
    guard let context = whisper_init_from_file_with_params(model.path, parameters) else {
      throw TranscriptionFailure(message: "The transcription model could not be loaded.")
    }
    guard let detection = whisper_init_state(context) else {
      whisper_free(context)
      throw TranscriptionFailure(message: "The transcription model could not be loaded.")
    }
    self.context = context
    self.detection = detection
    var priming = Self.parameters()
    priming.audio_ctx = Self.detectionAudioContext
    priming.no_timestamps = true
    priming.single_segment = true
    priming.token_timestamps = false
    let silence = [Float](repeating: 0, count: 16_000)
    let status = "en".withCString { language in
      priming.language = language
      return whisper_full_with_state(context, detection, priming, silence, Int32(silence.count))
    }
    guard status == 0 else {
      whisper_free_state(detection)
      whisper_free(context)
      throw TranscriptionFailure(message: "Local transcription failed (whisper \(status)).")
    }
  }

  deinit {
    whisper_free_state(detection)
    whisper_free(context)
  }

  /// The language spoken at the start of 16 kHz mono samples, such as "de", or nil when whisper
  /// is unsure.
  func language(of samples: [Float]) -> String? {
    let threads = Self.parameters().n_threads
    guard
      samples.withUnsafeBufferPointer({
        whisper_pcm_to_mel_with_state(
          context, detection, $0.baseAddress, Int32($0.count), threads)
      }) == 0
    else { return nil }
    var probabilities = [Float](repeating: 0, count: Int(whisper_lang_max_id()) + 1)
    let id = whisper_lang_auto_detect_with_state(context, detection, 0, threads, &probabilities)
    guard id >= 0, probabilities[Int(id)] >= 0.5, let code = whisper_lang_str(id) else {
      return nil
    }
    return String(cString: code)
  }

  private static func parameters() -> whisper_full_params {
    var parameters = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
    parameters.n_threads = Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
    parameters.no_context = true
    parameters.n_max_text_ctx = 0
    parameters.token_timestamps = true
    parameters.print_progress = false
    parameters.print_realtime = false
    parameters.print_timestamps = false
    parameters.print_special = false
    parameters.beam_search.beam_size = 5
    parameters.greedy.best_of = 5
    return parameters
  }

  /// Transcribes 16 kHz mono samples in `language`, or the language whisper detects when nil,
  /// and returns the words with times relative to the samples. No text carries over between
  /// calls or between the 30-second windows of one call, so a misheard passage cannot repeat
  /// itself.
  func words(in samples: [Float], language: String?) throws -> [SpeechPlan.Word] {
    var parameters = Self.parameters()
    let status = (language ?? "auto").withCString { language in
      parameters.language = language
      return samples.withUnsafeBufferPointer {
        whisper_full(context, parameters, $0.baseAddress, Int32($0.count))
      }
    }
    guard status == 0 else {
      throw TranscriptionFailure(message: "Local transcription failed (whisper \(status)).")
    }
    let endOfText = whisper_token_eot(context)
    var words: [SpeechPlan.Word] = []
    var bytes: [UInt8] = []
    var start = 0.0
    var end = 0.0
    func finishWord() {
      if !bytes.isEmpty {
        words.append(.init(start: start, end: end, text: String(decoding: bytes, as: UTF8.self)))
      }
      bytes = []
    }
    for segment in 0..<whisper_full_n_segments(context) {
      for index in 0..<whisper_full_n_tokens(context, segment) {
        let token = whisper_full_get_token_data(context, segment, index)
        guard token.id < endOfText, let text = whisper_full_get_token_text(context, segment, index)
        else { continue }
        let tokenBytes = Array(UnsafeBufferPointer(start: text, count: strlen(text))).map {
          UInt8(bitPattern: $0)
        }
        guard !tokenBytes.isEmpty else { continue }
        let tokenStart = Double(max(0, token.t0)) / 100
        let tokenEnd = max(tokenStart, Double(token.t1) / 100)
        if tokenBytes.first == UInt8(ascii: " ") || bytes.isEmpty {
          finishWord()
          start = tokenStart
        }
        bytes += tokenBytes
        end = tokenEnd
      }
      finishWord()
    }
    return words
  }
}

/// Silero voice activity detection through whisper.cpp.
final class VoiceActivityDetector {
  private let context: OpaquePointer

  init(model: URL) throws {
    Whisper.silenceLogs()
    var parameters = whisper_vad_default_context_params()
    parameters.n_threads = 4
    parameters.use_gpu = false
    guard let context = whisper_vad_init_from_file_with_params(model.path, parameters) else {
      throw TranscriptionFailure(message: "The speech detection model could not be loaded.")
    }
    self.context = context
  }

  deinit { whisper_vad_free(context) }

  /// The speech regions of 16 kHz mono samples, in seconds.
  func regions(in samples: [Float]) throws -> [SpeechPlan.Region] {
    guard !samples.isEmpty else { return [] }
    let parameters = whisper_vad_default_params()
    guard
      let segments = samples.withUnsafeBufferPointer({
        whisper_vad_segments_from_samples(context, parameters, $0.baseAddress, Int32($0.count))
      })
    else { throw TranscriptionFailure(message: "Speech detection failed.") }
    defer { whisper_vad_free_segments(segments) }
    return (0..<whisper_vad_segments_n_segments(segments)).map {
      SpeechPlan.Region(
        start: Double(whisper_vad_segments_get_segment_t0(segments, $0)) / 100,
        end: Double(whisper_vad_segments_get_segment_t1(segments, $0)) / 100)
    }
  }
}

enum Whisper {
  static func silenceLogs() {
    whisper_log_set({ _, _, _ in }, nil)
  }
}
