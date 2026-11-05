import AppKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// 타이틀 화면처럼 천천히 도는 정육면체 파노라마. 축은 Panorama.basis와 같다.
struct PanoramaScene: NSViewRepresentable {
    @EnvironmentObject var ws: Workspace
    var spin: Bool
    var blur: Bool
    var interactive: Bool

    final class Coord: NSObject {
        let scene = SCNScene()
        let spinNode = SCNNode(), lookNode = SCNNode(), cam = SCNNode(), cube = SCNNode()
        var planes: [SCNNode] = []
        var version = -1
        var root: String?
        var yaw: CGFloat = 0, pitch: CGFloat = 0
        var spinning = false

        @objc func pan(_ g: NSPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            g.setTranslation(.zero, in: g.view)
            yaw += t.x * 0.006
            pitch = max(-1.4, min(1.4, pitch + t.y * 0.006))
            lookNode.eulerAngles = SCNVector3(pitch, yaw, 0)
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> SCNView {
        let c = context.coordinator
        let v = SCNView(frame: .zero)
        v.scene = c.scene
        v.backgroundColor = .black
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = true
        let camera = SCNCamera()
        camera.fieldOfView = 85
        camera.zNear = 0.01
        camera.zFar = 10
        c.cam.camera = camera
        c.scene.rootNode.addChildNode(c.spinNode)
        c.spinNode.addChildNode(c.lookNode)
        c.lookNode.addChildNode(c.cam)
        c.scene.rootNode.addChildNode(c.cube)
        let place: [(SCNVector3, SCNVector3)] = [
            (SCNVector3(0, 0, -1), SCNVector3(0, 0, 0)),
            (SCNVector3(1, 0, 0), SCNVector3(0, -CGFloat.pi / 2, 0)),
            (SCNVector3(0, 0, 1), SCNVector3(0, CGFloat.pi, 0)),
            (SCNVector3(-1, 0, 0), SCNVector3(0, CGFloat.pi / 2, 0)),
            (SCNVector3(0, 1, 0), SCNVector3(CGFloat.pi / 2, 0, 0)),
            (SCNVector3(0, -1, 0), SCNVector3(-CGFloat.pi / 2, 0, 0)),
        ]
        for (pos, rot) in place {
            let p = SCNPlane(width: 2.002, height: 2.002)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.minificationFilter = .linear
            m.diffuse.magnificationFilter = .linear
            p.materials = [m]
            let n = SCNNode(geometry: p)
            n.position = pos
            n.eulerAngles = rot
            c.cube.addChildNode(n)
            c.planes.append(n)
        }
        v.pointOfView = c.cam
        if interactive {
            v.addGestureRecognizer(NSPanGestureRecognizer(target: c, action: #selector(Coord.pan(_:))))
        }
        update(v, c)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) { update(v, context.coordinator) }

    private func update(_ v: SCNView, _ c: Coord) {
        if c.version != ws.assetsVersion || c.root != ws.root?.path {
            c.version = ws.assetsVersion
            c.root = ws.root?.path
            for i in 0..<6 {
                let mat = c.planes[i].geometry?.firstMaterial
                if let cg = ws.pixelImage(Panorama.rel(i))?.cgImage() {
                    mat?.diffuse.contents = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                } else {
                    mat?.diffuse.contents = NSColor.systemPink
                }
            }
        }
        if spin != c.spinning {
            c.spinning = spin
            c.spinNode.removeAllActions()
            if spin {
                c.spinNode.runAction(.repeatForever(.rotateBy(x: 0, y: -2 * .pi, z: 0, duration: 160)))
            }
        }
        if blur {
            let f = CIFilter(name: "CIGaussianBlur")
            f?.setValue(6, forKey: kCIInputRadiusKey)
            c.cube.filters = f.map { [$0] }
        } else {
            c.cube.filters = nil
        }
    }
}

struct PanoramaView: View {
    @EnvironmentObject var ws: Workspace
    @State private var spin = true
    @State private var blur = false
    @State private var size = 1024
    @State private var busy: String?
    @State private var tick = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("파노라마 (타이틀 배경)").font(.title3.bold()).foregroundStyle(Theme.gradient)
                Spacer(minLength: 0)
                Toggle(isOn: $spin) { Label("회전", systemImage: "arrow.triangle.2.circlepath") }.toggleStyle(.button)
                Toggle(isOn: $blur) { Label("흐림", systemImage: "drop.halffull") }.toggleStyle(.button)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ZStack(alignment: .bottomLeading) {
                PanoramaScene(spin: spin, blur: blur, interactive: true)
                Text("드래그해서 둘러보기").font(.caption).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule()).padding(10)
                if let busy {
                    HStack { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.white) }
                        .padding(10).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 200)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                cross.frame(minWidth: 360)
                actions.frame(width: 250)
            }
            .padding(12)
            .frame(height: 250)
        }
        .onAppear { ws.lastMock = "mock:panorama" }
    }

    // 십자 펼침: 위 / 왼 앞 오른 뒤 / 아래
    private var cross: some View {
        GeometryReader { g in
            let cell = min((g.size.width - 18) / 4, (g.size.height - 12) / 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { Color.clear.frame(width: cell, height: cell); tile(4, cell) }
                HStack(spacing: 6) { tile(3, cell); tile(0, cell); tile(1, cell); tile(2, cell) }
                HStack(spacing: 6) { Color.clear.frame(width: cell, height: cell); tile(5, cell) }
            }
        }
    }

