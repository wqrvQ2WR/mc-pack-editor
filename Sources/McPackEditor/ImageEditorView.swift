import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageEditorView: View {
    @ObservedObject var doc: ImageDoc
    @EnvironmentObject var ws: Workspace

    @State private var tool: Tool = .pencil
    @State private var color: Color = Color(red: 0.95, green: 0.25, blue: 0.55)
    @State private var opacity: Double = 100
    @State private var brush: Int = 1
    @State private var blend = false
    @State private var alphaLock = false
    @State private var zoom: CGFloat = 0
    @State private var grid = true
    @State private var bg: Int = 0
    @State private var hover: (Int, Int)?
    @State private var last: (Int, Int)?
    @State private var fit: PixelImage.Fit = .contain
    @State private var smooth = false
    @State private var dropTarget = false
    @State private var avail = CGSize(width: 560, height: 560)
    @State private var showAdjust = false

    private var effectiveZoom: CGFloat {
        if zoom > 0 { return zoom }
        let fw = (avail.width - 80) / CGFloat(doc.image.w)
        let fh = (avail.height - 80) / CGFloat(doc.image.h)
        return max(1, min(48, min(fw, fh).rounded(.down)))
    }

    private var rgba: RGBA {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return RGBA(r: UInt8((ns.redComponent * 255).rounded()),
                    g: UInt8((ns.greenComponent * 255).rounded()),
                    b: UInt8((ns.blueComponent * 255).rounded()),
                    a: UInt8((opacity / 100 * 255).rounded()))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .padding(40)
                        .frame(minWidth: 0, minHeight: 0)
                }
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { avail = g.size }
                        .onChange(of: g.size) { avail = g.size }
                })
                .onDrop(of: [.fileURL, .image], isTargeted: $dropTarget, perform: handleDrop)
                .overlay {
                    if dropTarget {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.gradient, lineWidth: 4)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                Divider()
                sidePanel.frame(width: 230)
            }
            Divider()
            statusLine
        }
        .sheet(isPresented: $showAdjust) { ColorAdjustSheet(doc: doc) }
    }

    // MARK: 상단 도구줄

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tool) {
                ForEach(Tool.allCases) { t in
                    Image(systemName: t.symbol).help(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .labelsHidden()
            Text(tool.rawValue).font(.callout.bold()).foregroundStyle(Theme.gradient).frame(width: 52, alignment: .leading)

            Divider().frame(height: 20)
            Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!doc.canUndo).help("실행취소 (Cmd+Z)")
            Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!doc.canRedo).help("다시실행 (Shift+Cmd+Z)")

            Divider().frame(height: 20)
            Button { zoom = max(1, effectiveZoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command).help("축소")
            Text("\(Int(effectiveZoom))x").monospacedDigit().frame(width: 34)
            Button { zoom = min(96, effectiveZoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command).help("확대")
            Button { zoom = 0 } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .keyboardShortcut("0", modifiers: .command).help("화면에 맞춤 (Cmd+0)")

            Spacer(minLength: 0)
            Toggle(isOn: $grid) { Image(systemName: "grid") }
                .toggleStyle(.button).help("격자")
            Picker("", selection: $bg) {
                Text("체커").tag(0); Text("흰색").tag(1); Text("검정").tag(2); Text("하늘").tag(3)
            }
            .labelsHidden()
            .frame(width: 76)
            .help("배경")
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: 캔버스

    private var canvas: some View {
        let z = effectiveZoom
        let w = CGFloat(doc.image.w) * z, h = CGFloat(doc.image.h) * z
        return ZStack(alignment: .topLeading) {
            background(w: w, h: h, z: z)
            if let cg = doc.image.cgImage() {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: w, height: h)
            }
            if grid && z >= 6 { gridOverlay(z: z) }
            if let (hx, hy) = hover {
                let s = CGFloat(tool == .pencil || tool == .eraser ? brush : 1)
                let off = CGFloat(-(Int(s) - 1) / 2)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1)
                    .background(Rectangle().strokeBorder(Color.black, lineWidth: 2))
                    .frame(width: s * z, height: s * z)
                    .offset(x: (CGFloat(hx) + off) * z, y: (CGFloat(hy) + off) * z)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = (Int(p.x / z), Int(p.y / z))
            case .ended: hover = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let p = (Int(floor(v.location.x / z)), Int(floor(v.location.y / z)))
                    hover = p
                    stroke(p, first: last == nil)
                }
                .onEnded { _ in last = nil }
        )
    }

    @ViewBuilder private func background(w: CGFloat, h: CGFloat, z: CGFloat) -> some View {
        switch bg {
        case 1: Color.white
        case 2: Color.black
        case 3: LinearGradient(colors: [Color(red: 0.45, green: 0.75, blue: 1), Color(red: 0.75, green: 0.9, blue: 1)],
                               startPoint: .top, endPoint: .bottom)
        default:
            Canvas { ctx, size in
                let cell = max(4, min(16, z / 2))
                var y: CGFloat = 0, row = 0
                while y < size.height {
                    var x: CGFloat = 0, col = row % 2
                    while x < size.width {
                        ctx.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                 with: .color(col % 2 == 0 ? Color(white: 0.86) : .white))
                        x += cell; col += 1
                    }
                    y += cell; row += 1
                }
            }
        }
    }

    private func gridOverlay(z: CGFloat) -> some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = 0
            while x <= size.width { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: size.height)); x += z }
            var y: CGFloat = 0
            while y <= size.height { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)); y += z }
            ctx.stroke(p, with: .color(.black.opacity(0.12)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func stroke(_ p: (Int, Int), first: Bool) {
        switch tool {
        case .pencil, .eraser:
            if first { doc.checkpoint() }
            doc.line(from: last ?? p, to: p, tool: tool, color: rgba, size: brush, blend: blend, alphaLock: alphaLock)
            last = p
        case .fill:
            guard first else { return }
            doc.checkpoint()
            doc.flood(p.0, p.1, color: rgba)
            last = p
        case .picker:
            if let c = doc.pick(p.0, p.1) {
                color = Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
                opacity = (Double(c.a) / 255 * 100).rounded()
            }
            last = p
        }
    }

    // MARK: 오른쪽 패널

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("색") {
                    HStack {
                        ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                        swatch
                        Spacer()
                        Text(hex).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Text("불투명도")
                        Slider(value: $opacity, in: 0...100, step: 1)
                        Text("\(Int(opacity))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                    HStack(spacing: 6) {
                        ForEach([100, 75, 50, 25, 0], id: \.self) { v in
                            Button("\(v)") { opacity = Double(v) }.controlSize(.small)
                        }
                    }
                }
                section("붓") {
                    Stepper("크기 \(brush)px", value: $brush, in: 1...32)
                    Toggle("섞어 칠하기 (블렌드)", isOn: $blend)
                        .help("끄면 지정한 RGBA를 그대로 찍어요. 반투명 픽셀을 정확히 만들 때 끄세요.")
                    Toggle("투명 잠금", isOn: $alphaLock)
                        .help("이미 있는 픽셀에만 칠하고 투명도는 그대로 둬요.")
                    Text(blend ? "지우개도 불투명도만큼 부분 지우기" : "지우개는 완전히 투명하게")
                        .font(.caption).foregroundStyle(.secondary)
                }
                section("이미지") {
                    HStack {
                        Button("좌우 반전") { doc.flip(horizontal: true) }
                        Button("상하 반전") { doc.flip(horizontal: false) }
                    }
                    Button("전체 지우기") { doc.clearAll() }
                    Button("색 조정… (색조·채도·밝기)") { showAdjust = true }
                    Button("이미지 가져와서 적용…") { importPanel() }
                    Picker("맞추기", selection: $fit) {
                        ForEach(PixelImage.Fit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("부드럽게 줄이기 (사진용)", isOn: $smooth)
                    Text("이미지를 캔버스에 끌어다 놓아도 돼요")
                        .font(.caption).foregroundStyle(.secondary)
                }
                section("정보") {
                    Text("\(doc.image.w) x \(doc.image.h)")
                    if doc.image.h > doc.image.w && doc.image.h % doc.image.w == 0 {
                        Text("애니메이션 스트립일 수 있음 (\(doc.image.h / doc.image.w)프레임)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(ws.relPath(doc.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(12)
        }
    }

    private var swatch: some View {
        ZStack {
            Canvas { ctx, size in
                for i in 0..<4 { for j in 0..<4 where (i + j) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(i) * size.width / 4, y: CGFloat(j) * size.height / 4,
                                         width: size.width / 4, height: size.height / 4)), with: .color(Color(white: 0.8)))
                } }
            }
            color.opacity(opacity / 100)
        }
        .frame(width: 34, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.2)))
    }

    private var hex: String {
        let c = rgba
        return String(format: "#%02X%02X%02X%02X", c.r, c.g, c.b, c.a)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Theme.gradient)
            c()
        }
    }

    private var statusLine: some View {
        HStack {
            if let (x, y) = hover, let c = doc.pick(x, y) {
                Text("(\(x), \(y))  R\(c.r) G\(c.g) B\(c.b) A\(c.a)")
                    .font(.system(.caption, design: .monospaced))
            } else {
                Text(" ").font(.caption)
            }
            Spacer()
            if doc.dirty { Text("저장 안 됨 (Cmd+S)").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    // MARK: 이미지 가져오기

    private func apply(_ cg: CGImage) {
        if let img = PixelImage.fitted(cg, w: doc.image.w, h: doc.image.h, fit: fit, smooth: smooth) {
            doc.replace(with: img)
            ws.status = "이미지 적용함 (\(fit.rawValue))"
        }
    }

    private func loadCG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url, let cg = loadCG(u) { apply(cg) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let pr = providers.first else { return false }
        if pr.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = pr.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let cg = loadCG(url) else { return }
                DispatchQueue.main.async { apply(cg) }
            }
            return true
        }
        if pr.canLoadObject(ofClass: NSImage.self) {
            _ = pr.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let ns = obj as? NSImage,
                      let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                DispatchQueue.main.async { apply(cg) }
            }
            return true
        }
        return false
    }
}
