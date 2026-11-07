import Foundation

// MARK: - 순서를 지키는 평면 JSON(문자열 -> 문자열) 파서
// JSONSerialization은 키 순서를 버려서, 저장할 때 원래 파일 순서를 그대로 두려고 직접 읽는다.

enum FlatJSON {
    static func parse(_ text: String) -> [(String, String)]? {
        let s = Array(text.unicodeScalars)
        var i = 0
        func ws() { while i < s.count, [" ", "\n", "\r", "\t", "\u{FEFF}"].contains(s[i]) { i += 1 } }
        func str() -> String? {
            guard i < s.count, s[i] == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == "\"" { i += 1; return String(out) }
                if c == "\\" {
                    i += 1
                    guard i < s.count else { return nil }
                    switch s[i] {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{8}")
                    case "f": out.append("\u{C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        func hex4() -> UInt32? {
                            guard i + 4 < s.count else { return nil }
                            let h = String(String.UnicodeScalarView(s[(i + 1)...(i + 4)]))
                            i += 4
                            return UInt32(h, radix: 16)
                        }
                        guard var v = hex4() else { return nil }
                        if (0xD800...0xDBFF).contains(v), i + 2 < s.count, s[i + 1] == "\\", s[i + 2] == "u" {
                            i += 2
                            guard let lo = hex4() else { return nil }
                            v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                        }
                        out.append(Unicode.Scalar(v) ?? "\u{FFFD}")
                    default: return nil
                    }
                    i += 1
                } else {
                    out.append(c); i += 1
                }
            }
            return nil
        }
        ws()
        guard i < s.count, s[i] == "{" else { return nil }
        i += 1
        var pairs: [(String, String)] = []
        ws()
        if i < s.count, s[i] == "}" { return pairs }
        while true {
            ws()
            guard let k = str() else { return nil }
            ws()
            guard i < s.count, s[i] == ":" else { return nil }
            i += 1
            ws()
            guard let v = str() else { return nil } // 값이 문자열이 아니면 평면 lang이 아님
            pairs.append((k, v))
            ws()
            guard i < s.count else { return nil }
            if s[i] == "," { i += 1; continue }
            if s[i] == "}" { return pairs }
            return nil
        }
    }

    static func escape(_ s: String) -> String {
        var o = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
            }
        }
        return o + "\""
    }
}

// MARK: - 언어 파일 문서

final class LangDoc: ObservableObject {
    let url: URL
    @Published private(set) var order: [String] = []
    @Published private(set) var map: [String: String] = [:]
    @Published private(set) var dirty = false
    @Published private(set) var loadError: String?
    private var undoStack: [([String], [String: String])] = []

    var code: String { url.deletingPathExtension().lastPathComponent }
    var namespace: String { url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
    var canUndo: Bool { !undoStack.isEmpty }

    init(url: URL) {
        self.url = url
        load()
    }

    func load() {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "{}"
        loadError = nil
        if let pairs = FlatJSON.parse(text) {
            var o: [String] = [], m: [String: String] = [:]
            for (k, v) in pairs { if m[k] == nil { o.append(k) }; m[k] = v }
            order = o; map = m
        } else if let d = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            // 문자열이 아닌 값이 섞인 경우: 문자열만 표에 올리고 알려 준다
            var m: [String: String] = [:]
            for (k, v) in obj { if let s = v as? String { m[k] = s } }
            map = m; order = m.keys.sorted()
            loadError = "문자열이 아닌 값이 있어서 문자열 키만 보여요. 저장하면 나머지는 사라지니 원시 JSON으로 고치세요."
        } else {
            map = [:]; order = []
            loadError = "JSON을 읽지 못했어요. 원시 JSON 보기로 고치세요."
        }
        dirty = false
        undoStack.removeAll()
    }

    func has(_ k: String) -> Bool { map[k] != nil }

    func set(_ k: String, _ v: String) {
        if map[k] == v { return }
        if map[k] == nil { order.append(k) }
        map[k] = v
        dirty = true
    }

    func remove(_ k: String) {
        guard map[k] != nil else { return }
        map[k] = nil
        order.removeAll { $0 == k }
        dirty = true
    }

    /// 여러 개를 한 번에 바꾸는 작업 전에 불러서 한 번에 되돌릴 수 있게
    func checkpoint() {
        undoStack.append((order, map))
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    func undo() {
        guard let (o, m) = undoStack.popLast() else { return }
        order = o; map = m; dirty = true
    }

    func serialize() -> String {
        guard !order.isEmpty else { return "{}\n" }
        let body = order.map { "  \(FlatJSON.escape($0)): \(FlatJSON.escape(map[$0] ?? ""))" }.joined(separator: ",\n")
        return "{\n" + body + "\n}\n"
    }

    @discardableResult func save() -> Bool {
        guard loadError == nil || !map.isEmpty else { return false }
        do {
            if order.isEmpty && !FileManager.default.fileExists(atPath: url.path) { dirty = false; return true }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try serialize().write(to: url, atomically: true, encoding: .utf8)
            dirty = false
            return true
        } catch { return false }
    }
}

// MARK: - 설치된 마인크래프트에서 바닐라 데이터 읽기

struct McVersion: Identifiable, Hashable {
    let id: String
    let jar: URL
    let assetIndex: String?
    let releaseTime: String
    let type: String
}

final class MinecraftInstall {
    static let shared = MinecraftInstall()
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/minecraft")

    private(set) lazy var versions: [McVersion] = scan()
    private var langCache: [String: [String: String]] = [:]
    private let cacheLock = NSLock()
    private var codeCache: [String: [String]] = [:]
    private var packCache: [String: (Int, Int)] = [:]

