import CryptoKit
import Foundation

/// MCUmgr Simple Management Protocol, the Bluetooth DFU transport used by nRF54
/// and the rest of the nRF Connect SDK. Version 1 puts error codes in the CBOR map.
enum SMPProtocol {
    static let version: UInt8 = 1
    static let headerLength = 8

    enum Operation {
        static let read: UInt8 = 0
        static let readResponse: UInt8 = 1
        static let write: UInt8 = 2
        static let writeResponse: UInt8 = 3
    }

    enum Group {
        static let operatingSystem: UInt16 = 0
        static let image: UInt16 = 1
    }

    enum Command {
        static let imageState: UInt8 = 0
        static let imageUpload: UInt8 = 1
        static let reset: UInt8 = 5
        static let parameters: UInt8 = 6
    }

    struct Frame {
        var operation: UInt8
        var group: UInt16
        var sequence: UInt8
        var command: UInt8
        var payload: Data

        func encoded() -> Data {
            var frame = Data(count: SMPProtocol.headerLength)
            frame[frame.startIndex] = (SMPProtocol.version << 3) | (operation & 0x07)
            frame[frame.startIndex + 1] = 0
            frame[frame.startIndex + 2] = UInt8(payload.count >> 8)
            frame[frame.startIndex + 3] = UInt8(payload.count & 0xFF)
            frame[frame.startIndex + 4] = UInt8(group >> 8)
            frame[frame.startIndex + 5] = UInt8(group & 0xFF)
            frame[frame.startIndex + 6] = sequence
            frame[frame.startIndex + 7] = command
            frame.append(payload)
            return frame
        }

        static func decode(_ data: Data) throws -> Frame {
            guard data.count >= SMPProtocol.headerLength else {
                throw DFUError.remote("SMP response is shorter than a header.")
            }
            let length = Int(byte(data, 2)) << 8 | Int(byte(data, 3))
            guard data.count >= SMPProtocol.headerLength + length else {
                throw DFUError.remote("SMP response is missing \(SMPProtocol.headerLength + length - data.count) bytes.")
            }
            let payloadStart = data.startIndex + SMPProtocol.headerLength
            return Frame(
                operation: byte(data, 0) & 0x07,
                group: UInt16(byte(data, 4)) << 8 | UInt16(byte(data, 5)),
                sequence: byte(data, 6),
                command: byte(data, 7),
                payload: Data(data[payloadStart..<(payloadStart + length)])
            )
        }
    }

    struct Image {
        var number: Int?
        var slot: Int
        var version: String?
        var hash: Data?
        var active: Bool
    }

    struct Body {
        var offset: Int?
        var match: Bool?
        var status: Int?
        var reason: String?
        var bufferSize: Int?
        var images: [Image] = []
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func uploadPayload(offset: Int, chunk: Data, totalLength: Int?, sha: Data?) -> Data {
        var pairs: [(String, CBORValue)] = [
            ("off", .uint(UInt64(offset))),
            ("data", .bytes(chunk)),
        ]
        if offset == 0, let totalLength {
            pairs.insert(("len", .uint(UInt64(totalLength))), at: 0)
        }
        if offset == 0, let sha {
            pairs.append(("sha", .bytes(sha)))
        }
        return CBOR.encodeMap(pairs)
    }

    static func statePayload(hash: Data, confirm: Bool) -> Data {
        CBOR.encodeMap([
            ("hash", .bytes(hash)),
            ("confirm", .bool(confirm)),
        ])
    }

    static func emptyMap() -> Data {
        CBOR.encodeMap([])
    }

    static func interpret(_ payload: Data) throws -> Body {
        guard !payload.isEmpty else { return Body() }
        guard case .map(let fields) = try CBOR.decode(payload) else {
            throw DFUError.remote("SMP payload was not a CBOR map.")
        }
        var body = Body()
        if let value = fields["off"] { body.offset = CBOR.int(value) }
        if let value = fields["match"], case .bool(let match) = value { body.match = match }
        if let value = fields["rc"] { body.status = CBOR.int(value) }
        if let value = fields["rsn"], case .text(let reason) = value { body.reason = reason }
        if let value = fields["buf_size"] { body.bufferSize = CBOR.int(value) }
        if case .map(let error) = fields["err"], let value = error["rc"] {
            body.status = CBOR.int(value)
        }
        if case .array(let images) = fields["images"] {
            body.images = images.compactMap(image(from:))
        }
        return body
    }

