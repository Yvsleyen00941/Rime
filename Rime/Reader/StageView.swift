import AppKit
import QuartzCore

/// Lays out the window: frost across the whole screen, the pages inside the insets, the controls at the bottom.
final class StageView: NSView {
    let frost = FrostView()
    /// Holds the PDF view; masked so pages fade softly where they meet the notch, menu bar or Dock.
    let content = NSView()
    let controls: NSView
    private let fade = CAGradientLayer()
    private var controlsBottom: NSLayoutConstraint!

    var insets = NSEdgeInsetsZero {
        didSet {
            controlsBottom.constant = -(insets.bottom + 16)
            needsLayout = true
        }
    }

    init(pdfView: NSView, controls: NSView) {
        self.controls = controls
        super.init(frame: .zero)
        wantsLayer = true
        content.wantsLayer = true
        addSubview(frost)
        addSubview(content)
        addSubview(controls)
        pdfView.frame = content.bounds
        pdfView.autoresizingMask = [.width, .height]
        content.addSubview(pdfView)

        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsBottom = controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([controls.centerXAnchor.constraint(equalTo: centerXAnchor), controlsBottom])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        frost.frame = bounds
        content.frame = NSRect(
            x: insets.left, y: insets.bottom,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom
        )
        updateFade()
    }

    private func updateFade() {
        guard insets.top > 0 || insets.bottom > 0 else {
            content.layer?.mask = nil
            return
        }
        let edge = 22 / max(content.bounds.height, 1)
        let clear = NSColor.clear.cgColor, opaque = NSColor.black.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = content.bounds
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [insets.bottom > 0 ? clear : opaque, opaque, opaque, insets.top > 0 ? clear : opaque]
        fade.locations = [0, NSNumber(value: insets.bottom > 0 ? edge : 0), NSNumber(value: insets.top > 0 ? 1 - edge : 1), 1]
        content.layer?.mask = fade
        CATransaction.commit()
    }
}
