import AppKit
import SwiftUI

// MARK: - 텍스처 분류

struct TexCategory: Identifiable, Hashable {
    let id: String          // 폴더 이름 또는 "ns:<네임스페이스>"
    let label: String
    let icon: String

    static let all: [TexCategory] = [
        .init(id: "block", label: "블록", icon: "cube.fill"),
        .init(id: "item", label: "아이템", icon: "wand.and.stars"),
        .init(id: "entity", label: "엔티티·몹", icon: "pawprint.fill"),
        .init(id: "gui", label: "GUI·화면", icon: "rectangle.on.rectangle"),
        .init(id: "particle", label: "파티클", icon: "sparkles"),
        .init(id: "environment", label: "하늘·날씨", icon: "cloud.sun.fill"),
        .init(id: "mob_effect", label: "효과 아이콘", icon: "flask.fill"),
        .init(id: "painting", label: "그림", icon: "photo.artframe"),
        .init(id: "trims", label: "갑옷 장식", icon: "shield.lefthalf.filled"),
        .init(id: "map", label: "지도", icon: "map.fill"),
        .init(id: "font", label: "글꼴", icon: "textformat"),
        .init(id: "colormap", label: "색상맵", icon: "paintpalette.fill"),
        .init(id: "misc", label: "기타", icon: "ellipsis.circle.fill"),
        .init(id: "effect", label: "화면 효과", icon: "camera.filters"),
        .init(id: "palettes", label: "팔레트", icon: "swatchpalette.fill"),
    ]
}

struct TexEntry: Identifiable, Hashable {
    let rel: String
    let inPack: Bool
    let inVanilla: Bool
    var id: String { rel }
    var name: String { (rel as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "") }
    /// 카테고리 폴더 아래 하위 폴더 (예: entity의 "cat")
    func sub(_ base: String) -> String {
        let r = rel.replacingOccurrences(of: base + "/", with: "")
        let d = (r as NSString).deletingLastPathComponent
        return d
    }
}

enum ChangeKind { case same, modified, added }

extension Workspace {
    /// 팩에 있는 다른 네임스페이스 (minecraft 말고)
    func packNamespaces() -> [String] {
        guard let root else { return [] }
        let a = root.appendingPathComponent("assets")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: a.path)) ?? []
        return names.filter { $0 != "minecraft" && !$0.hasPrefix(".") }.sorted()
    }

    /// 카테고리의 텍스처 목록 (바닐라 + 팩). 오래 걸릴 수 있어 백그라운드에서 부른다.
    func textureEntries(_ cat: String) -> (base: String, entries: [TexEntry]) {
        let base: String
        var vanillaDir: URL?
        if cat.hasPrefix("ns:") {
            base = "assets/\(cat.dropFirst(3))/textures"
        } else {
            base = "assets/minecraft/textures/\(cat)"
            if let v = mcVersion, vanillaReady { vanillaDir = VanillaAssets.shared.dir(v).appendingPathComponent(base) }
        }
        func pngs(_ dir: URL?) -> Set<String> {
            guard let dir, let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
            var out = Set<String>()
            for case let u as URL in en where u.pathExtension.lowercased() == "png" {
                out.insert(base + u.path.dropFirst(dir.path.count))
            }
            return out
        }
        let van = pngs(vanillaDir)
        let pack = pngs(packURL(base))
        let all = van.union(pack).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (base, all.map { TexEntry(rel: $0, inPack: pack.contains($0), inVanilla: van.contains($0)) })
    }

    /// 팩 파일이 바닐라와 다른지 (저장된 파일 기준, 복사만 해 놓고 안 고친 건 same)
    func changeKind(_ rel: String) -> ChangeKind? {
        guard let p = packURL(rel), FileManager.default.fileExists(atPath: p.path) else { return nil }
        guard let v = mcVersion, let van = VanillaAssets.shared.url(v, rel) else { return .added }
        let a = try? Data(contentsOf: p), b = try? Data(contentsOf: van)
        return a == b ? .same : .modified
    }
}

// MARK: - 썸네일 (작게 줄인 CGImage를 기억)

