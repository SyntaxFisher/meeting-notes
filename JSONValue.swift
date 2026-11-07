import Foundation

/// A dynamically typed JSON value for protocols whose payloads are not known at compile time.
enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      if value.rounded() == value, abs(value) < 1e15 {
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var doubleValue: Double? {
    switch self {
    case .number(let value): return value
    case .string(let value): return Double(value)
    default: return nil
    }
  }

  var intValue: Int? {
    guard let value = doubleValue, value.isFinite, value.rounded(.towardZero) == value,
      value >= Double(Int.min), value < Double(Int.max)
    else { return nil }
    return Int(value)
  }

  var boolValue: Bool? {
    switch self {
    case .bool(let value): return value
    case .string(let value): return ["true", "yes", "1", "on"].contains(value.lowercased())
    default: return nil
    }
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var isNull: Bool { self == .null }

  /// Converts any `Encodable` value through `JSONCoding` so dates and keys match the file format.
  static func from<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONCoding.encoder().encode(value))
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONCoding.decoder().decode(type, from: JSONEncoder().encode(self))
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral
{
  init(stringLiteral value: String) { self = .string(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
  init(integerLiteral value: Int) { self = .number(Double(value)) }
  init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements) { _, last in last })
  }
  init(nilLiteral: ()) { self = .null }
}

/// Shared encoders so every machine-readable surface (sidecars, socket, CLI, MCP) formats dates
/// as ISO 8601 with the local offset and orders keys stably.
enum JSONCoding {
  static func encoder(pretty: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      pretty
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(formatDate(date))
    }
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = parseDate(text) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Expected an ISO 8601 date, got \(text)")
      }
      return date
    }
    return decoder
  }

  static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = timeZone
    return formatter.string(from: date)
  }

  /// Accepts full ISO 8601 timestamps (with or without fractional seconds) and plain
  /// `yyyy-MM-dd` dates, which are read as local midnight.
  static func parseDate(_ text: String, timeZone: TimeZone = .current) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    for options: ISO8601DateFormatter.Options in [
      [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
      [.withFullDate],
    ] {
      formatter.formatOptions = options
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }
}
