import AppKit

/// A labelled slider with a live value readout.
final class SliderRow: NSStackView {
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")
    private let formatter: (Double) -> String
    private let onChange: (Double) -> Void

    init(title: String,
         value: Double,
         range: ClosedRange<Double>,
         formatter: @escaping (Double) -> String = { String(format: "%.2f", $0) },
         onChange: @escaping (Double) -> Void) {
        self.formatter = formatter
        self.onChange = onChange
        self.slider = NSSlider(value: value,
                               minValue: range.lowerBound,
                               maxValue: range.upperBound,
                               target: nil,
                               action: nil)
        super.init(frame: .zero)

        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        distribution = .fill

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.alignment = .right
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 96).isActive = true

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.widthAnchor.constraint(equalToConstant: 190).isActive = true

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                     weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .left
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        valueLabel.stringValue = formatter(value)

        addArrangedSubview(titleLabel)
        addArrangedSubview(slider)
        addArrangedSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(value: Double) {
        slider.doubleValue = value
        valueLabel.stringValue = formatter(value)
    }

    @objc private func sliderMoved() {
        valueLabel.stringValue = formatter(slider.doubleValue)
        onChange(slider.doubleValue)
    }
}

/// Compact floating control panel reached from the menu bar.
final class SettingsPanel: NSPanel {

    private let settings = Settings.shared

    private let enableSwitch = NSSwitch()
    private let modeControl: NSSegmentedControl
    private let noticeLabel = NSTextField(labelWithString: "")
    private let captureSwitch = NSSwitch()
    private let captureStatus = NSTextField(labelWithString: "")
    private var sliderRows: [SliderRow] = []
    private var openSystemSettingsButton: NSButton?