final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, CGImage>()
    private let queue = DispatchQueue(label: "thumbs", qos: .userInitiated, attributes: .concurrent)

    func key(_ url: URL) -> NSString {
        let t = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(t)" as NSString
    }

    func cached(_ url: URL) -> CGImage? { cache.object(forKey: key(url)) }

    /// 애니메이션 스트립이면 첫 칸만
    func load(_ url: URL, done: @escaping (CGImage?) -> Void) {
        let k = key(url)
        if let c = cache.object(forKey: k) { done(c); return }
        queue.async {
            var cg: CGImage?
            if let img = PixelImage.load(url) {
                let f = img.h > img.w && img.h % img.w == 0 ? img.crop(CGRect(x: 0, y: 0, width: img.w, height: img.w)) : img
                cg = f.cgImage()
            }
            if let cg { self.cache.setObject(cg, forKey: k) }
            DispatchQueue.main.async { done(cg) }
        }
    }

    func clear() { cache.removeAllObjects() }
}

struct Thumb: View {
    @EnvironmentObject var ws: Workspace
    let rel: String
    var size: CGFloat = 48
    var vanilla = false     // true면 팩이 아니라 바닐라 원본
    @State private var cg: CGImage?
    @State private var loadedKey = ""

    private var url: URL? {
        if vanilla { return ws.mcVersion.flatMap { VanillaAssets.shared.url($0, rel) } }
        return ws.resolve(rel)
    }

    var body: some View {
        ZStack {
            Checker().opacity(0.6)
            if let cg {
                Image(decorative: cg, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear(perform: load)
        .onChange(of: ws.assetsVersion) { load() }
    }

    private func load() {
        guard let u = url else { cg = nil; return }
        let k = ThumbCache.shared.key(u) as String
        if k == loadedKey, cg != nil { return }
        loadedKey = k
        if let c = ThumbCache.shared.cached(u) { cg = c; return }
        ThumbCache.shared.load(u) { cg = $0 }
    }
}

// MARK: - 텍스처 격자

struct TextureBrowserView: View {
    @EnvironmentObject var ws: Workspace
    let category: String
    @State private var entries: [TexEntry] = []
    @State private var base = ""
    @State private var loading = true
    @State private var query = ""
    @State private var filter = 0          // 0 전체, 1 팩에 있는 것, 2 팩에 없는 것
    @AppStorage("thumbSize") private var size: Double = 56
    @State private var sub = ""            // 하위 폴더 거르기

    private var title: String {
        if category.hasPrefix("ns:") { return "\(category.dropFirst(3)) 네임스페이스" }
        return TexCategory.all.first { $0.id == category }?.label ?? category
    }

    private var subs: [String] {
        Array(Set(entries.map { $0.sub(base) })).filter { !$0.isEmpty }.sorted()
    }

    private var shown: [TexEntry] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            (filter == 0 || (filter == 1 && e.inPack) || (filter == 2 && !e.inPack)) &&
            (sub.isEmpty || e.sub(base) == sub || e.sub(base).hasPrefix(sub + "/")) &&
            (q.isEmpty || e.rel.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.title3.bold()).foregroundStyle(Theme.gradient)
                TextField("이름 검색", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                Picker("", selection: $filter) {
                    Text("전체").tag(0); Text("팩에 있는 것").tag(1); Text("바닐라만").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 250)
                if subs.count > 1 {
                    Picker("폴더", selection: $sub) {
                        Text("모든 폴더").tag("")
                        ForEach(subs, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 200)
                }
                Spacer(minLength: 0)
                Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                Slider(value: $size, in: 32...128).frame(width: 110).help("아이콘 크기")
            }
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if loading {
                ProgressView("텍스처 모으는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 6) {
                    Text("텍스처가 없어요").font(.headline)
                    if !ws.vanillaReady { Text("바닐라 준비 중이에요. 잠시 뒤 다시 열어 주세요.").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let list = shown
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 24), spacing: 10)], spacing: 12) {
                        ForEach(list) { e in cell(e) }
                    }
                    .padding(14)
                }
                Divider()
                HStack {
                    Text("\(list.count)개 표시 · 전체 \(entries.count)개 · 팩에 \(entries.filter(\.inPack).count)개")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("누르면 그림판, 팩에 없으면 바닐라에서 복사해서 열어요").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
            }
        }
        .onAppear(perform: load)
        .onChange(of: ws.vanillaReady) { load() }
        .onChange(of: category) { sub = ""; load() }
    }

