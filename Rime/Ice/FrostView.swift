import AppKit
import QuartzCore

/// The frozen surface around the pages: the frost image, grown in from the screen edges by animated masks.
final class FrostView: NSView {
    private let frostLayer = CALayer()
    private let frostMask = CALayer()
    private let rimLayer = CALayer()
    private let rimMask = CALayer()
    private var frames: FreezeFrames?
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        frostLayer.contentsGravity = .resize
        frostLayer.isHidden = true
        rimLayer.backgroundColor = NSColor.white.cgColor
        rimLayer.opacity = 0.55
        rimLayer.isHidden = true
        for mask in [frostMask, rimMask] {
            mask.contentsGravity = .resize
            mask.magnificationFilter = .linear
        }
        rimLayer.mask = rimMask
        layer?.addSublayer(frostLayer)
        layer?.addSublayer(rimLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [frostLayer, rimLayer, frostMask, rimMask] {
            sublayer.frame = bounds
        }
        CATransaction.commit()
    }

    func show(_ surface: FrostRenderer.Surface, crossfade: Bool) {
        if crossfade, frostLayer.contents != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.4
            frostLayer.add(fade, forKey: "surface")
        }
        frostLayer.contents = surface.frost
        frames = surface.frames
    }

    /// Frozen shows frost everywhere; thawed leaves the window clear. With a duration, the frost grows in
    /// from the screen edges (or recedes to them), and `completion` runs once it settles.
    func setFrozen(_ frozen: Bool, duration: CFTimeInterval, completion: (() -> Void)? = nil) {
        generation += 1
        let current = generation
        frostMask.removeAllAnimations()
        rimMask.removeAllAnimations()

        guard duration > 0, let frames, frames.frost.count > 1 else {
            settle(frozen: frozen)
            completion?()
            return
        }

        let frostValues = frozen ? frames.frost : frames.frost.reversed()
        let rimValues = frozen ? frames.rim : frames.rim.reversed()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                self.settle(frozen: frozen)
                completion?()
            }
        }
        frostLayer.mask = frostMask
        frostLayer.isHidden = false
        rimLayer.isHidden = false
        frostMask.contents = frostValues.last
        rimMask.contents = rimValues.last
        let timing = frozen
            ? CAMediaTimingFunction(controlPoints: 0.15, 0.6, 0.3, 1)
            : CAMediaTimingFunction(controlPoints: 0.5, 0, 0.85, 0.6)
        for (mask, values) in [(frostMask, frostValues), (rimMask, rimValues)] {
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = values
            animation.duration = duration
            animation.timingFunction = timing
            animation.calculationMode = .linear
            mask.add(animation, forKey: "freeze")
        }
        CATransaction.commit()
    }

    private func settle(frozen: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frostLayer.mask = nil
        frostLayer.isHidden = !frozen
        rimLayer.isHidden = true
        CATransaction.commit()
    }
}
