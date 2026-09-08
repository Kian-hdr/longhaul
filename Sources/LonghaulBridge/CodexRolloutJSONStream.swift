import Foundation

/// JSONL syntax recognizer with bounded structural state. Payload strings are
/// validated byte by byte and discarded; only selected metadata strings survive.
/// Duplicate selected keys are rejected after escape decoding, independently of
/// key order. Unknown duplicate keys have no semantic effect on the projection.
struct CodexRolloutJSONStream: Sendable {
    enum Invalid: Error { case syntax, depth }
    enum Field: Hashable, Sendable {
        case type, timestamp, payload, id, cliVersion, originator, source, eventType, turnID
    }
    enum Value: Sendable { case string(String), object, other }
    struct Record: Sendable {
        var values: [Field: Value] = [:]
        func string(_ key: Field) -> String? {
            if case .string(let value) = values[key] { return value }; return nil
        }
    }
    private enum Scope: Sendable { case root, payload, ignored }
    private enum Position: Sendable {
        case firstKey, key, colon, value, firstValue, comma
    }
    private struct Frame: Sendable {
        let object: Bool
        let scope: Scope
        var position: Position
        var key: String?
        var selected: Set<Field> = []
    }
    private enum StringMode: Sendable {
        case normal, escape, unicode(UInt32, Int), surrogateSlash, surrogateU
    }
    private struct StringToken: Sendable {
        let key: Bool
        let field: Field?
        let capture: Bool
        var bytes: [UInt8] = []
        var overflow = false
        var mode = StringMode.normal
        var highSurrogate: UInt32?
        var continuation = 0
        var nextMinimum: UInt8 = 0x80
        var nextMaximum: UInt8 = 0xbf
    }
    private enum NumberState: Sendable { case minus, zero, integer, dot, fraction, e, sign, exponent }
    private enum Token: Sendable {
        case string(StringToken), number(NumberState), literal([UInt8], Int)
    }
    private static let metadataKeys = ["type", "timestamp", "payload", "id", "cli_version", "originator", "source", "turn_id"].map { Array($0.utf8) }
    private let maximumMetadataBytes: Int
    private var stack: [Frame] = []
    private var token: Token?
    private var began = false
    private var done = false
    private var record = Record()
    private(set) var hasPartialRecord = false

    init(maximumMetadataBytes: Int) { self.maximumMetadataBytes = min(maximumMetadataBytes, 4096) }
    /// Inspectable bound for regression tests, excluding fixed-size grammar state.
    var retainedMetadataBytes: Int {
        var total = record.values.values.reduce(0) { result, value in
            if case .string(let text) = value { return result + text.utf8.count }; return result
        }
        total += stack.reduce(0) { $0 + ($1.key?.utf8.count ?? 0) }
        if case .string(let text) = token { total += text.bytes.count }
        return total
    }

    mutating func feed(_ byte: UInt8) throws -> Record? {
        if case .string(var text) = token {
            if try stringByte(byte, token: &text) {
                token = nil
                let value = text.overflow ? nil : String(bytes: text.bytes, encoding: .utf8)
                if text.key {
                    guard !stack.isEmpty else { throw Invalid.syntax }
                    let index = stack.count - 1
                    stack[index].key = value
                    if let field = selectedField(scope: stack[index].scope, key: value) {
                        guard stack[index].selected.insert(field).inserted else { throw Invalid.syntax }
                    }
                    stack[index].position = .colon
                } else if let field = text.field {
                    record.values[field] = value.map(Value.string) ?? .other
                }
            } else { token = .string(text) }
            return nil
        }
        if case .literal(let expected, let index) = token {
            guard byte == expected[index] else { throw Invalid.syntax }
            token = index + 1 == expected.count ? nil : .literal(expected, index + 1)
            return nil
        }
        if case .number(let state) = token {
            if let next = try numberByte(byte, state: state) { token = .number(next); return nil }
            token = nil // The delimiter is still processed below.
        }
        if byte == 10 {
            guard began, done, stack.isEmpty, token == nil else { throw Invalid.syntax }
            let result = record
            record = Record(); began = false; done = false; hasPartialRecord = false
            return result
        }
        hasPartialRecord = true
        if byte == 32 || byte == 9 || byte == 13 { return nil }
        guard !done else { throw Invalid.syntax }
        if !began {
            guard byte == 123 else { throw Invalid.syntax }
            began = true
            stack.append(Frame(object: true, scope: .root, position: .firstKey))
            return nil
        }
        guard !stack.isEmpty else { throw Invalid.syntax }
        let index = stack.count - 1
        switch stack[index].position {
        case .firstKey, .key:
            if byte == 125 && stack[index].position == .firstKey { close(); return nil }
            guard byte == 34 else { throw Invalid.syntax }
            token = .string(StringToken(key: true, field: nil, capture: stack[index].scope != .ignored))
        case .colon:
            guard byte == 58 else { throw Invalid.syntax }
            stack[index].position = .value
        case .comma:
            if byte == (stack[index].object ? 125 : 93) { close(); return nil }
            guard byte == 44 else { throw Invalid.syntax }
            stack[index].position = stack[index].object ? .key : .value
        case .firstValue, .value:
            if byte == 93 && !stack[index].object && stack[index].position == .firstValue { close(); return nil }
            let field = stack[index].object ? selectedField(scope: stack[index].scope, key: stack[index].key) : nil
            let childScope: Scope = field == .payload && byte == 123 ? .payload : .ignored
            if let field { record.values[field] = .other }
            stack[index].position = .comma
            stack[index].key = nil
            switch byte {
            case 123, 91:
                guard stack.count < 128 else { throw Invalid.depth }
                stack.append(Frame(object: byte == 123, scope: childScope, position: byte == 123 ? .firstKey : .firstValue))
                // A payload object is distinguished from invalid payload shapes.
                if field == .payload && byte == 123 { record.values[.payload] = .object }
            case 34:
                let metadataField = field == .payload ? nil : field
                token = .string(StringToken(key: false, field: metadataField, capture: metadataField != nil))
            case 116: token = .literal(Array("true".utf8), 1)
            case 102: token = .literal(Array("false".utf8), 1)
            case 110: token = .literal(Array("null".utf8), 1)
            case 45: token = .number(.minus)
            case 48: token = .number(.zero)
            case 49...57: token = .number(.integer)
            default: throw Invalid.syntax
            }
        }
        return nil
    }

