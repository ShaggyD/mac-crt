import CoreGraphics
import Foundation

/// Hides and restores the hardware cursor.
///
/// The cursor hide counter is global and **outlives the process that changed
/// it**. If this app died while the cursor was hidden, you would be left with an
/// invisible pointer and no obvious way to recover. So `heal()` is called
/// unconditionally on every launch, exactly like the colour-table restore —
/// a previous crash must never be able to strand the mouse.
enum SystemCursor {

    /// Displays we have hidden the cursor on, so we only ever undo our own work.
    private static var hiddenOn: Set<CGDirectDisplayID> = []

    static func hide() {
        for id in DisplayLUT.activeDisplays() where !hiddenOn.contains(id) {
            CGDisplayHideCursor(id)
            hiddenOn.insert(id)
        }
    }

    static func show() {
        for id in hiddenOn {
            CGDisplayShowCursor(id)
        }
        hiddenOn.removeAll()
    }

    /// Unconditional restore, for launch. Returns the counter to zero even if a
    /// previous run died without cleaning up, so a stale hide cannot persist.
    static func heal() {
        for id in DisplayLUT.activeDisplays() {
            CGDisplayShowCursor(id)
        }
        hiddenOn.removeAll()
    }
}
