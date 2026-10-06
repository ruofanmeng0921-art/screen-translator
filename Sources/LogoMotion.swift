import Foundation

struct LogoPresentation {
    var scale: CGFloat = 1
    var angle: CGFloat = 0
    var opacity: CGFloat = 1
    var shine: CGFloat = 0.45
}

struct LogoMotion {
    private enum Transition { case hover, start, stop, settle }
    private(set) var state: TranslatorState = .paused
    private var hovered = false
    private var fromScale: CGFloat = 1
    private var targetScale: CGFloat = 1
    private var started: TimeInterval = -10
    private var duration: TimeInterval = 0.22
    private var transition: Transition = .hover
    private var breathingStart: TimeInterval = 0

    mutating func setState(_ value: TranslatorState, at time: TimeInterval) {
        guard value != state else { return }
        let previous = state
        fromScale = sample(at: time).scale
        state = value
        if value == .paused { hovered = false }
        targetScale = value == .paused ? 1 : 3
        transition = value == .paused ? .stop : previous == .paused ? .start : .settle
        duration = value == .paused ? 0.36 : previous == .paused ? 0.42 : 0.22
        started = time
        breathingStart = time
    }

    mutating func setHovered(_ value: Bool, at time: TimeInterval) {
        guard hovered != value else { return }
        hovered = value
        guard state == .paused else { return }
        fromScale = sample(at: time).scale
        targetScale = value ? 3 : 1
        transition = .hover
        duration = 0.22
        started = time
    }

    func isAnimating(at time: TimeInterval) -> Bool {
        state != .paused || time - started < duration
    }

    func needsLargeCanvas(at time: TimeInterval) -> Bool {
        state != .paused || hovered || time - started < duration
    }

    func sample(at time: TimeInterval) -> LogoPresentation {
        let progress = min(1, max(0, (time - started) / duration))
        let easing: Double
        if transition == .start {
            let shifted = progress - 1
            easing = 1 + 2.2 * shifted * shifted * shifted + 1.2 * shifted * shifted
        } else {
            easing = progress * progress * (3 - 2 * progress)
        }
        var result = LogoPresentation(scale: fromScale + (targetScale - fromScale) * CGFloat(easing))
        if transition == .start { result.angle = 0.12 * CGFloat(sin(progress * .pi)) }
        if transition == .stop { result.angle = -0.18 * CGFloat(sin(progress * .pi)) }
        if state != .paused {
            let period: Double = state == .preparing ? 0.85 : 1.8
            let wave = CGFloat((sin((time - breathingStart) * 2 * .pi / period) + 1) / 2)
            result.opacity = state == .preparing ? 0.50 + wave * 0.50 : 0.65 + wave * 0.35
            result.shine = 0.20 + wave * 0.60
        }
        return result
    }
}
