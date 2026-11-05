import AppKit
import SwiftUI

final class Node: Identifiable {
    let url: URL
    let isDir: Bool
    var children: [Node]?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    init(url: URL, isDir: Bool, children: [Node]? = nil) {
        self.url = url; self.isDir = isDir; self.children = children
    }
}

let textExts: Set<String> = ["json", "mcmeta", "txt", "lang", "properties", "fsh", "vsh", "glsl", "md", "csv", "cfg", "toml", "yml", "yaml", "xml"]
let imageExts: Set<String> = ["png"]

final class Workspace: ObservableObject {
    static let shared = Workspace()

    @Published var root: URL?
    @Published var nodes: [Node] = []
    @Published var selection: String?
    @Published var query = ""
    @Published var status = "폴더를 열어 주세요"
    @Published var searchResults: [Node] = []

    @Published var showNewLang = false
    @Published var lastMock: String?
    @Published var mockLang = UserDefaults.standard.string(forKey: "mockLang") ?? "ko_kr" {
        didSet { UserDefaults.standard.set(mockLang, forKey: "mockLang") }
    }
    @Published var assetsVersion = 0 // 파노라마 등 파일을 밖에서 바꿨을 때 화면 갱신용
    var pendingLangKey: String?
    var soundCache: [String: [String: Any]] = [:]
    var biomeCache: [String: [Biome]] = [:]
    private var imgCache: [String: (Date, PixelImage)] = [:]
    @Published var mcVersionID: String? = UserDefaults.standard.string(forKey: "mcVersion") {
        didSet { UserDefaults.standard.set(mcVersionID, forKey: "mcVersion"); prepareVanilla() }
    }
    @Published var vanillaReady = false

    private var imageDocs: [String: ImageDoc] = [:]
    private var textDocs: [String: TextDoc] = [:]
    private var langDocs: [String: LangDoc] = [:]
    private var modelDocs: [String: ModelDoc] = [:]

    var selectedURL: URL? {
        guard let s = selection, !s.hasPrefix("mock:") else { return nil }
        return URL(fileURLWithPath: s)
    }
    var selectedMock: MockKind? {
        guard let s = selection, s.hasPrefix("mock:") else { return nil }
        return MockKind(rawValue: String(s.dropFirst(5)))
    }
    var mcVersion: McVersion? { MinecraftInstall.shared.version(mcVersionID) }

    var dirtyCount: Int {
        imageDocs.values.filter { $0.dirty }.count + textDocs.values.filter { $0.dirty }.count
            + langDocs.values.filter { $0.dirty }.count + modelDocs.values.filter { $0.dirty }.count
    }

    // MARK: 팩 또는 바닐라에서 에셋 찾기 (화면 목업·파노라마)

    /// 바닐라 GUI 텍스처·파노라마를 캐시에 풀고 자주 쓰는 언어를 미리 읽는다. 화면 스레드를 막지 않게 백그라운드에서.
    func prepareVanilla() {
        guard let v = mcVersion else { return }
        vanillaReady = VanillaAssets.shared.isReady(v)
        let lang = mockLang
        DispatchQueue.global(qos: .userInitiated).async {
            VanillaAssets.shared.ensure(v)
            _ = MinecraftInstall.shared.lang(v, "en_us")
            _ = MinecraftInstall.shared.lang(v, lang)
            DispatchQueue.main.async {
                self.vanillaReady = true
                self.assetsVersion += 1
            }
        }
    }

    func packURL(_ rel: String) -> URL? { root?.appendingPathComponent(rel) }

