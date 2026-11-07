import AppKit
import SceneKit
import SwiftUI

/// 플레이어 스킨 부위: 몸 위치(픽셀 단위, 발이 y=0, 얼굴이 +z) + 스킨 UV
struct SkinPart {
    let name: String
    let label: String
    let group: String        // head, body, arms, legs
    let overlay: Bool
    let from: SIMD3<Double>, to: SIMD3<Double>
    let uv: (Int, Int)
    let size: (w: Int, h: Int, d: Int)
}

enum SkinModel {
    static func parts(slim: Bool, legacy: Bool) -> [SkinPart] {
        let aw = slim ? 3.0 : 4.0
        let awi = slim ? 3 : 4
        var p: [SkinPart] = [
            SkinPart(name: "head", label: "머리", group: "head", overlay: false, from: [-4, 24, -4], to: [4, 32, 4], uv: (0, 0), size: (8, 8, 8)),
            SkinPart(name: "body", label: "몸", group: "body", overlay: false, from: [-4, 12, -2], to: [4, 24, 2], uv: (16, 16), size: (8, 12, 4)),
            SkinPart(name: "rarm", label: "오른팔", group: "arms", overlay: false, from: [-4 - aw, 12, -2], to: [-4, 24, 2], uv: (40, 16), size: (awi, 12, 4)),
            SkinPart(name: "larm", label: "왼팔", group: "arms", overlay: false, from: [4, 12, -2], to: [4 + aw, 24, 2], uv: legacy ? (40, 16) : (32, 48), size: (awi, 12, 4)),
            SkinPart(name: "rleg", label: "오른다리", group: "legs", overlay: false, from: [-4, 0, -2], to: [0, 12, 2], uv: (0, 16), size: (4, 12, 4)),
            SkinPart(name: "lleg", label: "왼다리", group: "legs", overlay: false, from: [0, 0, -2], to: [4, 12, 2], uv: legacy ? (0, 16) : (16, 48), size: (4, 12, 4)),
            SkinPart(name: "hat", label: "모자", group: "head", overlay: true, from: [-4.5, 23.5, -4.5], to: [4.5, 32.5, 4.5], uv: (32, 0), size: (8, 8, 8)),
        ]
        if !legacy {
            p += [
                SkinPart(name: "jacket", label: "겉옷", group: "body", overlay: true, from: [-4.25, 11.75, -2.25], to: [4.25, 24.25, 2.25], uv: (16, 32), size: (8, 12, 4)),
                SkinPart(name: "rsleeve", label: "오른소매", group: "arms", overlay: true, from: [-4.25 - aw, 11.75, -2.25], to: [-3.75, 24.25, 2.25], uv: (40, 32), size: (awi, 12, 4)),
                SkinPart(name: "lsleeve", label: "왼소매", group: "arms", overlay: true, from: [3.75, 11.75, -2.25], to: [4.25 + aw, 24.25, 2.25], uv: (48, 48), size: (awi, 12, 4)),
                SkinPart(name: "rpants", label: "오른바지", group: "legs", overlay: true, from: [-4.25, -0.25, -2.25], to: [0.25, 12.25, 2.25], uv: (0, 32), size: (4, 12, 4)),
                SkinPart(name: "lpants", label: "왼바지", group: "legs", overlay: true, from: [-0.25, -0.25, -2.25], to: [4.25, 12.25, 2.25], uv: (0, 48), size: (4, 12, 4)),
            ]
        }
        return p
    }

