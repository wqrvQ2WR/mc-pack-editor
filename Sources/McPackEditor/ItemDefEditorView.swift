import AppKit
import SceneKit
import SwiftUI

struct TreeRow: Identifiable {
    let id: String
    let path: JPath
    let depth: Int
    let edge: String?
    let title: String
    let detail: String
}

struct ItemDefEditorView: View {
    @ObservedObject var doc: ModelDoc   // 범용 JSON 문서로 씀
    @EnvironmentObject var ws: Workspace
    @State private var tab = 0
    @State private var selected: String? = "model"
    @State private var ctx = ItemContext()
    @State private var customProp = ""
    @State private var rawText = ""
    @State private var rawError: String?

    private var rootNode: Any? { doc.root["model"] }

    private var rows: [TreeRow] {
        var out: [TreeRow] = []
        func walk(_ path: JPath, _ depth: Int, _ edge: String?) {
            guard let n = JTree.get(doc.root, path[...]) as? [String: Any] else {
                out.append(TreeRow(id: JTree.id(path), path: path, depth: depth, edge: edge, title: "(비어 있음)", detail: ""))
                return
            }
            let (t, d) = ItemNodeKind.label(n)
            out.append(TreeRow(id: JTree.id(path), path: path, depth: depth, edge: edge, title: t, detail: d))
            for (e, p) in ItemNodeKind.children(n, path) { walk(p, depth + 1, e) }
        }
        walk(["model"], 0, nil)
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == 1 {
                TextEditorView(doc: ws.textDoc(doc.url)).id("json-" + doc.url.path)
            } else {
                var visited = Set<String>()
                let ids = ItemEval.run(rootNode, ["model"], ctx, &visited)
                HStack(spacing: 0) {
                    tree(visited).frame(minWidth: 280, idealWidth: 330)
                    Divider()
                    VStack(spacing: 0) {
                        contextPanel
                        Divider()
                        ItemPreviewScene(ids: ids, context: ctx.display, rev: doc.root.description.hashValue)
                        Divider()
                        HStack {
                            Text(ids.isEmpty ? "이 상황에선 그릴 모델이 없어요" : "그려지는 모델: " + ids.map { id in
                                let r = ws.resolveModel(ws.modelJSON(id) ?? [:], id: id)
                                let shapeless = !r.generated && r.elements == nil
                                return ModelIDs.split(id).1 + (shapeless ? " (모양 없음: 게임이 직접 그림)" : "")
                            }.joined(separator: " + "))
                                .font(.caption).lineLimit(1)
                            Spacer()
                            ForEach(ids, id: \.self) { id in
                                Button("열기") { ws.editAsset(ModelIDs.modelRel(id)) }.controlSize(.small).help(id)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                    }
                    .frame(minWidth: 300)
                    Divider()
                    inspector.frame(width: 290)
                }
            }
        }
        .onChange(of: tab) { syncTab() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) { Text("나무 편집").tag(0); Text("JSON").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            Text(ws.relPath(doc.url)).font(.system(.callout, design: .monospaced).bold()).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if doc.dirty { Text("저장 안 됨 (Cmd+S)").font(.caption).foregroundStyle(.orange) }
            Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(!doc.canUndo)
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: 나무

    private func tree(_ visited: Set<String>) -> some View {
        List(selection: $selected) {
            Section {
                ForEach(rows) { r in
                    HStack(spacing: 6) {
                        Circle().fill(visited.contains(r.id) ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                            .frame(width: 8, height: 8)
                            .help(visited.contains(r.id) ? "지금 상황에서 지나가는 길" : "")
                        VStack(alignment: .leading, spacing: 1) {
                            if let e = r.edge { Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            HStack(spacing: 4) {
                                Text(r.title).font(.callout.bold())
                                Text(r.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(r.depth) * 16)
                    .tag(r.id)
                }
            } header: {
                Text("상황에 따라 고르는 나무 · 색 점 = 지금 상황에서 쓰이는 길")
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: 상황 조작판

    private var contextPanel: some View {
        let c = ItemEval.controls(rootNode)
        return FlowLayout(spacing: 14, lineSpacing: 6) {
                Picker("보이는 곳", selection: $ctx.display) {
                    ForEach(ItemNodeKind.contexts, id: \.self) { Text(ItemNodeKind.contextLabel($0)).tag($0) }
                }
                .frame(width: 230)
                ForEach(c.selects.keys.sorted(), id: \.self) { p in
                    Picker(ItemNodeKind.propLabel(p, ItemNodeKind.selectProps), selection: Binding(
                        get: { ctx.selects[p] ?? "" }, set: { ctx.selects[p] = $0.isEmpty ? nil : $0 })) {
                        Text("(그 외)").tag("")
                        ForEach(c.selects[p] ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 240)
                }
                ForEach(c.conds.sorted(), id: \.self) { p in
                    Toggle(ItemNodeKind.propLabel(p, ItemNodeKind.conditionProps), isOn: Binding(
                        get: { ctx.conds[p] ?? false }, set: { ctx.conds[p] = $0 }))
                    .toggleStyle(.checkbox)
                }
                ForEach(c.ranges.keys.sorted(), id: \.self) { p in
                    let mx = max(1, (c.ranges[p] ?? 1) * 1.25)
                    HStack(spacing: 4) {
                        Text(ItemNodeKind.propLabel(p, ItemNodeKind.rangeProps)).font(.caption)
                        Slider(value: Binding(get: { ctx.ranges[p] ?? 0 }, set: { ctx.ranges[p] = $0 }), in: 0...mx).frame(width: 110)
                        Text(String(format: "%.2f", ctx.ranges[p] ?? 0)).font(.caption).monospacedDigit()
                    }
                }
            }
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: 속성

    @ViewBuilder private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let r = rows.first(where: { $0.id == selected }) {
                    nodeInspector(r.path)
                } else {
                    Text("왼쪽 나무에서 칸을 고르세요.").foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func title(_ t: String) -> some View { Text(t).font(.headline).foregroundStyle(Theme.gradient) }

    private func node(_ p: JPath) -> [String: Any]? { JTree.get(doc.root, p[...]) as? [String: Any] }

    private func setNode(_ p: JPath, _ n: Any?, coalesce: String? = nil) {
        doc.mutate(coalesce: coalesce) { r in
            if let new = JTree.set(r, p[...], n) as? [String: Any] { r = new }
        }
    }

    private func setField(_ p: JPath, _ k: String, _ v: Any?, coalesce: String? = nil) {
        setNode(p + [k], v, coalesce: coalesce)
    }

    @ViewBuilder private func nodeInspector(_ p: JPath) -> some View {
        let n = node(p)
        let type = ItemNodeKind.short(n?["type"] as? String)
        title(n.map { ItemNodeKind.label($0).title } ?? "빈 칸")

        if let n {
            switch type {
            case "model": modelFields(p, n)
            case "select": selectFields(p, n)
            case "condition": conditionFields(p, n)
            case "range_dispatch": rangeFields(p, n)
            case "composite":
                Button("겹칠 모델 추가") {
                    var a = n["models"] as? [Any] ?? []
                    a.append(["type": "minecraft:model", "model": firstModelID()])
                    setField(p, "models", a)
                }
            case "special":
                Text("방패·머리·현수막처럼 게임 코드가 그리는 아이템이에요. base 모델만 바꿀 수 있어요.").font(.caption).foregroundStyle(.secondary)
                modelIDField("base 모델", p, "base", n["base"] as? String ?? "")
            default:
                Text("이 종류는 아래 원시 JSON으로 고쳐요.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            wrapButtons(p, n)
        } else {
            Button("모델로 채우기") { setNode(p, ["type": "minecraft:model", "model": firstModelID()]) }
        }
        Divider()
        rawEditor(p)
    }

    private func modelIDField(_ label: String, _ p: JPath, _ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("minecraft:item/…", text: Binding(get: { value }, set: { setField(p, key, $0, coalesce: JTree.id(p) + key) }))
                .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
            HStack {
                if ws.modelJSON(value) == nil, !value.isEmpty {
                    Label("이 모델이 팩·바닐라에 없어요", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    Button("새로 만들기") { createModel(value) }.controlSize(.small)
                } else if !value.isEmpty {
                    Button("모델 편집기로 열기") { ws.editAsset(ModelIDs.modelRel(value)) }.controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private func modelFields(_ p: JPath, _ n: [String: Any]) -> some View {
        modelIDField("모델", p, "model", n["model"] as? String ?? "")
        if let t = n["tints"] as? [Any], !t.isEmpty {
            Text("색 입히기(tints) \(t.count)개 · 원시 JSON에서 고쳐요").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func propPicker(_ p: JPath, _ n: [String: Any], _ list: [(String, String)]) -> some View {
        let cur = n["property"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            Picker("무엇으로", selection: Binding(get: { cur }, set: { setField(p, "property", $0) })) {
                ForEach(list, id: \.0) { Text($0.1).tag($0.0) }
                if !list.contains(where: { $0.0 == cur }) { Text(cur).tag(cur) }
            }
            HStack {
                TextField("직접 입력 (예: minecraft:…)", text: $customProp).textFieldStyle(.roundedBorder).font(.caption)
                Button("적용") { if !customProp.isEmpty { setField(p, "property", customProp); customProp = "" } }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private func selectFields(_ p: JPath, _ n: [String: Any]) -> some View {
        propPicker(p, n, ItemNodeKind.selectProps)
        let isDisplay = (n["property"] as? String) == "minecraft:display_context"
        let cases = n["cases"] as? [Any] ?? []
        Text("경우들").font(.subheadline.bold())
        ForEach(Array(cases.enumerated()), id: \.offset) { i, c in
            let when = ItemNodeKind.whenList((c as? [String: Any])?["when"])
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("경우 \(i + 1)").bold()
                    Spacer()
                    Button { selected = JTree.id(p + ["cases", i, "model"]) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless).help("이 경우의 모델로 가기")
                    Button(role: .destructive) { setNode(p + ["cases", i], nil) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                if isDisplay {
                    // 보이는 곳은 체크로 고르기
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 2) {
                        ForEach(ItemNodeKind.contexts, id: \.self) { cx in
                            Toggle(ItemNodeKind.contextLabel(cx), isOn: Binding(get: { when.contains(cx) }, set: { on in
                                var w = when.filter { $0 != cx }; if on { w.append(cx) }
                                setNode(p + ["cases", i, "when"], w.count == 1 ? w[0] : w)
                            }))
                            .toggleStyle(.checkbox).font(.caption)
                        }
                    }
                } else {
                    TextField("값 (쉼표로 여러 개)", text: Binding(get: { when.joined(separator: ", ") }, set: { s in
                        let w = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        setNode(p + ["cases", i, "when"], w.count == 1 ? w[0] : w, coalesce: JTree.id(p) + "when\(i)")
                    }))
                    .textFieldStyle(.roundedBorder)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        }
        Button("경우 추가") {
            var a = cases
            let fb = n["fallback"] ?? ["type": "minecraft:model", "model": firstModelID()]
            a.append(["when": isDisplay ? "gui" : "", "model": fb])
            setField(p, "cases", a)
        }
        Toggle("그 외(fallback) 있음", isOn: Binding(get: { n["fallback"] != nil }, set: { on in
            setField(p, "fallback", on ? ["type": "minecraft:model", "model": firstModelID()] : nil)
        }))
        if n["fallback"] == nil { Text("그 외가 없으면 맞는 경우가 없을 때 아이템이 안 보이거나 오류 모델이 나와요.").font(.caption).foregroundStyle(.orange) }
    }

    @ViewBuilder private func conditionFields(_ p: JPath, _ n: [String: Any]) -> some View {
        propPicker(p, n, ItemNodeKind.conditionProps)
        let prop = n["property"] as? String ?? ""
        if prop.hasSuffix("has_component") || prop.hasSuffix(":component") {
            TextField("component (예: minecraft:damage)", text: Binding(get: { n["component"] as? String ?? "" },
                                                                      set: { setField(p, "component", $0, coalesce: "comp") }))
                .textFieldStyle(.roundedBorder)
        }
        HStack {
            Button("참일 때로") { selected = JTree.id(p + ["on_true"]) }
            Button("거짓일 때로") { selected = JTree.id(p + ["on_false"]) }
        }
    }

    @ViewBuilder private func rangeFields(_ p: JPath, _ n: [String: Any]) -> some View {
        propPicker(p, n, ItemNodeKind.rangeProps)
        HStack {
            Text("scale (곱하기)")
            TextField("", value: Binding(get: { (n["scale"] as? NSNumber)?.doubleValue ?? 1 },
                                         set: { setField(p, "scale", $0 == 1 ? nil : $0) }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 80)
        }
        let entries = n["entries"] as? [Any] ?? []
        ForEach(Array(entries.enumerated()), id: \.offset) { i, e in
            HStack {
                Text("기준값")
                TextField("", value: Binding(get: { ((e as? [String: Any])?["threshold"] as? NSNumber)?.doubleValue ?? 0 },
                                             set: { setNode(p + ["entries", i, "threshold"], $0) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("이상").font(.caption)
                Spacer()
                Button { selected = JTree.id(p + ["entries", i, "model"]) } label: { Image(systemName: "arrow.right.circle") }.buttonStyle(.borderless)
                Button(role: .destructive) { setNode(p + ["entries", i], nil) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
        }
        Button("단계 추가") {
            var a = entries
            let last = entries.compactMap { (($0 as? [String: Any])?["threshold"] as? NSNumber)?.doubleValue }.max() ?? 0
            a.append(["threshold": last + 0.5, "model": n["fallback"] ?? ["type": "minecraft:model", "model": firstModelID()]])
            setField(p, "entries", a)
        }
    }

    /// 지금 칸을 select/condition/range/겹치기로 감싸기 (기존 내용은 그대로 안에 들어감)
    @ViewBuilder private func wrapButtons(_ p: JPath, _ n: [String: Any]) -> some View {
        Text("이 칸 나누기").font(.subheadline.bold())
        Text("지금 내용은 그대로 두고 그 위에 갈림길을 만들어요.").font(.caption).foregroundStyle(.secondary)
        Button {
            setNode(p, ["type": "minecraft:select", "property": "minecraft:display_context",
                        "cases": [["when": "gui", "model": n]], "fallback": n])
            selected = JTree.id(p)
        } label: { Label("보이는 곳별로 (손·인벤토리·머리…)", systemImage: "hand.raised").frame(maxWidth: .infinity, alignment: .leading) }
        Button {
            setNode(p, ["type": "minecraft:condition", "property": "minecraft:using_item", "on_true": n, "on_false": n])
            selected = JTree.id(p)
        } label: { Label("조건으로 (쓰는 중·부서짐…)", systemImage: "arrow.triangle.branch").frame(maxWidth: .infinity, alignment: .leading) }
        Button {
            setNode(p, ["type": "minecraft:range_dispatch", "property": "minecraft:damage", "entries": [["threshold": 0.5, "model": n]], "fallback": n])
            selected = JTree.id(p)
        } label: { Label("값 범위로 (닳은 정도·개수…)", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }
        Button {
            setNode(p, ["type": "minecraft:composite", "models": [n]])
            selected = JTree.id(p)
        } label: { Label("다른 모델과 겹치기", systemImage: "square.stack").frame(maxWidth: .infinity, alignment: .leading) }
        if p.count > 1 {
            Button(role: .destructive) {
                setNode(p, ["type": "minecraft:model", "model": firstModelID()])
            } label: { Label("이 칸을 모델 하나로 되돌리기", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private func rawEditor(_ p: JPath) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("이 칸 원시 JSON").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $rawText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                if let e = rawError { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("적용") {
                    guard let d = rawText.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else {
                        rawError = "JSON 문법 오류"; return
                    }
                    rawError = nil
                    setNode(p, o)
                }
            }
        }
        .onAppear { loadRaw(p) }
        .onChange(of: JTree.id(p)) { loadRaw(p) }
        .onChange(of: doc.root.description.hashValue) { loadRaw(p) }
    }

    private func loadRaw(_ p: JPath) {
        if let n = JTree.get(doc.root, p[...]),
           let d = try? JSONSerialization.data(withJSONObject: n, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            rawText = String(data: d, encoding: .utf8) ?? ""
        } else { rawText = "" }
        rawError = nil
    }

    // MARK: 도움

    private func firstModelID() -> String {
        var v = Set<String>()
        return ItemEval.run(rootNode, ["model"], ItemContext(), &v).first
            ?? "minecraft:item/" + doc.url.deletingPathExtension().lastPathComponent
    }

    /// 없는 모델 id면 빈 평면 아이템 모델을 만든다 (layer0은 원래 아이템 텍스처)
    private func createModel(_ id: String) {
        guard let u = ws.packURL(ModelIDs.modelRel(id)) else { return }
        let name = doc.url.deletingPathExtension().lastPathComponent
        let json = "{\n  \"parent\": \"minecraft:item/generated\",\n  \"textures\": {\n    \"layer0\": \"minecraft:item/\(name)\"\n  }\n}\n"
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.write(to: u, atomically: true, encoding: .utf8)
        ws.reload()
        ws.status = "새 모델: \(ws.relPath(u)) (원래 아이템 그림으로 시작, 모델 편집기에서 바꾸세요)"
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
        }
    }
}

// MARK: - 상황 미리보기 3D

struct ItemPreviewScene: NSViewRepresentable {
    @EnvironmentObject var ws: Workspace
    let ids: [String]
    let context: String
    let rev: Int

    final class Coord { let holder = SCNNode(); var key = "" }
    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context ctx: Context) -> InteractiveSCNView {
        let v = InteractiveSCNView(frame: .zero)
        v.scene = SCNScene()
        v.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.92, blue: 1, alpha: 1)
        v.antialiasingMode = .multisampling4X
        v.distance = 46; v.yaw = -0.5; v.pitch = 0.35
        v.paintEnabled = false
        v.setup()
        v.pivot.addChildNode(ModelScene.guides())
        v.pivot.addChildNode(ctx.coordinator.holder)
        update(v, ctx.coordinator)
        return v
    }

    func updateNSView(_ v: InteractiveSCNView, context ctx: Context) { update(v, ctx.coordinator) }

    private func update(_ v: InteractiveSCNView, _ c: Coord) {
        let key = ids.joined(separator: "|") + "-" + context + "-\(rev)-\(ws.assetsVersion)"
        guard key != c.key else { return }
        c.key = key
        c.holder.childNodes.forEach { $0.removeFromParentNode() }
        for id in ids {
            guard let json = ws.modelJSON(id) else { continue }
            let r = ws.resolveModel(json, id: id)
            let (n, _) = ModelScene.build(r, ws: ws, opt: .init())
            let t = SCNNode()
            t.addChildNode(n)
            ModelScene.applyDisplay(t, context == "none" ? nil : r.display[context])
            c.holder.addChildNode(t)
        }
    }
}

// MARK: - 아이템 고르기 (사이드바)

struct ItemPickerView: View {
    @EnvironmentObject var ws: Workspace
    @State private var query = ""

    private var names: [String] {
        var set = Set<String>()
        let fm = FileManager.default
        if let v = ws.mcVersion {
            let d = VanillaAssets.shared.dir(v).appendingPathComponent("assets/minecraft/items")
            for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".json") { set.insert(String(f.dropLast(5))) }
        }
        if let d = ws.packURL("assets/minecraft/items") {
            for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".json") { set.insert(String(f.dropLast(5))) }
        }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return set.filter { q.isEmpty || $0.contains(q) }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("아이템 상황별 모델").font(.title2.bold()).foregroundStyle(Theme.gradient)
            Text("손에 들 때·인벤토리·머리 등 상황마다 다른 모델을 보여주게 정해요 (items/*.json). 누르면 팩으로 복사해서 열어요.")
                .foregroundStyle(.secondary)
            TextField("아이템 이름 검색 (예: sword, bow)", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            let list = names
            Text("\(list.count)개").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(list.prefix(400), id: \.self) { n in
                        let rel = "assets/minecraft/items/\(n).json"
                        Button { ws.editAsset(rel) } label: {
                            HStack(spacing: 8) {
                                icon(n)
                                Text(n).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if ws.inPack(rel) { Circle().fill(Theme.gradient).frame(width: 7, height: 7).help("팩에 있음") }
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .id(ws.assetsVersion)
    }

    @ViewBuilder private func icon(_ n: String) -> some View {
        if let img = ws.pixelImage("assets/minecraft/textures/item/\(n).png"), let cg = ModelScene.frame(img).cgImage() {
            Image(decorative: cg, scale: 1).interpolation(.none).resizable().frame(width: 20, height: 20)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(width: 20, height: 20)
        }
    }
}


/// 자리가 모자라면 다음 줄로 넘기는 배치
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += lineH + lineSpacing; x = 0; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += lineH + lineSpacing; x = bounds.minX; lineH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