    init() {
        modeControl = NSSegmentedControl(labels: CRTMode.allCases.map { $0.displayName },
                                         trackingMode: .selectOne,
                                         target: nil, action: nil)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                   styleMask: [.titled, .closable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "CRT Overlay"
        isReleasedWhenClosed = false
        buildUI()
        refresh()
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Construction

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        // Master switch
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled)
        root.addArrangedSubview(rowing(label: "CRT effect", control: enableSwitch))

        // Mode picker
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        let modeRow = NSStackView()
        modeRow.orientation = .vertical
        modeRow.alignment = .leading
        modeRow.spacing = 6
        let modeTitle = NSTextField(labelWithString: "Phosphor")
        modeTitle.textColor = .secondaryLabelColor
        modeRow.addArrangedSubview(modeTitle)
        modeRow.addArrangedSubview(modeControl)
        root.addArrangedSubview(modeRow)

        noticeLabel.textColor = .systemOrange
        noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noticeLabel.preferredMaxLayoutWidth = 360
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.isHidden = true
        root.addArrangedSubview(noticeLabel)

        root.addArrangedSubview(separator())

        // Capture engine
        let captureTitle = NSTextField(labelWithString: "True CRT engine")
        captureTitle.textColor = .labelColor
        captureSwitch.target = self
        captureSwitch.action = #selector(captureToggled)
        let captureRow = NSStackView(views: [captureTitle, flexible(), captureSwitch])
        captureRow.orientation = .horizontal
        captureRow.spacing = 8
        root.addArrangedSubview(captureRow)

        captureStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        captureStatus.textColor = .secondaryLabelColor
        captureStatus.preferredMaxLayoutWidth = 360
        captureStatus.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(captureStatus)

        openSystemSettingsButton = NSButton(title: "Open Screen Recording settings…",
                                            target: self,
                                            action: #selector(openScreenRecordingSettings))
        openSystemSettingsButton?.bezelStyle = .rounded
        openSystemSettingsButton?.isHidden = true
        if let button = openSystemSettingsButton { root.addArrangedSubview(button) }

        root.addArrangedSubview(separator())

        // Effect parameters
        let rows: [(String, Double, ClosedRange<Double>, (Double) -> String, (Double) -> Void)] = [
            ("Colour strength", Double(settings.tintIntensity), 0...1,
             { String(format: "%.0f%%", $0 * 100) },
             { [weak self] in self?.settings.tintIntensity = $0 }),
            ("Contrast", Double(settings.contrast), 0.5...2.0,
             { String(format: "%.2fx", $0) },
             { [weak self] in self?.settings.contrast = $0 }),
            ("Scanlines", Double(settings.scanlineIntensity), 0...1, { String(format: "%.0f%%", $0 * 100) },
             { [weak self] in self?.settings.scanlineIntensity = $0 }),
            ("Line pitch", Double(settings.scanlinePitch), 1...8, { String(format: "%.1f px", $0) },
             { [weak self] in self?.settings.scanlinePitch = $0 }),
            ("Curvature", Double(settings.curvature), 0...0.5, { String(format: "%.2f", $0) },
             { [weak self] in self?.settings.curvature = $0 }),
            ("Vignette", Double(settings.vignette), 0...1, { String(format: "%.0f%%", $0 * 100) },
             { [weak self] in self?.settings.vignette = $0 }),
            ("Glow", Double(settings.bloom), 0...1, { String(format: "%.0f%%", $0 * 100) },
             { [weak self] in self?.settings.bloom = $0 }),
            ("Flicker", Double(settings.flicker), 0...0.2, { String(format: "%.2f", $0) },
             { [weak self] in self?.settings.flicker = $0 }),
        ]
        for (title, value, range, format, setter) in rows {
            let row = SliderRow(title: title, value: value, range: range,
                                formatter: format, onChange: setter)
            sliderRows.append(row)
            root.addArrangedSubview(row)
        }

        let hint = NSTextField(labelWithString:
            "Colour strength 0% keeps the original colours; 100% leaves only the "
            + "phosphor colour. On the colour-table engine the slider can only "
            + "cast, never fully replace colours.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 360
        hint.lineBreakMode = .byWordWrapping
        root.addArrangedSubview(hint)

        root.addArrangedSubview(separator())
        let resetButton = NSButton(title: "Reset to defaults", target: self,
                                   action: #selector(resetDefaults))
        resetButton.bezelStyle = .rounded
        root.addArrangedSubview(resetButton)

        contentView = NSView()
        contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        setContentSize(root.fittingSize)
    }

    private func rowing(label: String, control: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        let row = NSStackView(views: [title, flexible(), control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func flexible() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 360).isActive = true
        return box
    }

    // MARK: - State

    func refresh() {
        enableSwitch.state = settings.enabled ? .on : .off
        let modeIndex = CRTMode.allCases.firstIndex(of: settings.mode) ?? 0
        modeControl.selectedSegment = modeIndex
        captureSwitch.state = settings.useCaptureEngine ? .on : .off

        // Must out-rank the overlay window or the panel is hidden behind it.
        level = settings.enabled && settings.useCaptureEngine
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
            : .floating

        let needsCapture = settings.mode.requiresCaptureEngine
        noticeLabel.isHidden = !(needsCapture && !settings.useCaptureEngine)
        noticeLabel.stringValue = "\(settings.mode.displayName) needs the True CRT engine — "
            + "a per-channel colour table cannot desaturate."

        let permitted = CaptureEngine.hasPermission()
        captureStatus.stringValue = permitted
            ? "Captures the desktop so the shader can truly desaturate. Adds ~1 frame of latency; DRM video shows black."
            : "Requires Screen Recording permission. The real cursor still renders above the overlay at zero latency."
        openSystemSettingsButton?.isHidden = permitted

        // Re-seat sliders from the model so menu-driven changes stay in sync.
        rebuildSliderValues()
    }

    // MARK: - Actions

    @objc private func enableToggled() {
        settings.enabled = enableSwitch.state == .on
        refresh()
    }

    @objc private func modeChanged() {
        let index = modeControl.selectedSegment
        guard index >= 0, index < CRTMode.allCases.count else { return }
        settings.mode = CRTMode.allCases[index]
        refresh()
    }

    @objc private func captureToggled() {
        let wantsCapture = captureSwitch.state == .on
        if wantsCapture && !CaptureEngine.hasPermission() {
            CaptureEngine.requestPermission()
            // The grant only takes effect on next launch; surface that plainly
            // rather than silently rendering nothing.
            settings.useCaptureEngine = false
            _ = SettingsPanel.showPermissionAlert()
            refresh()
            return
        }
        settings.useCaptureEngine = wantsCapture
        refresh()
    }

    @objc private func resetDefaults() {
        settings.resetToDefaults()
        refresh()
    }

    private func rebuildSliderValues() {
        let values: [Double] = [
            settings.tintIntensity, settings.contrast, settings.scanlineIntensity,
            settings.scanlinePitch, settings.curvature, settings.vignette,
            settings.bloom, settings.flicker,
        ]
        for (row, value) in zip(sliderRows, values) { row.update(value: value) }
    }

    @objc private func openScreenRecordingSettings() {
        SettingsPanel.openScreenRecordingSettings()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    static func showPermissionAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        The True CRT engine captures the desktop so the shader can perform true \
        per-pixel desaturation (amber, red, sepia and monochrome).

        Enable \"CRT Overlay\" under System Settings ▸ Privacy & Security ▸ \
        Screen Recording, then relaunch the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
        return true
    }
}
