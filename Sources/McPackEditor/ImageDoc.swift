import AppKit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case pencil = "연필"
    case eraser = "지우개"
    case fill = "채우기"
    case picker = "스포이드"
    case select = "사각 선택"
    case wand = "마술봉"
    case move = "이동"
    var id: String { rawValue }
    /// 칠하는 도구 (3D 화면 붓에서 쓰는 것)
    static let paintTools: [Tool] = [.pencil, .eraser, .fill, .picker]
    var isPaint: Bool { Tool.paintTools.contains(self) }
    var symbol: String {
        switch self {
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        case .picker: return "eyedropper"
        case .select: return "rectangle.dashed"
        case .wand: return "wand.and.rays"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

struct RGBA: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    var hex: String { String(format: "%02X%02X%02X%02X", r, g, b, a) }
    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) { self.r = r; self.g = g; self.b = b; self.a = a }
    init?(hex: String) {
        guard hex.count == 8, let n = UInt32(hex, radix: 16) else { return nil }
        r = UInt8(n >> 24 & 255); g = UInt8(n >> 16 & 255); b = UInt8(n >> 8 & 255); a = UInt8(n & 255)
    }
}

final class ImageDoc: ObservableObject {
    let url: URL
    @Published var image: PixelImage
    @Published var dirty = false
    /// 선택 영역 (nil = 선택 없음 = 어디든 칠함). 크기는 w*h
    @Published var selection: [Bool]?
    /// 붙여넣었거나 이동 중인, 아직 그림에 안 박힌 조각
    @Published var floating: Floating?
    private var undoStack: [PixelImage] = []
    private var redoStack: [PixelImage] = []
    private var saved: PixelImage

    init(url: URL, image: PixelImage) {
        self.url = url
        self.image = image
        self.saved = image
    }

    var canUndo: Bool { !undoStack.isEmpty }
    func markDirty() { dirty = image != saved }
    var canRedo: Bool { !redoStack.isEmpty }

    func checkpoint() {
        undoStack.append(image)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(image)
        image = prev
        dirty = image != saved
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(image)
        image = next
        dirty = image != saved
    }

    func replace(with img: PixelImage) {
        checkpoint()
        if img.w != image.w || img.h != image.h { selection = nil; floating = nil } // 크기가 바뀌면 선택은 버림
        image = img
        dirty = image != saved
    }

    @discardableResult func save() -> Bool {
        guard let d = image.pngData() else { return false }
        do {
            try d.write(to: url, options: .atomic)
            saved = image; dirty = false
            return true
        } catch { return false }
    }

    // MARK: 그리기

    /// color.a = 칠할 색의 불투명도. blend면 기존 픽셀 위에 덮어 섞고, 아니면 RGBA를 그대로 써서 반투명을 정확히 찍는다.
    func plot(_ x: Int, _ y: Int, tool: Tool, color: RGBA, size: Int, blend: Bool, alphaLock: Bool, into img: inout PixelImage) {
        let start = -(size - 1) / 2
        for dy in 0..<size {
            for dx in 0..<size {
                let px = x + start + dx, py = y + start + dy
                guard img.inside(px, py) else { continue }
                if let sel = selection, sel.count == img.w * img.h, !sel[py * img.w + px] { continue } // 선택 밖은 안 칠함
                let i = img.index(px, py)
                switch tool {
                case .eraser:
                    if blend && color.a < 255 {
                        // 부분 지우기: 불투명도만큼 알파를 깎는다
                        let keep = 255 - Int(color.a)
                        img.px[i + 3] = UInt8(Int(img.px[i + 3]) * keep / 255)
                    } else {
                        img.px[i + 3] = 0
                    }
                case .pencil:
                    let dstA = Int(img.px[i + 3])
                    if alphaLock && dstA == 0 { continue }
                    if blend {
                        let sa = Double(color.a) / 255, da = Double(dstA) / 255
                        let oa = sa + da * (1 - sa)
                        if oa <= 0 { continue }
                        func mix(_ s: UInt8, _ d: UInt8) -> UInt8 {
                            UInt8(max(0, min(255, ((Double(s) * sa + Double(d) * da * (1 - sa)) / oa).rounded())))
                        }
                        img.px[i] = mix(color.r, img.px[i])
                        img.px[i + 1] = mix(color.g, img.px[i + 1])
                        img.px[i + 2] = mix(color.b, img.px[i + 2])
                        img.px[i + 3] = alphaLock ? UInt8(dstA) : UInt8((oa * 255).rounded())
                    } else {
                        img.px[i] = color.r; img.px[i + 1] = color.g; img.px[i + 2] = color.b
                        img.px[i + 3] = alphaLock ? UInt8(dstA) : color.a
                    }
                default: break
                }
            }
        }
    }