    private func cell(_ e: TexEntry) -> some View {
        Button { ws.editAsset(e.rel) } label: {
            VStack(spacing: 4) {
                Thumb(rel: e.rel, size: size)
                    .overlay(alignment: .topTrailing) {
                        if e.inPack {
                            Circle().fill(Theme.gradient).frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                .offset(x: 3, y: -3)
                                .help(e.inVanilla ? "팩에서 바꿈" : "팩에만 있음(새 텍스처)")
                        }
                    }
                Text(e.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    .frame(width: size + 20)
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(e.rel.replacingOccurrences(of: "assets/minecraft/textures/", with: ""))
        .contextMenu {
            Button("그림판으로 열기") { ws.editAsset(e.rel) }
            if e.inPack, let u = ws.packURL(e.rel) {
                Button("Finder에서 보기") { ws.reveal(u) }
                if e.inVanilla {
                    Button("바닐라로 되돌리기 (팩에서 빼기)", role: .destructive) { ws.trash(u); ThumbCache.shared.clear(); load() }
                }
            }
        }
    }

    private func load() {
        loading = true
        let cat = category
        DispatchQueue.global(qos: .userInitiated).async {
            let (b, e) = ws.textureEntries(cat)
            DispatchQueue.main.async {
                guard cat == category else { return }
                base = b; entries = e; loading = false
            }
        }
    }
}

// MARK: - 바꾼 것만 보기 (전/후)

struct ChangedFile: Identifiable {
    let rel: String
    let kind: ChangeKind
    var id: String { rel }
}

struct ChangesView: View {
    @EnvironmentObject var ws: Workspace
    @State private var files: [ChangedFile] = []
    @State private var loading = true
    @State private var showSame = false
    @State private var group = "all"
    @AppStorage("thumbSize") private var size: Double = 56

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("바꾼 것 미리보기").font(.title3.bold()).foregroundStyle(Theme.gradient)
                Picker("", selection: $group) {
                    Text("전체").tag("all"); Text("텍스처").tag("tex"); Text("모델·아이템").tag("model")
                    Text("언어").tag("lang"); Text("소리").tag("sound"); Text("기타").tag("etc")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                Toggle("바닐라와 같은 것도", isOn: $showSame).toggleStyle(.checkbox)
                    .help("편집하려고 복사만 하고 안 고친 파일")
                Spacer(minLength: 0)
                Slider(value: $size, in: 32...128).frame(width: 100)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("다시 살펴보기")
            }
            .lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if loading {
                ProgressView("팩과 바닐라 비교 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let list = filtered
                let same = files.filter { $0.kind == .same }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary
                        if !same.isEmpty {
                            HStack {
                                Label("바닐라와 똑같은 파일 \(same.count)개 (복사만 하고 안 고침)", systemImage: "equal.circle")
                                    .foregroundStyle(.secondary)
                                Button("정리하기 (휴지통으로)") { cleanSame(same) }
                                    .help("팩 크기를 줄이고 바닐라 업데이트를 그대로 받게 돼요")
                            }
                        }
                        let tex = list.filter { $0.rel.hasSuffix(".png") }
                        if !tex.isEmpty {
                            Text("텍스처 \(tex.count)개").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: size * 2 + 60), spacing: 12)], spacing: 12) {
                                ForEach(tex) { f in texCard(f) }
                            }
                        }
                        let rest = list.filter { !$0.rel.hasSuffix(".png") }
                        if !rest.isEmpty {
                            Text("그 밖의 파일 \(rest.count)개").font(.headline)
                            ForEach(rest) { f in fileRow(f) }
                        }
                        if list.isEmpty {
                            Text(files.isEmpty ? "아직 바꾼 게 없어요. 텍스처 목록에서 그림을 눌러 고쳐 보세요." : "이 종류에는 바꾼 게 없어요.")
                                .foregroundStyle(.secondary).padding(.top, 30)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: ws.vanillaReady) { load() }
    }

