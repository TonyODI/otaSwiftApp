import CoreBluetooth
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DeviceItem: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var lastSeen: Date
    var secureDFU: Bool
    var legacyDFU: Bool
    var smp: Bool
    var nordic: Bool
    var firmwareVersion: String?
    let peripheral: CBPeripheral

    var isOTA: Bool {
        smp || secureDFU || legacyDFU || nordic || name.lowercased().contains("dfu")
    }

    var badge: String? {
        if smp { return "nRF54" }
        if secureDFU { return "Secure DFU" }
        if legacyDFU { return "Legacy DFU" }
        if name.lowercased().contains("dfu") { return "DFU" }
        if nordic { return "Nordic" }
        return nil
    }
}

enum TransferPhase: Equatable {
    case idle
    case working
    case success
    case failed
}

@MainActor
final class OTAController: NSObject, ObservableObject {
    @Published private(set) var devices: [DeviceItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var bluetoothReady = false
    @Published private(set) var bluetoothMessage = "Starting Bluetooth…"
    @Published private(set) var phase: TransferPhase = .idle
    @Published private(set) var statusLine = "Choose a device and a .bin file."
    @Published private(set) var logLines: [String] = []
    @Published private(set) var bytesSent = 0
    @Published private(set) var bytesTotal = 0
    @Published var selectedID: UUID?
    @Published private(set) var firmwareName: String?
    @Published private(set) var firmwareSize = 0
    @Published private(set) var firmwareCRC: UInt32 = 0
    @Published private(set) var isReadingVersion = false

    var isBusy: Bool { phase == .working }
    var progress: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesSent) / Double(bytesTotal))
    }

    var selectedDevice: DeviceItem? {
        devices.first { $0.id == selectedID }
    }

    var canUpload: Bool {
        bluetoothReady && !isBusy && !isReadingVersion && selectedDevice != nil && firmwareData?.isEmpty == false
    }

    private var firmwareData: Data?
    private var central: CBCentralManager!
    private var pruneTimer: Timer?
    private var connectedPeripheral: CBPeripheral?
    private var cancelled = false
    private var uploadFinished = false
    private var acceptDisconnectAsSuccess = false
    private var inbound: [Data] = []

    private var connectShot: OneShot<Void>?
    private var disconnectShot: OneShot<Void>?
    private var servicesShot: OneShot<Void>?
    private var pendingCharacteristicDiscovers = 0
    private var notifyShot: OneShot<Void>?
    private var writeShot: OneShot<Void>?
    private var readyShot: OneShot<Void>?
    private var inboundShot: OneShot<Data>?
    private var readShot: OneShot<Data>?
    private var bootloaderShot: OneShot<CBPeripheral>?
    private var versionGeneration = 0
    private var suppressDisconnectID: UUID?
    private var scanBeforeVersionRead = false
    private var bootloaderToken: String?
    private var bootloaderScanAllowedAt: Date?

    private let staleInterval: TimeInterval = 12
    private let prn: UInt16 = 12

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func toggleScan() {
        guard !isBusy else { return }
        if isScanning {
            scanBeforeVersionRead = false
            stopScan()
        } else {
            scanBeforeVersionRead = true
            startScan()
        }
    }

    func importBin(from url: URL) {
        do {
            let loaded = try loadSecurityScopedFile(url)
            guard loaded.name.lowercased().hasSuffix(".bin") else {
                throw DFUError.wrongExtension
            }
            guard !loaded.data.isEmpty else { throw DFUError.fileEmpty }
            firmwareData = loaded.data
            firmwareName = loaded.name
            firmwareSize = loaded.data.count
            firmwareCRC = CRC32.checksum(loaded.data)
            if phase == .failed || phase == .success {
                phase = .idle
            }
            statusLine = "Ready to upload \(loaded.name)."
            log("Selected \(loaded.name) (\(loaded.data.count) bytes, CRC \(hex32(firmwareCRC))).")
        } catch {
            phase = .failed
            statusLine = error.localizedDescription
            log("Could not read firmware: \(error.localizedDescription)")
        }
    }

    func selectDevice(_ id: UUID) {
        selectedID = id
        guard !isBusy else { return }
        versionGeneration += 1
        if !isReadingVersion {
            scanBeforeVersionRead = isScanning
        }
        if isReadingVersion {
            failActive(DFUError.cancelled)
            releaseLink(resumeWaitersWith: nil)
        }
        isReadingVersion = true
        let generation = versionGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == self.versionGeneration, !self.isBusy else {
                if generation == self.versionGeneration {
                    self.isReadingVersion = false
                }
                return
            }
            await self.loadFirmwareVersion(id, generation: generation)
        }
    }

    func startUpload() {
        guard canUpload, let device = selectedDevice, let firmware = firmwareData else { return }
        versionGeneration += 1
        cancelled = false
        uploadFinished = false
        acceptDisconnectAsSuccess = false
        inbound.removeAll()
        bytesSent = 0
        bytesTotal = 0
        phase = .working
        statusLine = "Connecting…"
        log("Uploading \(firmwareName ?? "firmware") to \(device.name).")

        Task { @MainActor in
            do {
                try await self.performUpload(to: device.peripheral, firmware: firmware)
                self.finishSuccess()
            } catch DFUError.resetComplete {
                self.finishSuccess()
            } catch is CancellationError {
                self.finishCancel()
            } catch DFUError.cancelled {
                self.finishCancel()
            } catch {
                self.finishFailure(error)
            }
        }
    }

    func cancelUpload() {
        guard isBusy else { return }
        cancelled = true
        uploadFinished = true
        bootloaderToken = nil
        connectedPeripheral?.delegate = nil
        failActive(DFUError.cancelled)
        haltScan()
        if let peripheral = connectedPeripheral, peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    func openBluetoothSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Scan

    private func startScan() {
        guard central.state == .poweredOn, bootloaderShot == nil else { return }
        isScanning = true
        bluetoothMessage = "Scanning for nRF devices"
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneStaleDevices()
            }
        }
    }

    private func stopScan() {
        haltScan()
        if bluetoothReady && !isBusy {
            bluetoothMessage = "Scan stopped"
        }
    }

    private func haltScan() {
        isScanning = false
        central.stopScan()
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    private func pruneStaleDevices() {
        let cutoff = Date().addingTimeInterval(-staleInterval)
        devices.removeAll { $0.lastSeen < cutoff && $0.id != selectedID }
    }

    private func upsert(_ peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) {
        let services = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflow = (advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let advertised = services + overflow
        let name = (advertisement[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "Unnamed"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rssiValue = rssi.intValue == 127 ? -100 : rssi.intValue
        let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data
        var company: UInt16 = 0
        if let manufacturer, manufacturer.count >= 2 {
            let first = manufacturer.startIndex
            company = UInt16(manufacturer[first]) | (UInt16(manufacturer[first + 1]) << 8)
        }

        let item = DeviceItem(
            id: peripheral.identifier,
            name: trimmed.isEmpty ? "Unnamed" : trimmed,
            rssi: rssiValue,
            lastSeen: Date(),
            secureDFU: advertised.contains(NRFUUID.secureService),
            legacyDFU: advertised.contains(NRFUUID.legacyService),
            smp: advertised.contains(NRFUUID.smpService),
            nordic: company == NRFUUID.nordicCompanyID,
            firmwareVersion: nil,
            peripheral: peripheral
        )

        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            var existing = devices[index]
            existing.name = item.name == "Unnamed" ? existing.name : item.name
            if rssi.intValue != 127 {
                existing.rssi = item.rssi
            }
            existing.lastSeen = item.lastSeen
            existing.secureDFU = existing.secureDFU || item.secureDFU
            existing.legacyDFU = existing.legacyDFU || item.legacyDFU
            existing.smp = existing.smp || item.smp
            existing.nordic = existing.nordic || item.nordic
            devices[index] = existing
        } else {
            devices.append(item)
        }

        devices.sort { lhs, rhs in
            if lhs.isOTA != rhs.isOTA { return lhs.isOTA && !rhs.isOTA }
            return lhs.rssi > rhs.rssi
        }
    }

    // MARK: - Upload

    private func performUpload(to peripheral: CBPeripheral, firmware: Data) async throws {
        try checkpoint()
        haltScan()
        statusLine = "Connecting to \(peripheral.name ?? "device")…"
        log("Connecting.")
        try await connect(peripheral)
        try checkpoint()

        statusLine = "Discovering services…"
        log("Discovering GATT services.")
        try await discoverGATT()
        try checkpoint()

        if find(NRFUUID.smpService, NRFUUID.smpCharacteristic) != nil {
            try await uploadSMP(firmware)
            return
        }

        if find(NRFUUID.secureService, NRFUUID.controlPoint) == nil {
            if let buttonless = find(NRFUUID.secureService, NRFUUID.buttonless) {
                try await enterBootloader(using: buttonless, bonded: false, from: peripheral)
            } else if let bonded = find(NRFUUID.secureService, NRFUUID.buttonlessBonded) {
                log("Bonded buttonless DFU. Accept the pairing prompt if it appears.")
                try await enterBootloader(using: bonded, bonded: true, from: peripheral)
            } else if peripheral.services?.contains(where: { $0.uuid == NRFUUID.legacyService }) == true {
                throw DFUError.legacyDFU
            } else {
                throw DFUError.notDFUDevice
            }
            try await discoverGATT()
        }

        guard
            let control = find(NRFUUID.secureService, NRFUUID.controlPoint),
            let packet = find(NRFUUID.secureService, NRFUUID.packet)
        else {
            if peripheral.services?.contains(where: { $0.uuid == NRFUUID.legacyService }) == true {
                throw DFUError.legacyDFU
            }
            throw DFUError.missingCharacteristics
        }

        log("Secure DFU service found.")
        try await setNotify(true, on: control)
        try checkpoint()

        statusLine = "Preparing transfer…"
        log("Setting packet receipt notifications to \(prn).")
        try await writeControl(DFUProtocol.setPacketReceiptNotification(prn), to: control, expecting: DFUProtocol.Opcode.setPRN)

        bytesTotal = firmware.count
        bytesSent = 0
        statusLine = "Uploading firmware…"
        log("Sending firmware (\(firmware.count) bytes).")
        try await sendFirmware(firmware, control: control, packet: packet)
    }

    /// Uploads a MCUboot image with SMP, then marks the secondary slot confirmed and resets.
    private func uploadSMP(_ firmware: Data) async throws {
        guard let characteristic = find(NRFUUID.smpService, NRFUUID.smpCharacteristic) else {
            throw DFUError.missingCharacteristics
        }
        log("nRF54 SMP service found.")
        statusLine = "Preparing nRF54 update…"
        try await setNotify(true, on: characteristic)
        var sequence: UInt8 = 0
        var frameLimit = try await smpBufferSize(characteristic, sequence: &sequence)

        let digest = SMPProtocol.sha256(firmware)
        bytesTotal = firmware.count
        bytesSent = 0
        statusLine = "Uploading firmware…"
        log("Sending \(firmware.count) bytes. SMP frames are limited to \(frameLimit) bytes.")

        var offset = 0
        var stalls = 0
        var restarts = 0
        while offset < firmware.count {
            try checkpoint()
            let request = try smpUploadFrame(
                firmware: firmware,
                offset: offset,
                digest: digest,
                sequence: sequence,
                frameLimit: &frameLimit
            )
            let body: SMPProtocol.Body
            let previousLimit = frameLimit
            do {
                body = try await transactSMP(request.frame, through: characteristic, shrinking: &frameLimit)
            } catch let error as DFUError {
                guard case .remote(let message) = error,
                      frameLimit < previousLimit,
                      message.contains("ran out of memory") || message.contains("larger than the device") else {
                    throw error
                }
                sequence &+= 1
                log("Packet was too large. Retrying with \(frameLimit) byte frames.")
                continue
            }
            sequence &+= 1
            if body.match == false {
                throw DFUError.remote("The device rejected the image hash. The .bin must be the MCUboot-signed image.")
            }
            guard let next = body.offset else {
                throw DFUError.remote("The nRF54 upload response did not include an offset.")
            }
            if next == 0 && offset != 0 {
                restarts += 1
                guard restarts <= 3 else {
                    throw DFUError.remote("The nRF54 restarted the upload repeatedly.")
                }
                log("Device restarted the upload.")
                offset = 0
                bytesSent = 0
                stalls = 0
                continue
            }
            if next < offset {
                offset = next
                bytesSent = offset
                continue
            }
            if next == offset {
                stalls += 1
                guard stalls <= 3 else {
                    throw DFUError.remote("The nRF54 did not accept more firmware at offset \(next).")
                }
                frameLimit = max(128, frameLimit / 2)
                log("No progress. Retrying with \(frameLimit) byte frames.")
                continue
            }
            stalls = 0
            offset = min(next, firmware.count)
            bytesSent = offset
            if offset >= firmware.count {
                bytesSent = firmware.count
                break
            }
        }

        statusLine = "Activating firmware…"
        log("Reading image slots.")
        let state = try await sendSMP(
            operation: SMPProtocol.Operation.read,
            group: SMPProtocol.Group.image,
            command: SMPProtocol.Command.imageState,
            payload: SMPProtocol.emptyMap(),
            through: characteristic,
            sequence: &sequence
        )
        guard let hash = SMPProtocol.updateImage(in: state.images)?.hash else {
            throw DFUError.remote("The firmware was stored, but the device did not report a secondary image to boot. Use the MCUboot-signed file, usually zephyr.signed.bin.")
        }
        log("Marking the new image confirmed.")
        _ = try await sendSMP(
            operation: SMPProtocol.Operation.write,
            group: SMPProtocol.Group.image,
            command: SMPProtocol.Command.imageState,
            payload: SMPProtocol.statePayload(hash: hash, confirm: true),
            through: characteristic,
            sequence: &sequence
        )

        statusLine = "Restarting device…"
        log("Resetting the device.")
        acceptDisconnectAsSuccess = true
        do {
            _ = try await sendSMP(
                operation: SMPProtocol.Operation.write,
                group: SMPProtocol.Group.operatingSystem,
                command: SMPProtocol.Command.reset,
                payload: SMPProtocol.emptyMap(),
                through: characteristic,
                sequence: &sequence
            )
        } catch DFUError.resetComplete {
            return
        }
    }

    private func smpBufferSize(_ characteristic: CBCharacteristic, sequence: inout UInt8) async throws -> Int {
        let fallback = 384
        do {
            let body = try await sendSMP(
                operation: SMPProtocol.Operation.read,
                group: SMPProtocol.Group.operatingSystem,
                command: SMPProtocol.Command.parameters,
                payload: SMPProtocol.emptyMap(),
                through: characteristic,
                sequence: &sequence
            )
            if let size = body.bufferSize, size >= 128 {
                return min(size, 4096)
            }
        } catch let error as DFUError {
            if case .remote(let message) = error, message.contains("does not support") {
                log("Device did not report an SMP buffer size. Using \(fallback) byte frames.")
                return fallback
            }
            throw error
        }
        log("Using \(fallback) byte SMP frames.")
        return fallback
    }

    private func smpUploadFrame(
        firmware: Data,
        offset: Int,
        digest: Data,
        sequence: UInt8,
        frameLimit: inout Int
    ) throws -> (frame: Data, shrunk: Bool) {
        var shrunk = false
        var chunkLength = min(firmware.count - offset, max(16, frameLimit - (offset == 0 ? 160 : 48)))
        while true {
            let chunk = firmware.subdata(in: offset..<(offset + chunkLength))
            let payload = SMPProtocol.uploadPayload(
                offset: offset,
                chunk: chunk,
                totalLength: firmware.count,
                sha: digest
            )
            let frame = SMPProtocol.Frame(
                operation: SMPProtocol.Operation.write,
                group: SMPProtocol.Group.image,
                sequence: sequence,
                command: SMPProtocol.Command.imageUpload,
                payload: payload
            ).encoded()
            if frame.count <= frameLimit || chunkLength <= 16 {
                return (frame, shrunk)
            }
            shrunk = true
            chunkLength = max(16, chunkLength / 2)
        }
    }

    private func sendSMP(
        operation: UInt8,
        group: UInt16,
        command: UInt8,
        payload: Data,
        through characteristic: CBCharacteristic,
        sequence: inout UInt8
    ) async throws -> SMPProtocol.Body {
        let frame = SMPProtocol.Frame(
            operation: operation,
            group: group,
            sequence: sequence,
            command: command,
            payload: payload
        ).encoded()
        var limit = Int.max
        let body = try await transactSMP(frame, through: characteristic, shrinking: &limit)
        sequence &+= 1
        return body
    }

    /// Sends one SMP frame. A packet that is too large is reported to the caller through `shrinking`.
    private func transactSMP(
        _ frame: Data,
        through characteristic: CBCharacteristic,
        shrinking limit: inout Int
    ) async throws -> SMPProtocol.Body {
        inbound.removeAll()
        try await writeWithoutResponse(frame, to: characteristic)
        let response = try await readSMPFrame()
        guard response.sequence == byte(frame, 6) else {
            throw DFUError.remote("SMP response sequence did not match the request.")
        }
        let body = try SMPProtocol.interpret(response.payload)
        if let status = body.status, status != 0 {
            if (status == 2 || status == 7), limit > 128 {
                limit = max(128, min(limit, frame.count) / 2)
            }
            throw DFUError.remote(SMPProtocol.statusMessage(status, reason: body.reason))
        }
        return body
    }

    private func writeWithoutResponse(_ data: Data, to characteristic: CBCharacteristic) async throws {
        guard let peripheral = connectedPeripheral else { throw DFUError.lostConnection }
        var sent = 0
        while sent < data.count {
            try checkpoint()
            if !peripheral.canSendWriteWithoutResponse {
                try await waitUntilReady()
            }
            let mtu = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
            let length = min(mtu, data.count - sent)
            peripheral.writeValue(data.subdata(in: sent..<(sent + length)), for: characteristic, type: .withoutResponse)
            sent += length
            await Task.yield()
        }
    }

    private func readSMPFrame() async throws -> SMPProtocol.Frame {
        var buffer = Data()
        var expected: Int?
        while expected == nil || buffer.count < expected! {
            try checkpoint()
            buffer.append(try await nextInbound(what: "waiting for the nRF54"))
            if expected == nil, buffer.count >= SMPProtocol.headerLength {
                let length = Int(byte(buffer, 2)) << 8 | Int(byte(buffer, 3))
                expected = SMPProtocol.headerLength + length
                if expected! > 1_048_576 {
                    throw DFUError.remote("The SMP response is too large.")
                }
            }
        }
        let total = expected!
        let frame = try SMPProtocol.Frame.decode(Data(buffer.prefix(total)))
        if buffer.count > total {
            inbound.insert(Data(buffer.dropFirst(total)), at: 0)
        }
        return frame
    }

    private func enterBootloader(using characteristic: CBCharacteristic, bonded: Bool, from peripheral: CBPeripheral) async throws {
        statusLine = "Entering DFU mode…"
        log("Requesting the bootloader.")
        let token = "OTA-" + peripheral.identifier.uuidString.prefix(4)
        try await setNotify(true, on: characteristic)
        if let changed = findServiceChanged() {
            try? await setNotify(true, on: changed)
        }

        if !bonded {
            do {
                peripheral.writeValue(
                    DFUProtocol.buttonless(DFUProtocol.Buttonless.setAdvertisementName, payload: Data(token.utf8)),
                    for: characteristic,
                    type: .withResponse
                )
                try await waitForWrite()
                let response = try await nextInbound(what: "waiting for the advertisement name to be accepted")
                try DFUProtocol.parseButtonless(response, expecting: DFUProtocol.Buttonless.setAdvertisementName)
                bootloaderToken = token
                log("Bootloader will advertise as \(token).")
            } catch let error as DFUError {
                if case .remote = error {
                    bootloaderToken = nil
                    log("Device kept its own DFU name (\(error.localizedDescription)).")
                } else {
                    throw error
                }
            }
        }

        peripheral.writeValue(
            DFUProtocol.buttonless(DFUProtocol.Buttonless.enterBootloader),
            for: characteristic,
            type: .withResponse
        )
        try await waitForWrite()
        let response = try await nextInbound(what: "waiting for the bootloader to accept")
        try DFUProtocol.parseButtonless(response, expecting: DFUProtocol.Buttonless.enterBootloader)
        log("Device accepted DFU mode. Waiting for it to reset.")
        try await waitForDisconnect()

        statusLine = "Reconnecting to bootloader…"
        log("Scanning for the bootloader.")
        let bootloader = try await waitForBootloader()
        bootloaderToken = nil
        log("Connected to bootloader \(bootloader.name ?? bootloader.identifier.uuidString).")
    }

    private func sendFirmware(_ firmware: Data, control: CBCharacteristic, packet: CBCharacteristic) async throws {
        let selected = try await selectObject(DFUProtocol.ObjectType.data, control: control)
        guard selected.maxSize > 0, selected.maxSize < 16_777_216 else {
            throw DFUError.remote("The bootloader reported an unusable object size.")
        }
        log("Data object size \(selected.maxSize) bytes. Device offset \(selected.offset).")

        let maxSize = Int(selected.maxSize)
        var offset = 0
        var crc: UInt32 = 0

        if selected.offset > 0 && Int(selected.offset) <= firmware.count {
            let prefix = firmware.prefix(Int(selected.offset))
            let expected = CRC32.update(0, prefix)
            if expected == selected.crc {
                offset = Int(selected.offset)
                crc = expected
                log("Resuming from \(offset) bytes already on the device.")
                let remainder = offset % maxSize
                if remainder != 0 && offset != firmware.count {
                    let length = min(maxSize - remainder, firmware.count - offset)
                    let slice = firmware.subdata(in: offset..<(offset + length))
                    crc = try await stream(slice, crc: crc, absoluteOffset: UInt32(offset), control: control, packet: packet)
                    try await execute(control, lastObject: offset + length == firmware.count)
                    offset += length
                }
            } else {
                let remainder = Int(selected.offset) % maxSize
                let rewind = remainder == 0 ? maxSize : remainder
                let restarted = max(0, Int(selected.offset) - rewind)
                offset = restarted
                crc = CRC32.update(0, firmware.prefix(restarted))
                log("Partial firmware did not match this file. Continuing from byte \(offset).")
            }
        }

        bytesSent = offset
        while offset < firmware.count {
            try checkpoint()
            let length = min(maxSize, firmware.count - offset)
            let slice = firmware.subdata(in: offset..<(offset + length))
            let crcAtStart = crc
            var attempt = 0
            while true {
                do {
                    try await createObject(type: DFUProtocol.ObjectType.data, size: length, control: control)
                    crc = try await stream(
                        slice,
                        crc: crcAtStart,
                        absoluteOffset: UInt32(offset),
                        control: control,
                        packet: packet
                    )
                    try await execute(control, lastObject: offset + length == firmware.count)
                    break
                } catch let error as DFUError {
                    guard case .crcMismatch = error else { throw error }
                    attempt += 1
                    crc = crcAtStart
                    guard attempt < 3 else { throw error }
                    log("CRC mismatch. Retrying this block (\(attempt)).")
                }
            }
            offset += length
            bytesSent = offset
        }
    }

    private func sendObject(
        _ data: Data,
        type: UInt8,
        control: CBCharacteristic,
        packet: CBCharacteristic,
        progress: ((Int) -> Void)?
    ) async throws {
        let selected = try await selectObject(type, control: control)
        let checksum = CRC32.checksum(data)
        if selected.offset == UInt32(data.count) && selected.crc == checksum {
            log("Object is already on the device. Executing it.")
            try await execute(control, lastObject: false)
            progress?(data.count)
            return
        }
        guard selected.maxSize == 0 || data.count <= selected.maxSize else {
            throw DFUError.objectTooLarge
        }
        try await createObject(type: type, size: data.count, control: control)
        _ = try await stream(data, crc: 0, absoluteOffset: 0, control: control, packet: packet)
        try await execute(control, lastObject: false)
        progress?(data.count)
    }

    private func stream(
        _ data: Data,
        crc startingCRC: UInt32,
        absoluteOffset: UInt32,
        control: CBCharacteristic,
        packet: CBCharacteristic
    ) async throws -> UInt32 {
        guard let peripheral = connectedPeripheral else { throw DFUError.lostConnection }
        var crc = startingCRC
        var offset = absoluteOffset
        var sentInObject = 0
        var sinceReceipt = 0

        while sentInObject < data.count {
            try checkpoint()
            if !peripheral.canSendWriteWithoutResponse {
                try await waitUntilReady()
            }
            let mtu = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
            let length = min(mtu, data.count - sentInObject)
            let slice = data.subdata(in: sentInObject..<(sentInObject + length))
            peripheral.writeValue(slice, for: packet, type: .withoutResponse)
            crc = CRC32.update(crc, slice)
            offset += UInt32(length)
            sentInObject += length
            sinceReceipt += 1
            bytesSent = Int(offset)

            if prn > 0 && sinceReceipt >= prn {
                sinceReceipt = 0
                try await validateReceipt(expectedCRC: crc, expectedOffset: offset)
            } else {
                await Task.yield()
            }
        }

        let raw = try await writeControl(DFUProtocol.calculateCRC(), to: control, expecting: DFUProtocol.Opcode.calculateCRC)
        try matchChecksum(raw, expectedCRC: crc, expectedOffset: offset)
        return crc
    }

    private func validateReceipt(expectedCRC: UInt32, expectedOffset: UInt32) async throws {
        let notification = try await nextInbound(what: "waiting for a packet receipt")
        let payload = try DFUProtocol.parseResponse(notification, expecting: DFUProtocol.Opcode.calculateCRC)
        try matchChecksum(payload, expectedCRC: expectedCRC, expectedOffset: expectedOffset)
    }

    private func matchChecksum(_ payload: Data, expectedCRC: UInt32, expectedOffset: UInt32) throws {
        let checksum = try DFUProtocol.parseChecksum(payload)
        guard checksum.crc == expectedCRC, checksum.offset == expectedOffset else {
            throw DFUError.crcMismatch(
                expectedCRC: expectedCRC,
                gotCRC: checksum.crc,
                expectedOffset: expectedOffset,
                gotOffset: checksum.offset
            )
        }
    }

    private func selectObject(_ type: UInt8, control: CBCharacteristic) async throws -> DFUProtocol.ObjectInfo {
        let payload = try await writeControl(DFUProtocol.selectObject(type), to: control, expecting: DFUProtocol.Opcode.selectObject)
        return try DFUProtocol.parseObjectInfo(payload)
    }

    private func createObject(type: UInt8, size: Int, control: CBCharacteristic) async throws {
        _ = try await writeControl(
            DFUProtocol.createObject(type: type, size: UInt32(size)),
            to: control,
            expecting: DFUProtocol.Opcode.createObject
        )
    }

    private func execute(_ control: CBCharacteristic, lastObject: Bool) async throws {
        if lastObject {
            acceptDisconnectAsSuccess = true
        }
        do {
            _ = try await writeControl(DFUProtocol.execute(), to: control, expecting: DFUProtocol.Opcode.execute)
        } catch DFUError.resetComplete {
            if lastObject { return }
            throw DFUError.lostConnection
        }
    }

    // MARK: - GATT helpers

    private func loadFirmwareVersion(_ id: UUID, generation: Int) async {
        guard let peripheral = devices.first(where: { $0.id == id })?.peripheral else {
            if generation == versionGeneration {
                isReadingVersion = false
                if scanBeforeVersionRead { startScan() }
            }
            return
        }
        cancelled = false
        setFirmwareVersion(id, "Reading…")
        haltScan()
        defer {
            let current = generation == versionGeneration
            if current && !isBusy {
                releaseLink(resumeWaitersWith: nil)
                isReadingVersion = false
                if scanBeforeVersionRead {
                    startScan()
                }
            } else if !current && isBusy {
                isReadingVersion = false
            }
        }
        do {
            log("Reading firmware version.")
            try await connect(peripheral)
            guard generation == versionGeneration else { return }
            try await discoverGATT()
            guard generation == versionGeneration else { return }
            let version = try await queryFirmwareVersion()
            guard generation == versionGeneration else { return }
            setFirmwareVersion(id, version)
            log("Firmware version \(version).")
        } catch DFUError.cancelled {
            if generation != versionGeneration, selectedID != id,
               devices.first(where: { $0.id == id })?.firmwareVersion == "Reading…" {
                setFirmwareVersion(id, nil)
            }
        } catch {
            guard generation == versionGeneration else { return }
            setFirmwareVersion(id, "Version unavailable")
            log("Could not read firmware version: \(error.localizedDescription)")
        }
    }

    private func queryFirmwareVersion() async throws -> String {
        if let smp = find(NRFUUID.smpService, NRFUUID.smpCharacteristic) {
            try await setNotify(true, on: smp)
            var sequence: UInt8 = 0
            let state = try await sendSMP(
                operation: SMPProtocol.Operation.read,
                group: SMPProtocol.Group.image,
                command: SMPProtocol.Command.imageState,
                payload: SMPProtocol.emptyMap(),
                through: smp,
                sequence: &sequence
            )
            if let version = SMPProtocol.runningVersion(in: state.images) {
                return version
            }
        }
        if let revision = find(NRFUUID.deviceInformation, NRFUUID.firmwareRevision) {
            let data = try await readCharacteristic(revision)
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                return text
            }
        }
        throw DFUError.remote("This device does not report a firmware version.")
    }

    private func readCharacteristic(_ characteristic: CBCharacteristic) async throws -> Data {
        guard let peripheral = connectedPeripheral else { throw DFUError.lostConnection }
        return try await withTimeout("reading the firmware version", seconds: 10) { (shot: OneShot<Data>) in
            self.readShot = shot
            peripheral.readValue(for: characteristic)
        }
    }

    private func setFirmwareVersion(_ id: UUID, _ version: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].firmwareVersion = version
    }

    private func connect(_ peripheral: CBPeripheral) async throws {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            return
        }
        try await withTimeout("connecting to the device", seconds: 15) { shot in
            self.connectShot = shot
            self.central.connect(peripheral, options: nil)
        }
    }

    private func discoverGATT() async throws {
        guard let peripheral = connectedPeripheral else { throw DFUError.lostConnection }
        try await withTimeout("discovering services", seconds: 15) { shot in
            self.servicesShot = shot
            self.pendingCharacteristicDiscovers = 0
            peripheral.discoverServices(nil)
        }
    }

    private func setNotify(_ enabled: Bool, on characteristic: CBCharacteristic) async throws {
        guard let peripheral = connectedPeripheral else { throw DFUError.lostConnection }
        if characteristic.isNotifying == enabled { return }
        try await withTimeout("enabling notifications", seconds: 10) { shot in
            self.notifyShot = shot
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    private func writeControl(_ data: Data, to characteristic: CBCharacteristic, expecting operation: UInt8) async throws -> Data {
        guard let peripheral = connectedPeripheral else { throw DFUError.lostConnection }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        try await waitForWrite()
        let notification = try await nextInbound(what: "waiting for the bootloader")
        return try DFUProtocol.parseResponse(notification, expecting: operation)
    }

    private func waitForWrite() async throws {
        try await withTimeout("writing to the device", seconds: 15) { shot in
            self.writeShot = shot
        }
    }

    private func waitUntilReady() async throws {
        guard let peripheral = connectedPeripheral else { throw DFUError.lostConnection }
        try await withTimeout("waiting for the radio", seconds: 15) { shot in
            if peripheral.canSendWriteWithoutResponse {
                shot.resume(with: .success(()))
            } else {
                self.readyShot = shot
            }
        }
    }

    private func nextInbound(what: String) async throws -> Data {
        if !inbound.isEmpty {
            return inbound.removeFirst()
        }
        return try await withTimeout(what, seconds: 20) { (shot: OneShot<Data>) in
            self.inboundShot = shot
        }
    }

    private func waitForDisconnect() async throws {
        if connectedPeripheral?.state == .disconnected {
            return
        }
        try await withTimeout("waiting for the device to reset", seconds: 15) { shot in
            self.disconnectShot = shot
        }
    }

    private func waitForBootloader() async throws -> CBPeripheral {
        let peripheral: CBPeripheral = try await withTimeout("looking for the bootloader", seconds: 30) { shot in
            self.bootloaderShot = shot
            // Without a unique name, ignore advertisements for a moment so a
            // stale packet from the application is not treated as the bootloader.
            self.bootloaderScanAllowedAt = self.bootloaderToken == nil
                ? Date().addingTimeInterval(2)
                : .distantPast
            self.central.scanForPeripherals(
                withServices: [NRFUUID.secureService],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
        central.stopScan()
        try await connect(peripheral)
        return peripheral
    }

    private func find(_ service: CBUUID, _ characteristic: CBUUID) -> CBCharacteristic? {
        guard let services = connectedPeripheral?.services else { return nil }
        for item in services where item.uuid == service {
            if let match = item.characteristics?.first(where: { $0.uuid == characteristic }) {
                return match
            }
        }
        return nil
    }

    private func findServiceChanged() -> CBCharacteristic? {
        guard let services = connectedPeripheral?.services else { return nil }
        for service in services {
            if let match = service.characteristics?.first(where: { $0.uuid == NRFUUID.serviceChanged }) {
                return match
            }
        }
        return nil
    }

    private func checkpoint() throws {
        if cancelled { throw DFUError.cancelled }
    }

    private func finishSuccess() {
        uploadFinished = true
        acceptDisconnectAsSuccess = false
        phase = .success
        bytesSent = max(bytesSent, bytesTotal)
        statusLine = "Firmware sent. The device is restarting."
        log("Update complete.")
        releaseLink(resumeWaitersWith: nil)
    }

    private func finishCancel() {
        uploadFinished = true
        phase = .idle
        statusLine = "Upload cancelled."
        log("Upload cancelled.")
        releaseLink(resumeWaitersWith: nil)
    }

    private func finishFailure(_ error: Error) {
        uploadFinished = true
        acceptDisconnectAsSuccess = false
        phase = .failed
        statusLine = error.localizedDescription
        log("Failed: \(error.localizedDescription)")
        haltScan()
        releaseLink(resumeWaitersWith: error)
    }

    /// Drops the peripheral delegate so a late GATT callback cannot complete the next upload.
    private func releaseLink(resumeWaitersWith error: Error?) {
        let peripheral = connectedPeripheral
        peripheral?.delegate = nil
        if let error {
            failActive(error)
        } else {
            clearWaiters()
        }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting {
            suppressDisconnectID = peripheral.identifier
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func clearWaiters() {
        connectShot = nil
        disconnectShot = nil
        servicesShot = nil
        notifyShot = nil
        writeShot = nil
        readyShot = nil
        inboundShot = nil
        readShot = nil
        bootloaderShot = nil
    }

    private func failActive(_ error: Error) {
        connectShot?.resume(with: .failure(error))
        connectShot = nil
        disconnectShot?.resume(with: .failure(error))
        disconnectShot = nil
        servicesShot?.resume(with: .failure(error))
        servicesShot = nil
        notifyShot?.resume(with: .failure(error))
        notifyShot = nil
        writeShot?.resume(with: .failure(error))
        writeShot = nil
        readyShot?.resume(with: .failure(error))
        readyShot = nil
        inboundShot?.resume(with: .failure(error))
        inboundShot = nil
        readShot?.resume(with: .failure(error))
        readShot = nil
        bootloaderShot?.resume(with: .failure(error))
        bootloaderShot = nil
    }

    private func loadSecurityScopedFile(_ url: URL) throws -> (name: String, data: Data) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        return (url.lastPathComponent, data)
    }

    func record(_ message: String) {
        log(message)
    }

    private func log(_ message: String) {
        let stamp = Self.timestamp.string(from: Date())
        let line = "\(stamp)  \(message)"
        logLines.append(line)
        if logLines.count > 300 {
            logLines.removeFirst(logLines.count - 300)
        }
        print("[OTA] \(line)")
        fflush(stdout)
    }

    private func withTimeout<T>(
        _ what: String,
        seconds: Double,
        _ start: (OneShot<T>) -> Void
    ) async throws -> T {
        try checkpoint()
        return try await withCheckedThrowingContinuation { continuation in
            let shot = OneShot(continuation)
            start(shot)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            Task { @MainActor in
                if shot.resume(with: .failure(DFUError.timeout(what))) {
                    self.log("Timed out \(what).")
                }
            }
        }
        }
    }

    private func noteBluetooth(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            bluetoothReady = true
            bluetoothMessage = "Scanning for nRF devices"
            if !isBusy { startScan() }
        case .poweredOff:
            bluetoothReady = false
            bluetoothMessage = "Bluetooth is turned off."
            stopScan()
            devices.removeAll()
        case .unauthorized:
            bluetoothReady = false
            bluetoothMessage = "Bluetooth permission is turned off for this app."
            stopScan()
        case .unsupported:
            bluetoothReady = false
            bluetoothMessage = "This device does not support Bluetooth."
            stopScan()
        case .resetting:
            bluetoothReady = false
            bluetoothMessage = "Bluetooth is resetting…"
        default:
            bluetoothReady = false
            bluetoothMessage = "Starting Bluetooth…"
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private enum NRFUUID {
    static let secureService = CBUUID(string: "FE59")
    static let legacyService = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
    static let controlPoint = CBUUID(string: "8EC90001-F315-4F60-9FB8-838830DAEA50")
    static let packet = CBUUID(string: "8EC90002-F315-4F60-9FB8-838830DAEA50")
    static let buttonless = CBUUID(string: "8EC90003-F315-4F60-9FB8-838830DAEA50")
    static let buttonlessBonded = CBUUID(string: "8EC90004-F315-4F60-9FB8-838830DAEA50")
    static let serviceChanged = CBUUID(string: "2A05")
    static let smpService = CBUUID(string: "8D53DC1D-1DB7-4CD3-868B-8A527460AA84")
    static let smpCharacteristic = CBUUID(string: "DA2E7828-FBCE-4E01-AE9E-261174997C48")
    static let deviceInformation = CBUUID(string: "180A")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let nordicCompanyID: UInt16 = 0x0059
}

extension OTAController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.noteBluetooth(state)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        Task { @MainActor in
            if let shot = self.bootloaderShot {
                let allowedAt = self.bootloaderScanAllowedAt ?? .distantPast
                guard Date() >= allowedAt else { return }
                let token = self.bootloaderToken
                let haystack = [name, peripheral.name].compactMap { $0 }.joined(separator: " ")
                let nameMatch = token != nil && haystack.localizedCaseInsensitiveContains(token!)
                let serviceMatch = services.isEmpty || services.contains(NRFUUID.secureService)
                if nameMatch || (token == nil && serviceMatch) {
                    self.bootloaderShot = nil
                    central.stopScan()
                    shot.resume(with: .success(peripheral))
                }
                return
            }
            self.upsert(peripheral, advertisement: advertisementData, rssi: RSSI)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectShot?.resume(with: .success(()))
            self.connectShot = nil
            self.log("Connected.")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "The connection failed."
        Task { @MainActor in
            self.connectShot?.resume(with: .failure(DFUError.remote(message)))
            self.connectShot = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if self.suppressDisconnectID == peripheral.identifier {
                self.suppressDisconnectID = nil
                if let shot = self.disconnectShot {
                    self.disconnectShot = nil
                    shot.resume(with: .success(()))
                }
                self.log("Device disconnected.")
                return
            }
            if let shot = self.disconnectShot {
                self.disconnectShot = nil
                shot.resume(with: .success(()))
                self.log("Device disconnected.")
                return
            }
            if self.uploadFinished {
                return
            }
            if self.acceptDisconnectAsSuccess {
                self.acceptDisconnectAsSuccess = false
                self.failActive(DFUError.resetComplete)
                self.log("Device reset.")
                return
            }
            if self.connectShot != nil || self.isBusy || self.isReadingVersion {
                self.failActive(DFUError.lostConnection)
            }
        }
    }
}

extension OTAController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let resolved = error
        Task { @MainActor in
            if let resolved {
                self.servicesShot?.resume(with: .failure(resolved))
                self.servicesShot = nil
                return
            }
            let services = peripheral.services ?? []
            if services.isEmpty {
                self.servicesShot?.resume(with: .success(()))
                self.servicesShot = nil
                return
            }
            self.pendingCharacteristicDiscovers = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let resolved = error
        Task { @MainActor in
            if let resolved {
                self.servicesShot?.resume(with: .failure(resolved))
                self.servicesShot = nil
                return
            }
            guard self.servicesShot != nil else { return }
            self.pendingCharacteristicDiscovers -= 1
            if self.pendingCharacteristicDiscovers <= 0 {
                self.servicesShot?.resume(with: .success(()))
                self.servicesShot = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let resolved = error
        Task { @MainActor in
            if let resolved {
                self.notifyShot?.resume(with: .failure(self.mapATT(resolved)))
            } else {
                self.notifyShot?.resume(with: .success(()))
            }
            self.notifyShot = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let resolved = error
        Task { @MainActor in
            if let resolved {
                self.writeShot?.resume(with: .failure(self.mapATT(resolved)))
            } else {
                self.writeShot?.resume(with: .success(()))
            }
            self.writeShot = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        if uuid == NRFUUID.firmwareRevision {
            let value = characteristic.value ?? Data()
            let resolved = error
            Task { @MainActor in
                if let resolved {
                    self.readShot?.resume(with: .failure(self.mapATT(resolved)))
                } else {
                    self.readShot?.resume(with: .success(value))
                }
                self.readShot = nil
            }
            return
        }
        guard uuid == NRFUUID.controlPoint
                || uuid == NRFUUID.buttonless
                || uuid == NRFUUID.buttonlessBonded
                || uuid == NRFUUID.smpCharacteristic else {
            return
        }
        let value = characteristic.value ?? Data()
        let resolved = error
        Task { @MainActor in
            if let resolved {
                self.inboundShot?.resume(with: .failure(self.mapATT(resolved)))
                self.inboundShot = nil
                return
            }
            if let shot = self.inboundShot {
                self.inboundShot = nil
                shot.resume(with: .success(value))
            } else {
                self.inbound.append(value)
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            self.readyShot?.resume(with: .success(()))
            self.readyShot = nil
        }
    }

    private func mapATT(_ error: Error) -> Error {
        if let att = error as? CBATTError, att.code == .insufficientAuthentication || att.code == .insufficientEncryption {
            return DFUError.bondingRequired
        }
        return error
    }
}

/// Resumes a continuation at most once. Timeouts and BLE callbacks can both fire.
final class OneShot<Success>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Success, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Success, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Success, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}