    func inPack(_ rel: String) -> Bool {
        guard let u = packURL(rel) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// 팩에 있으면 팩 것, 없으면 바닐라 캐시
    func resolve(_ rel: String) -> URL? {
        if let u = packURL(rel), FileManager.default.fileExists(atPath: u.path) { return u }
        guard let v = mcVersion else { return nil }
        return VanillaAssets.shared.url(v, rel)
    }

    /// 열려 있는 그림판 문서가 있으면 저장 안 한 상태까지 그대로 반영
    func pixelImage(_ rel: String) -> PixelImage? {
        if let u = packURL(rel), let d = imageDocs[u.path] { return d.image }
        guard let u = resolve(rel) else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
        if let (t, img) = imgCache[u.path], t == mtime { return img }
        guard let img = PixelImage.load(u) else { return nil }
        imgCache[u.path] = (mtime, img)
        return img
    }

    func text(_ rel: String) -> String? {
        if let u = packURL(rel), let d = textDocs[u.path] { return d.text }
        guard let u = resolve(rel) else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }

    /// 목업에서 누른 에셋 편집: 팩에 없으면 바닐라를 (짝 .mcmeta까지) 복사해 와서 연다
    func editAsset(_ rel: String) {
        guard let dest = ensureInPack(rel) else { return }
        selection = dest.path
    }

    /// 팩에 없으면 바닐라에서 (짝 .mcmeta까지) 복사. 선택은 바꾸지 않는다.
    @discardableResult func ensureInPack(_ rel: String) -> URL? {
        guard let dest = packURL(rel) else { return nil }
        if !FileManager.default.fileExists(atPath: dest.path) {
            guard let v = mcVersion, let src = VanillaAssets.shared.url(v, rel) else {
                status = vanillaReady ? "바닐라에서 못 찾음: \(rel)" : "바닐라 그림 준비 중이에요. 잠시 뒤 다시 눌러 주세요"; return nil
            }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: src, to: dest)
            let meta = URL(fileURLWithPath: src.path + ".mcmeta")
            if FileManager.default.fileExists(atPath: meta.path) {
                try? FileManager.default.copyItem(at: meta, to: URL(fileURLWithPath: dest.path + ".mcmeta"))
            }
            reload()
            status = "바닐라에서 복사해 왔음: \(rel)"
        }
        return dest
    }

    /// 목업 글씨를 누르면 그 언어 파일의 해당 키로 이동
    func editLangKey(_ key: String) {
        guard let root else { return }
        let file = root.appendingPathComponent("assets/minecraft/lang/\(mockLang).json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{}\n".write(to: file, atomically: true, encoding: .utf8)
            reload()
            status = "새 언어 파일: \(relPath(file))"
        }
        pendingLangKey = key
        selection = file.path
    }

    /// 목업에 보일 글씨: 팩(저장 안 한 것 포함) > 바닐라 같은 언어 > 바닐라 en_us > 키
    func mockText(_ key: String) -> String {
        if let root {
            let file = root.appendingPathComponent("assets/minecraft/lang/\(mockLang).json")
            if FileManager.default.fileExists(atPath: file.path), let v = langDoc(file).map[key] { return v }
        }
        if let v = mcVersion, vanillaReady { // 준비 전엔 화면 스레드에서 jar를 풀지 않음
            if let s = MinecraftInstall.shared.lang(v, mockLang)[key] { return s }
            if let s = MinecraftInstall.shared.lang(v, "en_us")[key] { return s }
        }
        return key
    }

    /// 파일을 밖(파노라마 변환 등)에서 썼을 때 캐시 버리기
    func invalidate(_ url: URL) {
        imageDocs[url.path] = nil
        imgCache[url.path] = nil
        assetsVersion += 1
    }

    // MARK: 언어 파일

