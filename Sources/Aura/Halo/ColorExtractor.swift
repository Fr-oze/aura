import Foundation
import CoreGraphics

/// Extrait deux couleurs dominantes et vives d'une pochette.
enum ColorExtractor {

    static func dominantPair(from image: CGImage) -> (RGB, RGB)? {
        let side = 40
        guard let context = CGContext(data: nil,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }

        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * side)

        // Histogramme de teintes, pondéré par saturation × luminosité.
        let binCount = 18
        var weight = [Double](repeating: 0, count: binCount)
        var sumR = [Double](repeating: 0, count: binCount)
        var sumG = [Double](repeating: 0, count: binCount)
        var sumB = [Double](repeating: 0, count: binCount)

        for y in 0..<side {
            for x in 0..<side {
                let offset = y * rowBytes + x * 4
                let r = Double(pixels[offset]) / 255
                let g = Double(pixels[offset + 1]) / 255
                let b = Double(pixels[offset + 2]) / 255
                let hsv = toHSV(r: r, g: g, b: b)
                guard hsv.s > 0.18, hsv.v > 0.2 else { continue }
                let bin = min(binCount - 1, Int(hsv.h * Double(binCount)))
                let w = hsv.s * hsv.v
                weight[bin] += w
                sumR[bin] += r * w
                sumG[bin] += g * w
                sumB[bin] += b * w
            }
        }

        guard let firstBin = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[firstBin] > 1 else {
            return nil // pochette grise ou presque : pas de couleur exploitable
        }

        func average(_ bin: Int) -> RGB {
            let total = max(weight[bin], 0.0001)
            return vivid(RGB(r: sumR[bin] / total, g: sumG[bin] / total, b: sumB[bin] / total))
        }

        let first = average(firstBin)

        // Deuxième couleur : la teinte la plus présente à bonne distance de la première.
        var secondBin: Int?
        var best = weight[firstBin] * 0.12
        for bin in 0..<binCount {
            let direct = abs(bin - firstBin)
            let distance = min(direct, binCount - direct)
            if distance >= 3 && weight[bin] > best {
                best = weight[bin]
                secondBin = bin
            }
        }

        if let secondBin {
            return (first, average(secondBin))
        }
        // Pochette monochrome : on décale légèrement la teinte pour garder un dégradé.
        let hsv = toHSV(r: first.r, g: first.g, b: first.b)
        var shifted = hsv.h + 0.09
        if shifted > 1 { shifted -= 1 }
        return (first, fromHSV(h: shifted, s: hsv.s, v: hsv.v))
    }

    /// Renforce saturation et luminosité pour une lueur qui se voit.
    static func vivid(_ color: RGB) -> RGB {
        let hsv = toHSV(r: color.r, g: color.g, b: color.b)
        return fromHSV(h: hsv.h, s: max(hsv.s, 0.62), v: max(hsv.v, 0.88))
    }

    static func toHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxValue = max(r, max(g, b))
        let minValue = min(r, min(g, b))
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0.00001 {
            if maxValue == r {
                hue = (g - b) / delta
                if hue < 0 { hue += 6 }
            } else if maxValue == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
        }
        let saturation = maxValue <= 0 ? 0 : delta / maxValue
        return (min(max(hue, 0), 0.999999), saturation, maxValue)
    }

    static func fromHSV(h: Double, s: Double, v: Double) -> RGB {
        let scaled = (h - h.rounded(.down)) * 6
        let sector = Int(scaled) % 6
        let fraction = scaled - Double(Int(scaled))
        let p = v * (1 - s)
        let q = v * (1 - s * fraction)
        let t = v * (1 - s * (1 - fraction))
        switch sector {
        case 0: return RGB(r: v, g: t, b: p)
        case 1: return RGB(r: q, g: v, b: p)
        case 2: return RGB(r: p, g: v, b: t)
        case 3: return RGB(r: p, g: q, b: v)
        case 4: return RGB(r: t, g: p, b: v)
        default: return RGB(r: v, g: p, b: q)
        }
    }
}