    private func tile(_ i: Int, _ cell: CGFloat) -> some View {
        FaceTile(index: i, cell: cell, tick: tick) { cg in
            write(face: i, cg: cg)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("면을 누르면 그림판으로 열려요. 이미지를 면에 끌어다 놓으면 그 면만 바뀌어요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("면 크기", selection: $size) {
                ForEach([512, 1024, 2048], id: \.self) { Text("\($0) x \($0)").tag($0) }
            }
            Button { importEquirect() } label: {
                Label("360도 사진 한 장으로 만들기…", systemImage: "pano").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Color(red: 0.95, green: 0.3, blue: 0.6))
            Button { exportEquirect() } label: {
                Label("360도 사진으로 내보내기…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            Button { ws.editAsset(Panorama.overlayRel) } label: {
                Label("오버레이 그림 편집", systemImage: "square.on.square").frame(maxWidth: .infinity)
            }
            Button(role: .destructive) { resetVanilla() } label: {
                Label("바닐라로 되돌리기", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
            }
            .disabled(!(0..<6).contains { ws.inPack(Panorama.rel($0)) })
        }
        .disabled(busy != nil)
    }

    // MARK: 작업

    private func write(face i: Int, cg: CGImage) {
        guard let dest = ws.packURL(Panorama.rel(i)) else { return }
        let n = ws.pixelImage(Panorama.rel(i))?.w ?? size
        guard let img = PixelImage.fitted(cg, w: n, h: n, fit: .cover, smooth: true), let png = img.pngData() else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: dest)
        ws.invalidate(dest); ws.reload(); tick += 1
        ws.status = "파노라마 \(Panorama.names[i]) 면 바꿨음"
    }

    private func importEquirect() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "가로:세로 = 2:1 인 360도(등장방형) 사진을 고르세요"
        guard p.runModal() == .OK, let u = p.url, let src = PixelImage.load(u) else { return }
        let ratio = Double(src.w) / Double(src.h)
        if abs(ratio - 2) > 0.05 {
            let a = NSAlert()
            a.messageText = "360도 사진 비율이 아니에요 (\(src.w)x\(src.h))"
            a.informativeText = "가로가 세로의 2배여야 이음새 없이 붙어요. 그래도 만들까요?"
            a.addButton(withTitle: "그래도 만들기"); a.addButton(withTitle: "취소")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        let n = size
        busy = "6면으로 바꾸는 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            let faces = Panorama.faces(fromEquirect: src, size: n)
            DispatchQueue.main.async {
                for (i, f) in faces.enumerated() {
                    guard let dest = ws.packURL(Panorama.rel(i)), let png = f.pngData() else { continue }
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? png.write(to: dest)
                    ws.invalidate(dest)
                }
                ws.reload(); tick += 1; busy = nil
                ws.status = "360도 사진으로 파노라마 6면을 만들었음 (\(n)x\(n))"
            }
        }
    }

    private func exportEquirect() {
        let faces = (0..<6).compactMap { ws.pixelImage(Panorama.rel($0)) }
        guard faces.count == 6 else { ws.status = "6면을 다 못 읽었어요"; return }
        let sp = NSSavePanel()
        sp.nameFieldStringValue = "panorama_360.png"
        sp.allowedContentTypes = [.png]
        guard sp.runModal() == .OK, let out = sp.url else { return }
        busy = "360도 사진 만드는 중…"
        let w = min(8192, faces[0].w * 4)
        DispatchQueue.global(qos: .userInitiated).async {
            let eq = Panorama.equirect(fromFaces: faces, width: w)
            try? eq.pngData()?.write(to: out)
            DispatchQueue.main.async {
                busy = nil
                ws.status = "내보냈음: \(out.lastPathComponent) (\(w)x\(w / 2))"
                NSWorkspace.shared.activateFileViewerSelecting([out])
            }
        }
    }

    private func resetVanilla() {
        let a = NSAlert()
        a.messageText = "팩의 파노라마 6면을 휴지통으로 보낼까요?"
        a.informativeText = "바닐라 파노라마로 돌아가요. 휴지통에서 되살릴 수 있어요."
        a.addButton(withTitle: "휴지통으로"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for i in 0..<6 {
            if let u = ws.packURL(Panorama.rel(i)), FileManager.default.fileExists(atPath: u.path) {
                try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                ws.invalidate(u)
            }
        }
        ws.reload(); tick += 1
        ws.status = "파노라마를 바닐라로 되돌렸음"
    }
}

struct FaceTile: View {
    @EnvironmentObject var ws: Workspace
    let index: Int
    let cell: CGFloat
    let tick: Int
    let onDropImage: (CGImage) -> Void
    @State private var hover = false
    @State private var target = false

    var body: some View {
        let rel = Panorama.rel(index)
        let img = ws.pixelImage(rel)
        ZStack(alignment: .bottomLeading) {
            if let cg = img?.cgImage() {
                Image(decorative: cg, scale: 1).resizable()
            } else {
                Color.pink.opacity(0.4)
            }
            HStack(spacing: 3) {
                Text("\(index) \(Panorama.names[index])").bold()
                Text(ws.inPack(rel) ? "팩" : "바닐라").opacity(0.8)
            }
            .font(.system(size: 10))
            .lineLimit(1).fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
            .padding(3)
        }
        .frame(width: cell, height: cell)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(hover || target ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.3)),
                          lineWidth: hover || target ? 3 : 1))
        .onHover { hover = $0 }
        .onTapGesture { ws.editAsset(rel) }
        .help("panorama_\(index).png · \(img.map { "\($0.w)x\($0.h)" } ?? "")\n누르면 편집, 이미지를 끌어다 놓으면 교체")
        .onDrop(of: [.fileURL], isTargeted: $target) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                DispatchQueue.main.async { onDropImage(cg) }
            }
            return true
        }
        .id("\(index)-\(tick)-\(ws.assetsVersion)")
    }
}
