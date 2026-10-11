import Foundation
import simd

/// One of the four phosphor palettes.
enum CRTMode: String, CaseIterable, Codable {
    case amber
    case red
    case sepia
    case monochrome

    var displayName: String {
        switch self {
        case .amber:      return "Amber"
        case .red:        return "Red"
        case .sepia:      return "Sepia"
        case .monochrome: return "Monochrome"
        }
    }

    /// Linear RGB the picture is pushed toward. Shared by both engines so the
    /// two paths agree on what "amber" means.
    var tint: SIMD3<Float> {
        switch self {
        case .amber:      return SIMD3(1.00, 0.66, 0.15)
        case .red:        return SIMD3(1.00, 0.22, 0.12)
        case .sepia:      return SIMD3(0.94, 0.78, 0.55)
        case .monochrome: return SIMD3(1.00, 1.00, 1.00)
        }
    }

    /// True monochrome is luminance *replicated* across three channels, which
    /// needs per-pixel channel mixing. The LUT engine applies one 1-D curve per
    /// channel and therefore cannot desaturate. Only the capture engine can.
    var requiresCaptureEngine: Bool { self == .monochrome }
}
