import Foundation

/// Observable, persisted state for the whole app.
///
/// Deliberately a plain class rather than `ObservableObject`: the UI is AppKit,
/// so a single `onChange` hook is simpler than a Combine graph.
final class Settings {
    static let shared = Settings()

    /// Fired after any mutation, once the value has already been stored.
    var onChange: (() -> Void)?

    /// When false, mutations still notify observers but are never written to
    /// disk. `--selftest` needs this: exercising every mode used to run through
    /// `resetToDefaults()` and silently wipe the user's saved look.
    var persistenceEnabled = true

    var enabled: Bool = false            { didSet { changed() } }
    var mode: CRTMode = .amber           { didSet { changed() } }
    var useCaptureEngine: Bool = false   { didSet { changed() } }
    /// Bake the cursor into the captured frame and hide the real one, so the
    /// pointer is tinted and scanlined with everything else. Costs ~1 frame of
    /// lag. Only meaningful on the capture engine.
    var includeCursor: Bool = true       { didSet { changed() } }

    /// 0 = original colours, 1 = only the selected phosphor colour.
    /// On the capture engine this is a true saturation control.
    var tintIntensity: Double = 1.00     { didSet { changed() } }
    /// Post-tint contrast, pivoted at mid grey. Undoes the flat, washed-out
    /// look that heavy desaturation produces.
    var contrast: Double = 1.00          { didSet { changed() } }
    var scanlineIntensity: Double = 0.35 { didSet { changed() } }
    var scanlinePitch: Double = 2.0      { didSet { changed() } }
    /// Geometric curvature. Defaults to 0: it is the one effect that can change
    /// what you can see, so it stays off until deliberately dialled in.
    var curvature: Double = 0.0          { didSet { changed() } }
    var vignette: Double = 0.45          { didSet { changed() } }
    var bloom: Double = 0.18             { didSet { changed() } }
    var flicker: Double = 0.03           { didSet { changed() } }

    private let defaults = UserDefaults.standard
    private static let key = "CRTOverlay.Settings.v1"
    private var loading = false

    private struct Snapshot: Codable {
        var enabled: Bool
        var mode: CRTMode
        var useCaptureEngine: Bool
        var includeCursor: Bool?
        var tintIntensity: Double
        var contrast: Double?
        var scanlineIntensity: Double
        var scanlinePitch: Double
        var curvature: Double
        var vignette: Double
        var bloom: Double
        var flicker: Double
    }

    private init() {
        load()
    }

    /// True when the renderer should drive frames continuously rather than
    /// redrawing only on change. Flicker and live capture both need a clock.
    var needsContinuousRendering: Bool {
        enabled && (flicker > 0.0001 || useCaptureEngine)
    }

    /// Clamped view of the effect parameters, for handing to the renderer.
    func normalized() -> (tint: Float, contrast: Float, scan: Float, pitch: Float,
                          curve: Float, vignette: Float, bloom: Float, flicker: Float) {
        func c(_ v: Double) -> Float { Float(min(max(v, 0), 1)) }
        return (
            tint: c(tintIntensity),
            contrast: Float(min(max(contrast, 0.25), 3.0)),
            scan: c(scanlineIntensity),
            pitch: Float(min(max(scanlinePitch, 1), 8)),
            curve: Float(min(max(curvature, 0), 0.6)),
            vignette: c(vignette),
            bloom: c(bloom),
            flicker: c(flicker)
        )
    }

    func resetToDefaults() {
        enabled = false
        mode = .amber
        useCaptureEngine = false
        includeCursor = true
        tintIntensity = 1.00
        contrast = 1.00
        scanlineIntensity = 0.35
        scanlinePitch = 2.0
        curvature = 0.0
        vignette = 0.45
        bloom = 0.18
        flicker = 0.03
    }

    // MARK: - Persistence

    private func changed() {
        guard !loading else { return }
        if persistenceEnabled { persist() }
        onChange?()
    }

    private func persist() {
        let snap = Snapshot(
            enabled: enabled, mode: mode, useCaptureEngine: useCaptureEngine,
            includeCursor: includeCursor,
            tintIntensity: tintIntensity, contrast: contrast,
            scanlineIntensity: scanlineIntensity,
            scanlinePitch: scanlinePitch, curvature: curvature,
            vignette: vignette, bloom: bloom, flicker: flicker
        )
        if let data = try? JSONEncoder().encode(snap) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        loading = true
        enabled = snap.enabled
        mode = snap.mode
        useCaptureEngine = snap.useCaptureEngine
        // Absent in settings written before the cursor option existed.
        includeCursor = snap.includeCursor ?? true
        tintIntensity = snap.tintIntensity
        // Settings written before contrast existed default to neutral.
        contrast = snap.contrast ?? 1.0
        scanlineIntensity = snap.scanlineIntensity
        scanlinePitch = snap.scanlinePitch
        curvature = snap.curvature
        vignette = snap.vignette
        bloom = snap.bloom
        flicker = snap.flicker
        loading = false
    }
}
