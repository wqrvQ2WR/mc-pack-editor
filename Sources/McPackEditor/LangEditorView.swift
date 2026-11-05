import AppKit
import SwiftUI

struct KeyRow: Identifiable, Hashable { let id: String }

enum LangFilter: String, CaseIterable, Identifiable {
    case pack = "팩에 있는 키"
    case all = "바닐라 전체"
    case changed = "바닐라와 다름"
    case empty = "빈 값"
    case packOnly = "팩에만 있음"
    var id: String { rawValue }
}

enum RefSource: Hashable {
    case vanilla(String)   // 바닐라 언어 코드
    case packFile(String)  // 팩 안의 다른 언어 파일 경로
}

struct LangEditorView: View {
    @ObservedObject var doc: LangDoc
    @EnvironmentObject var ws: Workspace

    @State private var filter: LangFilter = .pack
    @State private var search = ""
    @State private var rows: [KeyRow] = []
    @State private var selection: String?
    @State private var ref: RefSource = .vanilla("en_us")
    @State private var refMap: [String: String] = [:]
    @State private var vanSame: [String: String] = [:]
    @State private var raw = false
    @State private var showReplace = false
    @State private var showAddKey = false
    @State private var loading = false

    private var install: MinecraftInstall { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if raw {
                TextEditorView(doc: ws.textDoc(doc.url)).id("raw-" + doc.url.path)
            } else {
                if let e = doc.loadError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                }
                filterBar
                Divider()
                table
                Divider()
                detail
            }
        }
        .onAppear {
            loadVanilla()
            if let k = ws.pendingLangKey {
                // 목업에서 글씨를 눌러 왔을 때: 그 키로 바로
                ws.pendingLangKey = nil
                filter = .all; search = k; selection = k
            } else if let k = ProcessInfo.processInfo.environment["MCPE_KEY"] { selection = k } // 검증용
        }
        .onChange(of: ws.mcVersionID) { loadVanilla() }
        .onChange(of: ref) { loadRef(); recompute() }
        .onChange(of: filter) { recompute() }
        .onChange(of: search) { recompute() }
        .onChange(of: doc.order.count) { recompute() }
        .onChange(of: raw) { toggleRaw() }
        .sheet(isPresented: $showReplace) {
            ReplaceSheet(doc: doc, vanilla: vanSame) { n in ws.status = "\(n)개 바꿨음"; recompute() }
        }
        .sheet(isPresented: $showAddKey) {
            AddKeySheet(doc: doc, vanilla: vanSame, ref: refMap) { k in
                filter = .pack; search = ""; recompute(); selection = k
            }
        }
    }

    // MARK: 머리줄

    private var header: some View {
        HStack(spacing: 10) {
            Picker("언어", selection: Binding(get: { doc.url.path }, set: { ws.selection = $0 })) {
                ForEach(ws.langFiles(), id: \.path) { u in
                    Text(langLabel(u)).tag(u.path)
                }
            }
            .frame(maxWidth: 260)
            Button { ws.showNewLang = true } label: { Label("새 언어", systemImage: "plus") }

            Divider().frame(height: 18)
            Picker("바닐라", selection: Binding(get: { ws.mcVersion?.id ?? "" }, set: { ws.mcVersionID = $0 })) {
                if install.versions.isEmpty { Text("마크 설치 없음").tag("") }
                ForEach(install.versions) { v in Text(v.id + (v.type == "release" ? "" : " (스냅샷)")).tag(v.id) }
            }
            .frame(maxWidth: 200)
            Picker("기준", selection: $ref) {
                Text("바닐라 en_us").tag(RefSource.vanilla("en_us"))
                if doc.code != "en_us" { Text("바닐라 \(doc.code)").tag(RefSource.vanilla(doc.code)) }
                ForEach(ws.langFiles().filter { $0 != doc.url }, id: \.path) { u in
                    Text("팩 " + u.deletingPathExtension().lastPathComponent + " (\(nsOf(u)))").tag(RefSource.packFile(u.path))
                }
            }
            .frame(maxWidth: 230)
            Spacer(minLength: 0)
            if loading { ProgressView().controlSize(.small) }
            Toggle(isOn: $raw) { Label("원시 JSON", systemImage: "curlybraces") }.toggleStyle(.button)
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(LangFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 470)
            TextField("키나 내용 검색", text: $search).textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 240)
            Spacer(minLength: 0)
            Button { showReplace = true } label: { Label("찾아 바꾸기", systemImage: "arrow.left.arrow.right") }
            Button { showAddKey = true } label: { Label("키 추가", systemImage: "plus.square") }
            Button { doc.undo(); recompute() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!doc.canUndo).help("일괄 작업 되돌리기")
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: 표

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("키") { r in
                HStack(spacing: 6) {
                    Circle()
                        .fill(doc.has(r.id) ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear))
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(doc.has(r.id) ? 0 : 0.4)))
                        .frame(width: 8, height: 8)
                    Text(r.id).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(doc.has(r.id) ? .primary : .secondary)
                        .help(r.id)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn(refTitle) { r in
                Text(refMap[r.id] ?? "").foregroundStyle(.secondary).help(refMap[r.id] ?? "")
            }
            .width(min: 120, ideal: 200)
            TableColumn("이 팩의 값") { r in
                ValueCell(doc: doc, key: r.id, placeholder: vanSame[r.id] ?? "")
            }
            .width(min: 160, ideal: 240)
        }
        .contextMenu(forSelectionType: String.self) { keys in
            if let k = keys.first {
                Button("기준 값 그대로 넣기") { if let v = refMap[k] { doc.set(k, v) } }
                Button("바닐라 \(doc.code) 값 넣기") { if let v = vanSame[k] { doc.set(k, v) } }
                Button("빈 값으로 (글씨 지우기)") { doc.set(k, "") }
                Divider()
                Button("키 복사") { copy(k) }
                Button("팩에서 빼기 (바닐라로 되돌림)", role: .destructive) { doc.remove(k) }
            }
        }
    }

    private var refTitle: String {
        switch ref {
        case .vanilla(let c): return "바닐라 \(c)"
        case .packFile(let p): return "팩 " + URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
        }
    }

    // MARK: 선택한 키 상세

    @ViewBuilder private var detail: some View {
        if let k = selection {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(k).font(.system(.callout, design: .monospaced).bold()).textSelection(.enabled)
                    Spacer()
                    Button("빈 값으로") { doc.set(k, "") }.help("게임에서 글씨가 안 보이게")
                    Button("기준 값 넣기") { if let v = refMap[k] { doc.set(k, v) } }.disabled(refMap[k] == nil)
                    Button("바닐라로 되돌림") { doc.remove(k) }.disabled(!doc.has(k))
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(refTitle).font(.caption).foregroundStyle(.secondary)
                        Text(refMap[k] ?? "(없음)").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if doc.code != "en_us", case .vanilla("en_us") = ref, let v = vanSame[k] {
                            Text("바닐라 \(doc.code)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                            Text(v).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(doc.has(k) ? (doc.map[k] == "" ? "이 팩의 값 (빈 값으로 덮음)" : "이 팩의 값") : "이 팩의 값 (아직 없음, 쓰면 추가됨)")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { doc.map[k] ?? "" }, set: { doc.set(k, $0) }))
                            .font(.body)
                            .frame(height: 54)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("게임 글씨 미리보기").font(.caption).foregroundStyle(.secondary)
                        McTextPreview(text: doc.map[k] ?? vanSame[k] ?? "")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .frame(height: 150)
        } else {
            HStack {
                Text("\(rows.count)개 표시 · 팩에 \(doc.order.count)개 · " + (vanSame.isEmpty ? "바닐라에 없는 언어 (나만의 언어)" : "바닐라 \(doc.code) \(vanSame.count)개"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("줄을 고르면 아래에서 길게 고치고 미리볼 수 있어요").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    // MARK: 데이터

    private func loadVanilla() {
        guard let v = ws.mcVersion else { vanSame = [:]; loadRef(); recompute(); return }
        loading = true
        let code = doc.code
        DispatchQueue.global(qos: .userInitiated).async {
            let same = MinecraftInstall.shared.lang(v, code)
            DispatchQueue.main.async {
                vanSame = same
                loading = false
                loadRef()
                recompute()
            }
        }
    }

    private func loadRef() {
        switch ref {
        case .vanilla(let c):
            if c == doc.code { refMap = vanSame }
            else if let v = ws.mcVersion { refMap = install.lang(v, c) }
            else { refMap = [:] }
        case .packFile(let p):
            refMap = ws.langDoc(URL(fileURLWithPath: p)).map
        }
    }

    private func recompute() {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var keys: [String]
        switch filter {
        case .pack: keys = doc.order
        case .all:
            keys = vanSame.keys.sorted()
            keys += doc.order.filter { vanSame[$0] == nil }
        case .changed: keys = doc.order.filter { vanSame[$0] != nil && vanSame[$0] != doc.map[$0] }
        case .empty: keys = doc.order.filter { (doc.map[$0] ?? "").isEmpty }
        case .packOnly: keys = doc.order.filter { vanSame[$0] == nil }
        }
        if !q.isEmpty {
            keys = keys.filter { k in
                k.lowercased().contains(q)
                    || (doc.map[k]?.lowercased().contains(q) ?? false)
                    || (refMap[k]?.lowercased().contains(q) ?? false)
                    || (vanSame[k]?.lowercased().contains(q) ?? false)
            }
        }
        rows = keys.map(KeyRow.init)
    }

    private func toggleRaw() {
        if raw {
            if doc.dirty { doc.save() }
            ws.dropTextDoc(doc.url)
        } else {
            let td = ws.textDoc(doc.url)
            if td.dirty { td.save() }
            ws.dropTextDoc(doc.url)
            doc.load()
            recompute()
        }
    }

    private func nsOf(_ u: URL) -> String { u.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }

    private func langLabel(_ u: URL) -> String {
        let code = u.deletingPathExtension().lastPathComponent
        var s = code
        if let v = ws.mcVersion, let name = install.lang(v, code)["language.name"] { s += " · " + name }
        if nsOf(u) != "minecraft" { s += " (\(nsOf(u)))" }
        return s
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// 표 안의 값 칸. 팩에 없으면 바닐라 값을 흐리게 보여 주고, 쓰면 팩에 추가된다.
struct ValueCell: View {
    @ObservedObject var doc: LangDoc
    let key: String
    let placeholder: String
    var body: some View {
        TextField("", text: Binding(get: { doc.map[key] ?? "" }, set: { doc.set(key, $0) }),
                  prompt: Text(doc.has(key) ? "(빈 값)" : placeholder).foregroundStyle(.tertiary))
            .textFieldStyle(.plain)
    }
}

/// § 서식 코드를 게임처럼 그려 본다
struct McTextPreview: View {
    let text: String
    var body: some View {
        let spans = McFormat.spans(text)
        let line = spans.reduce(Text("")) { acc, sp in
            var t = Text(sp.obf ? String(repeating: "#", count: sp.text.count) : sp.text)
            if let c = sp.color { t = t.foregroundColor(Color(red: c.0, green: c.1, blue: c.2)) } else { t = t.foregroundColor(.white) }
            if sp.bold { t = t.bold() }
            if sp.italic { t = t.italic() }
            if sp.underline { t = t.underline() }
            if sp.strike { t = t.strikethrough() }
            return acc + t
        }
        return ScrollView {
            line
                .font(.system(size: 13, weight: .medium))
                .shadow(color: .black.opacity(0.6), radius: 0, x: 1.5, y: 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 54)
        .background(
            LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.95), Color(red: 0.93, green: 0.35, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if text.isEmpty { Text("(보이지 않음)").font(.caption2).foregroundStyle(.white.opacity(0.8)).padding(4) }
        }
    }
}

// MARK: - 찾아 바꾸기

struct ReplaceSheet: View {
    @ObservedObject var doc: LangDoc
    let vanilla: [String: String]
    let done: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var find = ""
    @State private var repl = ""
    @State private var caseSensitive = false
    @State private var includeVanilla = true

    private func matches(_ s: String) -> Bool {
        caseSensitive ? s.contains(find) : s.range(of: find, options: .caseInsensitive) != nil
    }
    private func replaced(_ s: String) -> String {
        s.replacingOccurrences(of: find, with: repl, options: caseSensitive ? [] : .caseInsensitive)
    }

    private var preview: (pack: Int, van: Int) {
        guard !find.isEmpty else { return (0, 0) }
        let p = doc.order.filter { matches(doc.map[$0] ?? "") }.count
        let v = includeVanilla ? vanilla.filter { doc.map[$0.key] == nil && matches($0.value) }.count : 0
        return (p, v)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("찾아 바꾸기").font(.title3.bold())
            TextField("찾을 글자 (예: 다이아몬드)", text: $find)
            TextField("바꿀 글자 (예: 금강석)", text: $repl)
            Toggle("대소문자 구분", isOn: $caseSensitive)
            Toggle("팩에 없는 바닐라 문장에도 적용 (바뀐 키는 팩에 추가)", isOn: $includeVanilla)
            let p = preview
            Text("팩 값 \(p.pack)개" + (includeVanilla ? " + 바닐라 \(p.van)개" : "") + " 바뀜")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("모두 바꾸기") {
                    doc.checkpoint()
                    var n = 0
                    for k in doc.order where matches(doc.map[k] ?? "") { doc.set(k, replaced(doc.map[k] ?? "")); n += 1 }
                    if includeVanilla {
                        for (k, v) in vanilla.sorted(by: { $0.key < $1.key }) where doc.map[k] == nil && matches(v) {
                            doc.set(k, replaced(v)); n += 1
                        }
                    }
                    done(n); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(find.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }
}

// MARK: - 키 추가

struct AddKeySheet: View {
    @ObservedObject var doc: LangDoc
    let vanilla: [String: String]
    let ref: [String: String]
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var value = ""

    private var suggestions: [String] {
        let q = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        return Array(Set(vanilla.keys).union(ref.keys).filter { $0.lowercased().contains(q) && !doc.has($0) }.sorted().prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("키 추가").font(.title3.bold())
            TextField("키 (예: menu.returnToGame 또는 item.mymod.thing)", text: $key)
                .font(.system(.body, design: .monospaced))
            ForEach(suggestions, id: \.self) { s in
                Button {
                    key = s; if value.isEmpty { value = vanilla[s] ?? "" }
                } label: {
                    HStack {
                        Text(s).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(vanilla[s] ?? ref[s] ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            if let v = vanilla[key] { Text("바닐라 값: \(v)").font(.caption).foregroundStyle(.secondary) }
            if doc.has(key) { Text("이미 팩에 있는 키예요").font(.caption).foregroundStyle(.orange) }
            TextField("값", text: $value)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("추가") {
                    let k = key.trimmingCharacters(in: .whitespaces)
                    doc.set(k, value)
                    done(k); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}

// MARK: - 새 언어

struct NewLangSheet: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var code = "ko_kr"
    @State private var customCode = ""
    @State private var name = ""
    @State private var region = ""
    @State private var namespace = "minecraft"
    @State private var seed = "empty"

    private var install: MinecraftInstall { .shared }
    private var codes: [String] { ws.mcVersion.map { install.langCodes($0) } ?? ["en_us", "ko_kr"] }
    private var finalCode: String { custom ? customCode.lowercased().replacingOccurrences(of: " ", with: "_") : code }
    private var codeValid: Bool { finalCode.range(of: "^[a-z0-9_.-]+$", options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("새 언어 파일").font(.title3.bold())
            Picker("", selection: $custom) {
                Text("바닐라 언어 덮어쓰기").tag(false)
                Text("나만의 새 언어").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()

            if custom {
                TextField("코드 (예: a_cat)", text: $customCode).font(.system(.body, design: .monospaced))
                TextField("언어 이름 (게임 언어 목록에 보임)", text: $name)
                TextField("지역 (예: 대한민국)", text: $region)
                Text("pack.mcmeta의 language에 등록돼서 게임 언어 선택에 새로 떠요. 비어 있는 키는 영어로 나오니 바닐라 문장을 복사해서 시작하는 걸 추천해요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("언어", selection: $code) {
                    ForEach(codes, id: \.self) { c in Text(c).tag(c) }
                }
                if let n = selectedName { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
            TextField("네임스페이스", text: $namespace).font(.system(.body, design: .monospaced))
            Picker("시작 내용", selection: $seed) {
                Text("빈 파일 (바꿀 키만 추가)").tag("empty")
                if ws.mcVersion != nil {
                    Text("바닐라 \(custom ? "ko_kr" : code) 전체 복사").tag("same")
                    Text("바닐라 en_us 전체 복사").tag("en")
                }
            }
            Text("파일: assets/\(namespace)/lang/\(finalCode).json").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("만들기") {
                    var m: [String: String] = [:]
                    if let v = ws.mcVersion, seed != "empty" {
                        m = install.lang(v, seed == "en" ? "en_us" : (custom ? "ko_kr" : code))
                    }
                    if custom { m["language.name"] = name; m["language.region"] = region; m["language.code"] = finalCode }
                    let order = m.keys.sorted()
                    ws.createLang(code: finalCode, namespace: namespace.isEmpty ? "minecraft" : namespace,
                                  seed: m, seedOrder: seed == "empty" && !custom ? [] : order,
                                  custom: custom ? (name.isEmpty ? finalCode : name, region) : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!codeValid || (custom && name.isEmpty))
            }
        }
        .padding(20).frame(width: 440)
    }

    /// 고른 언어 하나만 읽어서 이름 표시 (142개를 다 읽으면 느림)
    private var selectedName: String? {
        guard let v = ws.mcVersion else { return nil }
        let m = install.lang(v, code)
        guard let n = m["language.name"] else { return nil }
        return [n, m["language.region"]].compactMap { $0 }.joined(separator: " · ")
    }
}
