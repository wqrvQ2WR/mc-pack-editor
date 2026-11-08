import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 일괄 쓰기 + 한 번에 되돌리기

/// 일괄 작업 한 번 = 바꾼 파일들의 원래 상태 (파일 내용, 없었으면 nil)
struct BatchRecord {
    var label: String
    var files: [(URL, Data?)] = []
}

extension Workspace {
    /// 텍스처 하나를 바꿔서 바로 저장 (바닐라와 같으면 팩에서 빼고, 처음 넣을 땐 짝 .mcmeta도). 되돌리기 기록에 쌓는다.
    @discardableResult func batchWriteTexture(_ rel: String, _ img: PixelImage, record: inout BatchRecord) -> Bool {
        guard let url = ensureInPack(rel), let doc = imageDoc(url) else { return false }
        let before = try? Data(contentsOf: url)
        let meta = URL(fileURLWithPath: url.path + ".mcmeta")
        let metaBefore = try? Data(contentsOf: meta)
        doc.commitFloating()
        doc.replace(with: img)
        guard doc.save() else { return false }
        if !doc.lastSaveRemoved { copyMetaIfNeeded(url) }
        record.files.append((url, before))
        if metaBefore == nil && FileManager.default.fileExists(atPath: meta.path) { record.files.append((meta, nil)) }
        return true
    }

    /// 텍스처의 지금 모습 (팩에 있으면 팩, 없으면 바닐라, 열려 있으면 편집 중인 것)
    func currentTexture(_ rel: String) -> PixelImage? { pixelImage(rel) }

    func finishBatch(_ r: BatchRecord) {
        if !r.files.isEmpty { batchHistory.append(r) }
        pruneEmptyDirs()
        reload(); texCache.removeAll(); changesCache = nil; assetsVersion += 1
    }

    func undoLastBatch() {
        guard let r = batchHistory.popLast() else { return }
        for (url, data) in r.files.reversed() {
            if let data {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            dropDocs(url)
        }
        pruneEmptyDirs()
        reload(); texCache.removeAll(); changesCache = nil; assetsVersion += 1
        status = "되돌렸어요: \(r.label)"
    }
}

// MARK: - 대상 고르기 (텍스처 여러 개)

struct TargetPicker: View {
    @EnvironmentObject var ws: Workspace
    @Binding var selected: Set<String>
    @State private var category = "block"
    @State private var entries: [TexEntry] = []
    @State private var query = ""
    @State private var onlyPack = false
    @State private var loading = false

    private var shown: [TexEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            (!onlyPack || e.inPack) && (q.isEmpty || e.rel.lowercased().contains(q) || (e.ko?.lowercased().contains(q) ?? false))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $category) {
                    ForEach(TexCategory.all) { Text($0.label).tag($0.id) }
                    ForEach(ws.packNamespaces(), id: \.self) { Text($0 + " (팩 전용)").tag("ns:" + $0) }
                }
                .labelsHidden().frame(width: 140)
                TextField("이름 검색 (한국어·영어)", text: $query).textFieldStyle(.roundedBorder)
            }
            HStack {
                Toggle("팩에 있는 것만", isOn: $onlyPack).toggleStyle(.checkbox)
                Spacer()
                Button("보이는 것 전부") { for e in shown { selected.insert(e.rel) } }.controlSize(.small)
                Button("보이는 것 빼기") { for e in shown { selected.remove(e.rel) } }.controlSize(.small)
                Button("모두 해제") { selected.removeAll() }.controlSize(.small).disabled(selected.isEmpty)
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 6) {
                    ForEach(shown) { e in
                        let on = selected.contains(e.rel)
                        Button { if on { selected.remove(e.rel) } else { selected.insert(e.rel) } } label: {
                            VStack(spacing: 2) {
                                Thumb(rel: e.rel, size: 40)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.6)))
                                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                            .offset(x: 5, y: -5)
                                    }
                                Text(e.ko ?? e.name).font(.system(size: 9)).lineLimit(1).frame(width: 56)
                            }
                            .padding(3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .help(e.rel.replacingOccurrences(of: "assets/minecraft/textures/", with: ""))
                    }
                }
            }
            Text("고른 텍스처 \(selected.count)개").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
        .onChange(of: category) { load() }
    }

    private func load() {
        if let c = ws.texCache[category] { entries = c.entries; return }
        loading = true
        let cat = category
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ws.textureEntries(cat)
            DispatchQueue.main.async { ws.texCache[cat] = r; if cat == category { entries = r.entries }; loading = false }
        }
    }
}