    private var filtered: [ChangedFile] {
        files.filter { f in
            (showSame || f.kind != .same) && {
                switch group {
                case "tex": return f.rel.hasSuffix(".png")
                case "model": return f.rel.contains("/models/") || f.rel.contains("/items/") || f.rel.contains("/blockstates/")
                case "lang": return f.rel.contains("/lang/")
                case "sound": return f.rel.contains("/sounds")
                case "etc": return !f.rel.hasSuffix(".png") && !f.rel.contains("/models/") && !f.rel.contains("/items/")
                    && !f.rel.contains("/blockstates/") && !f.rel.contains("/lang/") && !f.rel.contains("/sounds")
                default: return true
                }
            }()
        }
    }

    private var summary: some View {
        let mod = files.filter { $0.kind == .modified }.count
        let add = files.filter { $0.kind == .added }.count
        return HStack(spacing: 12) {
            stat("바꾼 파일", mod, "pencil.circle.fill")
            stat("새 파일", add, "plus.circle.fill")
            stat("텍스처", files.filter { $0.kind != .same && $0.rel.hasSuffix(".png") }.count, "photo.fill")
            stat("언어 파일", files.filter { $0.kind != .same && $0.rel.contains("/lang/") }.count, "character.book.closed.fill")
        }
    }

    private func stat(_ t: String, _ n: Int, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(t, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text("\(n)").font(.title.bold()).foregroundStyle(Theme.gradient)
        }
        .padding(10).frame(minWidth: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func texCard(_ f: ChangedFile) -> some View {
        Button { ws.editAsset(f.rel) } label: {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    if f.kind != .added {
                        VStack(spacing: 2) {
                            Thumb(rel: f.rel, size: size, vanilla: true)
                            Text("전").font(.caption2).foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        Thumb(rel: f.rel, size: size)
                        Text(f.kind == .added ? "새로 추가" : f.kind == .same ? "같음" : "후").font(.caption2)
                            .foregroundStyle(f.kind == .same ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.gradient))
                    }
                }
                Text(shortName(f.rel)).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .help(f.rel)
        .contextMenu {
            if let u = ws.packURL(f.rel) {
                Button("Finder에서 보기") { ws.reveal(u) }
                if f.kind != .added { Button("바닐라로 되돌리기", role: .destructive) { ws.trash(u); load() } }
            }
        }
    }

    private func fileRow(_ f: ChangedFile) -> some View {
        Button { ws.selection = ws.packURL(f.rel)?.path } label: {
            HStack {
                Image(systemName: f.kind == .added ? "plus.circle.fill" : f.kind == .same ? "equal.circle" : "pencil.circle.fill")
                    .foregroundStyle(f.kind == .same ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.gradient))
                Text(f.rel).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(f.kind == .added ? "새 파일" : f.kind == .same ? "바닐라와 같음" : "바뀜").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shortName(_ rel: String) -> String {
        rel.replacingOccurrences(of: "assets/minecraft/textures/", with: "").replacingOccurrences(of: ".png", with: "")
    }

    private func load() {
        guard let root = ws.root else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [ChangedFile] = []
            let a = root.appendingPathComponent("assets")
            if let en = FileManager.default.enumerator(at: a, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let u as URL in en {
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                    let rel = ws.relPath(u)
                    if let k = ws.changeKind(rel) { out.append(ChangedFile(rel: rel, kind: k)) }
                }
            }
            out.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
            DispatchQueue.main.async { files = out; loading = false }
        }
    }

    private func cleanSame(_ same: [ChangedFile]) {
        let a = NSAlert()
        a.messageText = "바닐라와 똑같은 파일 \(same.count)개를 휴지통으로 보낼까요?"
        a.informativeText = "게임에서 보이는 모습은 그대로예요. 휴지통에서 되살릴 수 있어요."
        a.addButton(withTitle: "정리하기"); a.addButton(withTitle: "취소")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for f in same {
            guard let u = ws.packURL(f.rel) else { continue }
            try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
            let meta = URL(fileURLWithPath: u.path + ".mcmeta")
            if FileManager.default.fileExists(atPath: meta.path), ws.changeKind(f.rel + ".mcmeta") == .same {
                try? FileManager.default.trashItem(at: meta, resultingItemURL: nil)
            }
            ws.invalidate(u)
        }
        ws.reload()
        ws.status = "똑같은 파일 \(same.count)개 정리했음"
        load()
    }
}
