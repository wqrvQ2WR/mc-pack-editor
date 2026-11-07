import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 새 팩 만들기

struct NewPackSheet: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = "내 리소스팩"
    @State private var desc = "§d나만의 §b리소스팩"
    @State private var location = Workspace.resourcepacksDir
    @State private var minID = ""
    @State private var maxID = ""
    @State private var icon: PixelImage?
    @State private var addKo = true
    @State private var error: String?

    private var releases: [McVersion] {
        MinecraftInstall.shared.versions.filter { $0.type == "release" && MinecraftInstall.shared.packVersion($0) != nil }
    }
    private var safeName: String {
        name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("새 리소스팩 만들기").font(.title2.bold()).foregroundStyle(Theme.gradient)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 6) {
                    iconView.frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
                    Button("아이콘 고르기…") { pickIcon() }.controlSize(.small)
                    Text("비우면 바닐라 아이콘").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField("팩 이름 (폴더 이름)", text: $name).textFieldStyle(.roundedBorder)
                    TextField("설명 (§ 색 코드 가능)", text: $desc).textFieldStyle(.roundedBorder)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("게임 팩 목록에서 이렇게 보여요").font(.caption2).foregroundStyle(.secondary)
                        McTextPreview(text: desc)
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("지원 버전")
                    HStack {
                        Picker("", selection: $minID) { ForEach(releases) { Text($0.id).tag($0.id) } }.labelsHidden().frame(width: 110)
                        Text("부터")
                        Picker("", selection: $maxID) { ForEach(releases) { Text($0.id).tag($0.id) } }.labelsHidden().frame(width: 110)
                        Text("까지")
                    }
                }
                GridRow {
                    Text("만들 곳")
                    HStack {
                        Text(location.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Button("바꾸기…") { pickLocation() }.controlSize(.small)
                    }
                }
                GridRow {
                    Text("시작 내용")
                    Toggle("빈 한국어 언어 파일 (ko_kr) 넣기", isOn: $addKo)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            HStack {
                Text("만들면 바로 열려요. resourcepacks 폴더에 만들면 게임 목록에 바로 떠요.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("만들기") { create() }.keyboardShortcut(.defaultAction).disabled(safeName.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            // 기본: 설치된 릴리스 중 26.x 가장 오래된 것 ~ 최신
            let r = releases
            maxID = r.first?.id ?? ""
            minID = r.last(where: { (MinecraftInstall.shared.packVersion($0)?.0 ?? 0) >= 84 })?.id ?? r.first?.id ?? ""
        }
    }

    @ViewBuilder private var iconView: some View {
        if let icon, let cg = icon.cgImage() {
            Image(decorative: cg, scale: 1).resizable().interpolation(.high)
        } else if let v = MinecraftInstall.shared.latestRelease, let d = MinecraftInstall.shared.jarFile(v, "pack.png"),
                  let ns = NSImage(data: d) {
            Image(nsImage: ns).resizable().interpolation(.none)
        } else {
            Theme.gradient
        }
    }

    private func pickIcon() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url,
              let src = CGImageSourceCreateWithURL(u as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        icon = PixelImage.fitted(cg, w: 128, h: 128, fit: .cover, smooth: true)
    }

    private func pickLocation() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.directoryURL = location
        if p.runModal() == .OK, let u = p.url { location = u }
    }

    private func create() {
        let dest = location.appendingPathComponent(safeName)
        guard !FileManager.default.fileExists(atPath: dest.path) else { error = "같은 이름의 폴더가 이미 있어요"; return }
        let inst = MinecraftInstall.shared
        let minF = releases.first { $0.id == minID }.flatMap { inst.packVersion($0)?.0 } ?? 84
        let maxF = max(minF, releases.first { $0.id == maxID }.flatMap { inst.packVersion($0)?.0 } ?? minF)
        do {
            try FileManager.default.createDirectory(at: dest.appendingPathComponent("assets/minecraft"), withIntermediateDirectories: true)
            var pack: [String: Any] = ["description": desc, "min_format": minF, "max_format": maxF]
            if minF < 84 { // 옛 버전도 받으면 예전 형식도 같이 적는다
                pack["pack_format"] = minF
                pack["supported_formats"] = [minF, maxF]
            }
            let d = try JSONSerialization.data(withJSONObject: ["pack": pack], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (d + Data("\n".utf8)).write(to: dest.appendingPathComponent("pack.mcmeta"))
            if let icon, let png = icon.pngData() {
                try png.write(to: dest.appendingPathComponent("pack.png"))
            } else if let v = inst.latestRelease, let png = inst.jarFile(v, "pack.png") {
                try png.write(to: dest.appendingPathComponent("pack.png"))
            }
            if addKo {
                let lang = dest.appendingPathComponent("assets/minecraft/lang")
                try FileManager.default.createDirectory(at: lang, withIntermediateDirectories: true)
                try "{}\n".write(to: lang.appendingPathComponent("ko_kr.json"), atomically: true, encoding: .utf8)
            }
        } catch {
            self.error = "만들지 못했어요: \(error.localizedDescription)"; return
        }
        dismiss()
        ws.open(dest)
        ws.selection = "changes"
        ws.status = "새 팩을 만들었어요: \(safeName) (형식 \(minF)~\(maxF))"
    }
}

extension MinecraftInstall {
    /// jar 안 파일 하나 (pack.png 등)
    func jarFile(_ v: McVersion, _ path: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", v.jar.path, path]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !d.isEmpty ? d : nil
    }
}

extension Workspace {
    static var resourcepacksDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/minecraft/resourcepacks")
    }
}

