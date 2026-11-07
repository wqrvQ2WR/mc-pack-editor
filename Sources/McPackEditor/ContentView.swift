import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ws: Workspace
    @State private var newPNGDir: URL?
    @State private var newName = ""
    @State private var newSize = 16

    var body: some View {
        Group {
            if ws.root == nil { welcome } else { editor }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ws.reload() // 다른 프로그램에서 파일을 바꿔도 돌아오면 반영
        }
        .sheet(item: Binding(get: { newPNGDir.map(IdURL.init) }, set: { newPNGDir = $0?.url })) { d in
            newPNGSheet(d.url)
        }
        .sheet(isPresented: $ws.showNewLang) { NewLangSheet().environmentObject(ws) }
        .sheet(isPresented: $ws.showNewPack) { NewPackSheet().environmentObject(ws) }
    }

    // MARK: 시작 화면

    private var welcome: some View {
        HStack(spacing: 0) {
            hero.frame(width: 420)
            recentPacks
        }
    }

    @State private var packs: [PackItem] = []

    private var recentPacks: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("내 리소스팩").font(.title2.bold())
                Spacer()
                Button { packs = PackItem.scan() } label: { Image(systemName: "arrow.clockwise") }.help("다시 읽기")
                Button { NSWorkspace.shared.open(Workspace.resourcepacksDir) } label: { Image(systemName: "folder") }
                    .help("resourcepacks 폴더 열기")
            }
            Text("마인크래프트 resourcepacks 폴더의 팩이에요. 누르면 바로 편집해요.").font(.caption).foregroundStyle(.secondary)
            if packs.isEmpty {
                Text("팩이 없어요. 왼쪽에서 새 팩을 만들어 보세요.").foregroundStyle(.secondary).padding(.top, 30)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                    ForEach(packs) { p in
                        Button { ws.openPackItem(p) } label: {
                            HStack(spacing: 10) {
                                Group {
                                    if let i = p.icon { Image(nsImage: i).resizable().interpolation(.none) }
                                    else { Theme.gradient.overlay(Image(systemName: p.isZip ? "doc.zipper" : "cube").foregroundStyle(.white)) }
                                }
                                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p.name).font(.headline).lineLimit(1)
                                    McTextLine(text: p.desc.isEmpty ? " " : p.desc, base: .secondary, size: 11, shadow: false)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { packs = PackItem.scan() }
    }

    private var hero: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.66), Color(red: 1, green: 0.7, blue: 0.3),
                                    Color(red: 0.3, green: 0.8, blue: 1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "cube.transparent").font(.system(size: 64, weight: .bold)).foregroundStyle(.white)
                Text("MC 팩 편집기").font(.system(size: 40, weight: .heavy)).foregroundStyle(.white)
                Text("새 팩을 만들거나 폴더를 열어 바로 고쳐요")
                    .font(.title3).foregroundStyle(.white.opacity(0.92)).multilineTextAlignment(.center)
                Button { ws.showNewPack = true } label: {
                    Label("새 팩 만들기", systemImage: "plus").font(.title3.bold())
                        .frame(width: 210).padding(.vertical, 12)
                        .background(.white, in: Capsule())
                        .foregroundStyle(Color(red: 0.9, green: 0.25, blue: 0.5))
                }
                .buttonStyle(.plain)
                Button { ws.openPanel() } label: {
                    Label("폴더 열기", systemImage: "folder").font(.title3.bold())
                        .frame(width: 210).padding(.vertical, 12)
                        .background(.white.opacity(0.22), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Text("Cmd+N 새 팩 · Cmd+O 열기").font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    // MARK: 편집 화면

    private var editor: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            VStack(spacing: 0) {
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text(ws.status).font(.caption).lineLimit(1)
                    Spacer()
                    if ws.dirtyCount > 0 {
                        Text("저장 안 됨 \(ws.dirtyCount)개").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.gradient.opacity(0.18))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if let back = ws.lastMock, ws.selectedURL != nil {
                    Button { ws.selection = back } label: { Label(backLabel(back) + "(으)로", systemImage: "chevron.backward") }
                        .help("보던 목록으로 돌아가기")
                }
            }
            ToolbarItemGroup {
                Button { ws.showNewPack = true } label: { Label("새 팩", systemImage: "plus.square.on.square") }
                    .help("새 리소스팩 만들기 (Cmd+N)")
                Button { openLanguage() } label: { Label("언어", systemImage: "character.book.closed") }
                    .help("언어 표 편집기")
                Button { ws.openPanel() } label: { Label("열기", systemImage: "folder") }
                Button { ws.saveAll() } label: { Label("모두 저장", systemImage: "square.and.arrow.down") }
                Button { ws.exportZip() } label: { Label("zip 내보내기", systemImage: "shippingbox") }
                Button { ws.installToMinecraft() } label: { Label("마크에 설치", systemImage: "gamecontroller") }
            }
        }
        .navigationTitle(ws.root?.lastPathComponent ?? "")
        .onAppear {
            // 목록이 처음 그려지며 선택을 비우므로 조금 뒤에 고른다
            if let p = ws.pendingSelection {
                ws.pendingSelection = nil
                for t in [0.3, 1.0, 2.0] { // 목록이 늦게 그려질 때도 남도록 몇 번 더
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { if ws.selection == nil { ws.selection = p } }
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("파일 이름 검색", text: $ws.query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .onChange(of: ws.query) { ws.refreshSearch() }
            if !ws.hasMcmeta() {
                Button { ws.createMcmeta(description: ws.root?.lastPathComponent ?? "") } label: {
                    Label("pack.mcmeta 만들기", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 8).padding(.bottom, 6)
            }
            List(selection: $ws.selection) {
                if ws.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("팩") {
                        Label("바꾼 것 미리보기", systemImage: "sparkles.rectangle.stack").tag("changes")
                    }
                    Section("텍스처") {
                        ForEach(TexCategory.all) { c in Label(c.label, systemImage: c.icon).tag("tex:" + c.id) }
                        ForEach(ws.packNamespaces(), id: \.self) { ns in
                            Label(ns + " (팩 전용)", systemImage: "shippingbox.fill").tag("tex:ns:" + ns)
                        }
                    }
                    Section("편집 도구") {
                        ForEach(MockKind.allCases) { k in
                            Label(k.label, systemImage: k.icon).tag("mock:" + k.rawValue)
                        }
                    }
                    Section("파일") {
                        OutlineGroup(ws.nodes, children: \.children) { n in row(n) }
                    }
                } else {
                    ForEach(ws.searchResults) { n in
                        row(n, label: ws.relPath(n.url))
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                if let r = ws.root {
                    Button("새 PNG (최상위)…") { newPNGDir = r }
                    Button("Finder에서 보기") { ws.reveal(r) }
                }
            }
        }
    }

    private func row(_ n: Node, label: String? = nil) -> some View {
        Label {
            Text(label ?? n.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: icon(n)).foregroundStyle(n.isDir ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.secondary))
        }
        .tag(n.id)
        .contextMenu {
            if n.isDir { Button("이 폴더에 새 PNG…") { newPNGDir = n.url } }
            Button("Finder에서 보기") { ws.reveal(n.url) }
            Divider()
            Button("휴지통으로 이동", role: .destructive) { ws.trash(n.url) }
        }
    }

    private func icon(_ n: Node) -> String {
        if n.isDir { return "folder.fill" }
        switch n.url.pathExtension.lowercased() {
        case "png": return "photo"
        case "json", "mcmeta": return "curlybraces"
        case "ogg": return "waveform"
        case "fsh", "vsh", "glsl": return "sparkles"
        default: return "doc.text"
        }
    }

    @ViewBuilder private var detail: some View {
        if ws.selection == "changes" {
            ChangesView().onAppear { ws.lastMock = "changes" }
        } else if let s = ws.selection, s.hasPrefix("tex:") {
            TextureBrowserView(category: String(s.dropFirst(4))).onAppear { ws.lastMock = s }
        } else if let m = ws.selectedMock {
            switch m {
            case .panorama: PanoramaView()
            case .skin: SkinPickerView().onAppear { ws.lastMock = "mock:skin" }
            case .items: ItemPickerView().onAppear { ws.lastMock = "mock:items" }
            case .sounds: SoundsView()
            case .environment: EnvironmentView()
            default: MockScreenView(kind: m).id(m.rawValue)
            }
        } else if let u = ws.selectedURL {
            let ext = u.pathExtension.lowercased()
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                placeholder("폴더: \(ws.relPath(u))", "왼쪽에서 파일을 고르세요")
            } else if ws.relPath(u) == "assets/minecraft/sounds.json" {
                SoundsView()
            } else if ws.isItemDefFile(u) {
                ItemDefEditorView(doc: ws.modelDoc(u)).id(u.path)
            } else if ws.isModelFile(u) {
                ModelEditorView(doc: ws.modelDoc(u)).id(u.path)
            } else if ws.isLangFile(u) {
                LangEditorView(doc: ws.langDoc(u)).id(u.path)
            } else if imageExts.contains(ext) {
                if let d = ws.imageDoc(u) {
                    if u.path.contains("/textures/entity/player/") && d.image.w == 64 && (d.image.h == 64 || d.image.h == 32) {
                        SkinEditorView(doc: d).id(u.path)
                    } else {
                        ImageEditorView(doc: d).id(u.path)
                    }
                }
                else { placeholder("이미지를 못 읽었어요", u.lastPathComponent) }
            } else if textExts.contains(ext) {
                TextEditorView(doc: ws.textDoc(u)).id(u.path)
            } else {
                FileInfoView(url: u)
            }
        } else {
            placeholder("파일을 고르세요", "PNG는 그림판, JSON/텍스트는 편집기로 열려요")
        }
    }

    private func backLabel(_ s: String) -> String {
        if s == "changes" { return "바꾼 것" }
        if s.hasPrefix("tex:ns:") { return String(s.dropFirst(7)) }
        if s.hasPrefix("tex:") { return TexCategory.all.first { $0.id == String(s.dropFirst(4)) }?.label ?? "텍스처" }
        if let k = MockKind(rawValue: String(s.dropFirst(5))) { return k.label }
        return "목록"
    }

    /// 팩의 언어 파일을 연다 (ko_kr 우선). 없으면 새 언어 만들기 창.
    private func openLanguage() {
        let files = ws.langFiles()
        if let f = files.first(where: { $0.lastPathComponent == "ko_kr.json" }) ?? files.first {
            ws.selection = f.path
        } else {
            ws.showNewLang = true
        }
    }

    private func placeholder(_ t: String, _ s: String) -> some View {
        VStack(spacing: 8) {
            Text(t).font(.title2.bold()).foregroundStyle(Theme.gradient)
            Text(s).foregroundStyle(.secondary)
        }
    }

    private func newPNGSheet(_ dir: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("새 PNG").font(.title3.bold())
            Text(ws.relPath(dir)).font(.caption).foregroundStyle(.secondary)
            TextField("파일 이름 (예: my_item)", text: $newName)
            Picker("크기", selection: $newSize) {
                ForEach([16, 32, 64, 128, 256], id: \.self) { Text("\($0) x \($0)").tag($0) }
            }
            HStack {
                Spacer()
                Button("취소") { newPNGDir = nil }.keyboardShortcut(.cancelAction)
                Button("만들기") {
                    ws.newPNG(in: dir, name: newName, size: newSize)
                    newName = ""; newPNGDir = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 340)
    }
}

struct IdURL: Identifiable { let url: URL; var id: String { url.path } }

struct TextEditorView: View {
    @ObservedObject var doc: TextDoc
    @EnvironmentObject var ws: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(ws.relPath(doc.url)).font(.headline)
                Spacer()
                if doc.isJSON {
                    if let e = doc.error {
                        Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption).lineLimit(2)
                    } else {
                        Label("JSON 문법 정상", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                    }
                    Button("정렬") { format() }.disabled(doc.error != nil)
                }
                if doc.dirty { Text("저장 안 됨").font(.caption).foregroundStyle(.orange) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            TextEditor(text: $doc.text)
                .font(.system(size: 13, design: .monospaced))
                .autocorrectionDisabled()
                .padding(4)
        }
    }

    private func format() {
        guard let d = doc.text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: out, encoding: .utf8) else { return }
        doc.text = s + "\n"
    }
}

struct FileInfoView: View {
    let url: URL
    var body: some View {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        VStack(spacing: 10) {
            Image(systemName: url.pathExtension.lowercased() == "ogg" ? "waveform" : "doc")
                .font(.system(size: 40)).foregroundStyle(Theme.gradient)
            Text(url.lastPathComponent).font(.title3.bold())
            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).foregroundStyle(.secondary)
            Text("이 형식의 편집기는 아직 없어요").foregroundStyle(.secondary)
            Button("기본 앱으로 열기") { NSWorkspace.shared.open(url) }
        }
    }
}
