import AppKit
import SwiftUI

// MARK: - 한국어 이름

extension Workspace {
    /// 아이템·블록·엔티티 id의 한국어 이름 (게임 ko_kr 언어 파일)
    func koName(_ id: String) -> String? {
        guard let v = mcVersion, vanillaReady else { return nil }
        let ko = MinecraftInstall.shared.lang(v, "ko_kr")
        for k in ["item.minecraft.\(id)", "block.minecraft.\(id)", "entity.minecraft.\(id)"] {
            if let s = ko[k] { return s }
        }
        return nil
    }

    /// 텍스처 파일 이름으로 한국어 이름 찾기: acacia_door_bottom → acacia_door → acacia 순으로 줄여 가며
    func koNameForTexture(_ rel: String) -> String? {
        let parts = rel.split(separator: "/").map(String.init)
        var name = (parts.last ?? "").replacingOccurrences(of: ".png", with: "")
        // entity/cat/tabby 같은 건 폴더 이름(cat)도 후보
        let folder = parts.count >= 2 ? parts[parts.count - 2] : ""
        for _ in 0..<5 {
            if let k = koName(name) { return k }
            guard let cut = name.lastIndex(of: "_") else { break }
            name = String(name[..<cut])
        }
        if !["block", "item", "textures"].contains(folder), let k = koName(folder) { return k }
        return nil
    }
}

// MARK: - 크리에이티브 탭 (게임 코드 CreativeModeTabs에서 읽음)

struct CreativeTab: Codable, Identifiable {
    let key: String        // itemGroup.buildingBlocks
    let items: [String]    // 게임 탭 순서 그대로
    var id: String { key }
}

enum CreativeTabs {
    /// 설치된 마크에 딸린 자바에서 javap 찾기 (클래스 파일을 읽을 수 있는 최신 것)
    static func javap() -> String? {
        let rt = MinecraftInstall.shared.dir.appendingPathComponent("runtime")
        var found: [String] = []
        if let en = FileManager.default.enumerator(atPath: rt.path) {
            for case let p as String in en where p.hasSuffix("/bin/javap") { found.append(rt.appendingPathComponent(p).path) }
        }
        // epsilon > delta > gamma 순으로 새 자바
        found.sort { $0 > $1 }
        if let f = found.first(where: { $0.contains("epsilon") }) ?? found.first { return f }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/javap") ? "/usr/bin/javap" : nil
    }

    static func cacheURL(_ v: McVersion) -> URL { VanillaAssets.shared.dir(v).appendingPathComponent("creative_tabs.json") }

