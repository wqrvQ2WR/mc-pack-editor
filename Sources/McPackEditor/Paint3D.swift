import AppKit
import SceneKit
import SwiftUI

/// 3D 화면에서 쓰는 붓 설정 (그림판과 같은 동작)
struct BrushSettings {
    var tool: Tool = .pencil
    var color = RGBA(r: 240, g: 70, b: 140, a: 255)
    var size = 1
    var blend = false
    var alphaLock = false

    /// 문서에 한 점(또는 이전 점부터 선) 칠하기. 스포이드면 색을 돌려준다.
    func apply(_ doc: ImageDoc, _ p: (Int, Int), from last: (Int, Int)?) -> RGBA? {
        switch tool {
        case .pencil, .eraser:
            if last == nil { doc.checkpoint() }
            doc.line(from: last ?? p, to: p, tool: tool, color: color, size: size, blend: blend, alphaLock: alphaLock)
        case .fill:
            if last == nil { doc.checkpoint(); doc.flood(p.0, p.1, color: color) }
        case .picker:
            return doc.pick(p.0, p.1)
        }
        return nil
    }
}

/// 작은 붓 도구줄 (3D 화면용)
struct BrushBar: View {
    @Binding var brush: BrushSettings
    @State private var color: Color = .pink
    @State private var opacity: Double = 100

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $brush.tool) {
                ForEach(Tool.allCases) { t in Image(systemName: t.symbol).help(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                .onChange(of: color) { sync() }
            Slider(value: $opacity, in: 0...100) { Text("불투명") }
                .frame(width: 110)
                .onChange(of: opacity) { sync() }
            Text("\(Int(opacity))").monospacedDigit().frame(width: 26)
            Stepper("\(brush.size)px", value: $brush.size, in: 1...8).fixedSize()
            Toggle("섞기", isOn: $brush.blend).toggleStyle(.checkbox)
            Toggle("투명 잠금", isOn: $brush.alphaLock).toggleStyle(.checkbox)
        }
        .lineLimit(1)
        .onAppear { load() }
        .onChange(of: brush.color) { load() }
    }

    private func sync() {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let c = RGBA(r: UInt8((ns.redComponent * 255).rounded()), g: UInt8((ns.greenComponent * 255).rounded()),
                     b: UInt8((ns.blueComponent * 255).rounded()), a: UInt8((opacity / 100 * 255).rounded()))
        if c != brush.color { brush.color = c }
    }

    private func load() {
        let c = brush.color
        let new = Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        let ns = NSColor(color).usingColorSpace(.sRGB)
        if ns.map({ UInt8(($0.redComponent * 255).rounded()) != c.r || UInt8(($0.greenComponent * 255).rounded()) != c.g || UInt8(($0.blueComponent * 255).rounded()) != c.b }) ?? true {
            color = new
        }
        let o = (Double(c.a) / 255 * 100).rounded()
        if o != opacity { opacity = o }
    }
}

// MARK: - 마우스로 돌리고 칠하는 SceneKit 뷰

/// 모델 위에서 누르면 칠하기(또는 선택), 빈 곳에서 끌면 돌리기, 휠/핀치로 확대.
final class InteractiveSCNView: SCNView {
    /// 맞은 것 전부(가까운 순). 어느 것을 쓸지는 쓰는 쪽이 고른다 (겉 레이어 건너뛰기 등)
    var onHit: (([SCNHitTestResult], _ first: Bool) -> Void)?
    var onHover: (([SCNHitTestResult]) -> Void)?
    var onStrokeEnd: (() -> Void)?
    var paintEnabled = true
    let pivot = SCNNode()       // 돌리는 축 (모델을 이 아래에 둔다)
    let camNode = SCNNode()
    var yaw: CGFloat = -0.5, pitch: CGFloat = 0.25, distance: CGFloat = 40

    private var dragMode = 0 // 0 없음, 1 칠하기, 2 돌리기
    private var lastPoint = CGPoint.zero
    private var tracking: NSTrackingArea?

    func setup(fov: CGFloat = 35) {
        let cam = SCNCamera()
        cam.fieldOfView = fov
        cam.zNear = 0.1
        cam.zFar = 1000
        camNode.camera = cam
        scene?.rootNode.addChildNode(pivot)
        scene?.rootNode.addChildNode(camNode)
        pointOfView = camNode
        updateCamera()
    }

    func updateCamera() {
        pivot.eulerAngles = SCNVector3(pitch, yaw, 0)
        camNode.position = SCNVector3(0, 0, distance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func hits(_ e: NSEvent) -> [SCNHitTestResult] {
        let p = convert(e.locationInWindow, from: nil)
        return hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true, .sortResults: true])
    }

    override func mouseDown(with e: NSEvent) {
        lastPoint = e.locationInWindow
        let h = hits(e)
        if !e.modifierFlags.contains(.option), paintEnabled, !h.isEmpty {
            dragMode = 1
            onHit?(h, true)
        } else {
            dragMode = 2
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if dragMode == 1 {
            let h = hits(e)
            if !h.isEmpty { onHit?(h, false) }
        } else {
            let p = e.locationInWindow
            yaw += (p.x - lastPoint.x) * 0.01
            pitch = max(-1.5, min(1.5, pitch - (p.y - lastPoint.y) * 0.01))
            lastPoint = p
            updateCamera()
        }
    }

    override func mouseUp(with e: NSEvent) {
        if dragMode == 1 { onStrokeEnd?() }
        dragMode = 0
    }

    override func rightMouseDragged(with e: NSEvent) {
        yaw += e.deltaX * 0.01
        pitch = max(-1.5, min(1.5, pitch + e.deltaY * 0.01))
        updateCamera()
    }

    override func mouseMoved(with e: NSEvent) { onHover?(hits(e)) }
    override func mouseExited(with e: NSEvent) { onHover?([]) }

    override func scrollWheel(with e: NSEvent) {
        distance = max(4, min(200, distance * (1 - e.scrollingDeltaY * 0.01)))
        updateCamera()
    }

    override func magnify(with e: NSEvent) {
        distance = max(4, min(200, distance * (1 - e.magnification)))
        updateCamera()
    }
}

/// 픽셀 텍스처용 재질: 가장 가까운 픽셀, 투명 부분은 잘라냄(게임의 cutout과 같게)
func pixelMaterial(_ cg: CGImage?, doubleSided: Bool = false) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } ?? NSColor.magenta
    m.diffuse.magnificationFilter = .nearest
    m.diffuse.minificationFilter = .nearest
    m.diffuse.mipFilter = .none
    m.diffuse.wrapS = .clamp
    m.diffuse.wrapT = .clamp
    m.isDoubleSided = doubleSided
    m.shaderModifiers = [.fragment: "if (_output.color.a < 0.1) { discard_fragment(); }"]
    return m
}

/// 사각형 하나. 꼭짓점은 바깥에서 봤을 때 [왼위, 오위, 오아래, 왼아래] 순서, uv는 픽셀/텍스처크기(0~1, 위가 0).
func quadGeometry(_ v: [SCNVector3], _ uv: [CGPoint], _ m: SCNMaterial) -> SCNGeometry {
    let src = SCNGeometrySource(vertices: v)
    let t = SCNGeometrySource(textureCoordinates: uv)
    let idx: [Int32] = [0, 3, 2, 0, 2, 1] // 바깥에서 봐서 시계 반대 = 앞면
    let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
    let g = SCNGeometry(sources: [src, t], elements: [el])
    g.materials = [m]
    return g
}
