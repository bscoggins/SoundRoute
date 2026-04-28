import SwiftUI
import AppKit

@main
struct SoundRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lastShowInDock: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockVisibility()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func defaultsDidChange() {
        applyDockVisibility()
    }

    private func applyDockVisibility() {
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        guard showInDock != lastShowInDock else { return }
        lastShowInDock = showInDock
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
