import SwiftUI
import AppKit

@main
struct SoundRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI Apps require at least one Scene. We use a Settings scene
        // as a placeholder and suppress its ⌘, menu item — all UI lives in
        // the menu bar status item managed by AppDelegate.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var lastShowInDock: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockVisibility()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        setupStatusItem()
        setupPopover()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "SoundRoute"
            )
            image?.isTemplate = true
            button.image = image
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 460)
        popover.contentViewController = NSHostingController(rootView: ContentView())
        popover.delegate = self
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let aboutItem = NSMenuItem(title: "About SoundRoute",
                                   action: #selector(showAbout),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let privacyItem = NSMenuItem(title: "Privacy Policy",
                                     action: #selector(openPrivacy),
                                     keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)

        let supportItem = NSMenuItem(title: "Support",
                                     action: #selector(openSupport),
                                     keyEquivalent: "")
        supportItem.target = self
        menu.addItem(supportItem)

        let githubItem = NSMenuItem(title: "View on GitHub",
                                    action: #selector(openGitHub),
                                    keyEquivalent: "")
        githubItem.target = self
        menu.addItem(githubItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SoundRoute",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        // Temporarily attach the menu so performClick presents it; clear it
        // afterward so subsequent left-clicks resume opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationName: "SoundRoute"
        ])
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(
            URL(string: "https://bscoggins.github.io/SoundRoute/privacy.html")!
        )
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(
            URL(string: "https://bscoggins.github.io/SoundRoute/support.html")!
        )
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(
            URL(string: "https://github.com/bscoggins/SoundRoute")!
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
