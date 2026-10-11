import AppKit
import Metal

/// A full-screen, click-through window that draws one Metal quad.
///
/// `ignoresMouseEvents` keeps every click, drag and scroll going to whatever is
/// underneath, so the overlay is purely cosmetic and never steals input.
final class OverlayWindow: NSWindow {

    let metalView: MetalOverlayView

    init(screen: NSScreen, device: MTLDevice) {
        self.metalView = MetalOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // Must use the 4-arg designated initializer. The `screen:` variant
        // re-dispatches to this one on `self`, which a subclass that declares
        // its own designated init does not inherit — and it traps at runtime.
        // Positioning via the screen's frame puts the window on the right display.
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Above the menu bar and Dock so the effect really is whole-screen.
        // Alerts and the Force Quit panel sit higher still.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false

        metalView.wantsLayer = true
        metalView.metalLayer.device = device
        metalView.metalLayer.pixelFormat = .bgra8Unorm
        metalView.metalLayer.framebufferOnly = true
        metalView.metalLayer.isOpaque = false
        contentView = metalView

        updateDrawableSize(for: screen)
    }

    func updateDrawableSize(for screen: NSScreen) {
        let scale = screen.backingScaleFactor
        metalView.metalLayer.drawableSize = CGSize(width: screen.frame.width * scale,
                                                   height: screen.frame.height * scale)
    }

    /// Capture mode paints the whole framebuffer, so the window can be opaque.
    /// Overlay mode must stay transparent for the desktop to show through.
    func setOpaqueRendering(_ opaque: Bool) {
        isOpaque = opaque
        backgroundColor = opaque ? .black : .clear
        metalView.metalLayer.isOpaque = opaque
    }
}

/// Backs the window with a `CAMetalLayer` instead of a drawing context.
final class MetalOverlayView: NSView {
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}
