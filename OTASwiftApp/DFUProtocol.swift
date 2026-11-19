import Foundation

/// Nordic Secure DFU opcodes, as used by the nRF5 SDK bootloader over BLE.
/// Service UUID is 0xFE59. The control point and packet characteristics live
/// under the Nordic 128-bit base UUID 8EC9xxxx-F315-4F60-9FB8-838830DAEA50.
enum DFUProtocol {
    enum Opcode {
        static let createObject: UInt8 = 0x01
        static let setPRN: UInt8 = 0x02
        static let calculateCRC: UInt8 = 0x03
        static let execute: UInt8 = 0x04
        static let selectObject: UInt8 = 0x06
        static let response: UInt8 = 0x60
    }

    enum ObjectType {
        static let command: UInt8 = 0x01
        static let data: UInt8 = 0x02
    }

    enum Buttonless {
        static let response: UInt8 = 0x20
        static let enterBootloader: UInt8 = 0x01
        static let setAdvertisementName: UInt8 = 0x02
        static let success: UInt8 = 0x01
    }

    static let resultSuccess: UInt8 = 0x01
    static let resultExtendedError: UInt8 = 0x0B

    struct ObjectInfo {
        var maxSize: UInt32
        var offset: UInt32
        var crc: UInt32
    }

    struct Checksum {
        var offset: UInt32
        var crc: UInt32
    }

    static func createObject(type: UInt8, size: UInt32) -> Data {
        Data([Opcode.createObject, type]) + le32(size)
    }

    static func setPacketReceiptNotification(_ count: UInt16) -> Data {
        Data([
            Opcode.setPRN,
            UInt8(count & 0xFF),
            UInt8((count >> 8) & 0xFF),
        ])
    }

    static func selectObject(_ type: UInt8) -> Data {
        Data([Opcode.selectObject, type])
    }

    static func calculateCRC() -> Data {
        Data([Opcode.calculateCRC])
    }

    static func execute() -> Data {
        Data([Opcode.execute])
    }

    static func buttonless(_ opcode: UInt8, payload: Data = Data()) -> Data {
        Data([opcode]) + payload
    }

    /// Control-point notifications are `[0x60, request, status, payload...]`.
    /// Returns the payload after a success status.
    static func parseResponse(_ data: Data, expecting operation: UInt8) throws -> Data {
        guard data.count >= 3 else {
            throw DFUError.remote("Short DFU response (\(hex(data))).")
        }
        let response = byte(data, 0)
        let request = byte(data, 1)
        let status = byte(data, 2)
        guard response == Opcode.response else {
            throw DFUError.remote("Unexpected DFU notification \(hex(data)).")
        }
        guard request == operation else {
            throw DFUError.remote(
                "Unexpected DFU opcode 0x\(DFUByte(request)) (expected 0x\(DFUByte(operation)))."
            )
        }
        if status == resultSuccess {
            // Copy so the payload's indices start at 0. Data slices keep the parent's indices.
            return Data(data.dropFirst(3))
        }
        if status == resultExtendedError {
            let code = data.count >= 4 ? byte(data, 3) : 0
            throw DFUError.remote(extendedErrorDescription(code))
        }
        throw DFUError.remote(resultDescription(status))
    }

    static func parseObjectInfo(_ payload: Data) throws -> ObjectInfo {
        guard payload.count >= 12 else {
            throw DFUError.remote("Select Object response was too short.")
        }
        return ObjectInfo(
            maxSize: readUInt32LE(payload, at: 0),
            offset: readUInt32LE(payload, at: 4),
            crc: readUInt32LE(payload, at: 8)
        )
    }

    static func parseChecksum(_ payload: Data) throws -> Checksum {
        guard payload.count >= 8 else {
            throw DFUError.remote("Checksum response was too short.")
        }
        return Checksum(
            offset: readUInt32LE(payload, at: 0),
            crc: readUInt32LE(payload, at: 4)
        )
    }

    static func parseButtonless(_ data: Data, expecting operation: UInt8) throws {
        guard data.count >= 3,
              byte(data, 0) == Buttonless.response,
              byte(data, 1) == operation else {
            throw DFUError.remote("Unexpected buttonless response \(hex(data)).")
        }
        guard byte(data, 2) == Buttonless.success else {
            throw DFUError.remote("Buttonless DFU failed with status 0x\(DFUByte(byte(data, 2))).")
        }
    }