    /// 상자 하나의 면 6개: (면 이름, 꼭짓점[왼위,오위,오아래,왼아래], 스킨 픽셀 사각형)
    static func faces(_ p: SkinPart) -> [(String, [SCNVector3], CGRect)] {
        let (x0, y0, z0) = (CGFloat(p.from.x), CGFloat(p.from.y), CGFloat(p.from.z))
        let (x1, y1, z1) = (CGFloat(p.to.x), CGFloat(p.to.y), CGFloat(p.to.z))
        let u = CGFloat(p.uv.0), v = CGFloat(p.uv.1)
        let w = CGFloat(p.size.w), h = CGFloat(p.size.h), d = CGFloat(p.size.d)
        func V(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 { SCNVector3(x, y, z) }
        return [
            ("앞", [V(x0, y1, z1), V(x1, y1, z1), V(x1, y0, z1), V(x0, y0, z1)], CGRect(x: u + d, y: v + d, width: w, height: h)),
            ("뒤", [V(x1, y1, z0), V(x0, y1, z0), V(x0, y0, z0), V(x1, y0, z0)], CGRect(x: u + 2 * d + w, y: v + d, width: w, height: h)),
            ("오른쪽", [V(x0, y1, z0), V(x0, y1, z1), V(x0, y0, z1), V(x0, y0, z0)], CGRect(x: u, y: v + d, width: d, height: h)),
            ("왼쪽", [V(x1, y1, z1), V(x1, y1, z0), V(x1, y0, z0), V(x1, y0, z1)], CGRect(x: u + d + w, y: v + d, width: d, height: h)),
            ("위", [V(x0, y1, z0), V(x1, y1, z0), V(x1, y1, z1), V(x0, y1, z1)], CGRect(x: u + d, y: v, width: w, height: d)),
            ("아래", [V(x0, y0, z1), V(x1, y0, z1), V(x1, y0, z0), V(x0, y0, z0)], CGRect(x: u + d + w, y: v, width: w, height: d)),
        ]
    }
}

struct SkinEditorView: View {
    @ObservedObject var doc: ImageDoc
    @EnvironmentObject var ws: Workspace
    @State private var mode = 0
    @State private var brush = BrushSettings()
    @State private var slim: Bool
    @State private var showOverlay = true
    @State private var paintOverlay = false
    @State private var hidden: Set<String> = []
    @State private var info = ""

    init(doc: ImageDoc) {
        self.doc = doc
        _slim = State(initialValue: doc.url.path.contains("/slim/"))
    }

    private var legacy: Bool { doc.image.h == doc.image.w / 2 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    Text("3D").tag(0); Text("2D 그림판").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                Text(ws.relPath(doc.url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if mode == 0 {
                    Toggle("슬림 팔", isOn: $slim).toggleStyle(.checkbox)
                    Toggle("겉 레이어 보기", isOn: $showOverlay).toggleStyle(.checkbox)
                    Menu("부위 숨기기") {
                        ForEach([("head", "머리"), ("body", "몸"), ("arms", "팔"), ("legs", "다리")], id: \.0) { g in
                            Toggle(g.1, isOn: Binding(get: { hidden.contains(g.0) },
                                                      set: { if $0 { hidden.insert(g.0) } else { hidden.remove(g.0) } }))
                        }
                    }
                    .fixedSize()
                    Button("얼굴 없애기") { faceless() }.help("얼굴을 머리의 피부색으로 덮고 모자 레이어 앞면을 비워요")
                }
                Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!doc.canUndo)
            }
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if mode == 0 {
                HStack(spacing: 10) {
                    BrushBar(brush: $brush)
                    Spacer(minLength: 0)
                    Picker("칠할 곳", selection: $paintOverlay) {
                        Text("피부(안쪽)").tag(false); Text("겉 레이어").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 190)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                SkinSceneView(doc: doc, brush: $brush, slim: slim, legacy: legacy, showOverlay: showOverlay,
                              paintOverlay: paintOverlay, hidden: hidden, info: $info)
                Divider()
                HStack {
                    Text(info.isEmpty ? "모델 위를 끌면 칠하고, 빈 곳을 끌면 돌려요 (option+끌기·오른쪽 끌기도 돌리기, 휠로 확대)" : info)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if doc.dirty { Text("저장 안 됨 (Cmd+S)").font(.caption).foregroundStyle(.orange) }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
            } else {
                ImageEditorView(doc: doc)
            }
        }
    }

    /// 얼굴 없는 스티브: 머리 앞면을 머리에서 가장 많이 쓴 색으로 채우고, 모자 앞면은 투명하게
    private func faceless() {
        var count: [UInt32: Int] = [:]
        let img = doc.image
        for y in 8..<16 { for x in 0..<32 where img.inside(x, y) {
            let i = img.index(x, y)
            if img.px[i + 3] == 255 {
                let k = UInt32(img.px[i]) << 16 | UInt32(img.px[i + 1]) << 8 | UInt32(img.px[i + 2])
                count[k, default: 0] += 1
            }
        } }
        guard let skin = count.max(by: { $0.value < $1.value })?.key else { return }
        var out = img
        for y in 8..<16 { for x in 8..<16 where out.inside(x, y) {
            let i = out.index(x, y)
            out.px[i] = UInt8(skin >> 16 & 255); out.px[i + 1] = UInt8(skin >> 8 & 255); out.px[i + 2] = UInt8(skin & 255); out.px[i + 3] = 255
        } }
        for y in 8..<16 { for x in 40..<48 where out.inside(x, y) { out.px[out.index(x, y) + 3] = 0 } }
        doc.replace(with: out)
        ws.status = "얼굴을 피부색으로 덮었어요 (Cmd+Z로 되돌리기)"
    }
}

struct SkinSceneView: NSViewRepresentable {
    @ObservedObject var doc: ImageDoc
    @Binding var brush: BrushSettings
    let slim: Bool, legacy: Bool, showOverlay: Bool, paintOverlay: Bool
    let hidden: Set<String>
    @Binding var info: String

