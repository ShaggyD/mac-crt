import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: OverlayCoordinator?
    private var statusController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Heal any state left behind by a previous crash: a gamma table survives
        // the process that set it, and so does the cursor hide counter. A clean
        // slate on every launch is the only way to guarantee the display is not
        // stuck tinted and the pointer is not stuck invisible.
        CGDisplayRestoreColorSyncSettings()
        SystemCursor.heal()

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
                SystemCursor.show()
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
    // Also un-hide the pointer: a stuck invisible cursor is the worse failure.
    SystemCursor.heal()
    print("Display colour state and cursor visibility reset.")
    exit(0)
}

if CommandLine.arguments.contains("--check-access") {
    print("Screen Recording permission: \(CaptureEngine.hasPermission() ? "granted" : "not granted")")
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    // Exercises the parts that only fail at runtime: Metal pipeline creation and
    // the whole settings-panel construction/refresh path across every mode.
    // Persistence is suspended so a diagnostic run cannot clobber saved settings.
    app.setActivationPolicy(.accessory)
    Settings.shared.persistenceEnabled = false
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

if CommandLine.arguments.contains("--selftest-capture") {
    // Invasive integration test: brings the effect up for real, then changes the
    // frame rate and confirms the stream is rebuilt rather than left dead. Only
    // meaningful with Screen Recording granted, so it skips cleanly without it.
    app.setActivationPolicy(.accessory)
    Settings.shared.persistenceEnabled = false
    guard CaptureEngine.hasPermission() else {
        print("selftest-capture SKIPPED: Screen Recording not granted")
        exit(0)
    }
    do {
        let coordinator = try OverlayCoordinator()
        let settings = Settings.shared
        settings.enabled = true
        settings.useCaptureEngine = true
        settings.includeCursor = false
        settings.frameRate = 60
        coordinator.start()

        func settle(_ label: String) -> Bool {
            for _ in 0..<100 {
                switch coordinator.captureState {
                case .running:
                    print("  \(label): running")
                    return true
                case .failed(let why):
                    print("  \(label): FAILED \(why)")
                    return false
                default:
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                }
            }
            print("  \(label): timed out")
            return false
        }

        var ok = settle("60 fps")
        settings.frameRate = 30
        coordinator.sync()
        ok = settle("30 fps after change") && ok
        settings.frameRate = 60
        coordinator.sync()
        ok = settle("60 fps after change") && ok

        coordinator.shutdown()
        print(ok ? "selftest-capture ok" : "selftest-capture FAILED")
        exit(ok ? 0 : 1)
    } catch {
        print("selftest-capture FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
