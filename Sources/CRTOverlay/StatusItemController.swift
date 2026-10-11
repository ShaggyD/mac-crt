import AppKit

/// Menu-bar item with quick controls; opens the settings panel for the rest.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let settings = Settings.shared
    private let statusItem: NSStatusItem
    private let panel: SettingsPanel
    private let coordinator: OverlayCoordinator

    private let enableItem = NSMenuItem(title: "CRT Effect", action: nil, keyEquivalent: "")
    private let captureItem = NSMenuItem(title: "True CRT Engine", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(coordinator: OverlayCoordinator) {
        self.coordinator = coordinator
        self.panel = SettingsPanel()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "CRT Overlay")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(enableItem)
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(captureItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showPanel), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Restore Display & Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuItems()
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuItems()
    }

    private func refreshMenuItems() {
        enableItem.target = self
        enableItem.action = #selector(toggleEnabled)
        enableItem.state = settings.enabled ? .on : .off

        captureItem.target = self
        captureItem.action = #selector(toggleCapture)
        captureItem.state = settings.useCaptureEngine ? .on : .off
        captureItem.isEnabled = CaptureEngine.hasPermission()

        statusLine.attributedTitle = statusTitle()
    }

    private func statusTitle() -> NSAttributedString {
        let text: String
        if !settings.enabled {
            text = "Idle"
        } else if settings.useCaptureEngine {
            switch coordinator.captureState {
            case .running:        text = "True CRT · \(settings.mode.displayName)"
            case .starting:       text = "True CRT · starting…"
            case .failed(let m):  text = "True CRT failed · \(m)"
            case .idle:           text = "True CRT · idle"
            }
        } else {
            text = "Colour table · \(settings.mode.displayName)"
        }
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        panel.refresh()
    }

    @objc private func toggleCapture() {
        if !settings.useCaptureEngine && !CaptureEngine.hasPermission() {
            CaptureEngine.requestPermission()
            SettingsPanel.showPermissionAlert()
            panel.refresh()
            return
        }
        settings.useCaptureEngine.toggle()
        panel.refresh()
    }

    @objc private func showPanel() {
        panel.refresh()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        coordinator.shutdown()
        NSApp.terminate(nil)
    }

    func captureStateDidChange() {
        refreshMenuItems()
        panel.refresh()
    }
}