    final class Coord {
        var view: InteractiveSCNView?
        let model = SCNNode()
        var rects: [String: CGRect] = [:]
        var key = ""
        var last: (Int, Int)?
        var baseMat = SCNMaterial(), overMat = SCNMaterial()
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> InteractiveSCNView {
        let v = InteractiveSCNView(frame: .zero)
        v.scene = SCNScene()
        v.backgroundColor = Theme.sceneBackground(for: v)
        v.antialiasingMode = .multisampling4X
        v.distance = 70
        v.setup()
        v.pivot.addChildNode(context.coordinator.model)
        context.coordinator.view = v
        update(v, context.coordinator)
        return v
    }

    func updateNSView(_ v: InteractiveSCNView, context: Context) { update(v, context.coordinator) }

    private func update(_ v: InteractiveSCNView, _ c: Coord) {
        v.backgroundColor = Theme.sceneBackground(for: v)
        let cg = doc.image.cgImage()
        let key = "\(slim)-\(legacy)-\(showOverlay)-\(hidden.sorted())-\(doc.image.w)x\(doc.image.h)"
        if key != c.key {
            c.key = key
            c.model.childNodes.forEach { $0.removeFromParentNode() }
            c.rects.removeAll()
            c.baseMat = pixelMaterial(cg)
            c.baseMat.shaderModifiers = nil // 안쪽 피부는 게임에서도 불투명
            c.overMat = pixelMaterial(cg, doubleSided: true)
            let tw = CGFloat(doc.image.w), th = CGFloat(doc.image.h)
            // 64x32 옛 스킨은 텍스처 좌표를 64 기준으로
            let scaleW = tw / 64, scaleH = legacy ? th / 32 : th / 64
            for p in SkinModel.parts(slim: slim, legacy: legacy) {
                if hidden.contains(p.group) { continue }
                if p.overlay && !showOverlay { continue }
                for (fname, verts, r) in SkinModel.faces(p) {
                    let rr = CGRect(x: r.minX * scaleW, y: r.minY * scaleH, width: r.width * scaleW, height: r.height * scaleH)
                    let uv = [CGPoint(x: rr.minX / tw, y: rr.minY / th), CGPoint(x: rr.maxX / tw, y: rr.minY / th),
                              CGPoint(x: rr.maxX / tw, y: rr.maxY / th), CGPoint(x: rr.minX / tw, y: rr.maxY / th)]
                    let n = SCNNode(geometry: quadGeometry(verts, uv, p.overlay ? c.overMat : c.baseMat))
                    let name = "\(p.overlay ? "o" : "b"):\(p.label) \(fname)"
                    n.name = name
                    c.rects[name] = rr
                    c.model.addChildNode(n)
                }
            }
            c.model.position = SCNVector3(0, -16, 0)
        } else {
            let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            c.baseMat.diffuse.contents = img
            c.overMat.diffuse.contents = img
        }
        v.onHit = { hits, first in
            guard let (h, p) = pick(hits, c) else { return }
            if first { c.last = nil }
            if let picked = brush.apply(doc, p, from: c.last) {
                brush.color = picked
                brush.tool = .pencil
            }
            c.last = p
            info = describe(h, p)
        }
        v.onStrokeEnd = { c.last = nil }
        v.onHover = { hits in
            if let (h, p) = pick(hits, c) { info = describe(h, p) } else { info = "" }
        }
    }

