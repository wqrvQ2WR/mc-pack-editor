import AppKit
import SceneKit
import simd

// MARK: - 모델 JSON 문서

final class ModelDoc: ObservableObject {
    let url: URL
    @Published private(set) var root: [String: Any] = [:]
    @Published private(set) var dirty = false
    @Published private(set) var loadError: String?
    private var undoStack: [Data] = []

    init(url: URL) { self.url = url; load() }

    func load() {
        loadError = nil
        if let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            root = o
        } else {
            root = [:]
            loadError = "모델 JSON을 읽지 못했어요. JSON 탭에서 고치세요."
        }
        dirty = false
        undoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// 바꾸기 전 상태를 남기고 고친다. coalesce면 같은 손놀림(슬라이더 끌기)은 한 번만 남긴다.
    func mutate(coalesce: String? = nil, _ f: (inout [String: Any]) -> Void) {
        if coalesce == nil || coalesce != lastCoalesce, let snap = try? JSONSerialization.data(withJSONObject: root) {
            undoStack.append(snap)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        lastCoalesce = coalesce
        var r = root
        f(&r)
        root = r
        dirty = true
    }
    private var lastCoalesce: String?
    func endCoalesce() { lastCoalesce = nil }

    func undo() {
        guard let d = undoStack.popLast(), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        root = o; dirty = true; lastCoalesce = nil
    }

    @discardableResult func save() -> Bool {
        guard loadError == nil,
              let d = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        do { try (d + Data("\n".utf8)).write(to: url, options: .atomic); dirty = false; return true } catch { return false }
    }

    // 편의 접근
    var elements: [[String: Any]]? { root["elements"] as? [[String: Any]] }
    var textures: [String: String] { (root["textures"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:] }
    var parent: String? { root["parent"] as? String }

    func setElement(_ i: Int, _ key: String, _ value: Any?, coalesce: String? = nil) {
        mutate(coalesce: coalesce) { r in
            var els = r["elements"] as? [[String: Any]] ?? []
            guard els.indices.contains(i) else { return }
            els[i][key] = value
            r["elements"] = els
        }
    }

    func setFace(_ i: Int, _ dir: String, _ key: String, _ value: Any?) {
        mutate { r in
            var els = r["elements"] as? [[String: Any]] ?? []
            guard els.indices.contains(i) else { return }
            var faces = els[i]["faces"] as? [String: Any] ?? [:]
            var f = faces[dir] as? [String: Any] ?? [:]
            f[key] = value
            faces[dir] = f
            els[i]["faces"] = faces
            r["elements"] = els
        }
    }
}

func nums(_ v: Any?) -> [Double] { (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
func vec3(_ v: Any?, _ def: SIMD3<Double> = .zero) -> SIMD3<Double> {
    let a = nums(v); return a.count >= 3 ? SIMD3(a[0], a[1], a[2]) : def
}

// MARK: - 부모 따라가며 합치기

struct ResolvedModel {
    var textures: [String: String] = [:]
    var elements: [[String: Any]]?
    var elementsOwn = false          // 이 파일 자체에 elements가 있음
    var elementsFrom: String?
    var display: [String: [String: Any]] = [:]
    var displayFrom: [String: String] = [:]
    var generated = false            // builtin/generated (평면 아이템)
    var builtinEntity = false
    var chain: [String] = []
    var missing: String?

    func texture(_ ref: String) -> String? {
        var r = ref
        for _ in 0..<12 {
            guard r.hasPrefix("#") else { return r }
            guard let n = textures[String(r.dropFirst())] else { return nil }
            r = n
        }
        return nil
    }
}

enum ModelIDs {
    static func split(_ id: String) -> (String, String) {
        if let c = id.firstIndex(of: ":") { return (String(id[..<c]), String(id[id.index(after: c)...])) }
        return ("minecraft", id)
    }
    static func modelRel(_ id: String) -> String { let (ns, p) = split(id); return "assets/\(ns)/models/\(p).json" }
    static func textureRel(_ id: String) -> String { let (ns, p) = split(id); return "assets/\(ns)/textures/\(p).png" }
    /// assets/<ns>/models/<path>.json -> ns:path
    static func id(fromRel rel: String) -> String? {
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "assets", parts[2] == "models" else { return nil }
        return parts[1] + ":" + parts[3...].joined(separator: "/").replacingOccurrences(of: ".json", with: "")
    }
}

extension Workspace {
    func resolveModel(_ top: [String: Any], id: String) -> ResolvedModel {
        var r = ResolvedModel()
        var cur: [String: Any]? = top
        var curID = id
        for depth in 0..<24 {
            guard let m = cur else { r.missing = curID; break }
            r.chain.append(curID)
            for (k, v) in (m["textures"] as? [String: Any]) ?? [:] where r.textures[k] == nil {
                if let s = v as? String { r.textures[k] = s }
            }
            if r.elements == nil, let e = m["elements"] as? [[String: Any]] {
                r.elements = e; r.elementsFrom = curID; r.elementsOwn = depth == 0
            }
            for (slot, v) in (m["display"] as? [String: Any]) ?? [:] where r.display[slot] == nil {
                if let d = v as? [String: Any] { r.display[slot] = d; r.displayFrom[slot] = curID }
            }
            guard let p = m["parent"] as? String else { break }
            let (_, path) = ModelIDs.split(p)
            if path == "builtin/generated" { r.generated = r.elements == nil; break }
            if path == "builtin/entity" { r.builtinEntity = true; break }
            curID = p
            cur = modelJSON(p)
        }
        return r
    }

    /// 다른 모델 JSON (열려 있으면 편집 중인 내용)
    func modelJSON(_ id: String) -> [String: Any]? {
        let rel = ModelIDs.modelRel(id)
        if let u = packURL(rel), let d = openModelDoc(u) { return d.root }
        guard let u = resolve(rel), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

// MARK: - SceneKit으로 그리기

struct FaceInfo {
    let element: Int        // -1: 평면 아이템 레이어
    let dir: String
    let textureRel: String?
    let texW: Int, frameH: Int
}

enum ModelScene {
    static let dirs = ["north", "south", "west", "east", "up", "down"]
    static let dirLabel = ["north": "북(앞 -z)", "south": "남(+z)", "west": "서(-x)", "east": "동(+x)", "up": "위", "down": "아래"]
    /// 게임의 방향별 기본 명암
    static let dirShade: [String: CGFloat] = ["up": 1, "down": 0.5, "north": 0.8, "south": 0.8, "west": 0.6, "east": 0.6]

    /// 면 꼭짓점 [왼위, 오위, 오아래, 왼아래] (바깥에서 봤을 때), 0~16 좌표
    static func faceVerts(_ dir: String, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> [SIMD3<Double>] {
        let (x0, y0, z0, x1, y1, z1) = (a.x, a.y, a.z, b.x, b.y, b.z)
        switch dir {
        case "north": return [[x1, y1, z0], [x0, y1, z0], [x0, y0, z0], [x1, y0, z0]]
        case "south": return [[x0, y1, z1], [x1, y1, z1], [x1, y0, z1], [x0, y0, z1]]
        case "west": return [[x0, y1, z0], [x0, y1, z1], [x0, y0, z1], [x0, y0, z0]]
        case "east": return [[x1, y1, z1], [x1, y1, z0], [x1, y0, z0], [x1, y0, z1]]
        case "up": return [[x0, y1, z0], [x1, y1, z0], [x1, y1, z1], [x0, y1, z1]]
        default: return [[x0, y0, z1], [x1, y0, z1], [x1, y0, z0], [x0, y0, z0]]
        }
    }

    /// uv가 없을 때 게임이 쓰는 기본값
    static func defaultUV(_ dir: String, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> [Double] {
        switch dir {
        case "north": return [16 - b.x, 16 - b.y, 16 - a.x, 16 - a.y]
        case "south": return [a.x, 16 - b.y, b.x, 16 - a.y]
        case "west": return [a.z, 16 - b.y, b.z, 16 - a.y]
        case "east": return [16 - b.z, 16 - b.y, 16 - a.z, 16 - a.y]
        case "up": return [a.x, a.z, b.x, b.z]
        default: return [a.x, 16 - b.z, b.x, 16 - a.z]
        }
    }

    /// 요소 회전(축·각도·원점·rescale) 적용
    static func rotate(_ p: SIMD3<Double>, _ rot: [String: Any]?) -> SIMD3<Double> {
        guard let rot, let angle = (rot["angle"] as? NSNumber)?.doubleValue, angle != 0 else { return p }
        let o = vec3(rot["origin"], [8, 8, 8])
        let axis = rot["axis"] as? String ?? "y"
        let rad = angle * .pi / 180
        var d = p - o
        if (rot["rescale"] as? Bool) == true {
            let s = 1 / max(0.0001, cos(abs(rad)))
            switch axis {
            case "x": d.y *= s; d.z *= s
            case "z": d.x *= s; d.y *= s
            default: d.x *= s; d.z *= s
            }
        }
        let c = cos(rad), s = sin(rad)
        switch axis {
        case "x": d = [d.x, d.y * c - d.z * s, d.y * s + d.z * c]
        case "z": d = [d.x * c - d.y * s, d.x * s + d.y * c, d.z]
        default: d = [d.x * c + d.z * s, d.y, -d.x * s + d.z * c]
        }
        return o + d
    }

    struct Options {
        var dark = false            // 어두운 곳(밝기 0)에서 보기: light_emission만 빛남
        var selected: Int?
    }

    /// 텍스처 첫 프레임 (애니메이션 세로 스트립이면 위 정사각형)
    static func frame(_ img: PixelImage) -> PixelImage {
        img.h > img.w && img.h % img.w == 0 ? img.crop(CGRect(x: 0, y: 0, width: img.w, height: img.w)) : img
    }

    static func build(_ m: ResolvedModel, ws: Workspace, opt: Options) -> (SCNNode, [String: FaceInfo]) {
        let node = SCNNode()
        var info: [String: FaceInfo] = [:]
        var texCache: [String: (CGImage?, Int, Int)] = [:]
        func tex(_ rel: String?) -> (CGImage?, Int, Int) {
            guard let rel else { return (nil, 16, 16) }
            if let c = texCache[rel] { return c }
            var r: (CGImage?, Int, Int) = (nil, 16, 16)
            if let img = ws.pixelImage(rel) { let f = frame(img); r = (f.cgImage(), f.w, f.h) }
            texCache[rel] = r
            return r
        }
        func toScene(_ p: SIMD3<Double>) -> SCNVector3 { SCNVector3(p.x - 8, p.y - 8, p.z - 8) }

        if m.generated {
            // 평면 아이템: layer0, layer1… 을 겹쳐 그림 (게임은 두께를 만들지만 여기선 앞뒤 평면)
            var i = 0
            while let ref = m.textures["layer\(i)"] {
                let rel = m.texture(ref).map(ModelIDs.textureRel)
                let (cg, tw, th) = tex(rel)
                let z = 8.5 + Double(i) * 0.01, zb = 7.5 - Double(i) * 0.01
                let mat = pixelMaterial(cg)
                let front = quadGeometry([toScene([0, 16, z]), toScene([16, 16, z]), toScene([16, 0, z]), toScene([0, 0, z])],
                                         [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], mat)
                let back = quadGeometry([toScene([16, 16, zb]), toScene([0, 16, zb]), toScene([0, 0, zb]), toScene([16, 0, zb])],
                                        [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)], mat)
                for (g, nm) in [(front, "L\(i):south"), (back, "L\(i):north")] {
                    let n = SCNNode(geometry: g); n.name = nm
                    if opt.dark { mat.multiply.contents = NSColor(white: 0.15, alpha: 1) }
                    node.addChildNode(n)
                    info[nm] = FaceInfo(element: -1, dir: nm, textureRel: rel, texW: tw, frameH: th)
                }
                i += 1
            }
            return (node, info)
        }

        for (ei, el) in (m.elements ?? []).enumerated() {
            let a = vec3(el["from"]), b = vec3(el["to"], [16, 16, 16])
            let rot = el["rotation"] as? [String: Any]
            let shade = (el["shade"] as? Bool) ?? true
            let emission = (el["light_emission"] as? NSNumber)?.doubleValue ?? 0
            for (dir, fv) in (el["faces"] as? [String: Any]) ?? [:] {
                guard let f = fv as? [String: Any] else { continue }
                let rel = (f["texture"] as? String).flatMap { m.texture($0) }.map(ModelIDs.textureRel)
                let (cg, tw, th) = tex(rel)
                var uv = nums(f["uv"]); if uv.count < 4 { uv = defaultUV(dir, a, b) }
                // 꼭짓점별 uv (왼위, 오위, 오아래, 왼아래), 면 회전은 시계 방향으로 돌림
                var corners = [CGPoint(x: uv[0], y: uv[1]), CGPoint(x: uv[2], y: uv[1]), CGPoint(x: uv[2], y: uv[3]), CGPoint(x: uv[0], y: uv[3])]
                let frot = ((f["rotation"] as? NSNumber)?.intValue ?? 0) / 90
                for _ in 0..<((4 - frot % 4) % 4) { corners.append(corners.removeFirst()) }
                let tuv = corners.map { CGPoint(x: $0.x / 16, y: $0.y / 16) }
                let verts = faceVerts(dir, a, b).map { toScene(rotate($0, rot)) }
                let mat = pixelMaterial(cg, doubleSided: false)
                var light: CGFloat = shade ? (dirShade[dir] ?? 1) : 1
                if opt.dark { light *= CGFloat(max(0.12, emission / 15)) }
                var col = NSColor(white: light, alpha: 1)
                if let ti = (f["tintindex"] as? NSNumber)?.intValue, ti >= 0 {
                    col = NSColor(red: 0.49 * light, green: 0.74 * light, blue: 0.35 * light, alpha: 1) // 풀색 예시
                }
                mat.multiply.contents = col
                let n = SCNNode(geometry: quadGeometry(verts, tuv, mat))
                let nm = "E\(ei):\(dir)"
                n.name = nm
                node.addChildNode(n)
                info[nm] = FaceInfo(element: ei, dir: dir, textureRel: rel, texW: tw, frameH: th)
            }
            if opt.selected == ei { node.addChildNode(outline(a, b, rot)) }
        }
        return (node, info)
    }

    /// 선택한 요소 테두리
    static func outline(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ rot: [String: Any]?) -> SCNNode {
        let c: [SIMD3<Double>] = [[a.x, a.y, a.z], [b.x, a.y, a.z], [b.x, b.y, a.z], [a.x, b.y, a.z],
                                  [a.x, a.y, b.z], [b.x, a.y, b.z], [b.x, b.y, b.z], [a.x, b.y, b.z]]
        let v = c.map { p -> SCNVector3 in let q = rotate(p, rot); return SCNVector3(q.x - 8, q.y - 8, q.z - 8) }
        let idx: [Int32] = [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial(); m.lightingModel = .constant
        m.diffuse.contents = NSColor(red: 1, green: 0.3, blue: 0.65, alpha: 1)
        m.readsFromDepthBuffer = false
        g.materials = [m]
        let n = SCNNode(geometry: g); n.name = "outline"; n.renderingOrder = 10
        return n
    }

    /// 바닥 격자와 0~16 블록 테두리 (기준선)
    static func guides() -> SCNNode {
        let n = SCNNode()
        var v: [SCNVector3] = [], idx: [Int32] = []
        for i in 0...16 {
            let t = CGFloat(i) - 8
            v += [SCNVector3(t, -8, -8), SCNVector3(t, -8, 8), SCNVector3(-8, -8, t), SCNVector3(8, -8, t)]
        }
        for i in 0..<Int32(v.count / 2) { idx += [i * 2, i * 2 + 1] }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor(white: 0.3, alpha: 0.25)
        g.materials = [m]
        let grid = SCNNode(geometry: g); grid.name = "guide"
        n.addChildNode(grid)
        let box = outline([0, 0, 0], [16, 16, 16], nil)
        box.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.2, alpha: 0.35)
        box.name = "guide"
        n.addChildNode(box)
        // 북쪽(-z) 표시
        let arrow = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.8, height: 1.6))
        arrow.geometry?.firstMaterial?.diffuse.contents = NSColor(red: 0.3, green: 0.6, blue: 1, alpha: 0.8)
        arrow.geometry?.firstMaterial?.lightingModel = .constant
        arrow.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        arrow.position = SCNVector3(0, -8, -10)
        arrow.name = "guide"
        n.addChildNode(arrow)
        return n
    }

    /// display 변환: 이동 → 회전(X, Y, Z 순) → 크기
    static func applyDisplay(_ node: SCNNode, _ d: [String: Any]?) {
        let t = vec3(d?["translation"]), r = vec3(d?["rotation"]), s = vec3(d?["scale"], [1, 1, 1])
        node.simdPosition = SIMD3<Float>(Float(t.x), Float(t.y), Float(t.z))
        let qx = simd_quatf(angle: Float(r.x * .pi / 180), axis: [1, 0, 0])
        let qy = simd_quatf(angle: Float(r.y * .pi / 180), axis: [0, 1, 0])
        let qz = simd_quatf(angle: Float(r.z * .pi / 180), axis: [0, 0, 1])
        node.simdOrientation = qx * qy * qz
        node.simdScale = SIMD3<Float>(Float(s.x), Float(s.y), Float(s.z))
    }
}
