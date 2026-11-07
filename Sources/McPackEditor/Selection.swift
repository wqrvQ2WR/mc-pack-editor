import AppKit

/// 아직 그림에 박히지 않은 조각 (붙여넣기·이동 중)
struct Floating: Equatable {
    var img: PixelImage
    var x: Int
    var y: Int
    var lifted: Bool        // true면 그림에서 떼어 온 것 (취소하면 원래대로 되돌림)
}

enum SelectMode { case replace, add, subtract }

/// 앱 안 클립보드 (픽셀 그대로). 다른 앱으로는 PNG로도 같이 내보낸다.
enum PixelClipboard {
    static var image: PixelImage?
    static var changeCount = -1

    static func write(_ img: PixelImage) {
        image = img
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = img.pngData() { pb.setData(png, forType: .png) }
        changeCount = pb.changeCount
    }

    /// 다른 앱에서 복사한 그림도 읽는다 (그 경우 macOS를 거치며 반투명 색이 조금 달라질 수 있음)
    static func read() -> PixelImage? {
        let pb = NSPasteboard.general
        if pb.changeCount == changeCount, let image { return image }
        for t in [NSPasteboard.PasteboardType.png, .tiff] {
            if let d = pb.data(forType: t), let src = CGImageSourceCreateWithData(d as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) { return PixelImage(cg: cg) }
        }
        if let ns = NSImage(pasteboard: pb), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return PixelImage(cg: cg)
        }
        return nil
    }
}

extension ImageDoc {
    var w: Int { image.w }
    var h: Int { image.h }
    var hasSelection: Bool { selection != nil }

    private func combine(_ mask: [Bool], _ mode: SelectMode) {
        let old = selection ?? [Bool](repeating: false, count: w * h)
        var out = mask
        switch mode {
        case .replace: break
        case .add: for i in out.indices { out[i] = old[i] || mask[i] }
        case .subtract: for i in out.indices { out[i] = old[i] && !mask[i] }
        }
        selection = out.contains(true) ? out : nil
    }

