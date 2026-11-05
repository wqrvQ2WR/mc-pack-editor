import Foundation

/// 바닐라 에셋을 버전별 캐시 폴더에 풀어 둔다.
/// jar(GUI 텍스처·texts) + 에셋 인덱스의 텍스처(파노라마 진짜 그림은 jar엔 1x1이고 인덱스 쪽에 있음).
final class VanillaAssets {
    static let shared = VanillaAssets()
    let cacheRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/McPackEditor")
    private let lock = NSLock()

    func dir(_ v: McVersion) -> URL { cacheRoot.appendingPathComponent(v.id) }

    func isReady(_ v: McVersion) -> Bool {
        FileManager.default.fileExists(atPath: dir(v).appendingPathComponent(".ok-v3").path)
    }

    @discardableResult func ensure(_ v: McVersion) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let d = dir(v)
        let marker = d.appendingPathComponent(".ok-v3")
        if FileManager.default.fileExists(atPath: marker.path) { return d }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", "-o", v.jar.path, "assets/minecraft/textures/*", "assets/minecraft/texts/*",
                       "assets/minecraft/models/*", "assets/minecraft/items/*", "assets/minecraft/blockstates/*",
                       "data/minecraft/worldgen/biome/*", "-d", d.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        // 인덱스 쪽 텍스처/텍스트가 jar 것을 덮는다 (게임도 그렇게 읽음)
        let objects = MinecraftInstall.shared.assetObjects(v) ?? [:]
        let objDir = MinecraftInstall.shared.dir.appendingPathComponent("assets/objects")
        for (key, val) in objects where key.hasPrefix("minecraft/textures/") || key.hasPrefix("minecraft/texts/") {
            guard let o = val as? [String: Any], let h = o["hash"] as? String, h.count > 2 else { continue }
            let src = objDir.appendingPathComponent("\(h.prefix(2))/\(h)")
            let dst = d.appendingPathComponent("assets/" + key)
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        return d
    }

    /// rel = "assets/minecraft/..." 형태. 화면 그리는 중에 불리므로 절대 기다리지 않는다 (준비 전이면 nil).
    /// 풀기(ensure)는 Workspace.prepareVanilla가 백그라운드에서 한다.
    func url(_ v: McVersion, _ rel: String) -> URL? {
        guard isReady(v) else { return nil }
        let u = dir(v).appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: u.path) { return u }
        return objectURL(v, rel)
    }

    /// 캐시에 안 푼 것(소리 376MB 등)은 에셋 인덱스의 원본 파일을 그대로 가리킨다
    private var objectIndex: [String: [String: Any]] = [:]
    func objectURL(_ v: McVersion, _ rel: String) -> URL? {
        guard rel.hasPrefix("assets/") else { return nil }
        let key = String(rel.dropFirst("assets/".count))
        lock.lock()
        if objectIndex[v.id] == nil { objectIndex[v.id] = MinecraftInstall.shared.assetObjects(v) ?? [:] }
        let o = objectIndex[v.id]?[key] as? [String: Any]
        lock.unlock()
        guard let h = o?["hash"] as? String, h.count > 2 else { return nil }
        let u = MinecraftInstall.shared.dir.appendingPathComponent("assets/objects/\(h.prefix(2))/\(h)")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

// MARK: - nine-slice (.png.mcmeta의 gui.scaling)

struct GuiScaling {
    enum Kind { case stretch, tile, nineSlice }
    var kind: Kind
    var width: Int, height: Int
    var border: (l: Int, t: Int, r: Int, b: Int)
    var stretchInner = false

    static func read(_ pngURL: URL) -> GuiScaling? {
        let m = URL(fileURLWithPath: pngURL.path + ".mcmeta")
        guard let d = try? Data(contentsOf: m),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sc = (o["gui"] as? [String: Any])?["scaling"] as? [String: Any],
              let type = sc["type"] as? String else { return nil }
        let w = sc["width"] as? Int ?? 0, h = sc["height"] as? Int ?? 0
        switch type {
        case "nine_slice":
            var b = (l: 0, t: 0, r: 0, b: 0)
            if let n = sc["border"] as? Int { b = (n, n, n, n) }
            else if let bo = sc["border"] as? [String: Any] {
                b = (bo["left"] as? Int ?? 0, bo["top"] as? Int ?? 0, bo["right"] as? Int ?? 0, bo["bottom"] as? Int ?? 0)
            }
            return GuiScaling(kind: .nineSlice, width: w, height: h, border: b, stretchInner: sc["stretch_inner"] as? Bool ?? false)
        case "tile": return GuiScaling(kind: .tile, width: w, height: h, border: (0, 0, 0, 0))
        default: return GuiScaling(kind: .stretch, width: w, height: h, border: (0, 0, 0, 0))
        }
    }

    /// 텍스처를 GUI 크기 tw x th(텍스처 픽셀 단위, HD면 배율 곱함)로 나인슬라이스/타일 렌더
    func render(_ src: PixelImage, guiW: Int, guiH: Int) -> PixelImage {
        let sx = width > 0 ? Double(src.w) / Double(width) : 1
        let sy = height > 0 ? Double(src.h) / Double(height) : 1
        let tw = max(1, Int((Double(guiW) * sx).rounded())), th = max(1, Int((Double(guiH) * sy).rounded()))
        var out = PixelImage(w: tw, h: th)
        func copy(_ x: Int, _ y: Int, from fx: Int, _ fy: Int) {
            guard src.inside(fx, fy), out.inside(x, y) else { return }
            let s = src.index(fx, fy), d = out.index(x, y)
            out.px[d] = src.px[s]; out.px[d + 1] = src.px[s + 1]; out.px[d + 2] = src.px[s + 2]; out.px[d + 3] = src.px[s + 3]
        }
        if kind == .tile {
            for y in 0..<th { for x in 0..<tw { copy(x, y, from: x % src.w, y % src.h) } }
            return out
        }
        if kind == .stretch {
            for y in 0..<th { for x in 0..<tw { copy(x, y, from: x * src.w / tw, y * src.h / th) } }
            return out
        }
        let l = Int(Double(border.l) * sx), r = Int(Double(border.r) * sx)
        let t = Int(Double(border.t) * sy), b = Int(Double(border.b) * sy)
        let innerSW = max(1, src.w - l - r), innerSH = max(1, src.h - t - b)
        let innerTW = max(0, tw - l - r), innerTH = max(0, th - t - b)
        func mapX(_ x: Int) -> Int {
            if x < l { return x }
            if x >= tw - r { return src.w - (tw - x) }
            let ix = x - l
            return l + (stretchInner ? ix * innerSW / max(1, innerTW) : ix % innerSW)
        }
        func mapY(_ y: Int) -> Int {
            if y < t { return y }
            if y >= th - b { return src.h - (th - y) }
            let iy = y - t
            return t + (stretchInner ? iy * innerSH / max(1, innerTH) : iy % innerSH)
        }
        for y in 0..<th { let fy = mapY(y); for x in 0..<tw { copy(x, y, from: mapX(x), fy) } }
        return out
    }
}

extension PixelImage {
    func crop(_ r: CGRect) -> PixelImage {
        let x0 = max(0, Int(r.minX)), y0 = max(0, Int(r.minY))
        let w = max(1, min(Int(r.width), self.w - x0)), h = max(1, min(Int(r.height), self.h - y0))
        var out = PixelImage(w: w, h: h)
        for y in 0..<h {
            let s = index(x0, y0 + y), d = out.index(0, y)
            for k in 0..<(w * 4) { out.px[d + k] = px[s + k] }
        }
        return out
    }
}