// MARK: - 일괄 작업 화면

struct BatchView: View {
    @EnvironmentObject var ws: Workspace
    @State private var tab = 0
    @State private var targets: Set<String> = []
    @State private var busy: String?

    // 색·효과
    @State private var adj = ColorAdjust()
    @State private var tintColor: Color = .pink
    @State private var gray = false
    @State private var invert = false

    // 크기
    @State private var sizeMode = 0          // 0 배율, 1 정해진 크기
    @State private var factor = 2.0
    @State private var fixedSize = 32
    @State private var smooth = false

    // 이미지 넣기
    @State private var imgMode = 0           // 0 이름으로 맞추기, 1 한 장을 여러 곳에
    @State private var matches: [ImageMatch] = []
    @State private var oneImage: CGImage?
    @State private var fit: PixelImage.Fit = .original

    // 소리
    @State private var soundMode = 0         // 0 한 이벤트에 여러 소리, 1 파일 이름 = 이벤트
    @State private var soundFiles: [URL] = []
    @State private var eventID = ""
    @State private var replace = true
    @State private var mono = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("일괄 작업").font(.title3.bold()).foregroundStyle(Theme.gradient)
                Picker("", selection: $tab) {
                    Text("색·효과").tag(0); Text("이미지 넣기").tag(1); Text("소리 넣기").tag(2); Text("크기 바꾸기").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                Spacer()
                if let last = ws.batchHistory.last {
                    Button { ws.undoLastBatch() } label: { Label("되돌리기: \(last.label)", systemImage: "arrow.uturn.backward") }
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                if needsTargets {
                    TargetPicker(selected: $targets).padding(12).frame(minWidth: 380, maxWidth: .infinity)
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case 0: effectPanel
                        case 1: imagePanel
                        case 2: soundPanel
                        default: sizePanel
                        }
                        if let busy { HStack { ProgressView().controlSize(.small); Text(busy) } }
                    }
                    .padding(14)
                }
                .frame(width: needsTargets ? 360 : nil)
                .frame(maxWidth: needsTargets ? 360 : .infinity)
            }
        }
        .onAppear { ws.lastMock = "batch" }
    }

    private var needsTargets: Bool { tab == 0 || tab == 3 || (tab == 1 && imgMode == 1) }

    private func title(_ t: String) -> some View { Text(t).font(.headline).foregroundStyle(Theme.gradient) }

    // MARK: 색·효과

    private func effectApply(_ img: PixelImage) -> PixelImage {
        var a = adj
        if gray { a.saturation = 0 }
        var out = a.apply(img)
        if invert {
            var i = 0
            while i < out.px.count { if out.px[i + 3] > 0 { for k in 0..<3 { out.px[i + k] = 255 - out.px[i + k] } }; i += 4 }
        }
        return out
    }

    private var effectPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("고른 텍스처에 한 번에 적용")
            slider("색조", $adj.hue, -180...180, "°")
            slider("채도", $adj.saturation, 0...2, "배")
            slider("밝기", $adj.brightness, -1...1, "")
            slider("대비", $adj.contrast, 0...2, "배")
            HStack {
                Text("색 입히기").frame(width: 60, alignment: .leading)
                ColorPicker("", selection: $tintColor, supportsOpacity: false).labelsHidden()
                    .onChange(of: tintColor) { syncTint() }
                Slider(value: $adj.tintAmount, in: 0...1).onChange(of: adj.tintAmount) { syncTint() }
            }
            Toggle("흑백", isOn: $gray)
            Toggle("색 반전", isOn: $invert)
            preview { effectApply($0) }
            Button { runEffect() } label: { Label("\(targets.count)개에 적용", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(targets.isEmpty || busy != nil)
            Button("설정 초기화") { adj = ColorAdjust(); gray = false; invert = false }
        }
    }

    private func slider(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(t).frame(width: 60, alignment: .leading)
            Slider(value: v, in: r)
            Text(String(format: unit == "°" ? "%.0f" : "%.2f", v.wrappedValue) + unit).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    private func syncTint() {
        let ns = NSColor(tintColor).usingColorSpace(.sRGB) ?? .white
        adj.tint = RGBA(r: UInt8(ns.redComponent * 255), g: UInt8(ns.greenComponent * 255), b: UInt8(ns.blueComponent * 255), a: 255)
    }

    /// 고른 것 중 앞의 몇 개를 전/후로
    private func preview(_ f: @escaping (PixelImage) -> PixelImage) -> some View {
        let sample = targets.sorted().prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            Text("미리보기").font(.caption).foregroundStyle(.secondary)
            if sample.isEmpty { Text("왼쪽에서 텍스처를 고르세요").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(sample), id: \.self) { rel in
                if let img = ws.currentTexture(rel) {
                    let fr = ModelScene.frame(img)
                    HStack(spacing: 8) {
                        pixel(fr); Image(systemName: "arrow.right").foregroundStyle(.secondary); pixel(f(fr))
                        Text(ws.koNameForTexture(rel) ?? (rel as NSString).lastPathComponent).font(.caption).lineLimit(1)
                    }
                }
            }
        }
    }

    private func pixel(_ img: PixelImage) -> some View {
        Group {
            if let cg = img.cgImage() { Image(decorative: cg, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit) }
        }
        .frame(width: 48, height: 48).background(Checker()).clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func runEffect() {
        var rec = BatchRecord(label: "색·효과 \(targets.count)개")
        var n = 0
        for rel in targets.sorted() {
            guard let img = ws.currentTexture(rel) else { continue }
            if ws.batchWriteTexture(rel, effectApply(img), record: &rec) { n += 1 }
        }
        ws.finishBatch(rec)
        ws.status = "색·효과를 \(n)개에 적용했어요 (되돌리기 가능)"
    }

    // MARK: 크기 바꾸기

    private func resized(_ img: PixelImage) -> PixelImage {
        let w: Int, h: Int
        if sizeMode == 0 {
            w = max(1, Int((Double(img.w) * factor).rounded())); h = max(1, Int((Double(img.h) * factor).rounded()))
        } else {
            // 가로를 정한 크기로, 세로는 비율 그대로 (애니메이션 세로 스트립도 칸 수 유지)
            w = fixedSize; h = max(1, img.h * fixedSize / max(1, img.w))
        }
        guard let cg = img.cgImage() else { return img }
        return PixelImage.fitted(cg, w: w, h: h, fit: .stretch, smooth: smooth) ?? img
    }

    private var sizePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("고른 텍스처 해상도 한 번에")
            Picker("", selection: $sizeMode) { Text("배율").tag(0); Text("정해진 크기").tag(1) }.pickerStyle(.segmented).labelsHidden()
            if sizeMode == 0 {
                Picker("배율", selection: $factor) {
                    ForEach([0.25, 0.5, 2.0, 4.0, 8.0], id: \.self) { Text(($0 < 1 ? "1/\(Int(1 / $0))" : "\(Int($0))") + "배").tag($0) }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("가로", selection: $fixedSize) {
                    ForEach([16, 32, 64, 128, 256, 512], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("세로는 비율 그대로 (애니메이션 칸 수 유지)").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("부드럽게 (사진용, 끄면 픽셀 그대로)", isOn: $smooth)
            preview { resized($0) }
            if let r = targets.sorted().first, let img = ws.currentTexture(r) {
                let o = resized(img)
                Text("예: \(img.w)x\(img.h) → \(o.w)x\(o.h)").font(.caption).foregroundStyle(.secondary)
            }
            Button { runResize() } label: { Label("\(targets.count)개 크기 바꾸기", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(targets.isEmpty || busy != nil)
            Text("GUI 텍스처는 크기를 바꾸면 게임에서 위치가 어긋날 수 있어요. 블록·아이템은 같은 배율로 키우면 그대로 보여요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runResize() {
        var rec = BatchRecord(label: "크기 \(targets.count)개")
        var n = 0
        for rel in targets.sorted() {
            guard let img = ws.currentTexture(rel) else { continue }
            if ws.batchWriteTexture(rel, resized(img), record: &rec) { n += 1 }
        }
        ws.finishBatch(rec)
        ws.status = "\(n)개 크기를 바꿨어요 (되돌리기 가능)"
    }

    // MARK: 이미지 넣기

    private var imagePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("이미지 넣기")
            Picker("", selection: $imgMode) { Text("이름으로 맞추기").tag(0); Text("한 장을 여러 곳에").tag(1) }
                .pickerStyle(.segmented).labelsHidden()
            Picker("맞추기", selection: $fit) { ForEach(PixelImage.Fit.allCases) { Text($0.rawValue).tag($0) } }
            if imgMode == 0 {
                Text("이미지 파일 이름이 텍스처 이름과 같으면 거기에 넣어요 (예: stone.png → 돌). 여러 개 한 번에 골라도 돼요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { pickImages() } label: { Label("이미지 고르기…", systemImage: "photo.on.rectangle.angled") }
                ForEach($matches) { $m in matchRow($m) }
                let ok = matches.filter { $0.target != nil }.count
                if !matches.isEmpty {
                    Text("맞춘 것 \(ok)개 · 못 찾은 것 \(matches.count - ok)개").font(.caption).foregroundStyle(.secondary)
                    Button { runMatches() } label: { Label("\(ok)개 넣기", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(ok == 0 || busy != nil)
                }
            } else {
                Button { pickOne() } label: { Label(oneImage == nil ? "이미지 한 장 고르기…" : "다른 이미지 고르기…", systemImage: "photo") }
                if let cg = oneImage {
                    Image(decorative: cg, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit).frame(height: 90)
                        .background(Checker())
                    Text("\(cg.width)x\(cg.height)").font(.caption).foregroundStyle(.secondary)
                }
                Button { runOne() } label: { Label("고른 \(targets.count)개에 넣기", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(oneImage == nil || targets.isEmpty || busy != nil)
            }
        }
    }

    private func matchRow(_ m: Binding<ImageMatch>) -> some View {
        HStack(spacing: 8) {
            if let cg = m.wrappedValue.cg {
                Image(decorative: cg, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit).frame(width: 32, height: 32).background(Checker())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.wrappedValue.file.lastPathComponent).font(.caption.bold()).lineLimit(1)
                if m.wrappedValue.candidates.isEmpty {
                    Text("맞는 텍스처 없음").font(.caption2).foregroundStyle(.orange)
                } else {
                    Picker("", selection: m.target) {
                        ForEach(m.wrappedValue.candidates, id: \.self) { c in
                            Text(c.replacingOccurrences(of: "assets/minecraft/textures/", with: "")).tag(Optional(c))
                        }
                        Text("넣지 않기").tag(String?.none)
                    }
                    .labelsHidden().controlSize(.small)
                }
            }
        }
    }

    private func loadCG(_ u: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func pickImages() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        let files = p.urls
        busy = "텍스처 이름 찾는 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            // 모든 분류의 텍스처를 이름별로
            var byName: [String: [String]] = [:]
            var cats = TexCategory.all.map(\.id)
            cats += ws.packNamespaces().map { "ns:" + $0 }
            for c in cats {
                for e in (ws.texCache[c]?.entries ?? ws.textureEntries(c).entries) {
                    byName[e.name.lowercased(), default: []].append(e.rel)
                }
            }
            let out: [ImageMatch] = files.map { f in
                let key = f.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "_")
                // 블록·아이템 먼저
                let cands = (byName[key] ?? []).sorted { a, b in
                    func rank(_ s: String) -> Int { s.contains("/textures/block/") ? 0 : s.contains("/textures/item/") ? 1 : 2 }
                    return rank(a) < rank(b)
                }
                return ImageMatch(file: f, cg: loadCG(f), candidates: cands, target: cands.first)
            }
            DispatchQueue.main.async { matches = out; busy = nil }
        }
    }

    private func pickOne() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { oneImage = loadCG(u) }
    }

    private func fitted(_ cg: CGImage, to rel: String) -> PixelImage? {
        let cur = ws.currentTexture(rel)
        return PixelImage.fitted(cg, w: cur?.w ?? cg.width, h: cur?.h ?? cg.height, fit: fit, smooth: false)
    }

    private func runMatches() {
        var rec = BatchRecord(label: "이미지 \(matches.filter { $0.target != nil }.count)개")
        var n = 0
        for m in matches {
            guard let t = m.target, let cg = m.cg, let img = fitted(cg, to: t) else { continue }
            if ws.batchWriteTexture(t, img, record: &rec) { n += 1 }
        }
        ws.finishBatch(rec)
        ws.status = "이미지 \(n)개를 넣었어요 (되돌리기 가능)"
        matches = []
    }

    private func runOne() {
        guard let cg = oneImage else { return }
        var rec = BatchRecord(label: "한 장을 \(targets.count)곳에")
        var n = 0
        for rel in targets.sorted() {
            guard let img = fitted(cg, to: rel) else { continue }
            if ws.batchWriteTexture(rel, img, record: &rec) { n += 1 }
        }
        ws.finishBatch(rec)
        ws.status = "이미지 한 장을 \(n)곳에 넣었어요 (되돌리기 가능)"
    }

    // MARK: 소리 넣기

    private var soundPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("소리 파일 여러 개를 한 번에")
            Picker("", selection: $soundMode) { Text("한 이벤트에 여러 소리").tag(0); Text("파일 이름 = 이벤트 이름").tag(1) }
                .pickerStyle(.segmented).labelsHidden()
            if soundMode == 0 {
                TextField("이벤트 (예: entity.player.hurt)", text: $eventID).textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                let sugg = eventSuggestions
                if !sugg.isEmpty {
                    ForEach(sugg, id: \.self) { e in
                        Button { eventID = e } label: {
                            HStack { Text(e).font(.system(size: 11, design: .monospaced)); Spacer() }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("고른 소리들이 이 이벤트의 후보가 돼서 게임이 하나씩 골라 틀어요.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("파일 이름을 이벤트 이름으로 지어 두면 각자 알맞은 곳에 들어가요 (예: entity.player.hurt.mp3, ui.button.click.wav).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button { pickSounds() } label: { Label("소리 파일 고르기…", systemImage: "waveform.badge.plus") }
            ForEach(soundFiles, id: \.self) { f in
                HStack {
                    Image(systemName: "waveform").foregroundStyle(.secondary)
                    Text(f.lastPathComponent).font(.caption).lineLimit(1)
                    Spacer()
                    if soundMode == 1 {
                        let e = eventName(f)
                        Text(ws.vanillaSounds()[e] == nil ? "없는 이벤트" : e).font(.caption2)
                            .foregroundStyle(ws.vanillaSounds()[e] == nil ? .orange : .secondary)
                    }
                }
            }
            Toggle("바닐라 소리 빼고 내 것만 (replace)", isOn: $replace)
            Toggle("모노로 (멀리서 작게 들리게, 효과음 추천)", isOn: $mono)
            Text(AudioConvert.oggenc != nil ? "변환: oggenc (모노 가능)" : AudioConvert.ffmpeg != nil ? "변환: ffmpeg (스테레오만)" : "ogg 변환 도구 없음")
                .font(.caption).foregroundStyle(.secondary)
            Button { runSounds() } label: { Label("\(soundFiles.count)개 넣기", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .disabled(soundFiles.isEmpty || busy != nil || (soundMode == 0 && eventID.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }

    private var eventSuggestions: [String] {
        let q = eventID.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, ws.vanillaSounds()[q] == nil else { return [] }
        return Array(ws.vanillaSounds().keys.filter { $0.contains(q) }.sorted().prefix(6))
    }

    private func eventName(_ f: URL) -> String { f.deletingPathExtension().lastPathComponent.lowercased() }

    private func pickSounds() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = true
        if p.runModal() == .OK { soundFiles = p.urls }
    }

    private func runSounds() {
        let files = soundFiles, mode = soundMode, ev = eventID.trimmingCharacters(in: .whitespaces), monoNow = mono
        busy = "소리 \(files.count)개 변환 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            var done: [(event: String, name: String)] = []
            var notes = Set<String>()
            for (k, f) in files.enumerated() {
                let event = mode == 0 ? ev : f.deletingPathExtension().lastPathComponent.lowercased()
                let name = "custom/\(event.replacingOccurrences(of: ".", with: "_"))_\(Int(Date().timeIntervalSince1970) % 100000)_\(k)"
                guard let dest = ws.packURL(SoundIDs.rel(name)) else { continue }
                if f.pathExtension.lowercased() == "ogg" && !monoNow {
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? FileManager.default.copyItem(at: f, to: dest)) != nil { done.append((event, name)) }
                } else {
                    let r = AudioConvert.toOgg(f, dest, mono: monoNow)
                    notes.insert(r.note)
                    if r.ok { done.append((event, name)) }
                }
            }
            DispatchQueue.main.async {
                var rec = BatchRecord(label: "소리 \(done.count)개")
                for d in done { if let u = ws.packURL(SoundIDs.rel(d.name)) { rec.files.append((u, nil)) } }
                ws.addSounds(done, replace: replace, record: &rec)
                ws.finishBatch(rec)
                busy = nil
                soundFiles = []
                ws.status = "소리 \(done.count)개를 넣었어요" + (notes.isEmpty ? "" : " · " + notes.joined(separator: ", "))
            }
        }
    }
}

struct ImageMatch: Identifiable {
    let file: URL
    let cg: CGImage?
    let candidates: [String]
    var target: String?
    var id: String { file.path }
}

extension Workspace {
    /// sounds.json에 이벤트별로 소리 추가하고 바로 저장
    func addSounds(_ items: [(event: String, name: String)], replace: Bool, record: inout BatchRecord) {
        guard !items.isEmpty, let u = packURL("assets/minecraft/sounds.json") else { return }
        record.files.append((u, try? Data(contentsOf: u)))
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{}\n".write(to: u, atomically: true, encoding: .utf8)
            dropDocs(u)
        }
        let doc = modelDoc(u)
        let van = vanillaSounds()
        doc.mutate { r in
            for it in items {
                var ev = r[it.event] as? [String: Any] ?? [:]
                if ev["subtitle"] == nil, let st = (van[it.event] as? [String: Any])?["subtitle"] { ev["subtitle"] = st }
                if replace { ev["replace"] = true }
                var a = ev["sounds"] as? [Any] ?? []
                a.append(["name": it.name])
                ev["sounds"] = a
                r[it.event] = ev
            }
        }
        doc.save()
    }
}