    static func statusMessage(_ status: Int, reason: String?) -> String {
        let detail: String
        switch status {
        case 1: detail = "The device rejected the SMP command."
        case 2: detail = "The device ran out of memory for this SMP packet."
        case 3: detail = "The device rejected a value in the SMP command."
        case 5: detail = "The device could not find that image."
        case 6: detail = "The device is not in a state that allows this SMP command."
        case 7: detail = "The SMP packet is larger than the device accepts."
        case 8: detail = "The device does not support that SMP command."
        case 9: detail = "The device reported a corrupt image."
        case 11: detail = "The device denied SMP access. Pair when prompted, then try again."
        default: detail = "SMP failed with status \(status)."
        }
        if let reason, !reason.isEmpty {
            return "\(detail) \(reason)"
        }
        return detail
    }

    /// Version string of the image that is running now.
    static func runningVersion(in images: [Image]) -> String? {
        let withVersion = images.filter { $0.version?.isEmpty == false }
        let active = withVersion.filter(\.active)
        let running = active.isEmpty ? withVersion.filter { $0.slot == 0 } : active
        let labels = running.compactMap { image -> String? in
            guard let version = image.version else { return nil }
            if let number = image.number, running.count > 1 {
                return "image \(number): \(version)"
            }
            return version
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    /// Slot 1 is the update bank. Prefer image 0 when the device reports more than one image.
    static func updateImage(in images: [Image]) -> Image? {
        let secondary = images.filter { $0.slot == 1 && $0.hash != nil }
        return secondary.first { $0.number == 0 || $0.number == nil } ?? secondary.first
    }

    private static func image(from value: CBORValue) -> Image? {
        guard case .map(let fields) = value, let slot = fields["slot"].flatMap(CBOR.int) else {
            return nil
        }
        let hash: Data?
        if case .bytes(let bytes) = fields["hash"] {
            hash = bytes
        } else {
            hash = nil
        }
        let version: String?
        if case .text(let text) = fields["version"] {
            version = text
        } else {
            version = nil
        }
        let active: Bool
        if case .bool(let value) = fields["active"] {
            active = value
        } else {
            active = false
        }
        return Image(
            number: fields["image"].flatMap(CBOR.int),
            slot: slot,
            version: version,
            hash: hash,
            active: active
        )
    }

    #if SELFTEST
    static func selfTest() {
        let chunk = Data([0xAA, 0xBB])
        let sha = Data(repeating: 0x11, count: 32)
        let payload = uploadPayload(offset: 0, chunk: chunk, totalLength: 512, sha: sha)
        let frame = Frame(operation: Operation.write, group: Group.image, sequence: 7, command: Command.imageUpload, payload: payload).encoded()
        precondition(byte(frame, 0) == 0x0A, "version 1 write header")
        precondition(byte(frame, 6) == 7 && byte(frame, 7) == 1, "sequence and command")
        let decoded = try! Frame.decode(frame)
        precondition(decoded.operation == Operation.write && decoded.group == Group.image, "frame round trip")
        let body = try! interpret(decoded.payload)
        precondition(body.offset == 0, "upload payload offset")
        guard case .map(let fields) = try! CBOR.decode(decoded.payload) else {
            preconditionFailure("upload map")
        }
        precondition(CBOR.int(fields["len"]!) == 512, "length")
        precondition(CBOR.int(fields["off"]!) == 0, "offset")
        if case .bytes(let data) = fields["data"]! {
            precondition(data == chunk, "chunk")
        } else {
            preconditionFailure("chunk type")
        }

        let response = CBOR.encodeMap([("off", .uint(512))])
        let parsed = try! interpret(response)
        precondition(parsed.offset == 512 && parsed.status == nil, "upload response")

        let failure = CBOR.encodeMap([("rc", .uint(8)), ("rsn", .text("nope"))])
        let failed = try! interpret(failure)
        precondition(failed.status == 8 && failed.reason == "nope", "status")

        let hash = Data(repeating: 0xAB, count: 32)
        let images = CBOR.encodeMap([
            ("images", .array([
                .map([
                    "slot": .uint(0),
                    "version": .text("4.4.0"),
                    "hash": .bytes(Data(repeating: 0x01, count: 32)),
                    "active": .bool(true),
                ]),
                .map([
                    "image": .uint(0),
                    "slot": .uint(1),
                    "hash": .bytes(hash),
                ]),
            ])),
        ])
        let listed = try! interpret(images)
        let update = updateImage(in: listed.images)
        precondition(update?.hash == hash && update?.slot == 1, "secondary image")
        precondition(runningVersion(in: listed.images) == "4.4.0", "running version")

        let indefinite = Data([
            0xBF,
            0x66, 0x69, 0x6D, 0x61, 0x67, 0x65, 0x73,
            0x9F,
            0xBF,
            0x64, 0x73, 0x6C, 0x6F, 0x74, 0x00,
            0x67, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E,
            0x7F, 0x65, 0x34, 0x2E, 0x34, 0x2E, 0x30, 0xFF,
            0x66, 0x61, 0x63, 0x74, 0x69, 0x76, 0x65, 0xF5,
            0xFF,
            0xFF,
            0xFF,
        ])
        let indefiniteList = try! interpret(indefinite)
        precondition(runningVersion(in: indefiniteList.images) == "4.4.0", "indefinite version")
        print("smp protocol ok")
    }
    #endif
}

enum CBORValue {
    case uint(UInt64)
    case int(Int64)
    case bool(Bool)
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([String: CBORValue])
    case null
}

enum CBOR {
    static func encodeMap(_ pairs: [(String, CBORValue)]) -> Data {
        var data = Data()
        appendCount(UInt64(pairs.count), major: 5, to: &data)
        for (key, value) in pairs {
            appendText(key, to: &data)
            append(value, to: &data)
        }
        return data
    }

    static func decode(_ data: Data) throws -> CBORValue {
        var reader = Reader(data)
        let value = try reader.readValue()
        guard reader.isAtEnd else {
            throw DFUError.remote("SMP payload had trailing CBOR data.")
        }
        return value
    }

    static func int(_ value: CBORValue) -> Int? {
        switch value {
        case .uint(let number):
            return number <= UInt64(Int.max) ? Int(number) : nil
        case .int(let number):
            return Int(exactly: number)
        default:
            return nil
        }
    }

    private static func append(_ value: CBORValue, to data: inout Data) {
        switch value {
        case .uint(let number):
            appendCount(number, major: 0, to: &data)
        case .int(let number):
            let positive = UInt64(-1 - number)
            appendCount(positive, major: 1, to: &data)
        case .bool(let flag):
            data.append(flag ? 0xF5 : 0xF4)
        case .bytes(let bytes):
            appendCount(UInt64(bytes.count), major: 2, to: &data)
            data.append(bytes)
        case .text(let text):
            appendText(text, to: &data)
        case .array(let items):
            appendCount(UInt64(items.count), major: 4, to: &data)
            items.forEach { append($0, to: &data) }
        case .map(let fields):
            data.append(encodeMap(fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        case .null:
            data.append(0xF6)
        }
    }

    private static func appendText(_ text: String, to data: inout Data) {
        let encoded = Data(text.utf8)
        appendCount(UInt64(encoded.count), major: 3, to: &data)
        data.append(encoded)
    }

    private static func appendCount(_ value: UInt64, major: UInt8, to data: inout Data) {
        let prefix = major << 5
        if value < 24 {
            data.append(prefix | UInt8(value))
        } else if value <= UInt64(UInt8.max) {
            data.append(prefix | 24)
            data.append(UInt8(value))
        } else if value <= UInt64(UInt16.max) {
            data.append(prefix | 25)
            appendBE(value, bytes: 2, to: &data)
        } else if value <= UInt64(UInt32.max) {
            data.append(prefix | 26)
            appendBE(value, bytes: 4, to: &data)
        } else {
            data.append(prefix | 27)
            appendBE(value, bytes: 8, to: &data)
        }
    }

    private static func appendBE(_ value: UInt64, bytes: Int, to data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private struct Reader {
        let data: Data
        var index: Data.Index

        init(_ data: Data) {
            self.data = data
            index = data.startIndex
        }

        var isAtEnd: Bool { index >= data.endIndex }

        mutating func readValue() throws -> CBORValue {
            let initial = try next()
            let major = initial >> 5
            let additional = initial & 0x1F
            if additional == 31 {
                return try readIndefinite(major)
            }
            switch major {
            case 0:
                return .uint(try argument(additional))
            case 1:
                let raw = try argument(additional)
                return .int(-1 - Int64(raw))
            case 2:
                return .bytes(try bytes(count: try argument(additional)))
            case 3:
                return .text(try text(from: try bytes(count: try argument(additional))))
            case 4:
                let count = try argument(additional)
                var items: [CBORValue] = []
                for _ in 0..<count {
                    items.append(try readValue())
                }
                return .array(items)
            case 5:
                return .map(try mapFields(count: try argument(additional)))
            case 7:
                switch additional {
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22: return .null
                default:
                    throw DFUError.remote("SMP payload contains an unsupported CBOR value.")
                }
            default:
                throw DFUError.remote("SMP payload contains an unsupported CBOR type.")
            }
        }

        private mutating func readIndefinite(_ major: UInt8) throws -> CBORValue {
            switch major {
            case 2:
                var collected = Data()
                while try !atBreak() {
                    guard case .bytes(let chunk) = try readValue() else {
                        throw DFUError.remote("SMP payload had a non-byte chunk in an indefinite byte string.")
                    }
                    collected.append(chunk)
                }
                return .bytes(collected)
            case 3:
                var collected = Data()
                while try !atBreak() {
                    guard case .text(let chunk) = try readValue() else {
                        throw DFUError.remote("SMP payload had a non-text chunk in an indefinite text string.")
                    }
                    collected.append(Data(chunk.utf8))
                }
                return .text(try text(from: collected))
            case 4:
                var items: [CBORValue] = []
                while try !atBreak() {
                    items.append(try readValue())
                }
                return .array(items)
            case 5:
                var fields: [String: CBORValue] = [:]
                while try !atBreak() {
                    if let pair = try oneField() {
                        fields[pair.key] = pair.value
                    }
                }
                return .map(fields)
            default:
                throw DFUError.remote("SMP payload uses an indefinite-length CBOR type this app does not accept.")
            }
        }

        private mutating func atBreak() throws -> Bool {
            guard index < data.endIndex else {
                throw DFUError.remote("SMP payload ended before its CBOR break.")
            }
            guard data[index] == 0xFF else { return false }
            index = data.index(after: index)
            return true
        }

        private mutating func mapFields(count: UInt64) throws -> [String: CBORValue] {
            var fields: [String: CBORValue] = [:]
            for _ in 0..<count {
                if let pair = try oneField() {
                    fields[pair.key] = pair.value
                }
            }
            return fields
        }

        private mutating func oneField() throws -> (key: String, value: CBORValue)? {
            let key = try readValue()
            let value = try readValue()
            guard case .text(let name) = key else { return nil }
            return (name, value)
        }

        private func text(from bytes: Data) throws -> String {
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw DFUError.remote("SMP payload contained text that is not UTF-8.")
            }
            return text
        }

        private mutating func argument(_ additional: UInt8) throws -> UInt64 {
            switch additional {
            case 0...23:
                return UInt64(additional)
            case 24:
                return UInt64(try next())
            case 25:
                return try readBE(2)
            case 26:
                return try readBE(4)
            case 27:
                return try readBE(8)
            default:
                throw DFUError.remote("SMP payload uses indefinite-length CBOR, which this app does not accept.")
            }
        }

        private mutating func bytes(count: UInt64) throws -> Data {
            guard count <= UInt64(Int.max) else {
                throw DFUError.remote("SMP payload is too large.")
            }
            let length = Int(count)
            guard data.distance(from: index, to: data.endIndex) >= length else {
                throw DFUError.remote("SMP payload ended before its CBOR value.")
            }
            let end = data.index(index, offsetBy: length)
            let slice = Data(data[index..<end])
            index = end
            return slice
        }

        private mutating func readBE(_ count: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<count {
                value = (value << 8) | UInt64(try next())
            }
            return value
        }

        private mutating func next() throws -> UInt8 {
            guard index < data.endIndex else {
                throw DFUError.remote("SMP payload ended early.")
            }
            let value = data[index]
            index = data.index(after: index)
            return value
        }
    }
}
