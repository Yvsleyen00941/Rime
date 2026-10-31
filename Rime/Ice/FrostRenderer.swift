import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Turns the desktop wallpaper into frosted glass. Rendering from the wallpaper rather than the live screen
/// means icons, widgets and other windows can never show through, and it needs no screen-recording permission.
final class FrostRenderer: @unchecked Sendable {
    static let shared = FrostRenderer()

    struct Key: Hashable {
        var wallpaper: URL?
        var modified: Date?
        var pixelWidth: Int
        var pixelHeight: Int
        var dark: Bool
        /// Reduce Transparency is on: make the surface almost solid.
        var solid: Bool
    }

    struct Surface {
        let key: Key
        let frost: CGImage
        let frames: FreezeFrames
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "Rime.frost", qos: .userInitiated)
    private var cache: [Key: Surface] = [:]

    @MainActor
    static func key(for screen: NSScreen, dark: Bool) -> Key {
        let url = NSWorkspace.shared.desktopImageURL(for: screen)?.resolvingSymlinksInPath()
        let modified = (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let scale = screen.backingScaleFactor
        return Key(
            wallpaper: url, modified: modified,
            pixelWidth: Int(screen.frame.width * scale), pixelHeight: Int(screen.frame.height * scale),
            dark: dark, solid: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    /// Delivers the frost for `screen` on the main actor, rendering it in the background the first time.
    @MainActor
    func surface(for screen: NSScreen, dark: Bool, completion: @escaping @MainActor (Surface) -> Void) {
        let key = Self.key(for: screen, dark: dark)
        if let cached = cache[key] {
            completion(cached)
            return
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let size = screen.frame.size
        queue.async {
            let surface = Surface(key: key, frost: self.renderFrost(key, options: options), frames: FreezeFrames(size: size))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.cache.count > 3 { self.cache.removeAll() }
                    self.cache[key] = surface
                    completion(surface)
                }
            }
        }
    }

    private func renderFrost(_ key: Key, options: [NSWorkspace.DesktopImageOptionKey: Any]) -> CGImage {
        let full = CGRect(x: 0, y: 0, width: key.pixelWidth, height: key.pixelHeight)
        // Blur at quarter resolution: frost is soft anyway, and it keeps the render instant.
        let small = CGRect(x: 0, y: 0, width: (full.width / 4).rounded(), height: (full.height / 4).rounded())
        let wallpaper = key.wallpaper.flatMap { CIImage(contentsOf: $0, options: [.applyOrientationProperty: true]) }
        let base = wallpaper.map { place($0, in: small, options: options) } ?? fallback(in: small, dark: key.dark)

        let blurred = base.clampedToExtent().applyingGaussianBlur(sigma: Double(small.width) * 0.0275).cropped(to: small)
        let vivid = CIFilter.colorControls()
        vivid.inputImage = blurred
        vivid.saturation = key.dark ? 1.2 : 1.35
        let veilAlpha: CGFloat = key.solid ? 0.86 : (key.dark ? 0.52 : 0.46)
        let veil = key.dark
            ? CIColor(red: 0.08, green: 0.085, blue: 0.10, alpha: veilAlpha)
            : CIColor(red: 1, green: 1, blue: 1, alpha: veilAlpha)
        let frosted = CIImage(color: veil).cropped(to: small).composited(over: vivid.outputImage!)

        let upscaled = frosted
            .transformed(by: CGAffineTransform(scaleX: full.width / small.width, y: full.height / small.height))
            .clampedToExtent()
            .cropped(to: full)
        let finished = grain(upscaled, in: full, amount: key.dark ? 0.09 : 0.11)
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return context.createCGImage(finished, from: full, format: .RGBA8, colorSpace: space)!
    }

    /// Lays the wallpaper out the way the desktop does (fill, fit, stretch or centre).
    private func place(_ image: CIImage, in rect: CGRect, options: [NSWorkspace.DesktopImageOptionKey: Any]) -> CIImage {
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clips = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let fill = (options[.fillColor] as? NSColor).flatMap { CIColor(color: $0) } ?? CIColor(red: 0, green: 0, blue: 0)
        let extent = image.extent
        var sx = rect.width / extent.width, sy = rect.height / extent.height
        switch scaling {
        case .scaleAxesIndependently:
            break
        case .scaleNone:
            sx = 0.25
            sy = 0.25
        default:
            let s = clips ? max(sx, sy) : min(sx, sy)
            sx = s
            sy = s
        }
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy)))
        let centred = scaled.transformed(by: CGAffineTransform(translationX: (rect.width - scaled.extent.width) / 2, y: (rect.height - scaled.extent.height) / 2))
        return centred.composited(over: CIImage(color: fill).cropped(to: rect)).cropped(to: rect)
    }

    /// For wallpapers that can't be read (a rotating folder, say): a soft wash in the same spirit.
    private func fallback(in rect: CGRect, dark: Bool) -> CIImage {
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: rect.height)
        gradient.point1 = CGPoint(x: rect.width, y: 0)
        gradient.color0 = dark ? CIColor(red: 0.16, green: 0.19, blue: 0.26) : CIColor(red: 0.78, green: 0.85, blue: 0.95)
        gradient.color1 = dark ? CIColor(red: 0.27, green: 0.20, blue: 0.24) : CIColor(red: 0.96, green: 0.86, blue: 0.82)
        return gradient.outputImage!.cropped(to: rect)
    }

    /// A fine grain, one point per grain, so the surface reads as frosted glass rather than a flat blur.
    private func grain(_ image: CIImage, in rect: CGRect, amount: Float) -> CIImage {
        let half = CGRect(x: 0, y: 0, width: (rect.width / 2).rounded(.up), height: (rect.height / 2).rounded(.up))
        let gray = CIFilter.colorMatrix()
        gray.inputImage = CIFilter.randomGenerator().outputImage!.cropped(to: half)
        gray.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        gray.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        gray.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        gray.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        gray.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let noise = gray.outputImage!.samplingNearest().transformed(by: CGAffineTransform(scaleX: 2, y: 2)).cropped(to: rect)
        let soft = CIFilter.softLightBlendMode()
        soft.inputImage = noise
        soft.backgroundImage = image
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = soft.outputImage!
        mix.time = amount
        return mix.outputImage!.cropped(to: rect)
    }
}
