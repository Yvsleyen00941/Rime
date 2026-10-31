import CoreGraphics
import Foundation

/// The alpha masks that let frost creep in from the screen edges with a crystalline front.
/// Computed on the CPU at quarter resolution; Core Animation stretches and cross-fades them.
struct FreezeFrames {
    /// Frost coverage, from clear to fully frozen.
    let frost: [CGImage]
    /// A bright band just behind the freezing front, the glint of fresh ice.
    let rim: [CGImage]

    init(size: CGSize, count: Int = 24) {
        let width = max(Int(size.width / 4), 8), height = max(Int(size.height / 4), 8)
        let field = Self.field(width: width, height: height)
        var frost: [CGImage] = [], rim: [CGImage] = []
        for i in 0..<count {
            // The front starts just outside the edges and ends past the most sheltered spot.
            let front = -0.05 + 1.30 * Float(i) / Float(count - 1)
            frost.append(Self.mask(width, height) { min(max((front - field[$0]) / 0.02, 0), 1) })
            rim.append(Self.mask(width, height) { max(0, 1 - abs(field[$0] - (front - 0.025)) / 0.022) })
        }
        self.frost = frost
        self.rim = rim
    }

    /// When each spot freezes: 0 at the screen edges, about 1 in the middle, roughened by three octaves of noise.
    private static func field(width: Int, height: Int) -> [Float] {
        var field = [Float](repeating: 0, count: width * height)
        let halfWidth = Float(width) / 2, halfHeight = Float(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let fromSide = min(Float(x), Float(width - 1 - x)) / halfWidth
                let fromTop = min(Float(y), Float(height - 1 - y)) / halfHeight
                let noise = 0.20 * valueNoise(x, y, cell: 40, seed: 11)
                    + 0.12 * valueNoise(x, y, cell: 14, seed: 23)
                    + 0.07 * valueNoise(x, y, cell: 5, seed: 37)
                field[y * width + x] = 0.70 * min(fromSide, fromTop) + noise
            }
        }
        return field
    }

    private static func valueNoise(_ x: Int, _ y: Int, cell: Float, seed: UInt32) -> Float {
        let fx = Float(x) / cell, fy = Float(y) / cell
        let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down))
        let tx = smooth(fx - Float(ix)), ty = smooth(fy - Float(iy))
        let top = lattice(ix, iy, seed) + (lattice(ix + 1, iy, seed) - lattice(ix, iy, seed)) * tx
        let bottom = lattice(ix, iy + 1, seed) + (lattice(ix + 1, iy + 1, seed) - lattice(ix, iy + 1, seed)) * tx
        return top + (bottom - top) * ty
    }

    private static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    private static func lattice(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393
            &+ UInt32(truncatingIfNeeded: y) &* 668_265_263
            &+ seed &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65_535
    }

    private static func mask(_ width: Int, _ height: Int, _ alpha: (Int) -> Float) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let a = UInt8(alpha(i) * 255)
            bytes[i * 4] = a
            bytes[i * 4 + 1] = a
            bytes[i * 4 + 2] = a
            bytes[i * 4 + 3] = a
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }
}
