import AppKit
import SceneKit
import SwiftUI

let displaySlots: [(String, String)] = [
    ("thirdperson_righthand", "3인칭 오른손"), ("thirdperson_lefthand", "3인칭 왼손"),
    ("firstperson_righthand", "1인칭 오른손"), ("firstperson_lefthand", "1인칭 왼손"),
    ("head", "머리"), ("gui", "인벤토리(GUI)"), ("ground", "바닥"), ("fixed", "액자"), ("on_shelf", "선반"),
]

struct ModelEditorView: View {
    @ObservedObject var doc: ModelDoc
    @EnvironmentObject var ws: Workspace
    @State private var tab = 0
    @State private var selected: Int?
    @State private var selectedFace = "north"
    @State private var paint = false
    @State private var brush = BrushSettings()
    @State private var dark = false
    @State private var slot: String?        // nil = 모델 그대로
    @State private var info = ""
    @State private var newTexKey = ""
    @State private var rev = 0              // 칠하기 후 텍스처 다시 읽기

    private var modelID: String { ModelIDs.id(fromRel: ws.relPath(doc.url)) ?? doc.url.deletingPathExtension().lastPathComponent }
    private var resolved: ResolvedModel { ws.resolveModel(doc.root, id: modelID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == 1 {
                TextEditorView(doc: ws.textDoc(doc.url)).id("json-" + doc.url.path)
            } else {
                if let e = doc.loadError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(8)
                }
                HStack(spacing: 0) {
                    outliner.frame(width: 210)
                    Divider()
                    VStack(spacing: 0) {
                        viewBar
                        Divider()
                        ModelSceneView(doc: doc, resolved: resolved, selected: $selected, selectedFace: $selectedFace,
                                       paint: paint, brush: $brush, dark: dark, display: slot.flatMap { resolved.display[$0] },
                                       slot: slot, rev: rev, info: $info)
                        Divider()
                        HStack {
                            Text(info.isEmpty ? (paint ? "면 위를 끌면 그 텍스처에 칠해요 (팩에 없으면 바닐라에서 복사)" : "면을 누르면 요소가 선택돼요. 빈 곳을 끌면 돌리기, 휠로 확대") : info)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            if doc.dirty { Text("저장 안 됨 (Cmd+S)").font(.caption).foregroundStyle(.orange) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                    .frame(minWidth: 320)
                    Divider()
                    inspector.frame(width: 268)
                }
            }
        }
        .onChange(of: tab) { syncTab() }
    }

    // MARK: 머리줄

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) { Text("3D 편집").tag(0); Text("JSON").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            Text(modelID).font(.system(.callout, design: .monospaced).bold()).lineLimit(1).truncationMode(.middle)
            Text("부모").foregroundStyle(.secondary)
            TextField("없음", text: Binding(get: { doc.parent ?? "" }, set: { v in
                doc.mutate(coalesce: "parent") { $0["parent"] = v.isEmpty ? nil : v }
            }))
            .font(.system(.callout, design: .monospaced))
            .textFieldStyle(.roundedBorder).frame(minWidth: 150, maxWidth: 260)
            if let p = doc.parent, resolved.missing == p {
                Label("부모를 못 찾음", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            } else if let p = doc.parent {
                Button("열기") { ws.editAsset(ModelIDs.modelRel(p)) }.help("부모 모델 열기 (바닐라면 팩으로 복사)")
            }
            Spacer(minLength: 0)
            if modelID.hasPrefix("minecraft:item/") {
                Button { openItemDef() } label: { Label("상황별 정의", systemImage: "arrow.triangle.branch") }
                    .help("이 아이템이 손·인벤토리 등에서 어떤 모델을 쓸지 정하는 items/*.json 열기")
            }
            Button { doc.undo(); rev += 1 } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(!doc.canUndo).help("실행취소")
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var viewBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $paint) {
                Label("선택", systemImage: "cursorarrow").tag(false)
                Label("칠하기", systemImage: "paintbrush").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            if paint { BrushBar(brush: $brush) }
            Spacer(minLength: 0)
            Toggle(isOn: $dark) { Label("어두운 곳", systemImage: "moon.fill") }
                .toggleStyle(.button).help("밝기 0에서 보기: light_emission 준 요소만 밝게 보여요")
            Picker("보기", selection: $slot) {
                Text("모델 그대로").tag(String?.none)
                ForEach(displaySlots, id: \.0) { s in Text(s.1).tag(String?.some(s.0)) }
            }
            .frame(width: 190)
        }
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: 왼쪽: 요소·텍스처 목록

    private var outliner: some View {
        let r = resolved
        return List(selection: $selected) {
            Section {
                if r.generated {
                    Text("평면 아이템 (builtin/generated)\nlayer0, layer1… 텍스처를 겹쳐 그려요")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("큐브 요소로 바꾸기") { toCube() }
                } else if !r.elementsOwn, let from = r.elementsFrom {
                    Text("요소는 부모(\(from))에서 물려받는 중").font(.caption).foregroundStyle(.secondary)
                    Button("부모 요소를 가져와서 편집") {
                        doc.mutate { $0["elements"] = r.elements }
                    }
                }
                ForEach(Array((doc.elements ?? []).enumerated()), id: \.offset) { i, el in
                    let a = vec3(el["from"]), b = vec3(el["to"])
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text((el["name"] as? String) ?? "요소 \(i)").bold()
                            if ((el["light_emission"] as? NSNumber)?.intValue ?? 0) > 0 {
                                Image(systemName: "sun.max.fill").foregroundStyle(.orange).help("발광")
                            }
                        }
                        Text("\(fmt(a)) → \(fmt(b))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .tag(i)
                }
            } header: {
                HStack {
                    Text("요소")
                    Spacer()
                    Button { addElement() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("큐브 추가")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(.borderless)
                        .disabled(selected == nil).help("복제")
                    Button { deleteSelected() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        .disabled(selected == nil).help("삭제")
                }
            }
            Section("텍스처") {
                ForEach(r.textures.keys.sorted(), id: \.self) { k in
                    textureRow(k, own: doc.textures[k] != nil, value: r.textures[k] ?? "")
                }
                HStack {
                    TextField("새 키 (예: all, layer0)", text: $newTexKey).textFieldStyle(.roundedBorder)
                    Button("추가") {
                        let k = newTexKey.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty else { return }
                        doc.mutate { var t = $0["textures"] as? [String: Any] ?? [:]; t[k] = "minecraft:block/stone"; $0["textures"] = t }
                        newTexKey = ""
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func textureRow(_ k: String, own: Bool, value: String) -> some View {
        let rel = resolved.texture(value).map(ModelIDs.textureRel)
        return HStack(spacing: 6) {
            if let rel, let img = ws.pixelImage(rel), let cg = ModelScene.frame(img).cgImage() {
                Image(decorative: cg, scale: 1).interpolation(.none).resizable().frame(width: 20, height: 20)
                    .onTapGesture(count: 2) { ws.editAsset(rel) }
                    .help("두 번 누르면 그림판으로")
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2)).frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(k).font(.caption.bold()) + Text(own ? "" : "  (부모)").font(.caption2)
                TextField("", text: Binding(get: { value }, set: { v in
                    doc.mutate(coalesce: "tex-\(k)") { var t = $0["textures"] as? [String: Any] ?? [:]; t[k] = v; $0["textures"] = t }
                    rev += 1
                }))
                .font(.system(size: 10, design: .monospaced))
                .textFieldStyle(.plain)
            }
        }
    }

    // MARK: 오른쪽: 속성

    @ViewBuilder private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let slot {
                    displayInspector(slot)
                } else if let i = selected, let el = doc.elements?[safe: i] {
                    elementInspector(i, el)
                } else {
                    Text("요소를 고르거나 3D에서 면을 누르세요.\n위 '보기'에서 손·머리·인벤토리 등 위치를 고르면 display 값을 고칠 수 있어요.")
                        .foregroundStyle(.secondary).font(.callout)
                    if !resolved.generated && !resolved.elementsOwn && resolved.elements != nil {
                        Text("이 모델은 요소를 부모에서 물려받아요. 왼쪽의 '부모 요소를 가져와서 편집'을 누르면 이 파일에서 고칠 수 있어요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }

    private func elementInspector(_ i: Int, _ el: [String: Any]) -> some View {
        let a = vec3(el["from"]), b = vec3(el["to"], [16, 16, 16])
        let rot = el["rotation"] as? [String: Any]
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("요소 \(i)")
            TextField("이름 (선택)", text: Binding(get: { el["name"] as? String ?? "" },
                                               set: { doc.setElement(i, "name", $0.isEmpty ? nil : $0, coalesce: "name\(i)") }))
                .textFieldStyle(.roundedBorder)
            Vec3Editor(label: "시작 from", value: a, range: -16...32) { doc.setElement(i, "from", [$0.x, $0.y, $0.z], coalesce: "from\(i)"); rev += 1 }
            Vec3Editor(label: "끝 to", value: b, range: -16...32) { doc.setElement(i, "to", [$0.x, $0.y, $0.z], coalesce: "to\(i)"); rev += 1 }
            if a.x < -16 || a.y < -16 || a.z < -16 || b.x > 32 || b.y > 32 || b.z > 32 {
                Label("게임은 -16~32 밖을 허용하지 않아요", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }

            sectionTitle("회전")
            Picker("축", selection: Binding(get: { rot?["axis"] as? String ?? "y" }, set: { ax in
                var r = rot ?? ["origin": [8, 8, 8], "angle": 0]; r["axis"] = ax
                doc.setElement(i, "rotation", r)
            })) { Text("x").tag("x"); Text("y").tag("y"); Text("z").tag("z") }
                .pickerStyle(.segmented)
            let ang = (rot?["angle"] as? NSNumber)?.doubleValue ?? 0
            HStack {
                Slider(value: Binding(get: { ang }, set: { v in
                    var r = rot ?? ["origin": [8, 8, 8], "axis": "y"]; r["angle"] = (v / 22.5).rounded() * 22.5
                    doc.setElement(i, "rotation", r, coalesce: "ang\(i)")
                }), in: -45...45, step: 22.5)
                TextField("", value: Binding(get: { ang }, set: { v in
                    var r = rot ?? ["origin": [8, 8, 8], "axis": "y"]; r["angle"] = v
                    doc.setElement(i, "rotation", r)
                }), format: .number).frame(width: 48).textFieldStyle(.roundedBorder)
                Text("°")
            }
            Vec3Editor(label: "회전 중심 origin", value: vec3(rot?["origin"], [8, 8, 8]), range: -16...32) { o in
                var r = rot ?? ["axis": "y", "angle": 0]; r["origin"] = [o.x, o.y, o.z]
                doc.setElement(i, "rotation", r, coalesce: "org\(i)")
            }
            Toggle("rescale (회전해도 크기 유지)", isOn: Binding(get: { rot?["rescale"] as? Bool ?? false }, set: { v in
                var r = rot ?? ["origin": [8, 8, 8], "axis": "y", "angle": 0]; r["rescale"] = v ? true : nil
                doc.setElement(i, "rotation", r)
            }))

            sectionTitle("밝기")
            Toggle("방향별 명암 (shade)", isOn: Binding(get: { el["shade"] as? Bool ?? true },
                                                    set: { doc.setElement(i, "shade", $0 ? nil : false) }))
            let em = (el["light_emission"] as? NSNumber)?.intValue ?? 0
            HStack {
                Text("발광")
                Slider(value: Binding(get: { Double(em) }, set: { v in
                    doc.setElement(i, "light_emission", Int(v) == 0 ? nil : Int(v), coalesce: "em\(i)")
                }), in: 0...15, step: 1)
                Text("\(em)").monospacedDigit().frame(width: 22)
            }
            Button("풀브라이트 (발광 15 + 명암 끔)") {
                doc.mutate { r in
                    var els = r["elements"] as? [[String: Any]] ?? []
                    guard els.indices.contains(i) else { return }
                    els[i]["light_emission"] = 15; els[i]["shade"] = false
                    r["elements"] = els
                }
                dark = true
            }
            Text("'어두운 곳'을 켜면 게임 밤처럼 보고 발광 요소만 밝게 보여요.").font(.caption).foregroundStyle(.secondary)

            sectionTitle("면")
            faceInspector(i, el, a, b)
        }
    }

    private func faceInspector(_ i: Int, _ el: [String: Any], _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> some View {
        let faces = el["faces"] as? [String: Any] ?? [:]
        let f = faces[selectedFace] as? [String: Any]
        let keys = resolved.textures.keys.sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Picker("면", selection: $selectedFace) {
                ForEach(ModelScene.dirs, id: \.self) { d in
                    Text((ModelScene.dirLabel[d] ?? d) + (faces[d] == nil ? " (없음)" : "")).tag(d)
                }
            }
            if let f {
                Picker("텍스처", selection: Binding(get: { f["texture"] as? String ?? "" },
                                                 set: { doc.setFace(i, selectedFace, "texture", $0); rev += 1 })) {
                    ForEach(keys, id: \.self) { k in Text("#" + k).tag("#" + k) }
                    if let t = f["texture"] as? String, !keys.map({ "#" + $0 }).contains(t) { Text(t).tag(t) }
                }
                let uv = nums(f["uv"])
                let shown = uv.count == 4 ? uv : ModelScene.defaultUV(selectedFace, a, b)
                HStack {
                    Text("UV").frame(width: 24, alignment: .leading)
                    ForEach(0..<4, id: \.self) { k in
                        TextField("", value: Binding(get: { shown[k] }, set: { v in
                            var n = shown; n[k] = v; doc.setFace(i, selectedFace, "uv", n); rev += 1
                        }), format: .number).textFieldStyle(.roundedBorder)
                    }
                }
                if uv.count != 4 { Text("uv 없음: 요소 크기에 맞춘 기본값을 써요").font(.caption2).foregroundStyle(.secondary) }
                Picker("텍스처 회전", selection: Binding(get: { (f["rotation"] as? NSNumber)?.intValue ?? 0 },
                                                    set: { doc.setFace(i, selectedFace, "rotation", $0 == 0 ? nil : $0); rev += 1 })) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("색 입히기 (tintindex 0, 풀·잎처럼)", isOn: Binding(
                    get: { f["tintindex"] != nil },
                    set: { doc.setFace(i, selectedFace, "tintindex", $0 ? 0 : nil); rev += 1 }))
                Button("이 면 없애기", role: .destructive) {
                    doc.mutate { r in
                        var els = r["elements"] as? [[String: Any]] ?? []
                        var fs = els[i]["faces"] as? [String: Any] ?? [:]
                        fs[selectedFace] = nil; els[i]["faces"] = fs; r["elements"] = els
                    }
                    rev += 1
                }
            } else {
                Button("이 면 만들기") {
                    doc.setFace(i, selectedFace, "texture", keys.first.map { "#" + $0 } ?? "#missing"); rev += 1
                }
            }
        }
    }

    private func displayInspector(_ slot: String) -> some View {
        let own = (doc.root["display"] as? [String: Any])?[slot] as? [String: Any]
        let cur = own ?? resolved.display[slot]
        let label = displaySlots.first { $0.0 == slot }?.1 ?? slot
        func set(_ key: String, _ v: SIMD3<Double>, _ co: String) {
            doc.mutate(coalesce: co) { r in
                var d = r["display"] as? [String: Any] ?? [:]
                var s = d[slot] as? [String: Any] ?? (cur ?? [:])
                s[key] = [v.x, v.y, v.z]
                d[slot] = s; r["display"] = d
            }
        }
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("display: \(label)")
            if own == nil {
                Text(cur == nil ? "값 없음 (게임 기본)" : "부모(\(resolved.displayFrom[slot] ?? ""))에서 물려받은 값. 고치면 이 파일에 저장돼요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SliderVec3(label: "회전 rotation (°)", value: vec3(cur?["rotation"]), range: -180...180, step: 1) { set("rotation", $0, "drot") }
            SliderVec3(label: "이동 translation", value: vec3(cur?["translation"]), range: -80...80, step: 0.25) { set("translation", $0, "dtr") }
            SliderVec3(label: "크기 scale (최대 4)", value: vec3(cur?["scale"], [1, 1, 1]), range: 0...4, step: 0.05) { set("scale", $0, "dsc") }
            if slot.hasSuffix("lefthand") {
                Button("오른손 값을 거울로 복사") {
                    let right = slot.replacingOccurrences(of: "lefthand", with: "righthand")
                    let src = ((doc.root["display"] as? [String: Any])?[right] as? [String: Any]) ?? resolved.display[right]
                    guard let src else { return }
                    let r = vec3(src["rotation"]), t = vec3(src["translation"]), s = vec3(src["scale"], [1, 1, 1])
                    doc.mutate { root in
                        var d = root["display"] as? [String: Any] ?? [:]
                        d[slot] = ["rotation": [r.x, -r.y, -r.z], "translation": [-t.x, t.y, t.z], "scale": [s.x, s.y, s.z]]
                        root["display"] = d
                    }
                }
            }
            if own != nil {
                Button("내 값 지우기 (부모 값으로)") {
                    doc.mutate { r in
                        var d = r["display"] as? [String: Any] ?? [:]
                        d[slot] = nil
                        r["display"] = d.isEmpty ? nil : d
                    }
                }
            }
            Text("미리보기는 변환(이동·회전·크기)만 보여줘요. 손·머리에 실제로 붙는 위치는 게임에서 확인하세요. 회색 상자가 원래 블록 크기(16)예요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.headline).foregroundStyle(Theme.gradient)
    }

    // MARK: 작업

    private func fmt(_ v: SIMD3<Double>) -> String {
        func f(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d) }
        return "\(f(v.x)),\(f(v.y)),\(f(v.z))"
    }

    private func ensureOwnElements() {
        if doc.elements == nil { doc.mutate { $0["elements"] = resolved.elements ?? [] } }
    }

    private func addElement() {
        ensureOwnElements()
        let key = resolved.textures.keys.sorted().first { $0 != "particle" } ?? resolved.textures.keys.sorted().first
        let t = key.map { "#" + $0 } ?? "#missing"
        var faces: [String: Any] = [:]
        for d in ModelScene.dirs { faces[d] = ["texture": t] }
        doc.mutate { r in
            var els = r["elements"] as? [[String: Any]] ?? []
            els.append(["from": [4, 4, 4], "to": [12, 12, 12], "faces": faces])
            r["elements"] = els
        }
        selected = (doc.elements?.count ?? 1) - 1
        rev += 1
    }

    private func duplicate() {
        guard let i = selected, let el = doc.elements?[safe: i] else { return }
        doc.mutate { r in var els = r["elements"] as? [[String: Any]] ?? []; els.insert(el, at: i + 1); r["elements"] = els }
        selected = i + 1; rev += 1
    }

    private func deleteSelected() {
        guard let i = selected else { return }
        doc.mutate { r in var els = r["elements"] as? [[String: Any]] ?? []; if els.indices.contains(i) { els.remove(at: i) }; r["elements"] = els }
        selected = nil; rev += 1
    }

    /// 평면 아이템을 16x16x1 큐브로 (앞뒤에 layer0)
    private func toCube() {
        doc.mutate { r in
            r["elements"] = [["from": [0, 0, 7.5], "to": [16, 16, 8.5],
                              "faces": ["north": ["texture": "#layer0", "uv": [16, 0, 0, 16]], "south": ["texture": "#layer0", "uv": [0, 0, 16, 16]]]]]
        }
        selected = 0; rev += 1
    }

    /// items/<이름>.json 열기. 팩·바닐라에 없으면 이 모델을 쓰는 정의를 새로 만든다.
    private func openItemDef() {
        let name = String(modelID.dropFirst("minecraft:item/".count))
        let rel = "assets/minecraft/items/\(name).json"
        if ws.resolve(rel) != nil { ws.editAsset(rel); return }
        guard let u = ws.packURL(rel) else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{\n  \"model\": {\n    \"type\": \"minecraft:model\",\n    \"model\": \"\(modelID)\"\n  }\n}\n".write(to: u, atomically: true, encoding: .utf8)
        ws.reload()
        ws.selection = u.path
    }

    private func syncTab() {
        if tab == 1 {
            if doc.dirty { doc.save() }
            ws.dropTextDoc(doc.url)
        } else {
            let td = ws.textDoc(doc.url)
            if td.dirty { td.save() }
            ws.dropTextDoc(doc.url)
            doc.load()
            rev += 1
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct Vec3Editor: View {
    let label: String
    let value: SIMD3<Double>
    let range: ClosedRange<Double>
    let set: (SIMD3<Double>) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { k in
                    HStack(spacing: 2) {
                        Text(["x", "y", "z"][k]).font(.caption2).foregroundStyle([Color.red, .green, .blue][k])
                        TextField("", value: Binding(get: { value[k] }, set: { v in
                            var n = value; n[k] = min(max(v, range.lowerBound), range.upperBound); set(n)
                        }), format: .number).textFieldStyle(.roundedBorder)
                        Stepper("", onIncrement: { var n = value; n[k] = min(range.upperBound, n[k] + 1); set(n) },
                                onDecrement: { var n = value; n[k] = max(range.lowerBound, n[k] - 1); set(n) })
                            .labelsHidden()
                    }
                }
            }
        }
    }
}

struct SliderVec3: View {
    let label: String
    let value: SIMD3<Double>
    let range: ClosedRange<Double>
    let step: Double
    let set: (SIMD3<Double>) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ForEach(0..<3, id: \.self) { k in
                HStack(spacing: 6) {
                    Text(["x", "y", "z"][k]).font(.caption.bold()).foregroundStyle([Color.red, .green, .blue][k]).frame(width: 12)
                    Slider(value: Binding(get: { value[k] }, set: { v in var n = value; n[k] = (v / step).rounded() * step; set(n) }), in: range)
                    TextField("", value: Binding(get: { value[k] }, set: { v in
                        var n = value; n[k] = min(max(v, range.lowerBound), range.upperBound); set(n)
                    }), format: .number).textFieldStyle(.roundedBorder).frame(width: 56)
                }
            }
        }
    }
}

// MARK: - 3D 보기

struct ModelSceneView: NSViewRepresentable {
    @ObservedObject var doc: ModelDoc
    @EnvironmentObject var ws: Workspace
    let resolved: ResolvedModel
    @Binding var selected: Int?
    @Binding var selectedFace: String
    let paint: Bool
    @Binding var brush: BrushSettings
    let dark: Bool
    let display: [String: Any]?
    let slot: String?
    let rev: Int
    @Binding var info: String

    final class Coord {
        let holder = SCNNode()   // display 변환을 받는 노드
        var faces: [String: FaceInfo] = [:]
        var last: (Int, Int)?
        var lastRel: String?
        var key = ""
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> InteractiveSCNView {
        let v = InteractiveSCNView(frame: .zero)
        v.scene = SCNScene()
        v.backgroundColor = NSColor(calibratedRed: 0.8, green: 0.89, blue: 1, alpha: 1)
        v.antialiasingMode = .multisampling4X
        v.distance = 48
        v.yaw = -0.6; v.pitch = 0.45
        v.setup()
        v.pivot.addChildNode(ModelScene.guides())
        v.pivot.addChildNode(context.coordinator.holder)
        update(v, context.coordinator)
        return v
    }

    func updateNSView(_ v: InteractiveSCNView, context: Context) { update(v, context.coordinator) }

    private func rebuild(_ c: Coord) {
        c.holder.childNodes.forEach { $0.removeFromParentNode() }
        let (n, info) = ModelScene.build(resolved, ws: ws, opt: .init(dark: dark, selected: selected))
        c.holder.addChildNode(n)
        c.faces = info
    }

    private func update(_ v: InteractiveSCNView, _ c: Coord) {
        // 문서 내용·선택·밝기·텍스처가 바뀌면 다시 짓기
        let snap = (try? JSONSerialization.data(withJSONObject: doc.root, options: .sortedKeys)).map { String($0.hashValue) } ?? ""
        let key = "\(snap)-\(selected ?? -1)-\(dark)-\(rev)-\(ws.assetsVersion)-\(resolved.chain.joined())"
        if key != c.key { c.key = key; rebuild(c) }
        ModelScene.applyDisplay(c.holder, slot == nil ? nil : display)
        v.paintEnabled = true
        v.onHit = { hits, first in
            guard let h = hits.first(where: { c.faces[$0.node.name ?? ""] != nil }), let fi = c.faces[h.node.name ?? ""] else { return }
            if !paint {
                if first, fi.element >= 0 { selected = fi.element; selectedFace = fi.dir }
                info = describe(fi)
                return
            }
            guard let rel = fi.textureRel, let url = ws.ensureInPack(rel), let idoc = ws.imageDoc(url) else {
                info = "이 면의 텍스처를 찾지 못했어요"; return
            }
            if first || c.lastRel != rel { c.last = nil }
            let t = h.textureCoordinates(withMappingChannel: 0)
            let x = min(max(Int(floor(t.x * CGFloat(fi.texW))), 0), fi.texW - 1)
            let y = min(max(Int(floor(t.y * CGFloat(fi.frameH))), 0), fi.frameH - 1)
            if let picked = brush.apply(idoc, (x, y), from: c.last) { brush.color = picked; brush.tool = .pencil }
            c.last = (x, y); c.lastRel = rel
            // 칠한 텍스처만 바로 바꿔 끼우기
            let cg = ModelScene.frame(idoc.image).cgImage()
            let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            for child in c.holder.childNodes.flatMap({ $0.childNodes }) where c.faces[child.name ?? ""]?.textureRel == rel {
                child.geometry?.firstMaterial?.diffuse.contents = img
            }
            info = "\(describe(fi))  픽셀 (\(x), \(y))  · 텍스처 저장은 Cmd+S"
        }
        v.onStrokeEnd = { c.last = nil }
        v.onHover = { hits in
            if let h = hits.first(where: { c.faces[$0.node.name ?? ""] != nil }), let fi = c.faces[h.node.name ?? ""] {
                info = describe(fi)
            } else { info = "" }
        }
    }

    private func describe(_ fi: FaceInfo) -> String {
        let face = ModelScene.dirLabel[fi.dir] ?? fi.dir
        let tex = fi.textureRel.map { $0.replacingOccurrences(of: "assets/minecraft/textures/", with: "") } ?? "텍스처 없음"
        return fi.element >= 0 ? "요소 \(fi.element) · \(face) · \(tex)" : "\(fi.dir) · \(tex)"
    }
}
