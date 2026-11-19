import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var ota = OTAController()
    @State private var onlyOTA = true
    @State private var showBinImporter = false
    @State private var confirmUpload = false
    @State private var showLog = false

    private var visibleDevices: [DeviceItem] {
        onlyOTA ? ota.devices.filter(\.isOTA) : ota.devices
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scanHeader
                deviceList
            }
            .navigationTitle("nRF OTA")
            .modifier(InlineNavigationTitle())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(ota.isScanning ? "Stop" : "Scan") {
                        ota.toggleScan()
                    }
                    .disabled(!ota.bluetoothReady || ota.isBusy)
                }
                ToolbarItem(placement: .automatic) {
                    Button("Activity") { showLog = true }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                firmwarePanel
            }
        }
        .frame(minWidth: 420, minHeight: 640)
        .fileImporter(
            isPresented: $showBinImporter,
            allowedContentTypes: Self.binTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result, label: ".bin") { ota.importBin(from: $0) }
        }
        .confirmationDialog(
            "Upload firmware?",
            isPresented: $confirmUpload,
            titleVisibility: .visible
        ) {
            Button("Upload") { ota.startUpload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(isPresented: $showLog) {
            ActivityLogView(lines: ota.logLines)
        }
    }

    private var scanHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(ota.bluetoothMessage, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(visibleDevices.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("Devices", selection: $onlyOTA) {
                Text("nRF / DFU").tag(true)
                Text("All nearby").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(ota.isBusy)

            if !ota.bluetoothReady {
                Button("Open Bluetooth Settings", action: ota.openBluetoothSettings)
                    .font(.subheadline)
            }

            #if targetEnvironment(simulator)
            Text("The iOS Simulator has no Bluetooth radio. Run this on an iPhone, or run the Mac app.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            #endif
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var deviceList: some View {
        Group {
            if visibleDevices.isEmpty {
                ContentUnavailableView {
                    Label("No devices yet", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Looking for nRF54 SMP and Nordic Secure DFU. Switch to All nearby if the board is running an app and does not advertise the update service.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleDevices) { device in
                    Button {
                        ota.selectDevice(device.id)
                    } label: {
                        DeviceRow(device: device, selected: device.id == ota.selectedID)
                    }
                    .buttonStyle(.plain)
                    .disabled(ota.isBusy)
                }
                .listStyle(.plain)
            }
        }
    }

    private var firmwarePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ota.firmwareName ?? "No firmware selected")
                        .font(.headline)
                        .lineLimit(1)
                    if ota.firmwareName != nil {
                        Text("\(ByteCount.text(ota.firmwareSize))  ·  CRC \(hex32(ota.firmwareCRC))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose the application .bin to send.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Choose .bin") { chooseFile() }
                    .disabled(ota.isBusy)
            }

            if ota.isBusy {
                VStack(alignment: .leading, spacing: 8) {
                    if ota.bytesTotal > 0 {
                        ProgressView(value: ota.progress)
                        Text("\(ByteCount.text(ota.bytesSent)) of \(ByteCount.text(ota.bytesTotal))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    HStack {
                        Text(ota.statusLine)
                            .font(.subheadline)
                        Spacer()
                        Button("Cancel", role: .destructive, action: ota.cancelUpload)
                    }
                }
            } else {
                if ota.phase == .success {
                    Label(ota.statusLine, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else if ota.phase == .failed {
                    Label(ota.statusLine, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    confirmUpload = true
                } label: {
                    Label(uploadTitle, systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!ota.canUpload)
            }
        }
        .padding()
        .background(.bar)
    }

    private static let binTypes: [UTType] = [UTType(filenameExtension: "bin") ?? .data, .data]

    private func chooseFile() {
        ota.record("Choose .bin clicked")
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = Self.binTypes
        panel.title = "Choose .bin"
        panel.prompt = "Choose"
        panel.message = "Select a .bin file"
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        ota.record(window == nil ? "Opening file panel as a modal window" : "Opening file panel on \(window!.title)")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            ota.record("File panel closed with response \(response.rawValue)")
            guard response == .OK, let url = panel.url else {
                ota.record("No file selected")
                return
            }
            ota.record("Selected \(url.path)")
            ota.importBin(from: url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
        #else
        showBinImporter = true
        #endif
    }

    private func handleImport(_ result: Result<[URL], Error>, label: String, importURL: (URL) -> Void) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                ota.record("\(label) picker returned no file")
                return
            }
            ota.record("\(label) picker selected \(url.path)")
            importURL(url)
        case .failure(let error):
            ota.record("\(label) picker failed: \(error.localizedDescription)")
        }
    }

    private var uploadTitle: String {
        if let name = ota.selectedDevice?.name {
            return "Upload to \(name)"
        }
        return "Select a device"
    }

    private var confirmMessage: String {
        let file = ota.firmwareName ?? "firmware"
        let device = ota.selectedDevice?.name ?? "the device"
        return "\(file) will be sent to \(device). The device will reset if the update is accepted."
    }
}

private struct DeviceRow: View {
    let device: DeviceItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: signalSymbol)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let badge = device.badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(deviceSubtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var deviceSubtitle: String {
        if selected, let version = device.firmwareVersion, !version.isEmpty {
            return "\(version) · \(device.rssi) dBm"
        }
        return "\(device.rssi) dBm"
    }

    private var signalSymbol: String {
        switch device.rssi {
        case -55...0: "cellularbars"
        case -75 ..< -55: "chart.bar.fill"
        default: "antenna.radiowaves.left.and.right"
        }
    }
}

private struct ActivityLogView: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "text.alignleft")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding()
                        }
                        .onAppear { scrollToEnd(proxy) }
                        .onChange(of: lines.count) { _, _ in scrollToEnd(proxy) }
                    }
                }
            }
            .navigationTitle("Activity")
            .modifier(InlineNavigationTitle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy") { copy() }
                        .disabled(lines.isEmpty)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = lines.indices.last else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    private func copy() {
        let text = lines.joined(separator: "\n")
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

private struct InlineNavigationTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

private enum ByteCount {
    static func text(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
