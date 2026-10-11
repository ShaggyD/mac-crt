import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: OverlayCoordinator?
    private var statusController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Heal any colour state left behind by a previous crash: a gamma table
        // survives the process that set it, so a clean slate on every launch is
        // the only way to guarantee the display is never stuck tinted.
        CGDisplayRestoreColorSyncSettings()

        installSignalHandlers()

        do {
            let coordinator = try OverlayCoordinator()
            self.coordinator = coordinator
            let status = StatusItemController(coordinator: coordinator)
            coordinator.onCaptureStateChange = { [weak status] _ in
                status?.captureStateDidChange()
            }
            self.statusController = status
            coordinator.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "CRT Overlay could not start"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    /// A gamma table outlives its process, so a SIGTERM (or Ctrl-C when running
    /// from a terminal) must still restore the display.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                DisplayLUT.reset()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared

if CommandLine.arguments.contains("--reset") {
    CGDisplayRestoreColorSyncSettings()
    print("Display colour state reset.")
    exit(0)
}

if CommandLine.arguments.contains("--check-access") {
    print("Screen Recording permission: \(CaptureEngine.hasPermission() ? "granted" : "not granted")")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    // Exercises the parts that only fail at runtime: Metal pipeline creation and
    // the whole settings-panel construction/refresh path across every mode.
    app.setActivationPolicy(.accessory)
    do {
        let coordinator = try OverlayCoordinator()
        let panel = SettingsPanel()
        for mode in CRTMode.allCases {
            Settings.shared.mode = mode
            panel.refresh()
        }
        Settings.shared.resetToDefaults()
        panel.refresh()
        coordinator.shutdown()
        print("selftest ok: panel \(Int(panel.frame.width))x\(Int(panel.frame.height)), all modes refreshed")
        exit(0)
    } catch {
        print("selftest FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
