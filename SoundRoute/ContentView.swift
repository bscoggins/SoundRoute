import SwiftUI
import CoreAudio
import ServiceManagement

struct ContentView: View {
    @StateObject private var deviceManager = AudioDeviceManager()
    @StateObject private var audioManager = AudioManager()

    @State private var selectedInputDevice: AudioDevice?
    @State private var selectedOutputDevice: AudioDevice?

    @AppStorage("showInDock") private var showInDock = false
    @AppStorage("savedInputUID") private var savedInputUID: String = ""
    @AppStorage("savedOutputUID") private var savedOutputUID: String = ""
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            devicePicker(
                title: "Input",
                systemImage: "mic.fill",
                devices: deviceManager.inputDevices,
                selection: $selectedInputDevice
            )
            .disabled(audioManager.isRunning)

            devicePicker(
                title: "Output",
                systemImage: "speaker.wave.2.fill",
                devices: deviceManager.outputDevices,
                selection: $selectedOutputDevice
            )
            .disabled(audioManager.isRunning)

            actionButton

            if let error = audioManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            restoreSelections()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: selectedInputDevice) { _, new in
            savedInputUID = new?.uid ?? ""
        }
        .onChange(of: selectedOutputDevice) { _, new in
            savedOutputUID = new?.uid ?? ""
        }
        .onChange(of: deviceManager.inputDevices) { _, _ in
            reconcileSelection(isInput: true)
        }
        .onChange(of: deviceManager.outputDevices) { _, _ in
            reconcileSelection(isInput: false)
        }
        .onChange(of: launchAtLogin) { _, newValue in
            applyLaunchAtLogin(newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(audioManager.isRunning ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: audioManager.isRunning ? "waveform" : "waveform.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(audioManager.isRunning ? .green : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: audioManager.isRunning)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("SoundRoute")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                deviceManager.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Refresh devices")
        }
    }

    private func devicePicker(
        title: String,
        systemImage: String,
        devices: [AudioDevice],
        selection: Binding<AudioDevice?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Menu {
                ForEach(devices) { device in
                    Button(device.name) { selection.wrappedValue = device }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selection.wrappedValue?.name ?? "No device available")
                        .foregroundStyle(selection.wrappedValue == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionButton: some View {
        Button {
            if let input = selectedInputDevice {
                audioManager.setInputDevice(input.id)
            }
            if let output = selectedOutputDevice {
                audioManager.setOutputDevice(output.id)
            }
            audioManager.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: audioManager.isRunning ? "stop.fill" : "play.fill")
                Text(audioManager.isRunning ? "Stop Routing" : "Start Routing")
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(audioManager.isRunning ? .red : .accentColor)
        .disabled(selectedInputDevice == nil || selectedOutputDevice == nil)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show Dock icon", isOn: $showInDock)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            HStack {
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .keyboardShortcut("q")
                Spacer()
            }
            .padding(.top, 2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusText: String {
        if audioManager.isRunning {
            return "Routing audio"
        } else if selectedInputDevice != nil && selectedOutputDevice != nil {
            return "Ready"
        } else {
            return "Select input and output"
        }
    }

    private func restoreSelections() {
        selectedInputDevice = restoredDevice(
            from: deviceManager.inputDevices,
            savedUID: savedInputUID,
            systemDefault: deviceManager.getDefaultInputDevice()
        )
        selectedOutputDevice = restoredDevice(
            from: deviceManager.outputDevices,
            savedUID: savedOutputUID,
            systemDefault: deviceManager.getDefaultOutputDevice()
        )
    }

    private func restoredDevice(
        from devices: [AudioDevice],
        savedUID: String,
        systemDefault: AudioDeviceID?
    ) -> AudioDevice? {
        if !savedUID.isEmpty,
           let saved = devices.first(where: { $0.uid == savedUID }) {
            return saved
        }
        if let systemDefault {
            return devices.first { $0.id == systemDefault }
        }
        return nil
    }

    /// Re-resolve a selection by UID after the device list changes. If the
    /// device disappeared while routing, stop and surface a clean error.
    private func reconcileSelection(isInput: Bool) {
        let devices = isInput ? deviceManager.inputDevices : deviceManager.outputDevices
        let current = isInput ? selectedInputDevice : selectedOutputDevice
        guard let current else { return }

        if let updated = devices.first(where: { $0.uid == current.uid }) {
            if isInput {
                if updated.id != selectedInputDevice?.id { selectedInputDevice = updated }
            } else {
                if updated.id != selectedOutputDevice?.id { selectedOutputDevice = updated }
            }
        } else {
            let wasRunning = audioManager.isRunning
            if wasRunning {
                audioManager.stop()
                audioManager.errorMessage = "\(current.name) was disconnected"
            }
            if isInput {
                selectedInputDevice = nil
            } else {
                selectedOutputDevice = nil
            }
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert the toggle to whatever the system actually reports.
            DispatchQueue.main.async {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

#Preview {
    ContentView()
}
