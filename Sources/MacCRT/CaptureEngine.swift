import Foundation
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum CaptureState: Equatable {
    case idle
    case starting
    case running
    case failed(String)

    var isRunning: Bool { self == .running }
}

/// ScreenCaptureKit wrapper: one `SCStream` per display.
///
/// This is the only mechanism on macOS that yields the real composited desktop
/// as pixels, which is what makes true per-pixel desaturation possible.
final class CaptureEngine {

    var onFrame: ((CGDirectDisplayID, CVPixelBuffer) -> Void)?
    var onStateChange: ((CaptureState) -> Void)?

    private(set) var state: CaptureState = .idle

    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var sinks: [CGDirectDisplayID: StreamSink] = [:]
    private let sampleQueue = DispatchQueue(label: "com.dchadwick.crtoverlay.capture",
                                            qos: .userInteractive)
    private var generation = 0

    private func setState(_ new: CaptureState) {
        // Idempotent: state changes fan out to the menu and panel, so re-asserting
        // the same value on every settings tick would churn the UI for nothing.
        guard state != new else { return }
        state = new
        NSLog("MacCRT: capture state -> %@", String(describing: new))
        onStateChange?(new)
    }

    /// Ask the system for Screen Recording permission without starting a stream.
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the one-time system prompt if permission has not been granted.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// `targets` maps each display to the pixel size to capture at.
    ///
    /// This must be the *backing* size (points x backingScaleFactor), not
    /// `CGDisplayPixelsWide`. On a HiDPI panel that call returns the logical
    /// width in points, so using it captured at half resolution and let the
    /// compositor upscale 2x into the drawable — a uniformly soft picture, and
    /// enough resampling to erase fine scanline patterns entirely.
    func start(targets: [CGDirectDisplayID: CGSize],
               excludingWindowNumbers: [CGWindowID],
               includeCursor: Bool,
               frameRate: Double) {
        guard streams.isEmpty else { return }
        generation += 1
        let gen = generation
        setState(.starting)

        Task {
            do {
                let content = try await SCShareableContent.current
                let excluded = content.windows.filter { excludingWindowNumbers.contains($0.windowID) }

                for (id, pixelSize) in targets {
                    guard gen == self.generation else { return }
                    guard let display = content.displays.first(where: { $0.displayID == id }) else {
                        NSLog("MacCRT: no SCDisplay for display %u", id)
                        continue
                    }

                    let filter = SCContentFilter(display: display, excludingWindows: excluded)
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(pixelSize.width))
                    config.height = max(1, Int(pixelSize.height))
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.queueDepth = 3
                    // The frame interval is fixed when the stream is created, so a
                    // change to this requires rebuilding the stream.
                    let fps = min(max(frameRate, 1), 120)
                    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                    // The real cursor is composited by the window server *above*
                    // every window, so when it is left visible it sits on top of
                    // this overlay untinted and at zero latency. To make the
                    // cursor part of the effect we hide it and let ScreenCaptureKit
                    // bake it into the frame instead, so the shader tints and
                    // scanlines it along with everything else. That trades a frame
                    // of lag for a cursor that belongs to the picture.
                    config.showsCursor = includeCursor

                    let sink = StreamSink(displayID: id, engine: self)
                    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: self.sampleQueue)

                    self.sinks[id] = sink
                    try await stream.startCapture()
                    self.streams[id] = stream
                }

                guard gen == self.generation else { return }
                self.setState(self.streams.isEmpty ? .failed("No capturable displays") : .running)
            } catch {
                // Leave no half-open streams behind, so a later retry can start clean.
                self.streams.removeAll()
                self.sinks.removeAll()
                guard gen == self.generation else { return }
                self.setState(.failed(Self.describe(error)))
            }
        }
    }

    func stop() {
        generation += 1
        let active = streams
        streams.removeAll()
        sinks.removeAll()
        for (_, stream) in active {
            Task { try? await stream.stopCapture() }
        }
        setState(.idle)
    }

    fileprivate func deliver(_ buffer: CVPixelBuffer, for displayID: CGDirectDisplayID) {
        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(displayID, buffer)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let sc = error as? SCStreamError {
            switch sc.code {
            case .userDeclined:
                return "Screen Recording permission was declined."
            default:
                return "Capture failed (\(sc.code.rawValue)): \(sc.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}

/// `SCStreamOutput` needs an object conformance, and we need to know which
/// display a given stream belongs to, so each stream gets its own sink.
private final class StreamSink: NSObject, SCStreamOutput {
    let displayID: CGDirectDisplayID
    weak var engine: CaptureEngine?

    init(displayID: CGDirectDisplayID, engine: CaptureEngine) {
        self.displayID = displayID
        self.engine = engine
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // Skip frames the system marks as not-yet-complete, which otherwise show
        // up as torn/blank frames during window resizes.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        engine?.deliver(pixelBuffer, for: displayID)
    }
}
