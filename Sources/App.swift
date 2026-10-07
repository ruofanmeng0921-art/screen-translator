import AppKit
import SwiftUI
import Translation

@MainActor
final class AppleButton: NSView {
    var action: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    var onDragging: ((Bool) -> Void)?
    var state: TranslatorState = .paused {
        didSet {
            guard oldValue != state else { return }
            updateLabel()
            if state == .paused {
                hover = false
                pauseHoverSuppressed = true
                pausePointer = NSEvent.mouseLocation
            }
            motion.setState(state, at: ProcessInfo.processInfo.systemUptime)
            animateAppearance()
        }
    }
    private let logo = NSImage(contentsOf: Bundle.main.url(forResource: "apple-logo", withExtension: "svg")!)
    private var pressPoint: NSPoint?
    private var windowOrigin: NSPoint?
    private var dragged = false
    private var hover = false
    private var pauseHoverSuppressed = false
    private var pausePointer: CGPoint = .zero
    private var motion = LogoMotion()
    private var presentation = LogoPresentation()
    private var animationTimer: Timer?
    static let restingSize = CGSize(width: 40, height: 44)
    static let hoverSize = CGSize(width: 80, height: 88)
    var restingOrigin: CGPoint {
        guard let frame = window?.frame else { return .zero }
        return CGPoint(x: frame.midX - Self.restingSize.width / 2,
                       y: frame.midY - Self.restingSize.height / 2)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func updateLabel() {
        let label: String
        switch state {
        case .paused: label = "开始英文翻中文"
        case .preparing: label = "正在准备屏幕翻译，点击取消"
        case .running: label = "暂停屏幕翻译"
        }
        setAccessibilityLabel(label)
        toolTip = label + "；拖动可移动，右键打开菜单"
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override var isOpaque: Bool { false }
    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) {
        if pressPoint == nil { pauseHoverSuppressed = false; setHovered(false) }
    }
    override func mouseMoved(with event: NSEvent) {
        let pointer = NSEvent.mouseLocation
        if pauseHoverSuppressed && hypot(pointer.x - pausePointer.x, pointer.y - pausePointer.y) > 4 {
            pauseHoverSuppressed = false
            setHovered(true)
        }
    }
    private func setHovered(_ value: Bool) {
        if value && pauseHoverSuppressed { return }
        guard hover != value else { return }
        hover = value
        motion.setHovered(value, at: ProcessInfo.processInfo.systemUptime)
        animateAppearance()
    }
    private func animateAppearance() {
        let now = ProcessInfo.processInfo.systemUptime
        if window == nil {
            presentation = motion.sample(at: now + 1)
            needsDisplay = true
            return
        }
        updateAppearance(at: now)
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let now = ProcessInfo.processInfo.systemUptime
                self.updateAppearance(at: now)
                if !self.motion.isAnimating(at: now) { timer.invalidate(); self.animationTimer = nil }
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func updateAppearance(at time: TimeInterval) {
        presentation = motion.sample(at: time)
        if let window {
            let oldFrame = window.frame
            let size = motion.needsLargeCanvas(at: time) ? Self.hoverSize : Self.restingSize
            let frame = CGRect(x: oldFrame.midX - size.width / 2, y: oldFrame.midY - size.height / 2,
                               width: size.width, height: size.height)
            if oldFrame != frame { window.setFrame(frame, display: false) }
        }
        needsDisplay = true
        if window != nil { displayIfNeeded() }
    }
    static func logoBounds(in bounds: CGRect, hovered: Bool) -> CGRect {
        logoBounds(in: bounds, scale: hovered ? 3 : 1)
    }
    static func logoBounds(in bounds: CGRect, scale: CGFloat) -> CGRect {
        let size = CGSize(width: 16 * scale, height: 19 * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // A transparent backing surface must be erased before drawing a smaller
        // logo or moving the panel; otherwise old pixels can survive a repaint.
        context.clear(dirtyRect)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 155)
        guard let image = logo?.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let logoRect = Self.logoBounds(in: bounds, scale: presentation.scale)
        context.saveGState()
        context.setAlpha(presentation.opacity)
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: presentation.angle)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        context.clip(to: logoRect, mask: image)
        let colors: [CGColor]
        switch state {
        case .paused:
            colors = [NSColor(white: 0.83, alpha: 1).cgColor, NSColor(white: 0.57, alpha: 1).cgColor,
                      NSColor(white: 0.77, alpha: 1).cgColor]
        case .preparing:
            colors = [NSColor(white: 0.94, alpha: 1).cgColor, NSColor(white: 0.47, alpha: 1).cgColor,
                      NSColor(white: 0.86, alpha: 1).cgColor]
        case .running:
            colors = [NSColor(white: 0.96, alpha: 1).cgColor, NSColor(white: 0.29, alpha: 1).cgColor,
                      NSColor(white: 0.89, alpha: 1).cgColor]
        }
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                    locations: [0, presentation.shine, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: logoRect.minX, y: logoRect.maxY),
                                       end: CGPoint(x: logoRect.maxX, y: logoRect.minY), options: [])
        }
        context.restoreGState()
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        pressPoint = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint, let origin = windowOrigin else { return }
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - start.x, y: current.y - start.y)
        if !dragged && hypot(delta.x, delta.y) > 3 { dragged = true; onDragging?(true) }
        if dragged {
            window?.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
            needsDisplay = true
            displayIfNeeded()
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        if !dragged { action?() }
        if dragged { onDragging?(false) }
        if window != nil {
            let origin = restingOrigin
            UserDefaults.standard.set([origin.x, origin.y], forKey: "logoPosition")
        }
        pressPoint = nil
        if let window { setHovered(window.frame.contains(NSEvent.mouseLocation)) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

struct LanguageSetupView: View {
    @ObservedObject var model: LanguageSetupModel
    let onReady: () -> Void
    let onCancel: () -> Void
    var body: some View {
        let downloadID = model.downloadRequestID
        VStack(alignment: .leading, spacing: 18) {
            Text("准备英文 → 中文").font(.title2).fontWeight(.medium)
            Text(model.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.phase == .checking || model.phase == .downloading { ProgressView().controlSize(.small) }
                if model.phase == .missing {
                    Button("下载语言包") { model.download() }.buttonStyle(.borderedProminent)
                } else if model.phase == .ready {
                    Button(model.resumeWhenReady ? "开始翻译" : "完成", action: onReady).buttonStyle(.borderedProminent)
                } else if case .failed = model.phase {
                    Button("重新检查") { Task { await model.check() } }.buttonStyle(.borderedProminent)
                }
                if model.phase == .downloading {
                    Button("取消", action: onCancel)
                }
            }
        }
        .padding(28).frame(width: 370)
        .task { await model.check() }
        .translationTask(model.configuration) { session in
            if let downloadID { await model.finishDownload(using: session, requestID: downloadID) }
        }
        .onChange(of: model.phase) { _, phase in if phase == .ready && model.resumeWhenReady { onReady() } }
        .onChange(of: model.resumeWhenReady) { _, resume in if resume && model.phase == .ready { onReady() } }
        .onDisappear { model.cancel() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = ScreenEngine()
    private var logoWindow: NSPanel!
    private var apple: AppleButton!
    private var statusItem: NSStatusItem!
    private var setupWindow: NSWindow?
    private var setupModel: LanguageSetupModel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        createLogo()
        createStatusItem()
        engine.onState = { [weak self] state in
            self?.apple.state = state
            self?.statusItem.menu = self?.makeMenu()
        }
        engine.onLanguageSetup = { [weak self] in self?.showLanguageSetup(resumeWhenReady: true) }
        engine.onError = { [weak self] message in self?.showError(message) }
        engine.onProgress = { [weak self] count in
            self?.apple.setAccessibilityValue(count > 0 ? "正在显示 \(count) 处中文翻译" : "")
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.engine.clearForInteraction()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.engine.clearForInteraction()
            return event
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.engine.clearForInteraction() } }
    }

    func createLogo() {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let saved = UserDefaults.standard.array(forKey: "logoPosition") as? [Double]
        var origin = CGPoint(x: visible.maxX - 65, y: visible.midY)
        if let saved, saved.count == 2,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(CGPoint(x: saved[0], y: saved[1])) }) {
            origin = CGPoint(x: saved[0], y: saved[1])
        }
        logoWindow = NSPanel(contentRect: CGRect(origin: origin, size: CGSize(width: 40, height: 44)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        logoWindow.isOpaque = false
        logoWindow.backgroundColor = .clear
        logoWindow.hasShadow = false
        logoWindow.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        logoWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        logoWindow.hidesOnDeactivate = false
        logoWindow.isReleasedWhenClosed = false
        logoWindow.acceptsMouseMovedEvents = true
        apple = AppleButton(frame: CGRect(x: 0, y: 0, width: 40, height: 44))
        apple.action = { [weak self] in self?.engine.toggle() }
        apple.onDragging = { [weak self] active in self?.engine.setLogoDragging(active) }
        apple.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        logoWindow.contentView = apple
        logoWindow.orderFrontRegardless()
    }

    func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "apple-logo", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 12, height: 15)
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "屏幕翻译"
        statusItem.menu = makeMenu()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: engine.state == .paused ? "开始英文翻中文" : "暂停翻译",
                                action: #selector(toggleTranslation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let original = NSMenuItem(title: "显示／恢复原文", action: #selector(toggleOriginal), keyEquivalent: "")
        original.target = self
        original.isEnabled = engine.state == .running
        menu.addItem(original)
        let select = NSMenuItem(title: "选择翻译屏幕…", action: #selector(chooseScreen), keyEquivalent: "")
        select.target = self
        menu.addItem(select)
        menu.addItem(.separator())
        let models = NSMenuItem(title: "检查翻译语言包…", action: #selector(prepareLanguages), keyEquivalent: "")
        models.target = self
        menu.addItem(models)
        let help = NSMenuItem(title: "使用说明", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }
    @objc func toggleTranslation() { engine.toggle() }
    @objc func toggleOriginal() { engine.showOriginal() }
    @objc func chooseScreen() { engine.chooseScreen() }
    @objc func prepareLanguages() { showLanguageSetup() }
    @objc func quitApp() { engine.stop(); NSApp.terminate(nil) }
    @objc func showHelp() {
        let alert = NSAlert()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        alert.messageText = "屏幕翻译 \(version)"
        alert.informativeText = "点击小苹果：开始／暂停。\n拖动小苹果：移动位置。\n右键小苹果：选屏、语言包、原文和退出。\n\n英文识别和翻译在本机进行，不保存屏幕截图。每轮约一秒，长句与首次出现的内容可能稍慢。\n\n出现系统选屏界面时，选择要翻译的完整屏幕并确认共享。本次运行中暂停再开始会沿用选择；退出应用后需要重新选屏。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showLanguageSetup(resumeWhenReady: Bool = false) {
        if let setupWindow {
            if resumeWhenReady { setupModel?.resumeWhenReady = true }
            setupWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 426, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "准备系统翻译"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let model = LanguageSetupModel()
        model.resumeWhenReady = resumeWhenReady
        setupModel = model
        window.contentView = NSHostingView(rootView: LanguageSetupView(model: model, onReady: { [weak self] in
            guard let self else { return }
            let resume = model.resumeWhenReady
            self.setupWindow?.close()
            if resume { self.engine.start() }
        }, onCancel: { [weak self] in self?.setupWindow?.close() }))
        setupWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === setupWindow else { return }
        setupModel?.cancel()
        setupModel = nil
        setupWindow = nil
        window.contentView = nil
    }

    func showError(_ failure: TranslatorFailure) {
        let alert = NSAlert()
        alert.messageText = "屏幕翻译"
        alert.informativeText = failure.message
        alert.addButton(withTitle: "知道了")
        if failure.needsScreenPermission { alert.addButton(withTitle: "打开系统设置") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        setupModel?.cancel()
        engine.stop()
        ScreenSelection.shared.shutdown()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}

@main
struct ScreenTranslatorMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.contains("--self-test") {
            application.setActivationPolicy(.prohibited)
            Task { await SelfTest.run(); application.terminate(nil) }
            application.run()
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
