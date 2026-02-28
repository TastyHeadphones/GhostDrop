import SwiftUI

struct ContentView: View {
    @StateObject private var model = MacAppViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Mode", selection: $model.mode) {
                Text("Receive").tag(MacAppViewModel.Mode.receive)
                Text("Send").tag(MacAppViewModel.Mode.send)
            }
            .pickerStyle(.segmented)
            .onChange(of: model.mode) { _, mode in
                model.setMode(mode)
            }

            statusPanel

            if model.mode == .send {
                sendPanel
            }

            if model.showingPairing, let sas = model.sasCode {
                pairingPanel(code: sas)
            }

            if let progress = model.progress {
                transferPanel(progress: progress)
            }

            logsPanel
        }
        .padding(20)
        .task {
            model.setMode(model.mode)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
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
    }

    private var sendPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose File") {
                    model.chooseFile()
                }
                if let selected = model.selectedFileURL {
                    Text(selected.lastPathComponent)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Send File") {
                    model.sendSelectedFile()
                }
                .disabled(model.selectedFileURL == nil)

                Button("Export Logs") {
                    model.exportLogs()
                }
            }

            Text("Nearby Devices")
                .font(.headline)

            List(model.nearbyDevices) { device in
                HStack {
                    VStack(alignment: .leading) {
                        Text(device.displayName)
                        Text("RSSI \(device.rssi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        model.connect(to: device)
                    }
                }
            }
            .frame(minHeight: 140)
        }
    }

    private func pairingPanel(code: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pairing")
                .font(.headline)
            Text("Compare code on both devices")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 32, weight: .bold, design: .rounded))

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
        }
    }

    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Logs")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.logs.enumerated()), id: \.offset) { _, entry in
                        Text("[\(entry.level)] \(entry.message)")
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minHeight: 120)
        }
    }
}