// MARK: - 시작 화면의 내 리소스팩 목록

struct PackItem: Identifiable {
    let url: URL
    let isZip: Bool
    let icon: NSImage?
    let desc: String
    var id: String { url.path }
    var name: String { isZip ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }

    static func scan() -> [PackItem] {
        let dir = Workspace.resourcepacksDir
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var out: [PackItem] = []
        for u in items {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let meta = u.appendingPathComponent("pack.mcmeta")
                guard fm.fileExists(atPath: meta.path) else { continue }
                var d = ""
                if let data = try? Data(contentsOf: meta), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let p = o["pack"] as? [String: Any]
                    d = p?["description"] as? String ?? ""
                }
                out.append(PackItem(url: u, isZip: false, icon: NSImage(contentsOf: u.appendingPathComponent("pack.png")), desc: d))
            } else if u.pathExtension.lowercased() == "zip" {
                out.append(PackItem(url: u, isZip: true, icon: nil, desc: "zip (열면 폴더로 풀어서 편집)"))
            }
        }
        let date: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return out.sorted { date($0.url) > date($1.url) }
    }
}

extension Workspace {
    /// zip 팩은 옆에 폴더로 풀어서 연다
    func openPackItem(_ p: PackItem) {
        guard p.isZip else { open(p.url); return }
        var dest = p.url.deletingPathExtension()
        if FileManager.default.fileExists(atPath: dest.path) { dest = URL(fileURLWithPath: dest.path + " (편집)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = AudioConvert.run("/usr/bin/ditto", ["-x", "-k", p.url.path, tmp.path])
        // zip 안에 폴더가 하나 더 있으면 그 안이 팩
        var src = tmp
        let inner = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil))?.filter { $0.lastPathComponent != "__MACOSX" } ?? []
        if !FileManager.default.fileExists(atPath: tmp.appendingPathComponent("pack.mcmeta").path), inner.count == 1 { src = inner[0] }
        do {
            try FileManager.default.moveItem(at: src, to: dest)
            open(dest)
            status = "zip을 폴더로 풀어서 열었어요: \(dest.lastPathComponent)"
        } catch {
            status = "zip을 풀지 못했어요: \(error.localizedDescription)"
        }
    }
}
