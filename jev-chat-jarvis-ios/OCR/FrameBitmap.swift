import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct RGB: Sendable, Equatable {
    var r: Double
    var g: Double
    var b: Double

    var luma: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    /// HSV 饱和度，0...1。
    var saturation: Double {
        let high = max(r, g, b), low = min(r, g, b)
        return high <= 0 ? 0 : (high - low) / high
    }

    func distance(to other: RGB) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// 一帧解码后的 RGBA 像素，供 OCR、气泡取色、画面去重和长图拼接共用。
/// 只在流水线里短暂持有，不落盘。
nonisolated final class FrameBitmap: @unchecked Sendable {
    let image: CGImage
    let width: Int
    let height: Int
    private let bytesPerRow: Int
    private let pixels: [UInt8]

    init?(jpegData: Data) {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let width = decoded.width, height = decoded.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            // CGContext 的内存第 0 行对应图像顶部，所以下面按左上原点取像素。
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.image = decoded
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    var size: CGSize { CGSize(width: width, height: height) }

    func color(x: Int, y: Int) -> RGB {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let offset = cy * bytesPerRow + cx * 4
        return RGB(r: Double(pixels[offset]), g: Double(pixels[offset + 1]), b: Double(pixels[offset + 2]))
    }

    /// 多点取色后按通道取中位数，抗文字笔画和压缩噪点。
    func medianColor(at points: [CGPoint]) -> RGB? {
        let samples = points
            .filter { $0.x >= 0 && $0.y >= 0 && Int($0.x) < width && Int($0.y) < height }
            .map { color(x: Int($0.x), y: Int($0.y)) }
        guard !samples.isEmpty else { return nil }
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return RGB(r: mid(samples.map(\.r)), g: mid(samples.map(\.g)), b: mid(samples.map(\.b)))
    }

    /// 页面背景色：在内容区网格取样，去掉落在文字框里的点，取出现最多的量化颜色。
    func dominantColor(in region: CGRect, excluding boxes: [CGRect]) -> RGB? {
        var buckets: [Int: (count: Int, sum: RGB)] = [:]
        let stepX = max(region.width / 24, 1), stepY = max(region.height / 40, 1)
        var y = region.minY
        while y < region.maxY {
            var x = region.minX
            while x < region.maxX {
                let point = CGPoint(x: x, y: y)
                if !boxes.contains(where: { $0.insetBy(dx: -6, dy: -6).contains(point) }) {
                    let c = color(x: Int(x), y: Int(y))
                    let key = (Int(c.r) / 16) << 8 | (Int(c.g) / 16) << 4 | (Int(c.b) / 16)
                    var entry = buckets[key] ?? (0, RGB(r: 0, g: 0, b: 0))
                    entry.count += 1
                    entry.sum.r += c.r; entry.sum.g += c.g; entry.sum.b += c.b
                    buckets[key] = entry
                }
                x += stepX
            }
            y += stepY
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }), best.count > 0 else { return nil }
        let n = Double(best.count)
        return RGB(r: best.sum.r / n, g: best.sum.g / n, b: best.sum.b / n)
    }

    /// 单点亮度，用于气泡内部的像素级对齐。
    func luma(x: Int, y: Int) -> Double {
        let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
        let o = cy * bytesPerRow + cx * 4
        return 0.299 * Double(pixels[o]) + 0.587 * Double(pixels[o + 1]) + 0.114 * Double(pixels[o + 2])
    }

    /// 16×24 的亮度缩略图，判断“画面没变”以跳过 OCR（安卓 ocrSignature 刹车的等价物）。
    func thumbnail() -> [UInt8] {
        let cols = 16, rows = 24
        var out = [UInt8](repeating: 0, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                var sum = 0.0
                for sy in 0..<3 {
                    for sx in 0..<3 {
                        let x = (col * width + (sx * 2 + 1) * width / (cols * 6)) / cols
                        let y = (row * height + (sy * 2 + 1) * height / (rows * 6)) / rows
                        sum += color(x: x, y: y).luma
                    }
                }
                out[row * cols + col] = UInt8(min(255, sum / 9))
            }
        }
        return out
    }

    static func thumbnailDistance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    /// 裁出 [y, y+height) 的整行条带并压成 JPEG。长图只保存这些条带。
    func jpegStrip(y: Int, height stripHeight: Int, quality: Double = 0.8) -> Data? {
        let top = max(0, y), bottom = min(height, y + stripHeight)
        guard bottom > top, let cropped = image.cropping(to: CGRect(x: 0, y: top, width: width, height: bottom - top))
        else { return nil }
        return Self.encodeJPEG(cropped, quality: quality)
    }

    static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
