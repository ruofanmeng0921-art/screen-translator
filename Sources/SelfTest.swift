import AppKit
import Translation

enum SelfTest {
    @MainActor static func run() async {
        do {
            let image = NSImage(size: NSSize(width: 1000, height: 400))
            image.lockFocus()
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 1000, height: 400).fill()
            ("Create and edit documents" as NSString).draw(at: CGPoint(x: 70, y: 260),
                withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            ("Analyze your spreadsheets" as NSString).draw(at: CGPoint(x: 70, y: 150),
                withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            image.unlockFocus()
            var rect = CGRect(x: 0, y: 0, width: 1000, height: 400)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw NSError(domain: "SelfTest", code: 1)
            }
            let lines = try TextRecognition.lines(in: cgImage)
            guard lines.contains(where: { $0.source == "Create and edit documents" }),
                  lines.contains(where: { $0.source == "Analyze your spreadsheets" }) else {
                throw NSError(domain: "SelfTest.OCR", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Synthetic screen text was not recognized"])
            }
            print("PASS: English menu OCR and normalized coordinates")
            try checkInterfaceRecognition()
            try checkLogoRedraw()
            try checkLogoMotion()
            try checkTerminologyRules()
            guard !TextRecognition.isEnglish("创建和编辑文档"),
                  !TextRecognition.isEnglish("https://example.com"),
                  TextRecognition.isEnglish("Documents") else {
                throw NSError(domain: "SelfTest.Filter", code: 3)
            }
            print("PASS: Chinese text and URLs remain untouched")
            if let url = Bundle.main.url(forResource: "apple-logo", withExtension: "svg"),
               NSImage(contentsOf: url) != nil { print("PASS: Official logo resource loads") }
            else { throw NSError(domain: "SelfTest.Logo", code: 4) }
            try await checkLanguageSetup()
            let pair = await LanguageResources.pair()
            let session = LanguageResources.installedSession(pair)
            defer { session.cancel() }
            let readiness = try await LanguageResources.readiness(session, pair: pair)
            if readiness == .ready {
                let result = try await session.translate("Create and edit documents")
                guard result.targetText.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else {
                    throw NSError(domain: "SelfTest.Translation", code: 5)
                }
                print("PASS: Local English-to-Chinese translation: \(result.targetText)")
                let protected = try await session.translations(from: [TextVocabulary.request("Open Settings in Codex")])
                guard let response = protected.first,
                      response.targetText.contains("Codex"),
                      response.targetText.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else {
                    throw failure("Brand was changed by translation: \(protected.first?.targetText ?? "no response")")
                }
                print("PASS: Protected brand in a real local translation: \(response.targetText)")
                let technicalSource = "Use LoRA with GGUF"
                let technical = try await session.translations(from: [TextVocabulary.request(technicalSource)])
                guard let response = technical.first, response.targetText.contains("LoRA"), response.targetText.contains("GGUF"),
                      TextVocabulary.safeTranslation(response.targetText, for: technicalSource) != technicalSource else {
                    throw failure("Technical terms were changed: \(technical.first?.targetText ?? "no response")")
                }
                print("PASS: Unknown specialist term preserved in local translation: \(response.targetText)")
            } else {
                print("PENDING: Apple translation language pack readiness = \(readiness)")
            }
            print("Self-test finished")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func checkLanguageSetup() async throws {
        let pair = await LanguageResources.pair()
        let configuration = LanguageResources.configuration(pair)
        let session = LanguageResources.installedSession(pair)
        defer { session.cancel() }
        guard !session.canRequestDownloads,
              configuration.source == pair.source, configuration.target == pair.target else {
            throw failure("Installed-resource checks must never request a language download")
        }
        if #available(macOS 26.4, *) {
            guard configuration.preferredStrategy == .lowLatency,
                  session.preferredStrategy == .lowLatency,
                  LanguageResources.availability().preferredStrategy == .lowLatency else {
                throw failure("Language availability, downloads, and translation must use the same models")
            }
        }
        var readiness: LanguageReadiness = .missing
        let missing = LanguageSetupModel(checker: { _, _ in readiness })
        await missing.check()
        guard missing.phase == .missing else { throw failure("Missing languages must offer preparation") }
        missing.download()
        guard missing.phase == .downloading, missing.configuration != nil else { throw failure("Download did not start") }
        let firstID = missing.downloadRequestID!
        let firstVersion = missing.configuration!.version
        missing.cancel()
        guard missing.configuration == nil, missing.phase == .missing else { throw failure("Cancel must invalidate download work") }
        await missing.check()
        missing.download()
        guard missing.downloadRequestID != firstID, missing.configuration!.version > firstVersion else {
            throw failure("Retry must create a new task even with the same language pair")
        }
        readiness = .ready
        await missing.finishDownload(using: session, requestID: firstID)
        guard missing.phase == .downloading else { throw failure("A stale download callback changed the retry") }
        missing.cancel()

        var held: CheckedContinuation<LanguageReadiness, Never>?
        let cancelled = LanguageSetupModel(checker: { _, _ in
            await withCheckedContinuation { held = $0 }
        })
        let checking = Task { await cancelled.check() }
        for _ in 0..<1000 {
            if held != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard let continuation = held else { checking.cancel(); throw failure("Check did not begin") }
        cancelled.cancel()
        continuation.resume(returning: .ready)
        await checking.value
        guard cancelled.phase != .ready else { throw failure("A closed setup window accepted a stale completion") }
        print("PASS: Consistent model choice, missing-language setup, cancellation, and stale completion rejection")

        let installed = LanguageSetupModel()
        await installed.check()
        if installed.phase == .ready {
            installed.download()
            guard installed.phase == .ready, installed.configuration == nil else {
                throw failure("Already installed languages prompted another download")
            }
            await installed.check()
            guard installed.phase == .ready, installed.configuration == nil else {
                throw failure("Repeated language checks lost installed resources")
            }
            print("PASS: Already installed languages stay ready across repeated checks without a download task")
        }
        installed.cancel()
    }

    @MainActor private static func checkTerminologyRules() throws {
        guard TextVocabulary.shouldPreserveEntireLine("LoRA"),
              TextVocabulary.shouldPreserveEntireLine("GGUF"),
              TextVocabulary.shouldPreserveEntireLine("gguf"),
              !TextVocabulary.shouldPreserveEntireLine("Documents"),
              !TextVocabulary.shouldPreserveEntireLine("Settings"),
              !TextVocabulary.shouldPreserveEntireLine("Create and edit documents"),
              TextVocabulary.safeTranslation("使用低秩适配器", for: "Use LoRA") == "Use LoRA",
              TextVocabulary.safeTranslation("使用 LoRA", for: "Use LoRA") == "使用 LoRA" else {
            throw failure("Unknown technical terms must stay original without suppressing ordinary interface text")
        }
        print("PASS: Unknown terminology, acronym preservation, and rejected term substitutions")
    }

    @MainActor private static func checkLogoRedraw() throws {
        let width = 80, height = 88
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Could not render logo fixture") }
        let view = AppleButton(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let small = AppleButton.logoBounds(in: view.bounds, hovered: false)
        let large = AppleButton.logoBounds(in: view.bounds, hovered: true)
        guard large.width == small.width * 3, large.height == small.height * 3,
              large.midX == small.midX, large.midY == small.midY else { throw failure("Hover must enlarge the logo exactly three times around its center") }
        guard let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil),
              let exitEvent = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
            throw failure("Could not construct hover fixture")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        view.mouseEntered(with: enter)
        view.draw(view.bounds)
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw failure("Could not sample logo pixels") }
        let before = (0..<(width * height)).filter { bytes[$0 * 4 + 3] > 0 }.count
        view.mouseExited(with: exitEvent)
        view.draw(view.bounds)
        let after = (0..<(width * height)).filter { bytes[$0 * 4 + 3] > 0 }.count
        NSGraphicsContext.restoreGraphicsState()
        guard before > after * 5, after > 0, after <= Int(small.width * small.height) else {
            throw failure("Transparent logo redraw left old enlarged pixels: \(before) -> \(after)")
        }
        print("PASS: Three-times hover, unchanged center, and no old pixels after shrink (\(before) -> \(after))")
    }

    private static func checkLogoMotion() throws {
        var motion = LogoMotion()
        motion.setState(.preparing, at: 100)
        guard motion.sample(at: 100.2).scale > 2,
              motion.sample(at: 100.5).scale == 3 else { throw failure("Clicking Start must visibly enlarge the logo without a hover event") }
        motion.setState(.running, at: 100.5)
        let bright = motion.sample(at: 100.95), dim = motion.sample(at: 101.85)
        guard bright.scale == 3, dim.scale == 3, abs(bright.opacity - dim.opacity) > 0.3,
              motion.isAnimating(at: 101.85) else { throw failure("Running must retain three-times size and a visible breathing animation") }
        motion.setState(.paused, at: 102)
        let closing = motion.sample(at: 102.18), closed = motion.sample(at: 102.5)
        guard closing.scale > 1 && closing.scale < 3, closing.angle < 0,
              closed.scale == 1, closed.opacity == 1, !motion.isAnimating(at: 102.5) else {
            throw failure("Pause must visibly collapse and stop the running animation")
        }
        motion.setHovered(true, at: 103)
        guard motion.sample(at: 103.5).scale == 3 else { throw failure("Paused hover must still enlarge the logo") }
        motion.setHovered(false, at: 104)
        guard motion.sample(at: 104.5).scale == 1 else { throw failure("Mouse exit must restore the small logo") }
        print("PASS: Click-to-enlarge, continuous running pulse, pause collapse, and hover restoration")
    }

    @MainActor private static func checkInterfaceRecognition() throws {
        // A native-pixel fixture exercises the actual capture/OCR input scale,
        // including small labels, mixed languages, and both surface colors.
        let width = 1920, height = 1200
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw failure("Could not render OCR fixture") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        CGRect(x: 0, y: 600, width: width, height: 600).fill()
        NSColor(white: 0.10, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: 600).fill()
        let labels: [(String, CGFloat, CGFloat)] = [
            ("Settings", 14, 1120), ("Plugins", 18, 1050), ("Skills", 18, 980),
            ("Codex", 24, 910), ("ChatGPT", 24, 840), ("OpenAI", 24, 770),
            ("GitHub", 24, 700), ("GPT-6.1-sol", 24, 620),
            ("Create and edit documents", 24, 520), ("Privacy and Security", 18, 440),
            ("Search", 16, 360), ("Open Settings in Codex", 24, 280),
            ("Save changes", 18, 200), ("New task", 18, 120)
        ]
        for (text, size, y) in labels {
            (text as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: y >= 600 ? NSColor.black : NSColor.white
            ])
        }
        let otherText = ["系统设置", "隐私与安全性", "屏幕翻译", "安装", "https://example.com", "5 KB/s", "⌘ K", "Recognition.swift"]
        for (index, text) in otherText.enumerated() {
            (text as NSString).draw(at: CGPoint(x: 1100, y: 1120 - index * 135), withAttributes: [
                .font: NSFont.systemFont(ofSize: 24), .foregroundColor: index < 4 ? NSColor.black : NSColor.white
            ])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { throw failure("Could not read OCR fixture") }
        let started = Date()
        let lines = try TextRecognition.lines(in: image)
        let sources = Set(lines.map(\.source))
        let expected = Set(labels.map { $0.0 })
        guard sources == expected else {
            throw failure("OCR fixture mismatch. Missing: \(expected.subtracting(sources).sorted()); Unexpected: \(sources.subtracting(expected).sorted())")
        }
        for (_, _, y) in labels {
            guard lines.contains(where: { abs($0.bounds.minY * CGFloat(height) - y) < 15 }) else {
                throw failure("OCR coordinates do not match the source row at \(y)")
            }
        }
        guard lines.filter({ $0.bounds.midY < 0.5 }).allSatisfy({ $0.background.luminance < 0.2 }),
              lines.filter({ $0.bounds.midY > 0.5 }).allSatisfy({ $0.background.luminance > 0.9 }) else {
            throw failure("OCR crop or background coordinates are inverted")
        }
        guard TextVocabulary.interfaceTranslation("Settings") == "设置",
              TextVocabulary.interfaceTranslation("Skills") == "技能",
              TextVocabulary.isProtectedLabel("GPT-6.1-sol"),
              TextVocabulary.isProtectedLabel("Codex") else { throw failure("UI labels or protected names are incorrect") }
        print("PASS: \(labels.count) exact OCR labels, 14-pixel text, Chinese rejection, light/dark crops (\(String(format: "%.2f", Date().timeIntervalSince(started))) s)")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SelfTest", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
