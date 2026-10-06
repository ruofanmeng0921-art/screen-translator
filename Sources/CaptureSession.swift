import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

struct TranslatorFailure {
    let message: String
    var needsScreenPermission = false

    static func capture(_ error: Error) -> Self {
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain,
           failure.code == SCStreamError.Code.userDeclined.rawValue {
            return Self(message: "macOS 尚未允许当前版本读取屏幕。请在系统设置中允许「屏幕翻译」，然后退出并重新打开应用。",
                        needsScreenPermission: true)
        }
        return Self(message: "屏幕读取已暂停：\(error.localizedDescription)")
    }
}

// A single authorized stream stays open until Pause or Quit. Only the latest
// complete frame is retained in memory; no video or screenshots are written.
struct CapturedFrame {
    let image: CGImage
    let sequence: UInt64
}

private final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var image: CGImage?
    private var failure: Error?
    private var sequence: UInt64 = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let frame = CIImage(cvPixelBuffer: buffer)
        guard let copy = context.createCGImage(frame, from: frame.extent) else { return }
        lock.withLock { image = copy; sequence &+= 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { failure = error }
    }

    func latest() throws -> CapturedFrame? {
        try lock.withLock {
            if let failure { throw failure }
            return image.map { CapturedFrame(image: $0, sequence: sequence) }
        }
    }
}

@MainActor
final class CaptureSession {
    private struct Feed {
        let stream: SCStream
        let receiver: FrameReceiver
    }
    private var feeds: [CGDirectDisplayID: Feed] = [:]
    private var stopped = false

    func start() async throws {
        if UserDefaults.standard.bool(forKey: "useSystemScreenSelection") {
            try await startSelectedDisplay()
            return
        }
        // ScreenCaptureKit is the authority for this session. Do not call the
        // legacy CGRequestScreenCaptureAccess on every click or infer failure
        // from a cached CGPreflightScreenCaptureAccess result.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if TranslatorFailure.capture(error).needsScreenPermission {
                UserDefaults.standard.set(true, forKey: "useSystemScreenSelection")
                try await startSelectedDisplay()
                return
            }
            throw error
        }
        try Task.checkCancellation()
        let ownApps = content.applications.filter { $0.processID == getpid() }
        guard !ownApps.isEmpty else {
            throw NSError(domain: "ScreenTranslator.Capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法排除翻译覆盖层，请重新打开应用。"])
        }
        for screen in NSScreen.screens {
            guard !stopped else { throw CancellationError() }
            guard let id = ScreenEngine.displayID(screen),
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            try await addFeed(filter: filter, screen: screen, id: id)
        }
        guard !feeds.isEmpty else {
            throw NSError(domain: "ScreenTranslator.Capture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "没有可读取的显示器。"])
        }
    }

    private func startSelectedDisplay() async throws {
        let filter = try await ScreenSelection.shared.select()
        try Task.checkCancellation()
        guard filter.style == .display, let display = filter.includedDisplays.first,
              let screen = NSScreen.screens.first(where: { ScreenEngine.displayID($0) == display.displayID }) else {
            ScreenSelection.shared.reset()
            throw NSError(domain: "ScreenTranslator.Selection", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请选择一个完整屏幕用于翻译。"])
        }
        try await addFeed(filter: filter, screen: screen, id: display.displayID)
    }

    private func addFeed(filter: SCContentFilter, screen: NSScreen, id: CGDirectDisplayID) async throws {
        guard !stopped else { throw CancellationError() }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.minimumFrameInterval = CMTime(value: 9, timescale: 10)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.captureMicrophone = false
        let receiver = FrameReceiver()
        let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "screen-translator.frame.\(id)", qos: .utility))
        feeds[id] = Feed(stream: stream, receiver: receiver)
        try await stream.startCapture()
        if stopped || Task.isCancelled {
            try? await stream.stopCapture()
            throw CancellationError()
        }
    }

    func frame(for displayID: CGDirectDisplayID) throws -> CapturedFrame? {
        try feeds[displayID]?.receiver.latest()
    }

    func stop() {
        stopped = true
        for feed in feeds.values { feed.stream.stopCapture { _ in } }
        feeds.removeAll()
    }
}