    func selectRect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, mode: SelectMode = .replace) {
        let a = (max(0, min(x0, x1)), max(0, min(y0, y1)))
        let b = (min(w - 1, max(x0, x1)), min(h - 1, max(y0, y1)))
        var m = [Bool](repeating: false, count: w * h)
        if a.0 <= b.0 && a.1 <= b.1 {
            for y in a.1...b.1 { for x in a.0...b.0 { m[y * w + x] = true } }
        }
        combine(m, mode)
    }

    /// 마술봉: 비슷한 색(허용 오차) 고르기. contiguous면 이어진 곳만.
    func selectWand(_ x: Int, _ y: Int, tolerance: Int, contiguous: Bool, mode: SelectMode = .replace) {
        guard image.inside(x, y) else { return }
        let i0 = image.index(x, y)
        let t = Array(image.px[i0..<i0 + 4])
        func near(_ i: Int) -> Bool {
            // 둘 다 완전 투명이면 같은 색
            if t[3] == 0 && image.px[i + 3] == 0 { return true }
            for k in 0..<4 where abs(Int(image.px[i + k]) - Int(t[k])) > tolerance { return false }
            return true
        }
        var m = [Bool](repeating: false, count: w * h)
        if contiguous {
            var stack = [(x, y)]
            while let (cx, cy) = stack.popLast() {
                guard image.inside(cx, cy), !m[cy * w + cx], near(image.index(cx, cy)) else { continue }
                m[cy * w + cx] = true
                stack += [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
            }
        } else {
            for yy in 0..<h { for xx in 0..<w where near(image.index(xx, yy)) { m[yy * w + xx] = true } }
        }
        combine(m, mode)
    }

    func selectAll() { selection = [Bool](repeating: true, count: w * h) }
    func deselect() { selection = nil }
    func invertSelection() {
        guard let s = selection else { selectAll(); return }
        let inv = s.map { !$0 }
        selection = inv.contains(true) ? inv : nil
    }

    /// 투명하지 않은 곳 전부 고르기
    func selectOpaque() {
        var m = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where image.px[i * 4 + 3] > 0 { m[i] = true }
        selection = m.contains(true) ? m : nil
    }

    var selectionBounds: (x: Int, y: Int, w: Int, h: Int)? {
        guard let s = selection else { return nil }
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where s[y * w + x] {
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        } }
        return x1 < 0 ? nil : (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }

    var selectedCount: Int { selection?.filter { $0 }.count ?? 0 }

    /// 선택한 곳만 잘라낸 그림 (선택 밖은 투명). 선택이 없으면 전체.
    func copySelection() -> PixelImage {
        guard let s = selection, let b = selectionBounds else { return image }
        var out = PixelImage(w: b.w, h: b.h)
        for y in 0..<b.h { for x in 0..<b.w where s[(b.y + y) * w + b.x + x] {
            let si = image.index(b.x + x, b.y + y), di = out.index(x, y)
            for k in 0..<4 { out.px[di + k] = image.px[si + k] }
        } }
        return out
    }

    /// 선택한 곳 지우기 (투명하게). 선택이 없으면 아무것도 안 함.
    func deleteSelection() {
        guard let s = selection else { return }
        checkpoint()
        var img = image
        for i in 0..<(w * h) where s[i] { for k in 0..<4 { img.px[i * 4 + k] = 0 } }
        image = img
        markDirty()
    }

    func fillSelection(_ c: RGBA) {
        checkpoint()
        var img = image
        for i in 0..<(w * h) where selection?[i] ?? true {
            img.px[i * 4] = c.r; img.px[i * 4 + 1] = c.g; img.px[i * 4 + 2] = c.b; img.px[i * 4 + 3] = c.a
        }
        image = img
        markDirty()
    }

    // MARK: 떠 있는 조각

    /// 붙여넣기: 선택이 있으면 그 자리, 없으면 왼쪽 위
    func paste(_ img: PixelImage) {
        commitFloating()
        let at = selectionBounds.map { ($0.x, $0.y) } ?? (0, 0)
        floating = Floating(img: img, x: at.0, y: at.1, lifted: false)
        selectFloatingRect()
    }

    /// 이동 시작: 선택한 곳(없으면 전체)을 그림에서 떼어 띄운다
    func lift() {
        guard floating == nil else { return }
        if selection == nil { selectOpaque() }
        guard let b = selectionBounds else { return }
        let piece = copySelection()
        checkpoint()
        var img = image
        for i in 0..<(w * h) where selection?[i] ?? false { for k in 0..<4 { img.px[i * 4 + k] = 0 } }
        image = img
        floating = Floating(img: piece, x: b.x, y: b.y, lifted: true)
    }

    func moveFloating(to x: Int, _ y: Int) {
        guard var f = floating else { return }
        f.x = x; f.y = y
        floating = f
        selectFloatingRect()
    }

    private func selectFloatingRect() {
        guard let f = floating else { return }
        var m = [Bool](repeating: false, count: w * h)
        for y in 0..<f.img.h { for x in 0..<f.img.w where f.img.px[f.img.index(x, y) + 3] > 0 {
            let px = f.x + x, py = f.y + y
            if px >= 0, py >= 0, px < w, py < h { m[py * w + px] = true }
        } }
        selection = m.contains(true) ? m : nil
    }

    /// 떠 있는 조각을 그림에 박는다 (투명 부분은 아래가 보이게 섞음)
    func commitFloating() {
        guard let f = floating else { return }
        if !f.lifted { checkpoint() }
        image = composite()
        floating = nil
        markDirty()
    }

    /// 취소: 떼어 온 거면 원래 자리로 되돌리고, 붙여넣은 거면 버린다
    func cancelFloating() {
        guard let f = floating else { return }
        floating = nil
        if f.lifted { undo() }
        selection = nil
    }

    /// 화면에 보일 그림 (떠 있는 조각까지 합친 것)
    func composite() -> PixelImage {
        guard let f = floating else { return image }
        var out = image
        for y in 0..<f.img.h { for x in 0..<f.img.w {
            let px = f.x + x, py = f.y + y
            guard out.inside(px, py) else { continue }
            let s = f.img.index(x, y), d = out.index(px, py)
            let sa = Double(f.img.px[s + 3]) / 255
            if sa == 0 { continue }
            if sa == 1 { for k in 0..<4 { out.px[d + k] = f.img.px[s + k] }; continue }
            let da = Double(out.px[d + 3]) / 255
            let oa = sa + da * (1 - sa)
            for k in 0..<3 {
                let v = (Double(f.img.px[s + k]) * sa + Double(out.px[d + k]) * da * (1 - sa)) / oa
                out.px[d + k] = UInt8(max(0, min(255, v.rounded())))
            }
            out.px[d + 3] = UInt8((oa * 255).rounded())
        } }
        return out
    }

    /// 떠 있는 조각이나 선택한 곳 뒤집기
    func flipSelection(horizontal: Bool) {
        if floating == nil && selection == nil { flip(horizontal: horizontal); return }
        lift()
        guard var f = floating else { return }
        var o = f.img
        for y in 0..<o.h { for x in 0..<o.w {
            let sx = horizontal ? o.w - 1 - x : x, sy = horizontal ? y : o.h - 1 - y
            let d = o.index(x, y), s = f.img.index(sx, sy)
            for k in 0..<4 { o.px[d + k] = f.img.px[s + k] }
        } }
        f.img = o
        floating = f
        selectFloatingRect()
    }

    /// 선택 테두리 (픽셀 경계선) - 큰 그림은 사각형만
    func selectionOutline(zoom z: CGFloat) -> CGPath? {
        guard let s = selection else { return nil }
        let p = CGMutablePath()
        if w * h > 512 * 512, let b = selectionBounds {
            p.addRect(CGRect(x: CGFloat(b.x) * z, y: CGFloat(b.y) * z, width: CGFloat(b.w) * z, height: CGFloat(b.h) * z))
            return p
        }
        func on(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && s[y * w + x] }
        for y in 0..<h { for x in 0..<w where s[y * w + x] {
            let X = CGFloat(x) * z, Y = CGFloat(y) * z
            if !on(x, y - 1) { p.move(to: CGPoint(x: X, y: Y)); p.addLine(to: CGPoint(x: X + z, y: Y)) }
            if !on(x, y + 1) { p.move(to: CGPoint(x: X, y: Y + z)); p.addLine(to: CGPoint(x: X + z, y: Y + z)) }
            if !on(x - 1, y) { p.move(to: CGPoint(x: X, y: Y)); p.addLine(to: CGPoint(x: X, y: Y + z)) }
            if !on(x + 1, y) { p.move(to: CGPoint(x: X + z, y: Y)); p.addLine(to: CGPoint(x: X + z, y: Y + z)) }
        } }
        return p
    }
}
