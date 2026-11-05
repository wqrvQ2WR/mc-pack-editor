import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 재생 (macOS는 ogg vorbis를 읽을 수 있음)

final class SoundPlayer: ObservableObject {
    static let shared = SoundPlayer()
    @Published var playing: String?
    private var player: AVAudioPlayer?

    func play(_ url: URL, volume: Double = 1, pitch: Double = 1, tag: String) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { playing = nil; return }
        p.enableRate = true
        p.rate = Float(max(0.5, min(2, pitch)))
        p.volume = Float(max(0, min(1, volume)))
        p.play()
        player = p
        playing = tag
        let d = p.duration / Double(p.rate)
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.05) { [weak self] in
            if self?.player === p { self?.playing = nil }
        }
    }

    func stop() { player?.stop(); player = nil; playing = nil }

    private static var durations: [String: Double] = [:]
    /// 길이만 가볍게 (파일 머리만 읽음), 한 번 읽으면 기억
    static func duration(_ url: URL) -> Double? {
        if let d = durations[url.path] { return d }
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return nil }
        let d = Double(f.length) / f.processingFormat.sampleRate
        durations[url.path] = d
        return d
    }
}

// MARK: - 변환 (mp3·wav·m4a… -> ogg)

enum AudioConvert {
    static func find(_ names: [String]) -> String? {
        names.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var oggenc: String? { find(["/opt/homebrew/bin/oggenc", "/usr/local/bin/oggenc"]) }
    static var ffmpeg: String? { find(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) }

    /// 마크에서 위치 따라 들리려면 모노여야 한다. oggenc가 있으면 모노, 없으면 ffmpeg 내장 인코더(스테레오만 됨).
    static func toOgg(_ src: URL, _ dest: URL, mono: Bool) -> (ok: Bool, note: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let oggenc {
            // macOS 내장 afconvert로 wav(44.1kHz, 모노/스테레오)로 풀고 oggenc로 인코딩
            let ch = mono ? "1" : "2"
            let a = run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@44100", "-c", ch, src.path, tmp.path])
            if !a.ok, let ffmpeg { _ = run(ffmpeg, ["-y", "-loglevel", "error", "-i", src.path, "-ac", ch, "-ar", "44100", tmp.path]) }
            let r = run(oggenc, ["-Q", "-q", "5", "-o", dest.path, tmp.path])
            return (r.ok, r.ok ? (mono ? "모노 ogg로 변환" : "스테레오 ogg로 변환") : "oggenc 실패: \(r.err)")
        }
        if let ffmpeg {
            let r = run(ffmpeg, ["-y", "-loglevel", "error", "-i", src.path, "-vn", "-ac", "2", "-ar", "44100",
                                 "-c:a", "vorbis", "-strict", "-2", "-q:a", "5", dest.path])
            return (r.ok, r.ok ? (mono ? "스테레오로 변환됨 (모노는 oggenc 필요: brew install vorbis-tools)" : "스테레오 ogg로 변환") : "ffmpeg 실패: \(r.err)")
        }
        return (false, "ogg로 바꿀 도구가 없어요 (brew install vorbis-tools 또는 ffmpeg)")
    }

    @discardableResult static func run(_ exe: String, _ args: [String]) -> (ok: Bool, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let e = Pipe(); p.standardError = e; p.standardOutput = Pipe()
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let data = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - 소리 이벤트

enum SoundIDs {
    /// "ns:path" 또는 "path" -> assets/ns/sounds/path.ogg
    static func rel(_ name: String) -> String {
        let (ns, p) = ModelIDs.split(name)
        return "assets/\(ns)/sounds/\(p).ogg"
    }

    static let categories: [(String, String)] = [
        ("", "전체"), ("entity", "생물·플레이어"), ("block", "블록"), ("item", "아이템"), ("ui", "화면(UI)"),
        ("music", "음악"), ("music_disc", "음반"), ("ambient", "주변 소리"), ("weather", "날씨"),
        ("enchant", "마법 부여"), ("event", "이벤트"), ("particle", "입자"),
    ]

    /// 소리 항목: 문자열이거나 {name, volume, pitch, weight, stream, type…}
    static func entry(_ v: Any) -> [String: Any] {
        if let s = v as? String { return ["name": s] }
        return v as? [String: Any] ?? [:]
    }
}

extension Workspace {
    /// 바닐라 sounds.json (에셋 인덱스)
    func vanillaSounds() -> [String: Any] {
        guard let v = mcVersion, vanillaReady else { return [:] }
        if let c = soundCache[v.id] { return c }
        var o: [String: Any] = [:]
        if let u = VanillaAssets.shared.url(v, "assets/minecraft/sounds.json"), let d = try? Data(contentsOf: u) {
            o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        }
        soundCache[v.id] = o
        return o
    }
}


struct SoundsView: View {
    @EnvironmentObject var ws: Workspace
    @ObservedObject var player = SoundPlayer.shared
    @State private var query = ""
    @State private var category = ""
    @State private var onlyPack = false
    @State private var selected: String?
    @State private var tick = 0
    @State private var busy: String?
    @State private var mono = true

    private let rel = "assets/minecraft/sounds.json"

    /// 팩 sounds.json (없으면 nil)
    private var doc: ModelDoc? {
        guard let u = ws.packURL(rel), FileManager.default.fileExists(atPath: u.path) else { return nil }
        return ws.modelDoc(u)
    }

    /// 고치려면 파일부터 만든다
    private func ensureDoc() -> ModelDoc? {
        guard let u = ws.packURL(rel) else { return nil }
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{}\n".write(to: u, atomically: true, encoding: .utf8)
            ws.reload()
        }
        return ws.modelDoc(u)
    }

    private var events: [String] {
        let van = ws.vanillaSounds()
        var set = Set(van.keys)
        for k in (doc?.root.keys).map(Array.init) ?? [] { set.insert(k) }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        return set.filter { e in
            (category.isEmpty || e.hasPrefix(category + ".")) &&
            (!onlyPack || doc?.root[e] != nil) &&
            (q.isEmpty || e.contains(q) || subtitle(e).lowercased().contains(q))
        }.sorted()
    }

    private func subtitle(_ e: String) -> String {
        let def = (doc?.root[e] as? [String: Any]) ?? (ws.vanillaSounds()[e] as? [String: Any])
        guard let key = def?["subtitle"] as? String else { return "" }
        let t = ws.mockText(key)
        return t == key ? "" : t
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 360)
            Divider()
            if let e = selected { detail(e).id("\(e)-\(tick)") } else {
                VStack(spacing: 8) {
                    Text("소리 고르기").font(.title2.bold()).foregroundStyle(Theme.gradient)
                    Text("왼쪽에서 소리 이벤트를 고르면 듣고, 내 소리로 바꾸거나 끌 수 있어요.").foregroundStyle(.secondary)
                    if !ws.vanillaReady { ProgressView("바닐라 준비 중…") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            ws.lastMock = "mock:sounds"
            if let e = ProcessInfo.processInfo.environment["MCPE_SOUND"] { selected = e } // 검증용
        }
    }

    private var list: some View {
        VStack(spacing: 6) {
            TextField("이름이나 자막으로 검색 (예: hurt, 폭발)", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Picker("", selection: $category) {
                    ForEach(SoundIDs.categories, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                Toggle("바꾼 것만", isOn: $onlyPack).toggleStyle(.checkbox)
            }
            let es = events
            Text("\(es.count)개").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            List(selection: $selected) {
                ForEach(es.prefix(800), id: \.self) { e in
                    HStack(spacing: 6) {
                        Circle().fill(doc?.root[e] != nil ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            let st = subtitle(e)
                            if !st.isEmpty { Text(st).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                        Button { playEvent(e) } label: {
                            Image(systemName: player.playing == "ev:" + e ? "speaker.wave.2.fill" : "play.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .tag(e)
                }
            }
            .listStyle(.inset)
        }
        .padding(10)
    }

    // MARK: 이벤트 상세

    private func detail(_ e: String) -> some View {
        let van = ws.vanillaSounds()[e] as? [String: Any]
        let mine = doc?.root[e] as? [String: Any]
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e).font(.system(.title3, design: .monospaced).bold())
                    let st = subtitle(e)
                    if !st.isEmpty { Text("자막: \(st)").foregroundStyle(.secondary) }
                }
                HStack {
                    Button { playEvent(e) } label: { Label("들어보기 (게임처럼 무작위 하나)", systemImage: "play.circle.fill") }
                        .buttonStyle(.borderedProminent).tint(Color(red: 0.95, green: 0.3, blue: 0.6))
                    Button { player.stop() } label: { Label("멈춤", systemImage: "stop.fill") }
                }

                if let van {
                    GroupBox("바닐라 소리") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(((van["sounds"] as? [Any]) ?? []).enumerated()), id: \.offset) { i, s in
                                soundRow(SoundIDs.entry(s), tag: "v:\(e):\(i)", editable: false, onChange: { _ in }, onDelete: nil)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if let mine {
                            Picker("방식", selection: Binding(get: { mine["replace"] as? Bool ?? false }, set: { v in
                                setEvent(e) { $0["replace"] = v ? true : nil }
                            })) {
                                Text("바닐라 소리에 섞기").tag(false)
                                Text("바닐라 소리 빼고 내 것만").tag(true)
                            }
                            .pickerStyle(.segmented)
                            let sounds = (mine["sounds"] as? [Any]) ?? []
                            if sounds.isEmpty && (mine["replace"] as? Bool) == true {
                                Label("소리 없음: 게임에서 이 소리가 안 나요", systemImage: "speaker.slash.fill").foregroundStyle(.orange)
                            }
                            ForEach(Array(sounds.enumerated()), id: \.offset) { i, s in
                                soundRow(SoundIDs.entry(s), tag: "p:\(e):\(i)", editable: true, onChange: { new in
                                    setEvent(e) { ev in var a = ev["sounds"] as? [Any] ?? []; if a.indices.contains(i) { a[i] = new }; ev["sounds"] = a }
                                }, onDelete: {
                                    setEvent(e) { ev in var a = ev["sounds"] as? [Any] ?? []; if a.indices.contains(i) { a.remove(at: i) }; ev["sounds"] = a }
                                })
                            }
                            HStack {
                                Button { addAudio(e) } label: { Label("오디오 파일 넣기…", systemImage: "waveform.badge.plus") }
                                Toggle("모노 (위치 따라 들림)", isOn: $mono).toggleStyle(.checkbox)
                                    .help("효과음은 모노여야 멀리서 작게 들려요. 음악은 꺼도 돼요.")
                            }
                            Text(AudioConvert.oggenc != nil ? "변환: oggenc (모노 가능)" :
                                    AudioConvert.ffmpeg != nil ? "변환: ffmpeg (스테레오만 · 모노는 brew install vorbis-tools)" : "ogg 변환 도구 없음: ogg 파일만 넣을 수 있어요")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("바닐라 소리 이름 추가") {
                                    setEvent(e) { ev in var a = ev["sounds"] as? [Any] ?? []; a.append(["name": "minecraft:random/click"]); ev["sounds"] = a }
                                }
                                Button("소리 끄기 (무음)") {
                                    setEvent(e) { $0["replace"] = true; $0["sounds"] = [Any]() }
                                }
                            }
                            TextField("자막 키 (예: subtitles.entity.player.hurt)", text: Binding(
                                get: { mine["subtitle"] as? String ?? "" },
                                set: { v in setEvent(e, coalesce: "sub") { $0["subtitle"] = v.isEmpty ? nil : v } }))
                                .textFieldStyle(.roundedBorder)
                            Button("이 팩에서 안 바꾸기 (바닐라로)", role: .destructive) {
                                doc?.mutate { $0[e] = nil }; tick += 1
                            }
                        } else {
                            Text("이 팩에서 아직 안 바꾼 소리예요.").foregroundStyle(.secondary)
                            HStack {
                                Button("내 소리로 바꾸기") { setEvent(e) { $0["replace"] = true; $0["sounds"] = [Any]() } }
                                Button("바닐라 목록 복사해서 고치기") {
                                    setEvent(e) { $0["replace"] = true; $0["sounds"] = (van?["sounds"] as? [Any]) ?? [] }
                                }
                                Button("소리 끄기 (무음)") { setEvent(e) { $0["replace"] = true; $0["sounds"] = [Any]() } }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("이 팩에서").foregroundStyle(Theme.gradient)
                }
                if let busy { HStack { ProgressView().controlSize(.small); Text(busy) } }
                Text("소리는 assets/<ns>/sounds/ 아래 .ogg예요. 게임에서 F3+T로 다시 불러와 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func soundRow(_ s: [String: Any], tag: String, editable: Bool,
                          onChange: @escaping ([String: Any]) -> Void, onDelete: (() -> Void)?) -> some View {
        let name = s["name"] as? String ?? ""
        let isEvent = (s["type"] as? String) == "event"
        let url = isEvent ? nil : ws.resolve(SoundIDs.rel(name))
        let vol = (s["volume"] as? NSNumber)?.doubleValue ?? 1
        let pitch = (s["pitch"] as? NSNumber)?.doubleValue ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if let url { player.play(url, volume: vol, pitch: pitch, tag: tag) }
                } label: { Image(systemName: player.playing == tag ? "speaker.wave.2.fill" : "play.fill") }
                    .buttonStyle(.borderless).disabled(url == nil)
                if editable {
                    TextField("소리 이름", text: Binding(get: { name }, set: { var n = s; n["name"] = $0; onChange(n) }))
                        .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
                } else {
                    Text(name).font(.system(size: 12, design: .monospaced))
                }
                if isEvent { Text("이벤트 참조").font(.caption2).foregroundStyle(.secondary) }
                if url == nil && !isEvent { Label("파일 없음", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
                if let url, let d = SoundPlayer.duration(url) { Text(String(format: "%.1f초", d)).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let onDelete { Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless) }
            }
            if editable {
                HStack(spacing: 10) {
                    Text("크기").font(.caption)
                    Slider(value: Binding(get: { vol }, set: { var n = s; n["volume"] = ($0 * 100).rounded() / 100 == 1 ? nil : ($0 * 100).rounded() / 100; onChange(n) }), in: 0...1)
                        .frame(width: 90)
                    Text("높이").font(.caption)
                    Slider(value: Binding(get: { pitch }, set: { var n = s; n["pitch"] = ($0 * 100).rounded() / 100 == 1 ? nil : ($0 * 100).rounded() / 100; onChange(n) }), in: 0.5...2)
                        .frame(width: 90)
                    Text(String(format: "%.2f", pitch)).font(.caption).monospacedDigit()
                    Stepper("확률 \((s["weight"] as? NSNumber)?.intValue ?? 1)", value: Binding(
                        get: { (s["weight"] as? NSNumber)?.intValue ?? 1 },
                        set: { var n = s; n["weight"] = $0 == 1 ? nil : $0; onChange(n) }), in: 1...100)
                        .font(.caption).fixedSize()
                    Toggle("긴 소리(stream)", isOn: Binding(get: { s["stream"] as? Bool ?? false },
                                                         set: { var n = s; n["stream"] = $0 ? true : nil; onChange(n) }))
                        .toggleStyle(.checkbox).font(.caption)
                }
            } else {
                let extra = [s["volume"].map { "크기 \($0)" }, s["pitch"].map { "높이 \($0)" }, s["weight"].map { "확률 \($0)" },
                             (s["stream"] as? Bool) == true ? "stream" : nil].compactMap { $0 }
                if !extra.isEmpty { Text(extra.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 작업

    private func setEvent(_ e: String, coalesce: String? = nil, _ f: (inout [String: Any]) -> Void) {
        guard let d = ensureDoc() else { return }
        d.mutate(coalesce: coalesce.map { "\(e)-\($0)" }) { r in
            var ev = r[e] as? [String: Any] ?? [:]
            if ev["subtitle"] == nil, let st = (ws.vanillaSounds()[e] as? [String: Any])?["subtitle"] { ev["subtitle"] = st }
            f(&ev)
            if ev["sounds"] == nil { ev["sounds"] = [Any]() }
            r[e] = ev
        }
        tick += 1
    }

    /// 게임처럼 무게(weight)대로 하나 골라 재생
    private func playEvent(_ e: String) {
        let mine = doc?.root[e] as? [String: Any]
        let van = ws.vanillaSounds()[e] as? [String: Any]
        var pool: [[String: Any]] = []
        if let mine { pool += ((mine["sounds"] as? [Any]) ?? []).map(SoundIDs.entry) }
        if mine == nil || (mine?["replace"] as? Bool) != true { pool += ((van?["sounds"] as? [Any]) ?? []).map(SoundIDs.entry) }
        pool = pool.filter { ($0["type"] as? String) != "event" }
        guard !pool.isEmpty else { ws.status = "이 소리는 아무것도 안 나요"; return }
        let total = pool.reduce(0) { $0 + max(1, ($1["weight"] as? NSNumber)?.intValue ?? 1) }
        var r = Int.random(in: 0..<total)
        var pick = pool[0]
        for s in pool { r -= max(1, (s["weight"] as? NSNumber)?.intValue ?? 1); if r < 0 { pick = s; break } }
        guard let name = pick["name"] as? String, let u = ws.resolve(SoundIDs.rel(name)) else { ws.status = "소리 파일을 못 찾음"; return }
        player.play(u, volume: (pick["volume"] as? NSNumber)?.doubleValue ?? 1, pitch: (pick["pitch"] as? NSNumber)?.doubleValue ?? 1, tag: "ev:" + e)
    }

    private func addAudio(_ e: String) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        let base = e.replacingOccurrences(of: ".", with: "_")
        let monoNow = mono
        busy = "변환 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            var added: [String] = [], notes: [String] = []
            for (k, src) in urls.enumerated() {
                let stamp = Int(Date().timeIntervalSince1970) % 100000
                let name = "custom/\(base)_\(stamp)_\(k)"
                guard let dest = ws.packURL(SoundIDs.rel(name)) else { continue }
                if src.pathExtension.lowercased() == "ogg" && !monoNow {
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: src, to: dest)
                    added.append(name)
                } else {
                    let r = AudioConvert.toOgg(src, dest, mono: monoNow)
                    if r.ok { added.append(name) }
                    notes.append(r.note)
                }
            }
            DispatchQueue.main.async {
                setEvent(e) { ev in
                    var a = ev["sounds"] as? [Any] ?? []
                    for n in added { a.append(["name": n]) }
                    ev["sounds"] = a
                }
                ws.reload()
                busy = nil
                ws.status = "\(added.count)개 넣음" + (notes.isEmpty ? "" : " · " + Set(notes).joined(separator: ", "))
            }
        }
    }
}
