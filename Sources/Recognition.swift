import AppKit
import Vision
import NaturalLanguage

struct ScreenLine: Sendable {
    let source: String
    /// Vision coordinates: normalized, with origin at the bottom left.
    let bounds: CGRect
    let background: RGB
    var confidence: Float = 1
}

struct RGB: Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

enum TextRecognition {
    static func isEnglish(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }.count
        guard letters >= 2, text.count <= 700, !TextVocabulary.isNonLanguage(text) else { return false }
        guard !text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else {
            return false
        }
        // Leave URLs and code paths readable, rather than translating their identifiers.
        let words = text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        guard words.contains(where: { $0.count >= 3 }) || TextVocabulary.interfaceTranslation(text) != nil ||
                TextVocabulary.isProtectedLabel(text) else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english ||
            (text.count < 32 && letters >= 3 && letters >= text.count / 2) ||
            TextVocabulary.interfaceTranslation(text) != nil || TextVocabulary.isProtectedLabel(text)
    }

    static func lines(in image: CGImage) throws -> [ScreenLine] {
        let request = makeRequest(correctLanguage: true)
        // Preserve native screen resolution; small UI text must not be thrown
        // away by a relative text-height cutoff or forced through English OCR.
        request.minimumTextHeight = 0
        try VNImageRequestHandler(cgImage: image).perform([request])
        let patches: [Patch] = (request.results ?? []).compactMap { observation in
            // If the first result is a filename or Chinese text, a lower-ranked
            // English-looking alternative must not turn it into a translation.
            guard let primary = observation.topCandidates(1).first, isEnglish(primary.string) else { return nil }
            let candidates = observation.topCandidates(3).filter { $0.confidence >= 0.45 && isEnglish($0.string) }
            guard !candidates.isEmpty, observation.boundingBox.height * CGFloat(image.height) >= 10 else { return nil }
            let box = observation.boundingBox
            let cropRect = CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                                  width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
                .insetBy(dx: -4, dy: -3).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let crop = image.cropping(to: cropRect) else { return nil }
            return Patch(bounds: box, candidates: candidates, crop: crop)
        }
        var accepted: [ScreenLine] = []
        // Batch enlarged line crops into an atlas instead of invoking Vision
        // separately for every word. A second pass disables language correction
        // to check that the actual glyphs support the first pass's spelling.
        for offset in stride(from: 0, to: patches.count, by: 16) {
            accepted += try verify(Array(patches[offset..<min(offset + 16, patches.count)]), original: image)
        }
        return accepted
    }

    private struct Patch {
        let bounds: CGRect
        let candidates: [VNRecognizedText]
        let crop: CGImage
    }

    private static func makeRequest(correctLanguage: Bool) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = correctLanguage
        request.customWords = TextVocabulary.recognitionWords
        return request
    }

    private static func verify(_ patches: [Patch], original: CGImage) throws -> [ScreenLine] {
        let width = patches.map { $0.crop.width * 2 + 24 }.max() ?? 1
        let height = patches.reduce(0) { $0 + $1.crop.height * 2 + 24 }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        var slots = [CGRect]()
        var y: CGFloat = 12
        for patch in patches {
            let slot = CGRect(x: 12, y: y, width: CGFloat(patch.crop.width * 2), height: CGFloat(patch.crop.height * 2))
            context.draw(patch.crop, in: slot)
            slots.append(slot)
            y = slot.maxY + 24
        }
        guard let enlarged = context.makeImage() else { return [] }
        let check = makeRequest(correctLanguage: false)
        check.minimumTextHeight = 0
        try VNImageRequestHandler(cgImage: enlarged).perform([check])
        return patches.enumerated().compactMap { index, patch in
            let slot = slots[index]
            let found = (check.results ?? []).filter { observation in
                let box = observation.boundingBox
                return slot.contains(CGPoint(x: box.midX * CGFloat(width), y: box.midY * CGFloat(height)))
            }.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let raw = found.compactMap { $0.topCandidates(1).first }
            guard !raw.isEmpty, raw.allSatisfy({ $0.confidence >= 0.60 }),
                  !TextVocabulary.isNonLanguage(raw.map(\.string).joined(separator: " ")) else { return nil }
            var spellings = [raw.map(\.string).joined(separator: " ")]
            if found.count == 1 { spellings += found[0].topCandidates(3).filter { $0.confidence >= 0.60 }.map(\.string) }
            let keys = Set(spellings.map(TextVocabulary.comparisonKey))
            guard let candidate = patch.candidates.first(where: { keys.contains(TextVocabulary.comparisonKey($0.string)) }) else {
                return nil
            }
            guard candidate.confidence >= 0.70 || raw.allSatisfy({ $0.confidence >= 0.70 }) else { return nil }
            let text = TextVocabulary.canonicalNames(candidate.string.trimmingCharacters(in: .whitespacesAndNewlines))
            return ScreenLine(source: text, bounds: patch.bounds,
                              background: sampleBackground(original, bounds: patch.bounds), confidence: candidate.confidence)
        }
    }

    static func sampleBackground(_ image: CGImage, bounds: CGRect) -> RGB {
        // Sample around the text, so its glyphs don't darken the estimated surface.
        let x = bounds.minX * CGFloat(image.width)
        let y = (1 - bounds.maxY) * CGFloat(image.height)
        let w = bounds.width * CGFloat(image.width)
        let strip = CGRect(x: x - 2, y: y - 4, width: w + 4, height: 3)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard strip.width > 0, strip.height > 0,
              let crop = image.cropping(to: strip) else {
            return RGB(red: 0.97, green: 0.97, blue: 0.98)
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return RGB(red: CGFloat(rgba[0]) / 255, green: CGFloat(rgba[1]) / 255,
                   blue: CGFloat(rgba[2]) / 255)
    }
}

struct TranslatedLine {
    let text: String
    let bounds: CGRect
    let background: RGB
}

@MainActor
final class OverlayView: NSView {
    var lines = [TranslatedLine]() { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        for line in lines {
            let box = CGRect(x: line.bounds.minX * bounds.width,
                             y: line.bounds.minY * bounds.height,
                             width: line.bounds.width * bounds.width,
                             height: line.bounds.height * bounds.height)
            guard box.height >= 5, box.width >= 8 else { continue }
            let cover = box.insetBy(dx: -2, dy: -2).intersection(bounds)
            line.background.color.setFill()
            NSBezierPath(roundedRect: cover, xRadius: 2, yRadius: 2).fill()
            let foreground: NSColor = line.background.luminance > 0.45
                ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
                : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byTruncatingTail
            var fontSize = min(25, max(8, box.height * 0.84))
            let text = line.text as NSString
            while fontSize > 8 &&
                text.size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width > box.width {
                fontSize -= 0.5
            }
            let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            let drawHeight = font.ascender - font.descender + 2
            let rect = CGRect(x: box.minX, y: box.midY - drawHeight / 2,
                              width: box.width, height: drawHeight)
            text.draw(in: rect, withAttributes: [.font: font, .foregroundColor: foreground,
                                                 .paragraphStyle: paragraph])
        }
    }
}

@MainActor
final class OverlayWindow {
    let panel: NSPanel
    let view: OverlayView
    init(screen: NSScreen) {
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Menus and popovers can sit above normal floating windows.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
    }
    func display(_ lines: [TranslatedLine]) {
        view.lines = lines
        if lines.isEmpty { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }
    func clear() { view.lines = []; panel.orderOut(nil) }
}
