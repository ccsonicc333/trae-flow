import AppKit
import SwiftUI

/// 从图片中提取主色调，用于生成动态渐变背景。
@MainActor
enum ImageColorExtractor {
    /// 提取图片中最具代表性的若干颜色。
    /// - Parameters:
    ///   - image: 输入图片
    ///   - count: 希望提取的颜色数量
    ///   - fallback: 提取失败时的回退颜色
    /// - Returns: 提取出的颜色数组；若失败返回 fallback
    static func dominantColors(
        from image: NSImage,
        count: Int = 3,
        fallback: [Color] = [Color(nsColor: .systemIndigo), Color(nsColor: .systemPurple)]
    ) -> [Color] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return fallback
        }

        let size = CGSize(width: 64, height: 64)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return fallback
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))

        guard let data = context.data else { return fallback }
        let pixels = data.bindMemory(to: UInt8.self, capacity: Int(size.width * size.height * 4))

        var samples: [(r: Double, g: Double, b: Double)] = []
        for y in stride(from: 0, to: Int(size.height), by: 2) {
            for x in stride(from: 0, to: Int(size.width), by: 2) {
                let offset = (y * Int(size.width) + x) * 4
                let r = Double(pixels[offset]) / 255.0
                let g = Double(pixels[offset + 1]) / 255.0
                let b = Double(pixels[offset + 2]) / 255.0
                let a = Double(pixels[offset + 3]) / 255.0
                guard a > 0.1 else { continue }
                samples.append((r, g, b))
            }
        }

        guard !samples.isEmpty else { return fallback }

        // 使用 k-means 聚类提取主色
        let clusters = kMeans(samples: samples, k: min(count, samples.count), iterations: 10)
        let colors = clusters.map { Color(red: $0.r, green: $0.g, blue: $0.b) }

        return colors.isEmpty ? fallback : colors
    }

    private static func kMeans(
        samples: [(r: Double, g: Double, b: Double)],
        k: Int,
        iterations: Int
    ) -> [(r: Double, g: Double, b: Double)] {
        guard k > 0, !samples.isEmpty else { return [] }

        // 初始化中心点：按亮度排序后均匀分布
        let sorted = samples.sorted { luminance($0) > luminance($1) }
        var centroids: [(r: Double, g: Double, b: Double)] = []
        for i in 0..<k {
            let index = (sorted.count * i) / max(k, 1)
            centroids.append(sorted[min(index, sorted.count - 1)])
        }

        for _ in 0..<iterations {
            var groups: [[(r: Double, g: Double, b: Double)]] = Array(repeating: [], count: k)

            for sample in samples {
                var bestIndex = 0
                var bestDistance = Double.infinity
                for (i, centroid) in centroids.enumerated() {
                    let d = colorDistance(sample, centroid)
                    if d < bestDistance {
                        bestDistance = d
                        bestIndex = i
                    }
                }
                groups[bestIndex].append(sample)
            }

            for i in 0..<k {
                let group = groups[i]
                if group.isEmpty { continue }
                let avgR = group.map { $0.r }.reduce(0, +) / Double(group.count)
                let avgG = group.map { $0.g }.reduce(0, +) / Double(group.count)
                let avgB = group.map { $0.b }.reduce(0, +) / Double(group.count)
                centroids[i] = (avgR, avgG, avgB)
            }
        }

        return centroids
    }

    private static func colorDistance(
        _ a: (r: Double, g: Double, b: Double),
        _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }

    private static func luminance(_ color: (r: Double, g: Double, b: Double)) -> Double {
        0.299 * color.r + 0.587 * color.g + 0.114 * color.b
    }
}
