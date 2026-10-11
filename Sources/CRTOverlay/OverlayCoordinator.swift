import AppKit
import CoreVideo
import Metal

/// Owns every overlay window, both engines, and the render clock.
///
/// Two paths share one shader:
///   • LUT engine   — colour cast via display transfer tables (no permission),
///                    scanlines/vignette/bezel drawn by a transparent overlay.
///   • Capture engine — real captured pixels through the same shader, which adds
///                    true per-pixel desaturation and genuine barrel warping.
final class OverlayCoordinator {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    private var overlays: [OverlayWindow] = []
    private var latestFrames: [CGDirectDisplayID: CVPixelBuffer] = [:]
    private var timer: Timer?
    private let capture = CaptureEngine()
    private let settings = Settings.shared
    /// Tracks the last capture-engine request we acted on, so a failed stream is
    /// retried only when the user asks again rather than on every settings tick.
    private var appliedCaptureEngine = false
    private var isStartingCapture = false
    /// Re-entrancy guard. `sync()` can be reached from settings changes *and*
    /// from capture state changes, and without this the two call each other
    /// until the capture request never gets a chance to complete.
    private var syncing = false

    private(set) var captureState: CaptureState = .idle
    var onCaptureStateChange: ((CaptureState) -> Void)?

    var isEffectivelyRunning: Bool {
        settings.enabled && !overlays.isEmpty
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "CRTOverlay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No Metal device available."])
        }
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "CRTOverlay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create a Metal command queue."])
        }
        self.commandQueue = queue

        let library = try device.makeLibrary(source: CRTShader.source, options: nil)
        guard let vertexFunction = library.makeFunction(name: "crt_vertex"),
              let fragmentFunction = library.makeFunction(name: "crt_fragment") else {
            throw NSError(domain: "CRTOverlay", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Shader functions missing from library."])
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let created = cache else {
            throw NSError(domain: "CRTOverlay", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create a Metal texture cache."])
        }
        self.textureCache = created

        capture.onFrame = { [weak self] displayID, buffer in
            self?.store(frame: buffer, for: displayID)
        }
        capture.onStateChange = { [weak self] state in
            guard let self else { return }
            self.captureState = state
            switch state {
            case .running:
                self.isStartingCapture = false
                // Capture now owns colour. The fallback LUT was applied while the
                // stream spun up, so it has to be dropped here or the frame gets
                // the capture engine's colour *and* a second LUT cast on top.
                DisplayLUT.reset()
            case .failed:
                self.isStartingCapture = false
                // Never leave the user with bare scanlines over an untinted
                // desktop just because the stream died.
                self.applyFallbackColour()
            case .idle:
                self.isStartingCapture = false
            case .starting:
                break
            }
            self.onCaptureStateChange?(state)
            self.recordCaptureState(state)
            self.updateCursorVisibility()
        }
    }

    /// Writes the last capture outcome to Application Support. The menu shows
    /// this too, but a file survives a relaunch and makes "why is it only
    /// casting, not truly monochrome?" answerable without guessing.
    private func recordCaptureState(_ state: CaptureState) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CRTOverlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text: String
        switch state {
        case .idle:            text = "idle"
        case .starting:        text = "starting"
        case .running:         text = "running"
        case .failed(let why): text = "failed: \(why)"
        }
        try? text.write(to: dir.appendingPathComponent("capture-state.txt"),
                        atomically: true, encoding: .utf8)
    }

    // MARK: - Lifecycle

    func start() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        settings.onChange = { [weak self] in self?.sync() }
        sync()
    }

    @objc private func screensChanged() {
        // Displays moved/resized: tear the capture streams down so they are
        // rebuilt against the new display set, then rebuild the windows.
        capture.stop()
        latestFrames.removeAll()
        rebuildOverlays()
        sync()
    }

    /// The single place that reconciles current settings with running state.
    func sync() {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        if settings.enabled {
            ensureOverlays()

            let wantCapture = settings.useCaptureEngine
            // Deliberately no automatic permission request here. CGRequestScreenCaptureAccess()
            // blocks until the user answers, and sync() runs on the main thread
            // during startup — so asking automatically freezes the app with no
            // menu and no way to respond. The prompt is triggered from the menu
            // and the panel instead, where a human is actually waiting for it.
            if wantCapture {
                if !appliedCaptureEngine && !isStartingCapture {
                    isStartingCapture = true
                    // Capture owns colour from here; drop the LUT up front so the
                    // two are never applied to the same frame.
                    DisplayLUT.reset()
                    capture.start(targets: captureTargets(),
                                  excludingWindowNumbers: overlays.map { CGWindowID($0.windowNumber) },
                                  includeCursor: settings.includeCursor)
                }
            } else if appliedCaptureEngine {
                capture.stop()
                latestFrames.removeAll()
            }
            appliedCaptureEngine = wantCapture

            if !wantCapture || !captureState.isRunning {
                // Either the LUT engine by choice, or a graceful fallback while
                // a dead capture stream is sorted out.
                applyFallbackColour()
            }

            for overlay in overlays where !overlay.isVisible {
                overlay.orderFrontRegardless()
            }
            renderAll()
        } else {
            capture.stop()
            latestFrames.removeAll()
            appliedCaptureEngine = false
            isStartingCapture = false
            DisplayLUT.reset()
            for overlay in overlays { overlay.orderOut(nil) }
        }
        updateCursorVisibility()
        updateClock()
    }

    /// Only hide the pointer when the effect is genuinely painting it back from
    /// the captured frame. In every other state the real cursor must stay
    /// visible, or the mouse disappears with nothing drawn in its place.
    private func updateCursorVisibility() {
        let shouldHide = settings.enabled
            && settings.useCaptureEngine
            && settings.includeCursor
            && captureState.isRunning
        if shouldHide {
            SystemCursor.hide()
        } else {
            SystemCursor.show()
        }
    }

    /// Colour via the LUT engine on a transparent overlay.
    private func applyFallbackColour() {
        guard settings.enabled, !captureState.isRunning else { return }
        for overlay in overlays { overlay.setOpaqueRendering(false) }
        DisplayLUT.apply(mode: settings.mode,
                         intensity: settings.tintIntensity,
                         contrast: settings.contrast)
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        capture.stop()
        DisplayLUT.reset()
        // Never leave the machine with an invisible pointer.
        SystemCursor.show()
        for overlay in overlays { overlay.orderOut(nil) }
    }

    // MARK: - Overlays

    private func ensureOverlays() {
        let screens = NSScreen.screens
        let current = Set(overlays.compactMap { $0.screen.map(ObjectIdentifier.init) })
        let wanted = Set(screens.map(ObjectIdentifier.init))
        if current == wanted { return }
        rebuildOverlays()
    }

    private func rebuildOverlays() {
        for overlay in overlays { overlay.orderOut(nil) }
        overlays.removeAll()
        // Display geometry changed; cached frames belong to the old layout.
        latestFrames.removeAll()
        for screen in NSScreen.screens {
            let overlay = OverlayWindow(screen: screen, device: device)
            overlays.append(overlay)
        }
    }

    private func displayID(of window: NSWindow) -> CGDirectDisplayID? {
        guard let screen = window.screen else { return nil }
        return Self.displayID(of: screen)
    }

    /// Native backing pixel size per display, so capture and drawable match 1:1.
    private func captureTargets() -> [CGDirectDisplayID: CGSize] {
        var targets: [CGDirectDisplayID: CGSize] = [:]
        for overlay in overlays {
            guard let id = displayID(of: overlay), let screen = overlay.screen else { continue }
            let scale = screen.backingScaleFactor
            targets[id] = CGSize(width: screen.frame.width * scale,
                                 height: screen.frame.height * scale)
        }
        return targets
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    // MARK: - Frames

    private func store(frame buffer: CVPixelBuffer, for id: CGDirectDisplayID) {
        latestFrames[id] = buffer
        // Match the drawable to the capture resolution before the next draw.
        for overlay in overlays where displayID(of: overlay) == id {
            let size = CGSize(width: CVPixelBufferGetWidth(buffer),
                              height: CVPixelBufferGetHeight(buffer))
            if overlay.metalView.metalLayer.drawableSize != size {
                overlay.metalView.metalLayer.drawableSize = size
            }
            // First real frame: now it is safe to paint the whole framebuffer.
            if settings.useCaptureEngine {
                overlay.setOpaqueRendering(true)
            }
        }
    }

    // MARK: - Rendering

    private func updateClock() {
        if settings.needsContinuousRendering {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.renderAll()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func renderAll() {
        guard settings.enabled else { return }
        for overlay in overlays { render(overlay) }
    }

    private func render(_ overlay: OverlayWindow) {
        guard let displayID = displayID(of: overlay) else { return }
        let layer = overlay.metalView.metalLayer
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return }
        guard let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var sourceTexture: MTLTexture?
        var retainedCVTexture: CVMetalTexture?
        if settings.useCaptureEngine, let buffer = latestFrames[displayID] {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
            if status == kCVReturnSuccess, let cvTexture,
               let texture = CVMetalTextureGetTexture(cvTexture) {
                sourceTexture = texture
                retainedCVTexture = cvTexture
            }
        }

        var params = makeParams(drawableSize: layer.drawableSize,
                                hasCapture: sourceTexture != nil)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<CRTParams>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        // The CVMetalTexture wrapper must outlive the GPU's use of the backing
        // pixel buffer, or the cache can recycle it mid-frame. Handler has to be
        // registered *before* commit — Metal asserts otherwise.
        if let retainedCVTexture {
            commandBuffer.addCompletedHandler { _ in _ = retainedCVTexture }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeParams(drawableSize: CGSize,
                            hasCapture: Bool) -> CRTParams {
        let n = settings.normalized()
        let tint = settings.mode.tint
        var params = CRTParams()
        params.tint = SIMD4(tint.x, tint.y, tint.z, n.tint)
        params.effects = SIMD4(n.scan, n.pitch, n.curve, n.vignette)
        params.post = SIMD4(n.bloom, n.flicker,
                            Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)),
                            hasCapture ? 1 : 0)
        params.size = SIMD4(Float(drawableSize.width), Float(drawableSize.height), n.contrast, 0)
        return params
    }
}
