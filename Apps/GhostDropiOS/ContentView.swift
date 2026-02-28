import SwiftUI

struct ContentView: View {
    @StateObject private var model = IOSAppViewModel()
    @State private var showingFilePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Mode", selection: $model.mode) {
                        Text("Receive").tag(IOSAppViewModel.Mode.receive)
                        Text("Send").tag(IOSAppViewModel.Mode.send)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.mode) { _, mode in
                        model.setMode(mode)
                    }

                    statusCard

                    if model.mode == .send {
                        sendPanel
                    }

                    if model.showingPairing, let sasCode = model.sasCode {
                        pairingPanel(code: sasCode)
                    }

                    if let progress = model.progress {
                        transferPanel(progress: progress)
                    }

                    logsPanel
                }
                .padding(16)
            }
            .navigationTitle("GhostDrop iOS")
        }
        .task {
            model.setMode(model.mode)
        }
        .sheet(isPresented: $showingFilePicker) {
            IOSDocumentPicker { url in
                model.selectFile(url: url)
                showingFilePicker = false
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.headline)
            Text("State: \(model.state.rawValue)")
            if let transport = model.activeTransport {
                Text("Transport: \(transport.rawValue.uppercased())")
            }
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sendPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send")
                .font(.headline)

            Button("Choose File") {
                showingFilePicker = true
            }

            if let selected = model.selectedFileURL {
                Text(selected.lastPathComponent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Send File") {
                model.sendSelectedFile()
            }
            .disabled(model.selectedFileURL == nil)

            Text("Nearby Receivers")
                .font(.subheadline)

            if model.nearbyDevices.isEmpty {
                Text("No devices discovered yet.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            ForEach(model.nearbyDevices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.displayName)
                        Text("RSSI \(device.rssi) • L2CAP \(device.capabilities.supportsL2CAP ? "yes" : "no")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        model.connect(to: device)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func pairingPanel(code: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pairing Verification")
                .font(.headline)
            Text("Compare this 6-digit code on both devices:")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 34, weight: .bold, design: .rounded))

            HStack {
                Button("Codes Match") {
                    model.confirmSAS(match: true)
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    model.confirmSAS(match: false)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func transferPanel(progress: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transfer")
                .font(.headline)
            ProgressView(value: progress.fractionCompleted)
            Text("\(progress.bytesTransferred) / \(progress.totalBytes) bytes")
                .font(.footnote)
            Text(String(format: "%.1f KB/s", progress.throughputBytesPerSecond / 1024.0))
                .font(.footnote)
            if let eta = progress.etaSeconds {
                Text("ETA: \(Int(eta))s")
                    .font(.footnote)
            }
            Text("Transport: \(progress.transport.rawValue.uppercased())")
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Export NDJSON") {
                    model.exportLogs()
                }
                .font(.footnote)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, entry in
                        Text("[\(entry.level)] \(entry.message)")
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 200)
        }
    }
}
