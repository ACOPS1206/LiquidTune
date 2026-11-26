// SPDX-License-Identifier: Apache-2.0
import AVKit
import SwiftUI
import UIKit

struct ArtworkPalette: Sendable {
    let hue: Double
    let saturation: Double

    func accent(dark: Bool) -> Color {
        Color(hue: hue, saturation: min(0.6, saturation), brightness: dark ? 0.96 : 0.62)
    }

    func backdrop(dark: Bool) -> Color {
        Color(hue: hue, saturation: min(0.90, saturation * (dark ? 1.30 : 0.68)),
              brightness: dark ? 0.48 : 0.97)
    }

    struct Sample {
        let palette: ArtworkPalette?
        let bassRegion: BassRegion?

        @MainActor func ribbonColors(dark: Bool) -> RibbonColors {
            // The background's dominant hue and its bass region already share this sample.
            // Lift their value for emitted light, keeping their original hues.
            let primary = palette.map {
                UIColor(hue: $0.hue, saturation: $0.saturation, brightness: 1, alpha: 1)
            } ?? .white
            let secondary = bassRegion.map { UIColor($0.color) } ?? primary
            return RibbonColors(
                first: Self.lightHex(primary, brightness: dark ? 1 : 0.86),
                second: Self.lightHex(secondary, brightness: dark ? 0.82 : 0.68)
            )
        }

        @MainActor private static func lightHex(_ color: UIColor, brightness: CGFloat) -> String {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
            let light = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            light.getRed(&r, green: &g, blue: &b, alpha: nil)
            return String(format: "#%02x%02x%02x",
                          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
    }

    struct BassRegion {
        let color: Color
        let masks: [UIImage]
    }

    private static let sampleSide = 20

    private struct ColorBucket {
        var count = 0
        var red = 0
        var green = 0
        var blue = 0

        var brightness: Double {
            (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / Double(count)
        }

        var color: Color {
            let divisor = Double(count) * 255
            return Color(.sRGB, red: Double(red) / divisor, green: Double(green) / divisor, blue: Double(blue) / divisor)
        }

        mutating func add(red: Int, green: Int, blue: Int) {
            count += 1
            self.red += red
            self.green += green
            self.blue += blue
        }
    }

    @MainActor private static func sampledPixels(_ image: UIImage, side: Int) -> [UInt8]? {
        guard let source = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let sampled = pixels.withUnsafeMutableBytes { bytes in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return sampled ? pixels : nil
    }

    @MainActor static func albumColors(from image: UIImage) -> [Color] {
        guard let pixels = sampledPixels(image, side: 40) else { return [] }
        var buckets: [Int: ColorBucket] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha >= 192 else { continue }
            let red = min(255, Int(pixels[offset]) * 255 / alpha)
            let green = min(255, Int(pixels[offset + 1]) * 255 / alpha)
            let blue = min(255, Int(pixels[offset + 2]) * 255 / alpha)
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

            // Group shades by hue, with separate buckets for dark and neutral tones.
            let key: Int
            if brightness < 0.20 {
                key = 12
            } else if saturation < 0.20 {
                key = brightness < 0.64 ? 13 : 14
            } else {
                // Center the red bucket on zero so red shades wrap into the same group.
                key = Int(hue * 12 + 0.5) % 12
            }
            buckets[key, default: ColorBucket()].add(red: red, green: green, blue: blue)
        }
        let ranked = buckets.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }
        return ranked.prefix(2).map { $0.value.color }
    }

    @MainActor static func sample(_ image: UIImage) -> Sample? {
        let side = sampleSide
        guard let pixels = sampledPixels(image, side: side) else { return nil }
        var bins = [Double](repeating: 0, count: 24)
        var strengths = bins
        var buckets: [Int: ColorBucket] = [:]
        var pixelKeys = [Int](repeating: -1, count: side * side)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            guard alpha >= 192 else { continue }
            let r = min(255, Int(pixels[offset]) * 255 / alpha)
            let g = min(255, Int(pixels[offset + 1]) * 255 / alpha)
            let b = min(255, Int(pixels[offset + 2]) * 255 / alpha)
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            pixelKeys[offset / 4] = key
            buckets[key, default: ColorBucket()].add(red: r, green: g, blue: b)
            let red = CGFloat(r) / 255
            let green = CGFloat(g) / 255
            let blue = CGFloat(b) / 255
            var hue = CGFloat.zero
            var saturation = CGFloat.zero
            var brightness = CGFloat.zero
            UIColor(red: red, green: green, blue: blue, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.18, brightness > 0.15 else { continue }
            let bin = min(23, Int(hue * 24))
            bins[bin] += Double(saturation)
            strengths[bin] += Double(saturation * saturation)
        }
        let palette: ArtworkPalette?
        if let index = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[index] > 0 {
            palette = ArtworkPalette(hue: (Double(index) + 0.5) / 24,
                                     saturation: min(0.68, max(0.29, strengths[index] / bins[index])))
        } else {
            palette = nil
        }

        // Ignore isolated edge pixels and compression noise when ranking the dark tones.
        let ranked = buckets.filter { $0.value.count >= 4 }.sorted { left, right in
            let leftBrightness = left.value.brightness
            let rightBrightness = right.value.brightness
            return leftBrightness == rightBrightness ? left.key < right.key : leftBrightness < rightBrightness
        }
        let chosen = ranked.dropFirst().first ?? ranked.first
            ?? buckets.max { $0.value.count < $1.value.count }
        let bassRegion = chosen.flatMap { choice -> BassRegion? in
            let masks = regionMasks(for: choice.key, in: pixelKeys)
            guard masks.count >= 2 else { return nil }
            return BassRegion(color: choice.value.color, masks: masks)
        }
        return Sample(palette: palette, bassRegion: bassRegion)
    }

    private static func regionMasks(for key: Int, in pixelKeys: [Int]) -> [UIImage] {
        let side = sampleSide
        let matches = pixelKeys.indices.filter { pixelKeys[$0] == key }
        guard !matches.isEmpty else { return [] }
        let distances = pixelKeys.indices.map { index -> Double in
            let x = index % side
            let y = index / side
            let nearest = matches.map { match -> Int in
                let dx = x - match % side
                let dy = y - match / side
                return dx * dx + dy * dy
            }.min() ?? 0
            return sqrt(Double(nearest))
        }

        // Store growth stages ahead of playback; the renderer interpolates between them.
        return [0.0, 0.425, 0.85, 1.275, 1.7].compactMap { radius in
            let bytes = distances.map { distance in UInt8(min(1, max(0, radius + 0.85 - distance)) * 255) }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true,
                                      intent: .defaultIntent) else { return nil }
            return UIImage(cgImage: image)
        }
    }
}

struct Cover: View {
    var track: Track?
    var knownImage: UIImage? = nil
    var radius: CGFloat = 12
    var placeholder = "music.note"
    @Environment(LibraryModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = knownImage ?? image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: placeholder)
                        .font(.system(size: min(proxy.size.width / 2, 50)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .accessibilityHidden(true)
        .task(id: track?.id) {
            image = nil
            guard knownImage == nil, let track else { return }
            let result = await model.artwork(for: track)
            if !Task.isCancelled { image = result }
        }
    }
}

struct RoutePicker: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.accessibilityLabel = "Audio output"
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}

func clock(_ interval: Double) -> String {
    guard interval.isFinite, interval >= 0, interval < 3_600_000 else { return "0:00" }
    let seconds = Int(interval)
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