    var latestRelease: McVersion? { versions.first { $0.type == "release" } ?? versions.first }

    private func scan() -> [McVersion] {
        let vdir = dir.appendingPathComponent("versions")
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: vdir.path) else { return [] }
        var out: [McVersion] = []
        for id in ids {
            let jar = vdir.appendingPathComponent("\(id)/\(id).jar")
            let js = vdir.appendingPathComponent("\(id)/\(id).json")
            guard FileManager.default.fileExists(atPath: jar.path),
                  let d = try? Data(contentsOf: js),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["inheritsFrom"] == nil else { continue }
            let idx = (o["assetIndex"] as? [String: Any])?["id"] as? String
            out.append(McVersion(id: id, jar: jar, assetIndex: idx,
                                 releaseTime: o["releaseTime"] as? String ?? "",
                                 type: o["type"] as? String ?? ""))
        }
        return out.sorted { $0.releaseTime > $1.releaseTime }
    }

    func version(_ id: String?) -> McVersion? {
        guard let id else { return latestRelease }
        return versions.first { $0.id == id } ?? latestRelease
    }

    private func unzip(_ jar: URL, _ path: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", jar.path, path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !d.isEmpty ? d : nil
    }

    func assetObjects(_ v: McVersion) -> [String: Any]? {
        guard let idx = v.assetIndex,
              let d = try? Data(contentsOf: dir.appendingPathComponent("assets/indexes/\(idx).json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["objects"] as? [String: Any]
    }

    /// 이 버전에 있는 언어 코드 목록 (en_us는 jar, 나머지는 에셋 인덱스)
    func langCodes(_ v: McVersion) -> [String] {
        if let c = codeCache[v.id] { return c }
        var codes: Set<String> = ["en_us"]
        for k in (assetObjects(v) ?? [:]).keys where k.hasPrefix("minecraft/lang/") && k.hasSuffix(".json") {
            codes.insert(String(k.dropFirst("minecraft/lang/".count).dropLast(5)))
        }
        let c = codes.sorted()
        codeCache[v.id] = c
        return c
    }

    func lang(_ v: McVersion, _ code: String) -> [String: String] {
        let key = "\(v.id)/\(code)"
        cacheLock.lock(); let hit = langCache[key]; cacheLock.unlock()
        if let hit { return hit }
        var data: Data?
        if code == "en_us" {
            data = unzip(v.jar, "assets/minecraft/lang/en_us.json")
        } else if let o = assetObjects(v)?["minecraft/lang/\(code).json"] as? [String: Any],
                  let h = o["hash"] as? String, h.count > 2 {
            data = try? Data(contentsOf: dir.appendingPathComponent("assets/objects/\(h.prefix(2))/\(h)"))
        }
        var m: [String: String] = [:]
        if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, val) in o { if let s = val as? String { m[k] = s } }
        }
        cacheLock.lock(); langCache[key] = m; cacheLock.unlock()
        return m
    }

    /// jar의 version.json에서 리소스팩 형식 (major, minor)
    func packVersion(_ v: McVersion) -> (Int, Int)? {
        if let c = packCache[v.id] { return c }
        guard let d = unzip(v.jar, "version.json"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var r: (Int, Int)?
        if let pv = o["pack_version"] as? [String: Any], let maj = pv["resource_major"] as? Int {
            r = (maj, pv["resource_minor"] as? Int ?? 0)
        } else if let pv = o["pack_version"] as? [String: Any], let res = pv["resource"] as? Int {
            r = (res, 0)
        } else if let n = o["pack_version"] as? Int {
            r = (n, 0)
        }
        if let r { packCache[v.id] = r }
        return r
    }
}

// MARK: - 마크 서식 코드(§) 미리보기

enum McFormat {
    static let colors: [Character: (Double, Double, Double)] = [
        "0": (0, 0, 0), "1": (0, 0, 0.667), "2": (0, 0.667, 0), "3": (0, 0.667, 0.667),
        "4": (0.667, 0, 0), "5": (0.667, 0, 0.667), "6": (1, 0.667, 0), "7": (0.667, 0.667, 0.667),
        "8": (0.333, 0.333, 0.333), "9": (0.333, 0.333, 1), "a": (0.333, 1, 0.333), "b": (0.333, 1, 1),
        "c": (1, 0.333, 0.333), "d": (1, 0.333, 1), "e": (1, 1, 0.333), "f": (1, 1, 1),
    ]

    struct Span { var text: String; var color: (Double, Double, Double)?; var bold = false; var italic = false; var underline = false; var strike = false; var obf = false }

    static func spans(_ s: String) -> [Span] {
        var out: [Span] = []
        var cur = Span(text: "")
        var it = Array(s)
        var i = 0
        func flush() { if !cur.text.isEmpty { out.append(cur); cur.text = "" } }
        while i < it.count {
            let c = it[i]
            if c == "§", i + 1 < it.count {
                let code = Character(it[i + 1].lowercased())
                flush()
                if let col = colors[code] { cur = Span(text: "", color: col) }
                else {
                    switch code {
                    case "l": cur.bold = true
                    case "o": cur.italic = true
                    case "n": cur.underline = true
                    case "m": cur.strike = true
                    case "k": cur.obf = true
                    case "r": cur = Span(text: "")
                    default: cur.text.append(c); cur.text.append(it[i + 1])
                    }
                }
                i += 2
                continue
            }
            cur.text.append(c)
            i += 1
        }
        flush()
        it.removeAll()
        return out
    }
}
