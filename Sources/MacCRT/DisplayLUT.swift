import CoreGraphics
import Foundation

/// Colour transform via per-display transfer tables (the mechanism f.lux uses).
///
/// IMPORTANT LIMITATION — this is a 1-D lookup applied independently to each
/// channel. It cannot mix channels per pixel, so it can push the picture toward
/// a hue but can never desaturate. Measured on a colour-bar test card: green
/// stays green and magenta stays magenta; only the cast changes. It is also
/// applied at display scanout, downstream of the framebuffer, so it does not
/// appear in screenshots or screen recordings.
///
/// True monochrome/amber needs the capture engine. This engine exists because it
/// costs nothing and needs no permission, which makes it a good default.
enum DisplayLUT {

    private static let tableSize = 256

    /// Displays we have written tables to, so we only restore what we touched.
    private static var touched: Set<CGDirectDisplayID> = []

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &list, &count) == .success else { return [] }
        return Array(list.prefix(Int(count)))
    }

    /// Push every active display toward `mode`'s tint by `intensity` (0...1),
    /// with `contrast` applied after the tint, pivoted at mid grey.
    static func apply(mode: CRTMode, intensity: Double, contrast: Double = 1.0) {
        let k = min(max(intensity, 0), 1)
        let tint = mode.tint
        let gain = min(max(contrast, 0.25), 3.0)

        // Build one curve per channel: g(x) = lo + (1-lo)*x, then scaled by the
        // tint. The lifted floor is what pulls pure blue toward the tint — it is
        // the only lever a per-channel curve has. Cost: blacks lift, contrast
        // drops. That is inherent, not a bug.
        let lo = 0.22 * k

        func curve(channel: Int) -> [CGGammaValue] {
            let t = Double(tint[channel])
            return (0..<tableSize).map { i in
                let x = Double(i) / Double(tableSize - 1)
                let lifted = lo + (1.0 - lo) * x
                let target = t * lifted
                // Blend against identity by k so intensity 0 is a true no-op.
                let blended = (1.0 - k) * x + k * target
                // Contrast last, so it can counter the wash from the lift above.
                let contrasted = 0.5 + (blended - 0.5) * gain
                return CGGammaValue(min(1.0, max(0.0, contrasted)))
            }
        }

        let r = curve(channel: 0)
        let g = curve(channel: 1)
        let b = curve(channel: 2)

        for id in activeDisplays() {
            let err = r.withUnsafeBufferPointer { rp in
                g.withUnsafeBufferPointer { gp in
                    b.withUnsafeBufferPointer { bp in
                        CGSetDisplayTransferByTable(
                            id, UInt32(tableSize),
                            rp.baseAddress, gp.baseAddress, bp.baseAddress
                        )
                    }
                }
            }
            if err == .success {
                touched.insert(id)
            } else {
                NSLog("MacCRT: CGSetDisplayTransferByTable failed for display %u (CGError %d)",
                      id, err.rawValue)
            }
        }
    }

    /// Restore every display we modified. Safe to call repeatedly, including on
    /// the way out via a signal handler.
    static func reset() {
        guard !touched.isEmpty else { return }
        CGDisplayRestoreColorSyncSettings()
        touched.removeAll()
    }
}
