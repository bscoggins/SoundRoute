import SwiftUI
import CoreAudio
import ServiceManagement

struct ContentView: View {
    @StateObject private var deviceManager = AudioDeviceManager()
    @StateObject private var audioManager = AudioManager()
    @StateObject private var dailyUsageTracker = DailyUsageTracker()
    @EnvironmentObject private var storeManager: StoreManager

    @State private var selectedInputDevice: AudioDevice?
    @State private var selectedOutputDevice: AudioDevice?
    @State private var showingPaywall = false

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
                VStack(spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                    if audioManager.isMicrophoneDenied {
                        Button("Open System Settings") {
                            // Modern System Settings URL on macOS 14+; the
                            // ?Privacy_Microphone anchor scrolls to the mic
                            // subsection on launch.
                            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            restoreSelections()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            audioManager.dailyUsageTracker = dailyUsageTracker
            audioManager.handleUnlockStateChange(unlocked: storeManager.isUnlocked)
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
        .onChange(of: storeManager.isUnlocked) { _, unlocked in
            audioManager.handleUnlockStateChange(unlocked: unlocked)
        }
        .onChange(of: audioManager.dailyLimitReached) { _, reached in
            if reached {
                showingPaywall = true
                audioManager.dailyLimitReached = false
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(storeManager: storeManager)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(audioManager.isRunning ? 0.18 : 0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: audioManager.isRunning ? "waveform" : "waveform.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusTint)
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

            helpMenu
        }
    }

    private var helpMenu: some View {
        Menu {
            Button("About SoundRoute") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(options: [
                    NSApplication.AboutPanelOptionKey.applicationName: "SoundRoute"
                ])
            }
            Divider()
            Link("Privacy Policy",
                 destination: URL(string: "https://bscoggins.github.io/SoundRoute/privacy.html")!)
            Link("Support",
                 destination: URL(string: "https://bscoggins.github.io/SoundRoute/support.html")!)
            Link("View on GitHub",
                 destination: URL(string: "https://github.com/bscoggins/SoundRoute")!)
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
        .tint(.secondary)
        .foregroundStyle(.secondary)
        .help("Help")
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
            // If the user has burned through the daily free budget and
            // isn't unlocked, route the tap straight to the paywall
            // rather than try (and silently fail) to start audio.
            if !storeManager.isUnlocked && dailyUsageTracker.isLimitReached && !audioManager.isRunning {
                showingPaywall = true
                return
            }
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

            if !storeManager.isUnlocked {
                Button {
                    showingPaywall = true
                } label: {
                    Label("Unlock unlimited routing", systemImage: "lock.open")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.top, 2)
            }

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
            }
            .padding(.top, 2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusText: String {
        // Free users see a "left today" suffix so they understand why
        // routing eventually stops. Unlocked users see the clean text.
        let freeSuffix = storeManager.isUnlocked
            ? ""
            : " · \(formatRemaining(dailyUsageTracker.remainingSecondsToday)) left today"

        if audioManager.isRunning {
            return "Routing\(freeSuffix)"
        }
        if !storeManager.isUnlocked && dailyUsageTracker.isLimitReached {
            return "Daily free limit reached"
        }
        if selectedInputDevice != nil && selectedOutputDevice != nil {
            return "Ready\(freeSuffix)"
        }
        return "Select input and output"
    }

    private var statusTint: Color {
        guard audioManager.isRunning else { return .secondary }
        // Pulse amber in the final minute of the daily budget so the
        // user has a visual heads-up before routing cuts out.
        if !storeManager.isUnlocked && dailyUsageTracker.remainingSecondsToday <= 60 {
            return .orange
        }
        return .green
    }

    private func formatRemaining(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        let s = max(0, seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func restoreSelections() {
        selectedInputDevice = SelectionResolver.restoredDevice(
            from: deviceManager.inputDevices,
            savedUID: savedInputUID,
            systemDefault: deviceManager.getDefaultInputDevice()
        )
        selectedOutputDevice = SelectionResolver.restoredDevice(
            from: deviceManager.outputDevices,
            savedUID: savedOutputUID,
            systemDefault: deviceManager.getDefaultOutputDevice()
        )
    }

    private func reconcileSelection(isInput: Bool) {
        let devices = isInput ? deviceManager.inputDevices : deviceManager.outputDevices
        let current = isInput ? selectedInputDevice : selectedOutputDevice
        guard let current else { return }

        switch SelectionResolver.reconcile(current: current, against: devices) {
        case .unchanged:
            break
        case .updated(let refreshed):
            if isInput {
                selectedInputDevice = refreshed
            } else {
                selectedOutputDevice = refreshed
            }
        case .disconnected:
            if audioManager.isRunning {
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
        .environmentObject(StoreManager.shared)
}
