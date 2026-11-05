import Foundation

/// 타이틀 배경 파노라마: panorama_0~5 = 앞, 오른쪽, 뒤, 왼쪽, 위, 아래.
/// 위(4)는 아래쪽 가장자리가 앞(0)의 위 가장자리에, 아래(5)는 위쪽 가장자리가 앞(0)의 아래 가장자리에 붙는다.
/// 3D 미리보기(SceneKit)와 360도 변환이 같은 축 정의를 쓴다.
enum Panorama {
    static let names = ["앞", "오른쪽", "뒤", "왼쪽", "위", "아래"]
    static func rel(_ i: Int) -> String { "assets/minecraft/textures/gui/title/background/panorama_\(i).png" }
    static let overlayRel = "assets/minecraft/textures/gui/title/background/panorama_overlay.png"

    typealias V3 = (x: Double, y: Double, z: Double)

    /// 면마다 (중심, 오른쪽, 위) 방향. 카메라는 원점에서 -z(앞)를 본다.
    static let basis: [(c: V3, r: V3, u: V3)] = [
        ((0, 0, -1), (1, 0, 0), (0, 1, 0)),
        ((1, 0, 0), (0, 0, 1), (0, 1, 0)),
        ((0, 0, 1), (-1, 0, 0), (0, 1, 0)),
        ((-1, 0, 0), (0, 0, -1), (0, 1, 0)),
        ((0, 1, 0), (1, 0, 0), (0, 0, 1)),
        ((0, -1, 0), (1, 0, 0), (0, 0, -1)),
    ]

    static func sample(_ img: PixelImage, _ fx: Double, _ fy: Double, wrapX: Bool) -> (Double, Double, Double, Double) {
        // 쌍선형 보간
        let x = fx - 0.5, y = fy - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let ax = x - Double(x0), ay = y - Double(y0)
        func px(_ xx: Int, _ yy: Int) -> (Double, Double, Double, Double) {
            var cx = xx
            if wrapX { cx = ((cx % img.w) + img.w) % img.w } else { cx = min(max(cx, 0), img.w - 1) }
            let cy = min(max(yy, 0), img.h - 1)
            let i = img.index(cx, cy)
            return (Double(img.px[i]), Double(img.px[i + 1]), Double(img.px[i + 2]), Double(img.px[i + 3]))
        }
        let a = px(x0, y0), b = px(x0 + 1, y0), c = px(x0, y0 + 1), d = px(x0 + 1, y0 + 1)
        func mix(_ p: Double, _ q: Double, _ r: Double, _ s: Double) -> Double {
            (p * (1 - ax) + q * ax) * (1 - ay) + (r * (1 - ax) + s * ax) * ay
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2), mix(a.3, b.3, c.3, d.3))
    }

    /// 360도(equirectangular, 가로:세로=2:1) 사진 한 장 -> 6면
    static func faces(fromEquirect src: PixelImage, size n: Int) -> [PixelImage] {
        var out: [PixelImage] = []
        for f in 0..<6 {
            let (c, r, u) = basis[f]
            var img = PixelImage(w: n, h: n)
            for y in 0..<n {
                let b = 1 - 2 * (Double(y) + 0.5) / Double(n)
                for x in 0..<n {
                    let a = 2 * (Double(x) + 0.5) / Double(n) - 1
                    let dx = c.x + a * r.x + b * u.x, dy = c.y + a * r.y + b * u.y, dz = c.z + a * r.z + b * u.z
                    let len = (dx * dx + dy * dy + dz * dz).squareRoot()
                    let lon = atan2(dx, -dz)            // 앞이 0, 오른쪽이 +
                    let lat = asin(dy / len)
                    let sx = (lon / (2 * .pi) + 0.5) * Double(src.w)
                    let sy = (0.5 - lat / .pi) * Double(src.h)
                    let p = sample(src, sx, sy, wrapX: true)
                    let i = img.index(x, y)
                    img.px[i] = UInt8(max(0, min(255, p.0.rounded())))
                    img.px[i + 1] = UInt8(max(0, min(255, p.1.rounded())))
                    img.px[i + 2] = UInt8(max(0, min(255, p.2.rounded())))
                    img.px[i + 3] = UInt8(max(0, min(255, p.3.rounded())))
                }
            }
            out.append(img)
        }
        return out
    }

    /// 6면 -> 360도 사진 (내보내기·이음새 확인용)
    static func equirect(fromFaces faces: [PixelImage], width w: Int) -> PixelImage {
        let h = w / 2
        var out = PixelImage(w: w, h: h)
        for y in 0..<h {
            let lat = (0.5 - (Double(y) + 0.5) / Double(h)) * .pi
            for x in 0..<w {
                let lon = ((Double(x) + 0.5) / Double(w) - 0.5) * 2 * .pi
                let dx = cos(lat) * sin(lon), dy = sin(lat), dz = -cos(lat) * cos(lon)
                // 가장 큰 축으로 면 고르기
                var best = 0, bestDot = -Double.infinity
                for f in 0..<6 {
                    let c = basis[f].c
                    let dot = dx * c.x + dy * c.y + dz * c.z
                    if dot > bestDot { bestDot = dot; best = f }
                }
                let (c, r, u) = basis[best]
                let t = 1 / (dx * c.x + dy * c.y + dz * c.z)
                let px = dx * t, py = dy * t, pz = dz * t
                let a = px * r.x + py * r.y + pz * r.z
                let b = px * u.x + py * u.y + pz * u.z
                let face = faces[best]
                let sx = (a + 1) / 2 * Double(face.w), sy = (1 - b) / 2 * Double(face.h)
                let p = sample(face, sx, sy, wrapX: false)
                let i = out.index(x, y)
                out.px[i] = UInt8(p.0.rounded()); out.px[i + 1] = UInt8(p.1.rounded())
                out.px[i + 2] = UInt8(p.2.rounded()); out.px[i + 3] = UInt8(p.3.rounded())
            }
        }
        return out
    }
}
