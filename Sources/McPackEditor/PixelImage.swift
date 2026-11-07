import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 비-premultiplied RGBA 버퍼. canvas가 알파 0 근처 색을 뭉개는 문제를 피하려고 직접 들고 있는다.
struct PixelImage: Equatable {
    var w: Int
    var h: Int
    var px: [UInt8]

    init(w: Int, h: Int) {
        self.w = w
        self.h = h
        self.px = [UInt8](repeating: 0, count: w * h * 4)
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func load(_ url: URL) -> PixelImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return PixelImage(cg: cg)
    }

    init?(cg: CGImage) {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        // 빠른 길: PNG가 이미 비-premultiplied RGBA8(sRGB)이면 바이트를 그대로 복사해서 반투명 색 손실 0
        let order = cg.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        if cg.bitsPerComponent == 8, cg.bitsPerPixel == 32, cg.alphaInfo == .last,
           order == 0 || order == CGBitmapInfo.byteOrder32Big.rawValue,
           cg.colorSpace?.name == CGColorSpace.sRGB,
           let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let bpr = cg.bytesPerRow
            for y in 0..<h {
                for x in 0..<(w * 4) { buf[y * w * 4 + x] = bytes[y * bpr + x] }
            }
            self.w = w; self.h = h; self.px = buf
            return
        }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: PixelImage.space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        PixelImage.unpremultiply(&buf)
        self.w = w; self.h = h; self.px = buf
    }

    static func unpremultiply(_ b: inout [UInt8]) {
        var i = 0
        while i < b.count {
            let a = Int(b[i + 3])
            if a > 0 && a < 255 {
                b[i] = UInt8(min(255, (Int(b[i]) * 255 + a / 2) / a))
                b[i + 1] = UInt8(min(255, (Int(b[i + 1]) * 255 + a / 2) / a))
                b[i + 2] = UInt8(min(255, (Int(b[i + 2]) * 255 + a / 2) / a))
            }
            i += 4
        }
    }

    func cgImage() -> CGImage? {
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: PixelImage.space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func pngData() -> Data? {
        guard let cg = cgImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * w + x) * 4 }
    func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }

    // MARK: 가져온 이미지를 이 크기에 맞추기

    enum Fit: String, CaseIterable, Identifiable {
        case original = "이미지 크기 그대로"
        case contain = "비율 유지 (여백 투명)"
        case cover = "비율 유지 (꽉 채우고 자르기)"
        case stretch = "늘려서 맞추기"
        var id: String { rawValue }
    }

    /// 외부 이미지를 (w x h)에 맞춰 새 버퍼로 만든다. 사진이 늘어나지 않게 기본은 contain.
    static func fitted(_ src: CGImage, w: Int, h: Int, fit: Fit, smooth: Bool) -> PixelImage? {
        if fit == .original { return PixelImage(cg: src) } // 지금 크기는 무시하고 이미지 크기로
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let sw = CGFloat(src.width), sh = CGFloat(src.height)
        var dest = CGRect(x: 0, y: 0, width: w, height: h)
        switch fit {
        case .stretch, .original: break
        case .contain:
            let s = min(CGFloat(w) / sw, CGFloat(h) / sh)
            dest = CGRect(x: (CGFloat(w) - sw * s) / 2, y: (CGFloat(h) - sh * s) / 2, width: sw * s, height: sh * s)
        case .cover:
            let s = max(CGFloat(w) / sw, CGFloat(h) / sh)
            dest = CGRect(x: (CGFloat(w) - sw * s) / 2, y: (CGFloat(h) - sh * s) / 2, width: sw * s, height: sh * s)
        }
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = smooth ? .high : .none
            ctx.draw(src, in: dest)
            return true
        }
        guard ok else { return nil }
        unpremultiply(&buf)
        var out = PixelImage(w: w, h: h)
        out.px = buf
        return out
    }
}