    /// 칠할 곳 설정에 맞는 첫 면 고르기: 피부면 겉 레이어 건너뛰고, 겉이면 겉 레이어만
    private func pick(_ hits: [SCNHitTestResult], _ c: Coord) -> (SCNHitTestResult, (Int, Int))? {
        for h in hits {
            guard let name = h.node.name, let r = c.rects[name] else { continue }
            let isOver = name.hasPrefix("o:")
            if isOver != paintOverlay { continue }
            let t = h.textureCoordinates(withMappingChannel: 0)
            var x = Int(floor(t.x * CGFloat(doc.image.w))), y = Int(floor(t.y * CGFloat(doc.image.h)))
            x = min(max(x, Int(r.minX)), Int(r.maxX) - 1)
            y = min(max(y, Int(r.minY)), Int(r.maxY) - 1)
            return (h, (x, y))
        }
        return nil
    }

    private func describe(_ h: SCNHitTestResult, _ p: (Int, Int)) -> String {
        let name = String((h.node.name ?? "").dropFirst(2))
        let c = doc.pick(p.0, p.1)
        return "\(name)  픽셀 (\(p.0), \(p.1))" + (c.map { "  R\($0.r) G\($0.g) B\($0.b) A\($0.a)" } ?? "")
    }
}

/// 사이드바 "스킨": 기본 스킨 고르기
struct SkinPickerView: View {
    @EnvironmentObject var ws: Workspace
    private let names = ["steve", "alex", "ari", "efe", "kai", "makena", "noor", "sunny", "zuri"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("플레이어 스킨").font(.title2.bold()).foregroundStyle(Theme.gradient)
                Text("누르면 팩으로 복사해서 3D로 열어요. 와이드는 팔 4픽셀, 슬림은 3픽셀이에요.")
                    .foregroundStyle(.secondary)
                ForEach(["wide", "slim"], id: \.self) { kind in
                    Text(kind == "wide" ? "와이드 (팔 4px)" : "슬림 (팔 3px)").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(names, id: \.self) { n in
                            let rel = "assets/minecraft/textures/entity/player/\(kind)/\(n).png"
                            if ws.resolve(rel) != nil { card(rel, n) }
                        }
                    }
                }
                Text("몹·동물 텍스처도 entity 폴더에서 그림판으로 고칠 수 있어요. 몹 모양(뼈대)은 게임 코드에 있어서 리소스팩으로는 바꿀 수 없어요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .id(ws.assetsVersion)
    }

    private func card(_ rel: String, _ name: String) -> some View {
        Button { ws.editAsset(rel) } label: {
            VStack(spacing: 6) {
                if let img = ws.pixelImage(rel), img.w >= 16 {
                    // 얼굴(8,8)~(16,16) + 모자 앞면 겹치기
                    let face = img.crop(CGRect(x: 8, y: 8, width: 8, height: 8))
                    let hat = img.crop(CGRect(x: 40, y: 8, width: 8, height: 8))
                    ZStack {
                        if let f = face.cgImage() { Image(decorative: f, scale: 1).interpolation(.none).resizable() }
                        if let h = hat.cgImage() { Image(decorative: h, scale: 1).interpolation(.none).resizable() }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(name).font(.caption.bold())
                Text(ws.inPack(rel) ? "팩에 있음" : "바닐라").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ws.inPack(rel) ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.2)), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}
