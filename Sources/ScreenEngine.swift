import AppKit
import ScreenCaptureKit
import Translation

enum TranslatorState: Equatable {
    case paused, preparing, running
}

@MainActor
final class ScreenEngine {
    var onState: ((TranslatorState) -> Void)?
    var onLanguageSetup: (() -> Void)?
    var onError: ((TranslatorFailure) -> Void)?
    var onProgress: ((Int) -> Void)?
    private(set) var state: TranslatorState = .paused {
        didSet { if oldValue != state { onState?(state) } }
    }
    private var task: Task<Void, Never>?
    private var captureSession: CaptureSession?
    private var generation = UUID()
    private var overlays: [CGDirectDisplayID: OverlayWindow] = [:]
    private var cache: [String: String] = [:]
    private var restoreTimer: Timer?
    private var manualOriginal = false
    private var interactionSuppressed = false
    private var logoDragging = false
    private var contentRevision: UInt64 = 0
    private var showingOriginal: Bool { manualOriginal || interactionSuppressed || logoDragging }
    let source = Locale.Language(identifier: "en")
    let target = Locale.Language(identifier: "zh-Hans")

    func toggle() {
        if state == .paused { start() } else { stop() }
    }

    func chooseScreen() {
        stop()
        ScreenSelection.shared.reset()
        UserDefaults.standard.set(true, forKey: "useSystemScreenSelection")
        start()
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        captureSession?.stop()
        captureSession = nil
        state = .paused
        onProgress?(0)
        manualOriginal = false
        interactionSuppressed = false
        logoDragging = false
        restoreTimer?.invalidate()
        overlays.values.forEach { $0.clear() }
    }

    func showOriginal() {
        manualOriginal.toggle()
        if manualOriginal { clearOverlays() }
    }

    func clearOverlays() { overlays.values.forEach { $0.clear() } }

    func clearForInteraction() {
        contentRevision &+= 1
        clearOverlays()
        interactionSuppressed = true
        restoreTimer?.invalidate()
        restoreTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.interactionSuppressed = false }
        }
    }

    func setLogoDragging(_ active: Bool) {
        logoDragging = active
        contentRevision &+= 1
        clearOverlays()
        if !active { clearForInteraction() }
    }

    func start() {
        guard state == .paused else { return }
        state = .preparing
        let token = UUID()
        generation = token
        task = Task { [weak self] in
            guard let self else { return }
            let availability = await LanguageAvailability().status(from: source, to: target)
            guard generation == token, !Task.isCancelled else { return }
            guard availability == .installed else {
                stop()
                if availability == .supported { onLanguageSetup?() }
                else { onError?(TranslatorFailure(message: "这台 Mac 的系统翻译暂不支持英文到简体中文。")) }
                return
            }
            let session = TranslationSession(installedSource: source, target: target)
            let capture = CaptureSession()
            captureSession = capture
            defer { capture.stop() }
            var readingScreen = false
            do {
                // Check translation before beginning a recurring capture session.
                _ = try await session.translate("Hello")
                guard generation == token, !Task.isCancelled else { return }
                readingScreen = true
                try await capture.start()
                guard generation == token, !Task.isCancelled else { return }
                var recognizedFrames = [CGDirectDisplayID: (sequence: UInt64, lines: [ScreenLine])]()
                while generation == token, !Task.isCancelled {
                    if showingOriginal {
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    let activeIDs = Set(NSScreen.screens.compactMap(Self.displayID))
                    for id in Array(overlays.keys) where !activeIDs.contains(id) {
                        overlays[id]?.clear()
                        overlays.removeValue(forKey: id)
                    }
                    var translatedCount = 0
                    for screen in NSScreen.screens {
                        guard generation == token, !Task.isCancelled else { return }
                        guard let id = Self.displayID(screen),
                              let frame = try capture.frame(for: id) else { continue }
                        let revision = contentRevision
                        // Running means a real frame arrived, not merely that
                        // translation or a permission preflight succeeded.
                        state = .running
                        let overlay = overlays[id] ?? OverlayWindow(screen: screen)
                        overlays[id] = overlay
                        if overlay.panel.frame != screen.frame {
                            overlay.panel.setFrame(screen.frame, display: false)
                            overlay.view.setFrameSize(screen.frame.size)
                        }
                        let lines: [ScreenLine]
                        if let last = recognizedFrames[id], last.sequence == frame.sequence {
                            lines = last.lines
                        } else {
                            lines = try await Task.detached(priority: .utility) {
                                try TextRecognition.lines(in: frame.image)
                            }.value
                            recognizedFrames[id] = (frame.sequence, lines)
                        }
                        guard generation == token, !Task.isCancelled else { return }
                        if showingOriginal || revision != contentRevision { overlay.clear(); continue }
                        for line in lines {
                            if let label = TextVocabulary.interfaceTranslation(line.source) { cache[line.source] = label }
                            else if TextVocabulary.shouldPreserveEntireLine(line.source) { cache[line.source] = line.source }
                        }
                        // Remove obsolete covers before waiting for uncached translations.
                        overlay.display(translated(lines))
                        var seen = Set<String>()
                        let missing = lines.map(\.source).filter { self.cache[$0] == nil && seen.insert($0).inserted }
                        for start in stride(from: 0, to: missing.count, by: 24) {
                            readingScreen = false
                            let chunk = Array(missing[start..<min(start + 24, missing.count)])
                            let requests = chunk.map(TextVocabulary.request)
                            let responses = try await session.translations(from: requests)
                            guard generation == token, !Task.isCancelled else { return }
                            for response in responses {
                                let original = response.clientIdentifier ?? response.sourceText
                                cache[original] = TextVocabulary.safeTranslation(response.targetText, for: original)
                            }
                            readingScreen = true
                        }
                        if cache.count > 2500 {
                            let visible = Set(lines.map(\.source))
                            cache = cache.filter { visible.contains($0.key) }
                        }
                        if !showingOriginal && revision == contentRevision {
                            let result = translated(lines)
                            overlay.display(result)
                            translatedCount += result.count
                        }
                    }
                    onProgress?(translatedCount)
                    try await Task.sleep(for: .milliseconds(900))
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                stop()
                if error is CancellationError { return }
                if readingScreen { ScreenSelection.shared.reset() }
                onError?(readingScreen ? .capture(error) : TranslatorFailure(message: "翻译已暂停：\(error.localizedDescription)"))
            }
        }
    }

    private func translated(_ lines: [ScreenLine]) -> [TranslatedLine] {
        lines.compactMap { line in
            guard let text = cache[line.source], text != line.source else { return nil }
            return TranslatedLine(text: text, bounds: line.bounds, background: line.background)
        }
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
