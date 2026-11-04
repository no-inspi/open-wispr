import AppKit

/// Pastille flottante en bas au centre de l'écran : état de la dictée / de Jarvis,
/// et texte de la réponse de Jarvis.
final class RecordingOverlay {
    private let panel: NSPanel
    private let background: NSVisualEffectView
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var bars: [NSView] = []
    private var timer: Timer?
    private var phase: Double = 0
    private var hideWorkItem: DispatchWorkItem?

    private let compactSize = NSSize(width: 210, height: 44)
    private let answerWidth: CGFloat = 560
    private let answerMaxHeight: CGFloat = 260

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: compactSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        background = NSVisualEffectView(frame: NSRect(origin: .zero, size: compactSize))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.masksToBounds = true
        panel.contentView = background

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        background.addSubview(dot)

        for _ in 0..<5 {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.5
            bar.layer?.backgroundColor = NSColor.labelColor.cgColor
            background.addSubview(bar)
            bars.append(bar)
        }

        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        background.addSubview(label)
    }

    func update(_ state: StatusBarController.State, jarvis: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.update(state, jarvis: jarvis) }
            return
        }
        switch state {
        case .recording:
            showCompact(jarvis ? "Jarvis écoute…" : "Écoute…",
                        color: jarvis ? .systemBlue : .systemRed, animate: true)
        case .transcribing:
            showCompact("Transcription…", color: jarvis ? .systemBlue : .systemOrange, animate: false)
        case .jarvisThinking(let detail):
            showCompact(detail ?? "Jarvis réfléchit…", color: .systemPurple, animate: true)
        case .jarvisAnswer(let text):
            showAnswer(text, color: .systemPurple)
        case .copiedToClipboard:
            showCompact("Copié", color: .systemGreen, animate: false, autoHide: 1.2)
        case .error(let message):
            showAnswer(message, color: .systemYellow, autoHide: 4)
        default:
            hide()
        }
    }

    // MARK: - Layouts

    private func showCompact(_ text: String, color: NSColor, animate: Bool, autoHide: TimeInterval? = nil) {
        hideWorkItem?.cancel()
        panel.setContentSize(compactSize)
        background.frame = NSRect(origin: .zero, size: compactSize)
        background.layer?.cornerRadius = compactSize.height / 2

        dot.frame = NSRect(x: 18, y: 17, width: 10, height: 10)
        dot.layer?.backgroundColor = color.cgColor
        for (i, bar) in bars.enumerated() {
            bar.isHidden = false
            bar.frame = NSRect(x: 38 + CGFloat(i) * 6, y: 20, width: 3, height: 4)
        }

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = text
        label.frame = NSRect(x: 76, y: 13, width: compactSize.width - 86, height: 18)

        present(animate: animate, autoHide: autoHide)
    }

    private func showAnswer(_ text: String, color: NSColor, autoHide: TimeInterval? = nil) {
        hideWorkItem?.cancel()
        stopAnimation()
        for bar in bars { bar.isHidden = true }

        let display = text.count > 600 ? String(text.prefix(600)) + "…" : text
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.maximumNumberOfLines = 10
        label.lineBreakMode = .byWordWrapping
        label.stringValue = display

        let textWidth = answerWidth - 58
        let measured = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height ?? 20
        let textHeight = min(measured, answerMaxHeight - 28)
        let size = NSSize(width: answerWidth, height: textHeight + 28)

        panel.setContentSize(size)
        background.frame = NSRect(origin: .zero, size: size)
        background.layer?.cornerRadius = 16
        dot.frame = NSRect(x: 18, y: size.height - 26, width: 10, height: 10)
        dot.layer?.backgroundColor = color.cgColor
        label.frame = NSRect(x: 40, y: 14, width: textWidth, height: textHeight)

        present(animate: false, autoHide: autoHide)
    }

    private func present(animate: Bool, autoHide: TimeInterval?) {
        position()
        if animate { startAnimation() } else { stopAnimation() }
        panel.orderFrontRegardless()
        if let delay = autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Bas-centre de l'écran où se trouve la souris.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }

    private func hide() {
        stopAnimation()
        panel.orderOut(nil)
    }

    // MARK: - Animation

    private func startAnimation() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        for bar in bars where !bar.isHidden {
            bar.frame = NSRect(x: bar.frame.origin.x, y: 20, width: 3, height: 4)
        }
    }

    private func tick() {
        phase += 0.2
        for (i, bar) in bars.enumerated() {
            let h = 4 + 12 * abs(sin(phase + Double(i) * 0.6))
            bar.frame = NSRect(x: bar.frame.origin.x, y: 22 - h / 2, width: 3, height: h)
        }
    }
}
