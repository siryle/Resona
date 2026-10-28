import AppKit

final class MenuBarLyricButton: NSButton {
    static let maximumWidth: CGFloat = 184
    private var elapsed: TimeInterval?
    private var sample: TimeInterval?
    private var duration: TimeInterval?
    private var sampledAt = ProcessInfo.processInfo.systemUptime
    private var playing = false
    private var refresh: Timer?

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.maximumWidth, height: NSStatusBar.system.thickness)
    }

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    var viewport: NSRect {
        NSRect(x: max(bounds.minX, bounds.maxX - Self.maximumWidth), y: bounds.minY,
               width: min(bounds.width, Self.maximumWidth), height: bounds.height).insetBy(dx: 1, dy: 0)
    }

    private var currentElapsed: TimeInterval {
        guard let elapsed else { return 0 }
        return elapsed + (playing ? max(0, ProcessInfo.processInfo.systemUptime - sampledAt) : 0)
    }

    private var textSize: NSSize {
        (title as NSString).size(withAttributes: [.font: font ?? .menuBarFont(ofSize: 14)])
    }

    private var scrollWindow: ClosedRange<TimeInterval>? {
        guard elapsed != nil, let duration, textSize.width > viewport.width, viewport.width > 0 else { return nil }
        let hold = duration * viewport.width / (2 * textSize.width)
        return hold...(duration - hold)
    }

    var textDrawingRect: NSRect {
        let size = textSize
        let overflow = max(0, size.width - viewport.width)
        let progress = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 :
            min(1, max(0, currentElapsed / (duration ?? .infinity)))
        let offset = min(overflow, max(0, size.width * progress - viewport.width / 2))
        let x = overflow > 0 ? viewport.minX - offset : viewport.midX - size.width / 2
        return NSRect(x: x, y: viewport.midY - size.height / 2, width: size.width, height: size.height)
    }

    func update(text: String, elapsed: TimeInterval?, duration: TimeInterval? = nil, playing: Bool) {
        let bounded = elapsed.flatMap { $0.isFinite ? max(0, $0) : nil }
        let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let changed = title != text || sample != bounded || self.duration != length
        if changed || self.playing != playing {
            self.elapsed = changed ? bounded : currentElapsed
            sampledAt = ProcessInfo.processInfo.systemUptime
        }
        if title != text { title = text }
        sample = bounded
        self.duration = length
        self.playing = playing
        needsDisplay = true
        refresh?.invalidate()
        refresh = nil
        guard playing, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = scrollWindow, currentElapsed < window.upperBound else { return }
        // Follow the line's reading position through the center, with no work during either hold.
        let timer = Timer(fire: Date(timeIntervalSinceNow: max(0, window.lowerBound - currentElapsed)),
                          interval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.needsDisplay = true
            if self.currentElapsed >= window.upperBound {
                timer.invalidate()
                self.refresh = nil
            }
        }
        refresh = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = (dark ? NSColor.white : .black).withAlphaComponent(isHighlighted ? 0.65 : 1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        viewport.clip()
        (title as NSString).draw(at: textDrawingRect.origin,
                                withAttributes: [.font: font ?? .menuBarFont(ofSize: 14), .foregroundColor: color])
    }

    deinit { refresh?.invalidate() }
}
