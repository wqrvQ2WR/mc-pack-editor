import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageEditorView: View {
    @ObservedObject var doc: ImageDoc
    @EnvironmentObject var ws: Workspace

    // 도구·붓은 파일을 바꿔도 이어지게 저장 (3D 칠하기와 같은 키)
    @AppStorage("paint.tool") private var tool: Tool = .pencil
    @State private var color: Color = Color(red: 0.95, green: 0.25, blue: 0.55)
    @State private var opacity: Double = 100
    @AppStorage("paint.size") private var brush: Int = 1
    @AppStorage("paint.blend") private var blend = false
    @AppStorage("paint.alphaLock") private var alphaLock = false
    @AppStorage("paint.grid") private var grid = true
    @AppStorage("paint.bg") private var bg: Int = 0
    @AppStorage("paint.fit") private var fit: PixelImage.Fit = .original
    @State private var zoom: CGFloat = 0
    @State private var hover: (Int, Int)?
    @State private var last: (Int, Int)?
    @State private var smooth = false
    @State private var dropTarget = false
    @State private var avail = CGSize(width: 560, height: 560)
    @State private var showAdjust = false
    @State private var dragStart: (Int, Int)?
    @State private var dragNow: (Int, Int)?
    @State private var moveOrigin: (Int, Int)?     // 이동 시작 때 조각 위치
    @State private var wandTolerance: Double = 0
    @State private var wandContiguous = true
    @State private var resizeTo: (w: Int, h: Int)?   // 오른쪽 아래 손잡이로 끄는 중인 새 크기

    private var effectiveZoom: CGFloat {
        if zoom > 0 { return zoom }
        let fw = (avail.width - 80) / CGFloat(doc.image.w)
        let fh = (avail.height - 80) / CGFloat(doc.image.h)
        return max(1, min(48, min(fw, fh).rounded(.down)))
    }

    private func loadColor() {
        guard let c = UserDefaults.standard.string(forKey: "paint.rgba").flatMap(RGBA.init(hex:)) else { return }
        color = Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        opacity = (Double(c.a) / 255 * 100).rounded()
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
        .background(shortcuts)
        .onAppear { loadColor() }
        .onChange(of: rgba) { UserDefaults.standard.set(rgba.hex, forKey: "paint.rgba") }
        .onAppear {
            // 검증용: MCPE_SELRECT="x0,y0,x1,y1" 선택, MCPE_FLOAT=dx,dy 떼어서 옮김
            let env = ProcessInfo.processInfo.environment
            if let r = env["MCPE_SELRECT"]?.split(separator: ",").compactMap({ Int($0) }), r.count == 4 {
                doc.selectRect(r[0], r[1], r[2], r[3])
                if let m = env["MCPE_FLOAT"]?.split(separator: ",").compactMap({ Int($0) }), m.count == 2 {
                    doc.lift(); if let f = doc.floating { doc.moveFloating(to: f.x + m[0], f.y + m[1]) }
                    tool = .move
                }
            }
        }
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
            .frame(width: 250)
            .labelsHidden()
            .onChange(of: tool) { if tool.isPaint { doc.commitFloating() } }
            Text(tool.rawValue).font(.callout.bold()).foregroundStyle(Theme.gradient).frame(width: 62, alignment: .leading)

            Divider().frame(height: 20)
            Button { if doc.floating != nil { doc.cancelFloating() } else { doc.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
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
            if let cg = (doc.floating == nil ? doc.image : doc.composite()).cgImage() {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: w, height: h)
            }
            if grid && z >= 6 { gridOverlay(z: z) }
            selectionOverlay(z: z, w: w, h: h)
            if let (hx, hy) = hover {
                let s = CGFloat(tool == .pencil || tool == .eraser ? brush : 1)
                if tool.isPaint || tool == .wand {
                let off = CGFloat(-(Int(s) - 1) / 2)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1)
                    .background(Rectangle().strokeBorder(Color.black, lineWidth: 2))
                    .frame(width: s * z, height: s * z)
                    .offset(x: (CGFloat(hx) + off) * z, y: (CGFloat(hy) + off) * z)
                    .allowsHitTesting(false)
                }
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
                .onEnded { _ in endStroke() }
        )
        .overlay(alignment: .topLeading) { resizeOverlay(w: w, h: h) }
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

    private var selectMode: SelectMode {
        let f = NSEvent.modifierFlags
        if f.contains(.shift) { return .add }
        if f.contains(.option) { return .subtract }
        return .replace
    }

    private func endStroke() {
        if tool == .select, let a = dragStart, let b = dragNow {
            if a == b && selectMode == .replace { doc.deselect() } // 그냥 누르면 선택 해제
            else { doc.selectRect(a.0, a.1, b.0, b.1, mode: selectMode) }
        }
        dragStart = nil; dragNow = nil; moveOrigin = nil; last = nil
    }

    private func stroke(_ p: (Int, Int), first: Bool) {
        switch tool {
        case .select:
            if first { doc.commitFloating(); dragStart = p }
            dragNow = (min(max(p.0, 0), doc.w - 1), min(max(p.1, 0), doc.h - 1))
            last = p
        case .wand:
            guard first else { return }
            doc.commitFloating()
            doc.selectWand(p.0, p.1, tolerance: Int(wandTolerance), contiguous: wandContiguous, mode: selectMode)
            last = p
        case .move:
            if first {
                if doc.floating == nil { doc.lift() }
                dragStart = p
                if let f = doc.floating { moveOrigin = (f.x, f.y) }
            }
            if let s = dragStart, let o = moveOrigin { doc.moveFloating(to: o.0 + p.0 - s.0, o.1 + p.1 - s.1) }
            last = p
        case .pencil, .eraser:
            if first { doc.commitFloating() }
            if first { doc.checkpoint() }
            doc.line(from: last ?? p, to: p, tool: tool, color: rgba, size: brush, blend: blend, alphaLock: alphaLock)
            last = p
        case .fill:
            guard first else { return }
            doc.commitFloating()
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

    // MARK: 해상도 손잡이

    /// 마크 텍스처에 맞는 크기 (2의 거듭제곱)
    private static let niceSizes = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048]

    private func targetSize(dragWidth dx: CGFloat, canvasW w: CGFloat, free: Bool) -> (Int, Int) {
        let iw = doc.image.w, ih = doc.image.h
        let factor = max(0.05, (w + dx) / w)
        var nw = max(1, Int((CGFloat(iw) * factor).rounded()))
        if !free { nw = Self.niceSizes.min(by: { abs($0 - nw) < abs($1 - nw) }) ?? nw }
        nw = min(nw, 2048)
        let nh = max(1, Int((Double(ih) * Double(nw) / Double(iw)).rounded()))
        return (nw, nh)
    }

    @ViewBuilder private func resizeOverlay(w: CGFloat, h: CGFloat) -> some View {
        let z = effectiveZoom
        // 끄는 중이면 새 크기를 같은 확대 배율로 테두리로 미리 보여줌
        if let t = resizeTo {
            let sw = CGFloat(t.w) / CGFloat(doc.image.w) * w, sh = CGFloat(t.h) / CGFloat(doc.image.h) * h
            Rectangle()
                .strokeBorder(Theme.gradient, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: sw, height: sh)
                .overlay(alignment: .bottomTrailing) {
                    Text("\(t.w) x \(t.h)" + ratioText(t.w))
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.7)))
                        .offset(x: -6, y: -6)
                }
                .allowsHitTesting(false)
        }
        // 손잡이
        let hs: CGFloat = 16
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.gradient)
            .overlay(Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
            .frame(width: hs, height: hs)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .offset(x: w - hs / 2 + 4, y: h - hs / 2 + 4)
            .help("끌어서 해상도 바꾸기 (16·32·64…에 맞춤, Option을 누르면 자유롭게)")
            .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let free = NSEvent.modifierFlags.contains(.option)
                        let t = targetSize(dragWidth: max(v.translation.width, v.translation.height), canvasW: w, free: free)
                        resizeTo = (t.0, t.1)
                    }
                    .onEnded { _ in
                        if let t = resizeTo, t.w != doc.image.w || t.h != doc.image.h { resizeImage(to: t.w, t.h) }
                        resizeTo = nil
                    }
            )
        let _ = z
    }

    private func ratioText(_ nw: Int) -> String {
        let r = Double(nw) / Double(doc.image.w)
        if r == 1 { return "" }
        return r > 1 ? String(format: " (%g배)", r) : String(format: " (1/%g)", 1 / r)
    }

    /// 픽셀 모양 그대로 크기 바꾸기 (실행취소 가능)
    private func resizeImage(to nw: Int, _ nh: Int) {
        doc.commitFloating()
        let old = (doc.image.w, doc.image.h)
        guard let cg = doc.image.cgImage(), let img = PixelImage.fitted(cg, w: nw, h: nh, fit: .stretch, smooth: false) else { return }
        doc.replace(with: img)
        zoom = 0
        ws.status = "해상도 \(old.0)x\(old.1) → \(nw)x\(nh) (Cmd+Z로 되돌리기)"
    }

    // MARK: 선택

    /// 선택 테두리(개미 행진) + 드래그 중 사각형
    @ViewBuilder private func selectionOverlay(z: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        if let a = dragStart, let b = dragNow, tool == .select {
            let x0 = CGFloat(min(a.0, b.0)), y0 = CGFloat(min(a.1, b.1))
            let rw = CGFloat(abs(a.0 - b.0) + 1), rh = CGFloat(abs(a.1 - b.1) + 1)
            Rectangle().fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .frame(width: rw * z, height: rh * z)
                .offset(x: x0 * z, y: y0 * z)
                .allowsHitTesting(false)
        }
        if let path = doc.selectionOutline(zoom: z) {
            TimelineView(.animation(minimumInterval: 0.12)) { t in
                let phase = CGFloat(Int(t.date.timeIntervalSinceReferenceDate * 8) % 8)
                ZStack {
                    Path(path).stroke(Color.black, lineWidth: 1.5)
                    Path(path).stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4], dashPhase: phase))
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private var selectionSection: some View {
        section("선택") {
            Text(doc.hasSelection ? "선택한 곳 안에서만 칠해져요" : "사각 선택·마술봉으로 고르면 그 안에서만 칠해져요")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("전체") { doc.commitFloating(); doc.selectAll() }.help("전체 선택 (Cmd+A)")
                Button("해제") { doc.commitFloating(); doc.deselect() }.help("선택 해제 (Cmd+D)").disabled(!doc.hasSelection)
                Button("반전") { doc.commitFloating(); doc.invertSelection() }.help("선택 반전 (Shift+Cmd+I)")
            }
            .controlSize(.small)
            HStack {
                Button("복사") { copy() }.help("Cmd+C")
                Button("잘라내기") { cut() }.help("Cmd+X").disabled(!doc.hasSelection)
                Button("붙여넣기") { paste() }.help("Cmd+V")
            }
            .controlSize(.small)
            HStack {
                Button("지우기") { doc.commitFloating(); doc.deleteSelection() }.help("선택한 곳을 투명하게 (Delete)").disabled(!doc.hasSelection)
                Button("지금 색으로 채우기") { doc.commitFloating(); doc.fillSelection(rgba) }.disabled(!doc.hasSelection)
            }
            .controlSize(.small)
            if doc.floating != nil {
                HStack {
                    Button("확정") { doc.commitFloating() }.buttonStyle(.borderedProminent).help("Return")
                    Button("취소") { doc.cancelFloating() }.help("Esc")
                }
                .controlSize(.small)
            }
            if tool == .wand {
                HStack {
                    Text("허용 오차")
                    Slider(value: $wandTolerance, in: 0...128, step: 1)
                    Text("\(Int(wandTolerance))").monospacedDigit().frame(width: 28)
                }
                Toggle("이어진 곳만", isOn: $wandContiguous)
            }
            Text("Shift+끌기 더하기 · Option+끌기 빼기").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func copy() {
        PixelClipboard.write(doc.floating?.img ?? doc.copySelection())
        ws.status = "복사했어요" + (doc.hasSelection ? " (선택한 곳)" : " (전체)")
    }

    private func cut() {
        doc.commitFloating()
        guard doc.hasSelection else { return }
        PixelClipboard.write(doc.copySelection())
        doc.deleteSelection()
        ws.status = "잘라냈어요"
    }

    private func paste() {
        guard let img = PixelClipboard.read() else { ws.status = "붙여넣을 그림이 없어요"; return }
        doc.paste(img)
        tool = .move
        ws.status = "붙여넣었어요 (\(img.w)x\(img.h)) · 끌어서 옮기고 Return으로 확정"
    }

    /// 단축키 (안 보이는 버튼)
    private var shortcuts: some View {
        Group {
            Button("") { copy() }.keyboardShortcut("c", modifiers: .command)
            Button("") { cut() }.keyboardShortcut("x", modifiers: .command)
            Button("") { paste() }.keyboardShortcut("v", modifiers: .command)
            Button("") { doc.commitFloating(); doc.selectAll() }.keyboardShortcut("a", modifiers: .command)
            Button("") { doc.commitFloating(); doc.deselect() }.keyboardShortcut("d", modifiers: .command)
            Button("") { doc.commitFloating(); doc.invertSelection() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Button("") { doc.commitFloating(); doc.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { doc.commitFloating() }.keyboardShortcut(.return, modifiers: [])
            Button("") { if doc.floating != nil { doc.cancelFloating() } else { doc.deselect() } }.keyboardShortcut(.escape, modifiers: [])
            Button("") { nudge(-1, 0) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { nudge(1, 0) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { nudge(0, -1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { nudge(0, 1) }.keyboardShortcut(.downArrow, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false)
    }

    /// 방향키로 1픽셀씩 옮기기 (선택이 있으면 떼어서)
    private func nudge(_ dx: Int, _ dy: Int) {
        guard doc.hasSelection || doc.floating != nil else { return }
        if doc.floating == nil { doc.lift() }
        guard let f = doc.floating else { return }
        doc.moveFloating(to: f.x + dx, f.y + dy)
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
                selectionSection
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
                        Button("좌우 반전") { doc.flipSelection(horizontal: true) }
                        Button("상하 반전") { doc.flipSelection(horizontal: false) }
                    }
                    Button("전체 지우기") { doc.clearAll() }
                    Button("색 조정… (색조·채도·밝기)") { showAdjust = true }
                    Button("이미지 가져와서 적용…") { importPanel() }
                    Picker("맞추기", selection: $fit) {
                        ForEach(PixelImage.Fit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if fit == .original {
                        Text("텍스처가 넣은 이미지 크기로 바뀌어요").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("부드럽게 줄이기 (사진용)", isOn: $smooth)
                    }
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
            if let b = doc.selectionBounds {
                Text("선택 \(doc.selectedCount)픽셀 (\(b.w)x\(b.h))").font(.caption).foregroundStyle(.secondary)
            }
            if doc.floating != nil {
                Text("떠 있는 조각: 이동 도구로 옮기고 Return 확정 · Esc 취소").font(.caption).foregroundStyle(Theme.gradient)
            }
            if doc.dirty { Text("저장 안 됨 (Cmd+S)").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    // MARK: 이미지 가져오기

    private func apply(_ cg: CGImage) {
        let before = (doc.image.w, doc.image.h)
        if let img = PixelImage.fitted(cg, w: doc.image.w, h: doc.image.h, fit: fit, smooth: smooth) {
            doc.commitFloating()
            doc.replace(with: img)
            zoom = 0 // 새 크기에 맞춰 다시 보기
            var msg = "이미지 적용함 (\(img.w)x\(img.h)"
            if (img.w, img.h) != before { msg += ", 원래 \(before.0)x\(before.1)에서 바뀜" }
            msg += ")"
            // 블록·아이템 텍스처는 정사각형(세로로 긴 건 애니메이션 프레임)이어야 게임이 제대로 읽는다
            let rel = ws.relPath(doc.url)
            if rel.contains("/textures/block/") || rel.contains("/textures/item/") {
                if img.w != img.h && !(img.h > img.w && img.h % img.w == 0) {
                    msg += " · 블록·아이템은 정사각형이어야 해요. '비율 유지'로 다시 적용하거나 잘라 주세요"
                } else if img.h > img.w {
                    msg += " · 세로로 긴 그림은 애니메이션(프레임 \(img.h / img.w)장)으로 읽혀요"
                }
            }
            if max(img.w, img.h) > 1024 { msg += " · 아주 큰 그림이라 게임이 느려질 수 있어요" }
            ws.status = msg
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