    private mutating func close() {
        stack.removeLast()
        if stack.isEmpty { done = true }
    }
    private func selectedField(scope: Scope, key: String?) -> Field? {
        switch (scope, key) {
        case (.root, "type"): .type
        case (.root, "timestamp"): .timestamp
        case (.root, "payload"): .payload
        case (.payload, "id"): .id
        case (.payload, "cli_version"): .cliVersion
        case (.payload, "originator"): .originator
        case (.payload, "source"): .source
        case (.payload, "type"): .eventType
        case (.payload, "turn_id"): .turnID
        default: nil
        }
    }
    private func numberByte(_ byte: UInt8, state: NumberState) throws -> NumberState? {
        switch (state, byte) {
        case (.minus, 48): return .zero
        case (.minus, 49...57): return .integer
        case (.integer, 48...57): return .integer
        case (.zero, 46), (.integer, 46): return .dot
        case (.dot, 48...57), (.fraction, 48...57): return .fraction
        case (.zero, 101), (.zero, 69), (.integer, 101), (.integer, 69), (.fraction, 101), (.fraction, 69): return .e
        case (.e, 43), (.e, 45): return .sign
        case (.e, 48...57), (.sign, 48...57), (.exponent, 48...57): return .exponent
        default:
            guard [.zero, .integer, .fraction, .exponent].contains(state),
                  [UInt8(32), 9, 10, 13, 44, 93, 125].contains(byte) else { throw Invalid.syntax }
            return nil
        }
    }
    private func stringByte(_ byte: UInt8, token text: inout StringToken) throws -> Bool {
        func append(_ bytes: [UInt8], to text: inout StringToken) {
            guard text.capture, !text.overflow else { return }
            let limit = text.key ? 64 : maximumMetadataBytes
            guard text.bytes.count + bytes.count <= limit else {
                text.bytes.removeAll(keepingCapacity: false); text.overflow = true; return
            }
            text.bytes.append(contentsOf: bytes)
            if text.key && !Self.metadataKeys.contains(where: { $0.starts(with: text.bytes) }) {
                text.bytes.removeAll(keepingCapacity: false); text.overflow = true
            }
        }
        switch text.mode {
        case .surrogateSlash:
            guard byte == 92 else { throw Invalid.syntax }; text.mode = .surrogateU
        case .surrogateU:
            guard byte == 117 else { throw Invalid.syntax }; text.mode = .unicode(0, 0)
        case .unicode(let partial, let digits):
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 65 + 10)
            case 97...102: digit = UInt32(byte - 97 + 10)
            default: throw Invalid.syntax
            }
            let value = partial * 16 + digit
            if digits < 3 { text.mode = .unicode(value, digits + 1); return false }
            if let high = text.highSurrogate {
                guard (0xdc00...0xdfff).contains(value) else { throw Invalid.syntax }
                let scalar = 0x10000 + (high - 0xd800) * 0x400 + value - 0xdc00
                append(Array(String(UnicodeScalar(scalar)!).utf8), to: &text)
                text.highSurrogate = nil; text.mode = .normal
            } else if (0xd800...0xdbff).contains(value) {
                text.highSurrogate = value; text.mode = .surrogateSlash
            } else {
                guard !(0xdc00...0xdfff).contains(value), let scalar = UnicodeScalar(value) else { throw Invalid.syntax }
                append(Array(String(scalar).utf8), to: &text); text.mode = .normal
            }
        case .escape:
            let decoded: UInt8
            switch byte {
            case 34, 47, 92: decoded = byte
            case 98: decoded = 8
            case 102: decoded = 12
            case 110: decoded = 10
            case 114: decoded = 13
            case 116: decoded = 9
            case 117: text.mode = .unicode(0, 0); return false
            default: throw Invalid.syntax
            }
            append([decoded], to: &text); text.mode = .normal
        case .normal:
            if text.continuation > 0 {
                guard byte >= text.nextMinimum, byte <= text.nextMaximum else { throw Invalid.syntax }
                text.continuation -= 1; text.nextMinimum = 0x80; text.nextMaximum = 0xbf
                append([byte], to: &text); return false
            }
            switch byte {
            case 34: return true
            case 92: text.mode = .escape
            case 0...31: throw Invalid.syntax
            case 32...127: append([byte], to: &text)
            case 0xc2...0xdf: text.continuation = 1; append([byte], to: &text)
            case 0xe0...0xef:
                text.continuation = 2
                text.nextMinimum = byte == 0xe0 ? 0xa0 : 0x80
                text.nextMaximum = byte == 0xed ? 0x9f : 0xbf
                append([byte], to: &text)
            case 0xf0...0xf4:
                text.continuation = 3
                text.nextMinimum = byte == 0xf0 ? 0x90 : 0x80
                text.nextMaximum = byte == 0xf4 ? 0x8f : 0xbf
                append([byte], to: &text)
            default: throw Invalid.syntax
            }
        }
        return false
    }
}