    static func resultDescription(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "The bootloader rejected the opcode."
        case 0x02: return "The bootloader does not support that operation."
        case 0x03: return "The bootloader rejected a parameter."
        case 0x04: return "The bootloader does not have enough memory for this object."
        case 0x05: return "The bootloader rejected the object."
        case 0x07: return "The bootloader rejected the object type."
        case 0x08: return "The bootloader is not in a state that allows this operation."
        case 0x0A: return "The bootloader reported that the operation failed."
        default: return "DFU failed with status 0x\(DFUByte(code))."
        }
    }

    static func extendedErrorDescription(_ code: UInt8) -> String {
        switch code {
        case 0x02: return "The init packet format is wrong."
        case 0x03: return "The bootloader did not recognize the init command."
        case 0x04: return "The init packet is invalid."
        case 0x05: return "The firmware version was rejected."
        case 0x06: return "The hardware version was rejected."
        case 0x07: return "The SoftDevice version was rejected."
        case 0x08: return "The signature is missing."
        case 0x09: return "The init packet uses an unsupported hash type."
        case 0x0A: return "The firmware hash does not match the .bin."
        case 0x0B: return "The init packet uses an unsupported signature type."
        case 0x0C: return "Signature verification failed."
        case 0x0D: return "The device does not have enough space for this firmware."
        default: return "DFU extended error 0x\(DFUByte(code))."
        }
    }
}

enum DFUError: LocalizedError {
    case bluetoothUnavailable
    case timeout(String)
    case notDFUDevice
    case legacyDFU
    case missingCharacteristics
    case fileEmpty
    case wrongExtension
    case objectTooLarge
    case remote(String)
    case crcMismatch(expectedCRC: UInt32, gotCRC: UInt32, expectedOffset: UInt32, gotOffset: UInt32)
    case lostConnection
    case resetComplete
    case bondingRequired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is not available."
        case .timeout(let what):
            return "Timed out \(what)."
        case .notDFUDevice:
            return "This device does not expose nRF54 SMP or Nordic Secure DFU (FE59)."
        case .legacyDFU:
            return "This device uses legacy nRF DFU from SDK 11 or earlier. This app speaks Secure DFU (nRF5 SDK 12 and later)."
        case .missingCharacteristics:
            return "The DFU service is missing its control point or packet characteristic."
        case .fileEmpty:
            return "The firmware file is empty."
        case .wrongExtension:
            return "Choose a .bin firmware file."
        case .objectTooLarge:
            return "The init packet is larger than the bootloader accepts."
        case .remote(let message):
            return message
        case .crcMismatch(let expectedCRC, let gotCRC, let expectedOffset, let gotOffset):
            return "CRC check failed. Expected CRC \(hex32(expectedCRC)) at offset \(expectedOffset), bootloader reported \(hex32(gotCRC)) at offset \(gotOffset)."
        case .lostConnection:
            return "The device disconnected before the update finished."
        case .resetComplete:
            return "The device reset after receiving the firmware."
        case .bondingRequired:
            return "This DFU characteristic requires a bonded connection. Pair when prompted, then try again."
        case .cancelled:
            return "Upload cancelled."
        }
    }
}

/// Incremental CRC-32 matching zlib and nrfutil (`binascii.crc32`).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = 0xEDB8_8320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func update(_ seed: UInt32, _ data: Data) -> UInt32 {
        var crc = seed ^ 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func checksum(_ data: Data) -> UInt32 {
        update(0, data)
    }
}

func le32(_ value: UInt32) -> Data {
    Data([
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24),
    ])
}

func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    return UInt32(data[start])
        | (UInt32(data[start + 1]) << 8)
        | (UInt32(data[start + 2]) << 16)
        | (UInt32(data[start + 3]) << 24)
}

func byte(_ data: Data, _ offset: Int) -> UInt8 {
    data[data.startIndex + offset]
}

func hex(_ data: Data) -> String {
    data.map { DFUByte($0) }.joined(separator: " ")
}

func DFUByte(_ value: UInt8) -> String {
    String(format: "%02X", value)
}

func hex32(_ value: UInt32) -> String {
    String(format: "%08X", value)
}

#if SELFTEST
@main
struct DFUProtocolSelfTest {
    static func main() {
        let known = Data("123456789".utf8)
        precondition(CRC32.checksum(known) == 0xCBF4_3926, "CRC-32 check value")
        let split = CRC32.update(CRC32.update(0, known.prefix(4)), known.dropFirst(4))
        precondition(split == 0xCBF4_3926, "incremental CRC")
        precondition(CRC32.checksum(Data()) == 0, "empty CRC")

        let select = Data([0x60, 0x06, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let payload = try! DFUProtocol.parseResponse(select, expecting: DFUProtocol.Opcode.selectObject)
        let info = try! DFUProtocol.parseObjectInfo(payload)
        precondition(info.maxSize == 4096 && info.offset == 0 && info.crc == 0, "select object")

        let failure = Data([0x60, 0x04, 0x0B, 0x08])
        do {
            _ = try DFUProtocol.parseResponse(failure, expecting: DFUProtocol.Opcode.execute)
            preconditionFailure("expected extended error")
        } catch let error as DFUError {
            if case .remote(let message) = error {
                precondition(message.contains("signature"), message)
            } else {
                preconditionFailure("wrong error")
            }
        } catch {
            preconditionFailure("unexpected error")
        }

        print("dfu protocol ok")
        SMPProtocol.selfTest()
    }
}
#endif