    static func load(_ v: McVersion) -> [CreativeTab]? {
        if let d = try? Data(contentsOf: cacheURL(v)), let t = try? JSONDecoder().decode([CreativeTab].self, from: d) { return t }
        guard let t = extract(v) else { return nil }
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: cacheURL(v)) }
        return t
    }

    /// jar의 CreativeModeTabs.class를 javap로 풀어서 탭마다 Items/Blocks 필드를 쓰는 순서를 뽑는다
    static func extract(_ v: McVersion) -> [CreativeTab]? {
        guard let javap = javap() else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mcpe-tabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cls = "net/minecraft/world/item/CreativeModeTabs.class"
        guard AudioConvert.run("/usr/bin/unzip", ["-q", "-o", v.jar.path, cls, "-d", tmp.path]).ok else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: javap)
        p.arguments = ["-c", "-p", "-v", tmp.appendingPathComponent(cls).path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8), text.contains("BootstrapMethods") else { return nil }
        return parse(text, itemsDir: VanillaAssets.shared.dir(v).appendingPathComponent("assets/minecraft/items"))
    }

    static func parse(_ t: String, itemsDir: URL) -> [CreativeTab] {
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) }
        func groups(_ r: NSRegularExpression, _ s: String) -> [[String]] {
            r.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
                (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
            }
        }
        // BootstrapMethods: 번호 -> 람다 이름
        var bsm: [Int: String] = [:]
        if let r = t.range(of: "BootstrapMethods:") {
            let sec = String(t[r.lowerBound...])
            let entries = sec.components(separatedBy: "\n").reduce(into: [(Int, String)]()) { acc, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let c = trimmed.firstIndex(of: ":"), let n = Int(trimmed[..<c]), trimmed.contains("REF_invokeStatic") {
                    acc.append((n, ""))
                } else if !acc.isEmpty {
                    acc[acc.count - 1].1 += line + "\n"
                }
            }
            for (n, body) in entries {
                if let m = groups(rx(#"CreativeModeTabs\.(lambda\$[\w$]+)"#), body).first { bsm[n] = m[1] }
            }
        }
        // 메서드 몸체 나누기 (두 칸 들여쓴 선언 줄 기준)
        var methods: [String: String] = [:]
        var curName: String?
        var buf = ""
        for line in t.components(separatedBy: "\n") {
            if line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(");"),
               let m = groups(rx(#" ([\w$]+)\([^)]*\);$"#), line).first {
                if let c = curName { methods[c] = buf }
                curName = m[1]; buf = ""
            } else { buf += line + "\n" }
        }
        if let c = curName { methods[c] = buf }
        guard let boot = methods["bootstrap"] else { return [] }

        // 색 순서: bootstrap 안의 DyeColor 순서
        var colors: [String] = []
        for m in groups(rx(#"DyeColor\.([A-Z_]+)"#), boot) where !colors.contains(m[1].lowercased()) { colors.append(m[1].lowercased()) }
        func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: itemsDir.appendingPathComponent(id + ".json").path) }

        var tabs: [(key: String, lambda: String?)] = []
        for line in boot.components(separatedBy: "\n") {
            if let s = groups(rx(#"// String (itemGroup\.\w+)"#), line).first { tabs.append((s[1], nil)); continue }
            if let d = groups(rx(#"InvokeDynamic #(\d+):accept:.*DisplayItemsGenerator"#), line).first,
               !tabs.isEmpty, tabs[tabs.count - 1].lambda == nil, let n = Int(d[1]) {
                tabs[tabs.count - 1].lambda = bsm[n]
            }
        }
        var out: [CreativeTab] = []
        for tab in tabs {
            guard let l = tab.lambda, let body = methods[l] else { continue }
            var items: [String] = []
            for m in groups(rx(#"Field net/minecraft/world/(?:item/Items|level/block/Blocks)\.(\w+):"#), body) {
                let n = m[1].lowercased()
                var add: [String] = []
                if exists(n) { add = [n] }
                else {
                    // 색 묶음(wool, dyed_terracotta …)은 색별로 펼친다
                    let base = n.hasPrefix("dyed_") ? String(n.dropFirst(5)) : n
                    add = colors.map { "\($0)_\(base)" }.filter(exists)
                }
                for a in add where !items.contains(a) { items.append(a) }
            }
            if !items.isEmpty { out.append(CreativeTab(key: tab.key, items: items)) }
        }
        return out
    }

    /// 사이드바 순서 (게임 탭 순서)
    static let order = ["itemGroup.buildingBlocks", "itemGroup.coloredBlocks", "itemGroup.natural", "itemGroup.functional",
                        "itemGroup.redstone", "itemGroup.tools", "itemGroup.combat", "itemGroup.foodAndDrink",
                        "itemGroup.ingredients", "itemGroup.spawnEggs", "itemGroup.op"]

    static let icons: [String: String] = [
        "itemGroup.buildingBlocks": "building.2.fill", "itemGroup.coloredBlocks": "paintpalette.fill",
        "itemGroup.natural": "leaf.fill", "itemGroup.functional": "lamp.table.fill", "itemGroup.redstone": "bolt.fill",
        "itemGroup.tools": "hammer.fill", "itemGroup.combat": "shield.fill", "itemGroup.foodAndDrink": "fork.knife",
        "itemGroup.ingredients": "flask.fill", "itemGroup.spawnEggs": "oval.portrait.fill", "itemGroup.op": "terminal.fill",
    ]
}

extension Workspace {
    /// 아이템 아이콘 텍스처: 아이템 모델을 따라가서 layer0, 없으면 블록 면(all/side/top/front…)
    /// 인벤토리(gui)에서 그 아이템이 쓰는 모델 id: items/<id>.json을 따라가고, 없으면 models/item/<id>
    func itemModelID(_ id: String) -> String? {
        let rel = "assets/minecraft/items/\(id).json"
        let def: [String: Any]?
        if let u = packURL(rel), let d = openModelDoc(u) { def = d.root }
        else if let u = resolve(rel), let data = try? Data(contentsOf: u) { def = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        else { def = nil }
        if let def {
            var visited = Set<String>()
            var ctx = ItemContext(); ctx.display = "gui"
            if let m = ItemEval.run(def["model"], ["model"], ctx, &visited).first { return m }
        }
        return modelJSON("minecraft:item/\(id)") != nil ? "minecraft:item/\(id)" : nil
    }

    func itemIconRel(_ id: String) -> String? {
        let direct = "assets/minecraft/textures/item/\(id).png"
        if resolve(direct) != nil { return direct }
        if let mid = itemModelID(id), let json = modelJSON(mid) {
            let r = resolveModel(json, id: mid)
            for k in ["layer0", "all", "side", "front", "top", "texture", "cross", "plant", "particle"] {
                if let ref = r.textures[k], let tex = r.texture(ref) { return ModelIDs.textureRel(tex) }
            }
            if let any = r.textures.values.compactMap({ r.texture($0) }).first { return ModelIDs.textureRel(any) }
        }
        let block = "assets/minecraft/textures/block/\(id).png"
        return resolve(block) != nil ? block : nil
    }
}

// MARK: - 탭 화면

struct CreativeTabView: View {
    @EnvironmentObject var ws: Workspace
    let key: String
    @State private var tab: CreativeTab?
    @State private var icons: [String: String] = [:]
    @State private var thumbs3D: [String: CGImage] = [:]
    @AppStorage("ctab.3d") private var use3D = true
    @State private var renderGen = 0
    @State private var query = ""
    @AppStorage("thumbSize") private var size: Double = 56

    private var title: String { ws.mockText(key) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: CreativeTabs.icons[key] ?? "square.grid.2x2").foregroundStyle(Theme.gradient)
                Text(title).font(.title3.bold()).foregroundStyle(Theme.gradient)
                TextField("이름 검색 (한국어·영어)", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Spacer(minLength: 0)
                Toggle(isOn: $use3D) { Label("3D 아이콘", systemImage: "cube") }.toggleStyle(.button)
                    .help("블록처럼 모델이 있는 아이템을 게임 인벤토리처럼 입체로")
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $size, in: 32...128).frame(width: 110)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if let tab {
                let list = filtered(tab.items)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 24), spacing: 10)], spacing: 12) {
                            ForEach(list, id: \.self) { id in cell(id) }
                        }
                        .padding(14)
                    }
                    .onAppear {
                        if let id = ws.pageState["ctab:" + key]?.scrollID {
                            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("\(list.count)개 · 게임 크리에이티브 탭 순서").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("누르면 아이콘 텍스처를 그림판으로, 오른쪽 클릭으로 모델·상황별 정의").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
            } else {
                ProgressView("게임 코드에서 탭 목록 읽는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
        .onDisappear { renderGen += 1 } // 떠나면 그리던 것 멈춤
        .onChange(of: key) { load() }
        .onChange(of: ws.vanillaReady) { load() }
    }

    private func filtered(_ items: [String]) -> [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.contains(q) || (ws.koName($0)?.lowercased().contains(q) ?? false) }
    }

    private func cell(_ id: String) -> some View {
        let iconRel = icons[id]
        return Button {
            ws.pageState["ctab:" + key] = PageState(scrollID: id)
            if let r = iconRel { ws.editAsset(r) }
        } label: {
            VStack(spacing: 4) {
                if use3D, let cg = thumbs3D[id] {
                    Image(decorative: cg, scale: 1).resizable().interpolation(.none).frame(width: size, height: size)
                } else if let r = iconRel { Thumb(rel: r, size: size) }
                else { RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: size, height: size) }
                Text(ws.koName(id) ?? id).font(.system(size: 10)).lineLimit(1).truncationMode(.tail)
                    .frame(width: size + 20)
            }
            .padding(4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(id)\(iconRel.map { "\n" + $0.replacingOccurrences(of: "assets/minecraft/textures/", with: "") } ?? "")")
        .contextMenu {
            if let r = iconRel { Button("아이콘 텍스처 그림판으로") { ws.editAsset(r) } }
            Button("아이템 모델 편집") { ws.pageState["ctab:" + key] = PageState(scrollID: id); ws.editAsset("assets/minecraft/models/item/\(id).json") }
            Button("상황별 모델 (items/\(id).json)") { ws.pageState["ctab:" + key] = PageState(scrollID: id); ws.editAsset("assets/minecraft/items/\(id).json") }
        }
    }

    private func load() {
        guard let v = ws.mcVersion, ws.vanillaReady else { return }
        if let c = ws.creativeCache[v.id] { apply(c); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let tabs = CreativeTabs.load(v) ?? []
            DispatchQueue.main.async { ws.creativeCache[v.id] = tabs; apply(tabs) }
        }
    }

    private func apply(_ tabs: [CreativeTab]) {
        tab = tabs.first { $0.key == key } ?? CreativeTab(key: key, items: [])
        let ids = tab?.items ?? []
        // 아이콘 경로는 모델을 따라가야 해서 뒤에서 한 번에
        DispatchQueue.global(qos: .userInitiated).async {
            var m: [String: String] = [:]
            for id in ids { if let r = ws.itemIconRel(id) { m[id] = r } }
            DispatchQueue.main.async { icons = m; render3D(ids) }
        }
    }

    /// 3D 아이콘은 화면 스레드에서 몇 개씩 나눠 그려서 앱이 멈추지 않게
    private func render3D(_ ids: [String]) {
        renderGen += 1
        let gen = renderGen
        thumbs3D = [:]
        var queue = ids[...]
        func step() {
            guard gen == renderGen, !queue.isEmpty else { return }
            for _ in 0..<6 {
                guard let id = queue.popFirst() else { break }
                if let cg = ModelThumbs.shared.render(id, ws: ws) { thumbs3D[id] = cg }
            }
            DispatchQueue.main.async { step() }
        }
        step()
    }
}

// MARK: - 3D 아이콘 (게임 인벤토리처럼 gui 각도로 렌더)

import SceneKit
import Metal

final class ModelThumbs {
    static let shared = ModelThumbs()
    private let cache = NSCache<NSString, CGImage>()
    private lazy var renderer: SCNRenderer? = {
        guard let dev = MTLCreateSystemDefaultDevice() else { return nil }
        return SCNRenderer(device: dev, options: nil)
    }()

    func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    /// 요소가 있는 모델이면 3D로 그려서 돌려준다 (평면 아이템·특수 렌더러는 nil). 화면 스레드에서 부를 것.
    func render(_ id: String, ws: Workspace, size: Int = 128) -> CGImage? {
        let key = "\(id)#\(ws.assetsVersion)#\(ws.root?.path ?? "")"
        if let c = cache.object(forKey: key as NSString) { return c }
        guard let mid = ws.itemModelID(id), let json = ws.modelJSON(mid) else { return nil }
        let r = ws.resolveModel(json, id: mid)
        guard !r.generated, let els = r.elements, !els.isEmpty, let renderer else { return nil }
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let (node, _) = ModelScene.build(r, ws: ws, opt: .init())
        let holder = SCNNode()
        holder.addChildNode(node)
        ModelScene.applyDisplay(holder, r.display["gui"])
        scene.rootNode.addChildNode(holder)
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = 8.6     // 게임 슬롯(16칸)이 꽉 차게
        cam.zNear = 0.1; cam.zFar = 200
        let camNode = SCNNode(); camNode.camera = cam
        camNode.position = SCNVector3(0, 0, 60)
        scene.rootNode.addChildNode(camNode)
        renderer.scene = scene
        renderer.pointOfView = camNode
        let img = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        cache.setObject(cg, forKey: key as NSString)
        return cg
    }
}