    func isLangFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json" && url.deletingLastPathComponent().lastPathComponent == "lang"
            && url.path.contains("/assets/")
    }

    /// 팩 안의 모든 언어 파일 (assets/<ns>/lang/*.json)
    func langFiles() -> [URL] {
        var out: [URL] = []
        func walk(_ ns: [Node]) {
            for n in ns {
                if n.isDir { walk(n.children ?? []) } else if isLangFile(n.url) { out.append(n.url) }
            }
        }
        walk(nodes)
        return out.sorted { relPath($0) < relPath($1) }
    }

    func langDoc(_ url: URL) -> LangDoc {
        if let d = langDocs[url.path] { return d }
        let d = LangDoc(url: url)
        langDocs[url.path] = d
        return d
    }

    func dropTextDoc(_ url: URL) { textDocs[url.path] = nil }

    func modelDoc(_ url: URL) -> ModelDoc {
        if let d = modelDocs[url.path] { return d }
        let d = ModelDoc(url: url)
        modelDocs[url.path] = d
        return d
    }
    func openModelDoc(_ url: URL) -> ModelDoc? { modelDocs[url.path] }
    func dropModelDoc(_ url: URL) { modelDocs[url.path] = nil }

    func isItemDefFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json" && url.path.contains("/assets/")
            && url.deletingLastPathComponent().lastPathComponent == "items"
    }

    func isModelFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "json" && url.path.contains("/assets/") && url.path.contains("/models/")
    }

    /// 새 언어 파일. custom이면 pack.mcmeta의 "language"에 등록해서 게임 언어 목록에 뜨게 한다.
    func createLang(code: String, namespace: String, seed: [String: String], seedOrder: [String],
                    custom: (name: String, region: String)?) {
        guard let root else { return }
        let c = code.trimmingCharacters(in: .whitespaces).lowercased()
        guard !c.isEmpty else { return }
        let dir = root.appendingPathComponent("assets/\(namespace)/lang")
        let file = dir.appendingPathComponent("\(c).json")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            status = "이미 있음: \(relPath(file))"; selection = file.path; return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = seedOrder.isEmpty ? "{}\n"
            : "{\n" + seedOrder.map { "  \(FlatJSON.escape($0)): \(FlatJSON.escape(seed[$0] ?? ""))" }.joined(separator: ",\n") + "\n}\n"
        try? body.write(to: file, atomically: true, encoding: .utf8)
        if let custom { registerLanguage(code: c, name: custom.name, region: custom.region) }
        reload()
        selection = file.path
        status = "새 언어 파일: \(relPath(file))" + (custom != nil ? " (pack.mcmeta에 등록함)" : "")
    }

    private func registerLanguage(code: String, name: String, region: String) {
        guard let root else { return }
        let url = root.appendingPathComponent("pack.mcmeta")
        if !FileManager.default.fileExists(atPath: url.path) { createMcmeta(description: root.lastPathComponent) }
        guard let d = try? Data(contentsOf: url),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        var langs = o["language"] as? [String: Any] ?? [:]
        langs[code] = ["name": name, "region": region, "bidirectional": false]
        o["language"] = langs
        if let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? out.write(to: url)
            textDocs[url.path] = nil
        }
    }

    // MARK: 폴더 열기

    func openPanel() {
        let p = NSOpenPanel()
        p.title = "리소스팩 폴더 열기"
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        let def = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/minecraft/resourcepacks")
        if FileManager.default.fileExists(atPath: def.path) { p.directoryURL = def }
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func open(_ url: URL) {
        root = url
        imageDocs.removeAll(); textDocs.removeAll(); langDocs.removeAll(); modelDocs.removeAll()
        selection = nil
        reload()
        UserDefaults.standard.set(url.path, forKey: "lastRoot")
        prepareVanilla()
        status = "열었음: \(url.lastPathComponent)"
    }

    func reopenLast() {
        if let p = UserDefaults.standard.string(forKey: "lastRoot"),
           FileManager.default.fileExists(atPath: p) {
            open(URL(fileURLWithPath: p))
        }
    }

    func reload() {
        guard let root else { return }
        nodes = Workspace.scan(root)
        refreshSearch()
    }

    static func scan(_ dir: URL) -> [Node] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let sorted = items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let b = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if a != b { return a && !b }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return sorted.map { u in
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return Node(url: u, isDir: isDir, children: isDir ? scan(u) : nil)
        }
    }

    func refreshSearch() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { searchResults = []; return }
        var out: [Node] = []
        func walk(_ ns: [Node]) {
            for n in ns {
                if n.isDir { walk(n.children ?? []) }
                else if n.url.path.lowercased().contains(q) { out.append(n) }
                if out.count > 500 { return }
            }
        }
        walk(nodes)
        searchResults = out
    }

    func relPath(_ url: URL) -> String {
        guard let root else { return url.path }
        return url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    // MARK: 문서 캐시

    func imageDoc(_ url: URL) -> ImageDoc? {
        if let d = imageDocs[url.path] { return d }
        guard let img = PixelImage.load(url) else { return nil }
        let d = ImageDoc(url: url, image: img)
        imageDocs[url.path] = d
        return d
    }

    func textDoc(_ url: URL) -> TextDoc {
        if let d = textDocs[url.path] { return d }
        let d = TextDoc(url: url)
        textDocs[url.path] = d
        return d
    }

    func saveAll() {
        var n = 0
        for d in imageDocs.values where d.dirty { if d.save() { n += 1 } }
        for d in textDocs.values where d.dirty { if d.save() { n += 1 } }
        for d in langDocs.values where d.dirty { if d.save() { n += 1 } }
        for d in modelDocs.values where d.dirty { if d.save() { n += 1 } }
        status = n > 0 ? "저장했음 (\(n)개)" : "저장할 변경 없음"
    }

    // MARK: 파일 작업

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            imageDocs[url.path] = nil; textDocs[url.path] = nil; langDocs[url.path] = nil; modelDocs[url.path] = nil
            if selection == url.path { selection = nil }
            reload()
            status = "휴지통으로: \(url.lastPathComponent)"
        } catch { status = "삭제 실패: \(error.localizedDescription)" }
    }

    func newPNG(in dir: URL, name: String, size: Int) {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return }
        if !n.hasSuffix(".png") { n += ".png" }
        let dest = dir.appendingPathComponent(n)
        guard !FileManager.default.fileExists(atPath: dest.path) else { status = "이미 있음: \(n)"; return }
        let img = PixelImage(w: size, h: size)
        if let d = img.pngData() { try? d.write(to: dest) }
        reload()
        selection = dest.path
        status = "새 PNG: \(n) (\(size)x\(size))"
    }

    func hasMcmeta() -> Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("pack.mcmeta").path)
    }

    /// min_format/max_format 형식(26.x). max는 설치된 최신 릴리스 jar의 version.json에서 읽고, 못 읽으면 26.3 값(97).
    /// min 84는 26.1.2 jar에서 확인한 값.
    func createMcmeta(description: String) {
        guard let root else { return }
        let maxFmt = MinecraftInstall.shared.latestRelease.flatMap { MinecraftInstall.shared.packVersion($0)?.0 } ?? 97
        let text = """
        {
          "pack": {
            "min_format": 84,
            "max_format": \(max(84, maxFmt)),
            "description": \(jsonString(description))
          }
        }

        """
        try? text.write(to: root.appendingPathComponent("pack.mcmeta"), atomically: true, encoding: .utf8)
        reload()
        status = "pack.mcmeta 만들었음"
    }

    private func jsonString(_ s: String) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
           var str = String(data: d, encoding: .utf8) {
            str.removeFirst(); str.removeLast(); return str
        }
        return "\"\""
    }

    // MARK: 내보내기

    func exportZip() {
        guard let root else { return }
        saveAll()
        if !hasMcmeta() {
            let a = NSAlert()
            a.messageText = "pack.mcmeta가 없어요"
            a.informativeText = "마인크래프트가 팩으로 인식하려면 필요해요. 만들고 내보낼까요?"
            a.addButton(withTitle: "만들고 내보내기")
            a.addButton(withTitle: "그냥 내보내기")
            a.addButton(withTitle: "취소")
            switch a.runModal() {
            case .alertFirstButtonReturn: createMcmeta(description: root.lastPathComponent)
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        let sp = NSSavePanel()
        sp.nameFieldStringValue = root.lastPathComponent + ".zip"
        sp.allowedContentTypes = [.zip]
        guard sp.runModal() == .OK, let out = sp.url else { return }
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = root
        p.arguments = ["-r", "-X", "-q", out.path, ".", "-x", "*.DS_Store", "-x", "__MACOSX/*"]
        let pipe = Pipe(); p.standardError = pipe
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 {
                status = "내보냈음: \(out.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } else {
                let e = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                status = "내보내기 실패: \(e)"
            }
        } catch { status = "내보내기 실패: \(error.localizedDescription)" }
    }

    /// 마인크래프트 resourcepacks 폴더에 팩 폴더 그대로 복사 (이미 거기 있는 팩이면 필요 없음).
    func installToMinecraft() {
        guard let root else { return }
        saveAll()
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/minecraft/resourcepacks")
        if root.deletingLastPathComponent().path == dir.path {
            status = "이미 resourcepacks 폴더 안에 있어요. 게임에서 F3+T로 다시 불러와요"
            return
        }
        let dest = dir.appendingPathComponent(root.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: root, to: dest)
            status = "resourcepacks에 복사했음: \(dest.lastPathComponent)"
        } catch { status = "복사 실패: \(error.localizedDescription)" }
    }
}

// MARK: - 텍스트 문서

final class TextDoc: ObservableObject {
    let url: URL
    @Published var text: String { didSet { if text != saved { dirty = true; validate() } } }
    @Published var dirty = false
    @Published var error: String?
    private var saved: String

    init(url: URL) {
        self.url = url
        let t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        self.text = t
        self.saved = t
        validate()
    }

    var isJSON: Bool { ["json", "mcmeta"].contains(url.pathExtension.lowercased()) }

    func validate() {
        guard isJSON else { error = nil; return }
        guard let d = text.data(using: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = nil; return
        }
        do { _ = try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]); error = nil }
        catch let e { self.error = (e as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "JSON 문법 오류" }
    }

    @discardableResult func save() -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            saved = text; dirty = false
            return true
        } catch { return false }
    }
}