    /// 두 점 사이를 빈틈없이 잇는다 (빠르게 드래그해도 점이 띄엄띄엄 찍히지 않게).
    func line(from a: (Int, Int), to b: (Int, Int), tool: Tool, color: RGBA, size: Int, blend: Bool, alphaLock: Bool) {
        var img = image
        var x0 = a.0, y0 = a.1
        let x1 = b.0, y1 = b.1
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            plot(x0, y0, tool: tool, color: color, size: size, blend: blend, alphaLock: alphaLock, into: &img)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
        image = img
        dirty = image != saved
    }

    func flood(_ x: Int, _ y: Int, color: RGBA) {
        guard image.inside(x, y) else { return }
        var img = image
        let i0 = img.index(x, y)
        let target = RGBA(r: img.px[i0], g: img.px[i0 + 1], b: img.px[i0 + 2], a: img.px[i0 + 3])
        if target == color { return }
        func at(_ i: Int) -> RGBA { RGBA(r: img.px[i], g: img.px[i + 1], b: img.px[i + 2], a: img.px[i + 3]) }
        // 완전 투명한 칸은 RGB가 달라도 같은 "빈 칸"으로 본다
        func same(_ c: RGBA) -> Bool { (c.a == 0 && target.a == 0) || c == target }
        var stack = [(x, y)]
        var seen = [Bool](repeating: false, count: img.w * img.h)
        while let (cx, cy) = stack.popLast() {
            guard img.inside(cx, cy), !seen[cy * img.w + cx] else { continue }
            seen[cy * img.w + cx] = true
            if let sel = selection, sel.count == img.w * img.h, !sel[cy * img.w + cx] { continue } // 선택이 벽
            let i = img.index(cx, cy)
            guard same(at(i)) else { continue }
            img.px[i] = color.r; img.px[i + 1] = color.g; img.px[i + 2] = color.b; img.px[i + 3] = color.a
            stack.append((cx + 1, cy)); stack.append((cx - 1, cy))
            stack.append((cx, cy + 1)); stack.append((cx, cy - 1))
        }
        image = img
        dirty = image != saved
    }

    func pick(_ x: Int, _ y: Int) -> RGBA? {
        guard image.inside(x, y) else { return nil }
        let i = image.index(x, y)
        return RGBA(r: image.px[i], g: image.px[i + 1], b: image.px[i + 2], a: image.px[i + 3])
    }

    func flip(horizontal: Bool) {
        checkpoint()
        var img = image
        for y in 0..<img.h {
            for x in 0..<img.w {
                let sx = horizontal ? img.w - 1 - x : x
                let sy = horizontal ? y : img.h - 1 - y
                let d = img.index(x, y), s = image.index(sx, sy)
                for k in 0..<4 { img.px[d + k] = image.px[s + k] }
            }
        }
        image = img
        dirty = image != saved
    }

    func clearAll() {
        checkpoint()
        image = PixelImage(w: image.w, h: image.h)
        dirty = image != saved
    }
}
