import AppKit
import SwiftUI

enum MockKind: String, CaseIterable, Identifiable {
    case title, pause, inventory, hud, panorama, skin, items, sounds, environment
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "타이틀 화면"
        case .pause: return "ESC 메뉴"
        case .inventory: return "인벤토리"
        case .hud: return "HUD (체력·핫바)"
        case .panorama: return "파노라마"
        case .skin: return "플레이어 스킨"
        case .items: return "아이템 상황별 모델"
        case .sounds: return "사운드"
        case .environment: return "하늘·날씨·색"
        }
    }
    var icon: String {
        switch self {
        case .title: return "house"
        case .pause: return "pause.rectangle"
        case .inventory: return "square.grid.3x3"
        case .hud: return "heart"
        case .panorama: return "view.3d"
        case .skin: return "person.fill"
        case .items: return "arrow.triangle.branch"
        case .sounds: return "speaker.wave.2"
        case .environment: return "cloud.sun"
        }
    }
}

/// 게임 기본 창(854x480)을 GUI 배율 2로 본 좌표계
let guiW: CGFloat = 427, guiH: CGFloat = 240
let sprites = "assets/minecraft/textures/gui/sprites/"
let guiTex = "assets/minecraft/textures/gui/"

struct MockScreenView: View {
    let kind: MockKind
    @EnvironmentObject var ws: Workspace
    @State private var avail = CGSize(width: 854, height: 480)
    @State private var showHotspots = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(kind.label).font(.title3.bold()).foregroundStyle(Theme.gradient)
                Text("누르면 그 그림이나 글씨를 바로 고쳐요. 팩에 없으면 바닐라에서 복사해 와요.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Toggle(isOn: $showHotspots) { Image(systemName: "viewfinder") }
                    .toggleStyle(.button).help("누를 수 있는 곳 표시")
                Picker("글씨 언어", selection: $ws.mockLang) {
                    ForEach(langChoices, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 170)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            GeometryReader { g in
                let s = max(0.5, min((g.size.width - 24) / guiW, (g.size.height - 24) / guiH))
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    screen(s)
                        .frame(width: guiW * s, height: guiH * s)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                }
                .environment(\.guiScale, s)
                .environment(\.showHotspots, showHotspots)
            }
            .id(ws.assetsVersion)
            Divider()
            HStack {
                Text("위치·글꼴은 게임과 비슷하게 맞춘 미리보기예요. 정확한 모습은 게임에서 F3+T로 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .onAppear { ws.lastMock = "mock:" + kind.rawValue }
    }

    private var langChoices: [String] {
        var c = Set(["ko_kr", "en_us", ws.mockLang])
        for u in ws.langFiles() { c.insert(u.deletingPathExtension().lastPathComponent) }
        return c.sorted()
    }

    @ViewBuilder private func screen(_ s: CGFloat) -> some View {
        switch kind {
        case .title: TitleMock()
        case .pause: PauseMock()
        case .inventory: InventoryMock()
        case .hud: HudMock()
        case .panorama, .skin, .items, .sounds, .environment: EmptyView()
        }
    }
}

// MARK: - 환경값

private struct GuiScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 2 }
private struct HotspotKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var guiScale: CGFloat { get { self[GuiScaleKey.self] } set { self[GuiScaleKey.self] = newValue } }
    var showHotspots: Bool { get { self[HotspotKey.self] } set { self[HotspotKey.self] = newValue } }
}

// MARK: - 부품

/// GUI 좌표(x, y, w, h)에 텍스처를 그린다. crop은 텍스처 기본 크기(baseW) 기준 영역.
struct GuiSprite: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.guiScale) private var s
    @Environment(\.showHotspots) private var hot
    let rel: String
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var crop: CGRect? = nil
    var baseW: CGFloat = 0
    var tappable = true
    @State private var hover = false

    var body: some View {
        content
            .frame(width: w * s, height: h * s)
            .overlay {
                if tappable && (hover || hot) {
                    Rectangle().strokeBorder(hover ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.35)),
                                             style: StrokeStyle(lineWidth: hover ? 2 : 1, dash: hover ? [] : [3, 3]))
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = tappable && $0 }
            .onTapGesture { if tappable { ws.editAsset(rel) } }
            .help(tappable ? "\(rel.replacingOccurrences(of: "assets/minecraft/textures/", with: ""))\n\(ws.inPack(rel) ? "팩에 있음" : "바닐라 (누르면 복사해서 편집)")" : "")
            .position(x: (x + w / 2) * s, y: (y + h / 2) * s)
            .allowsHitTesting(tappable)
    }

    @ViewBuilder private var content: some View {
        if let cg = image() {
            Image(decorative: cg, scale: 1).interpolation(.none).resizable()
        } else {
            Rectangle().fill(Color(red: 1, green: 0, blue: 1).opacity(0.6))
                .overlay(Text("없음").font(.caption2).foregroundStyle(.white))
        }
    }

    private func image() -> CGImage? {
        guard var img = ws.pixelImage(rel) else { return nil }
        if let crop {
            let k = baseW > 0 ? CGFloat(img.w) / baseW : 1
            img = img.crop(CGRect(x: crop.minX * k, y: crop.minY * k, width: crop.width * k, height: crop.height * k))
        } else if let u = ws.resolve(rel), let sc = GuiScaling.read(u), sc.kind != .stretch || sc.width != Int(w) || sc.height != Int(h) {
            img = sc.render(img, guiW: Int(w), guiH: Int(h))
        }
        return img.cgImage()
    }
}

/// 언어 키 글씨. 누르면 언어 표에서 그 키로 간다.
struct GuiText: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.guiScale) private var s
    @Environment(\.showHotspots) private var hot
    let key: String
    let x: CGFloat, y: CGFloat
    var align: Alignment = .center
    var color = Color.white
    var shadow = true
    var size: CGFloat = 8
    var literal: String? = nil
    var onTap: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        let str = literal ?? ws.mockText(key)
        McTextLine(text: str, base: color, size: size * s, shadow: shadow, shadowOffset: s)
            .fixedSize()
            .padding(.horizontal, 2)
            .overlay {
                if hover || (hot && literal == nil) {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(hover ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.yellow.opacity(0.45)),
                                      style: StrokeStyle(lineWidth: hover ? 2 : 1, dash: hover ? [] : [2, 2]))
                }
            }
            .overlay { if str.isEmpty { Text("(빈 글씨)").font(.system(size: 6 * s)).foregroundStyle(.white.opacity(0.75)).fixedSize() } }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if let onTap { onTap() } else { ws.editLangKey(key) } }
            .help(literal == nil ? "\(key)\n누르면 언어 표에서 고쳐요" : "")
            .frame(width: 300 * s, alignment: align)
            .allowsHitTesting(true)
            .position(x: (align == .leading ? x + 150 : align == .trailing ? x - 150 : x) * s, y: y * s)
    }
}

/// § 서식 코드를 반영한 한 줄
struct McTextLine: View {
    let text: String
    var base = Color.white
    let size: CGFloat
    var shadow = true
    var shadowOffset: CGFloat = 1
    var body: some View {
        let spans = McFormat.spans(text)
        let t = spans.reduce(Text("")) { acc, sp in
            var t = Text(sp.obf ? String(repeating: "#", count: sp.text.count) : sp.text)
            t = t.foregroundColor(sp.color.map { Color(red: $0.0, green: $0.1, blue: $0.2) } ?? base)
            if sp.bold { t = t.bold() }
            if sp.italic { t = t.italic() }
            if sp.underline { t = t.underline() }
            if sp.strike { t = t.strikethrough() }
            return acc + t
        }
        t.font(.system(size: size, weight: .semibold))
            .shadow(color: shadow ? .black.opacity(0.75) : .clear, radius: 0, x: shadowOffset * 0.7, y: shadowOffset * 0.7)
            .lineLimit(1)
    }
}

/// 버튼: widget/button 나인슬라이스 + 가운데 글씨
struct GuiButton: View {
    let key: String
    let x: CGFloat, y: CGFloat, w: CGFloat
    var body: some View {
        ZStack(alignment: .topLeading) {
            GuiSprite(rel: sprites + "widget/button.png", x: x, y: y, w: w, h: 20)
            GuiText(key: key, x: x + w / 2, y: y + 10)
        }
    }
}

/// 게임 화면 뒤 세상 대신 쓰는 밝은 그라데이션
struct WorldBackdrop: View {
    var dim: Double = 0
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color(red: 0.47, green: 0.66, blue: 1), Color(red: 0.74, green: 0.86, blue: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [Color(red: 0.45, green: 0.78, blue: 0.32), Color(red: 0.33, green: 0.55, blue: 0.2)],
                               startPoint: .top, endPoint: .bottom)
            }
            Color.black.opacity(dim)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 화면들

struct TitleMock: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.guiScale) private var s

    private var splash: String {
        let lines = (ws.text("assets/minecraft/texts/splashes.txt") ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.first ?? ""
    }

    var body: some View {
        let cx = guiW / 2
        let top = guiH / 4 + 48
        ZStack(alignment: .topLeading) {
            PanoramaScene(spin: true, blur: false, interactive: false)
                .frame(width: guiW * s, height: guiH * s)
                .allowsHitTesting(false)
            GuiSprite(rel: Panorama.overlayRel, x: 0, y: 0, w: guiW, h: guiH, tappable: false)
            // 로고 256x64 (텍스처는 1024x256), 에디션 128x16
            GuiSprite(rel: guiTex + "title/minecraft.png", x: cx - 128, y: 30, w: 256, h: 64)
            GuiSprite(rel: guiTex + "title/edition.png", x: cx - 64, y: 30 + 49, w: 128, h: 16)
            GuiText(key: "", x: cx + 90, y: 30 + 54, color: Color(red: 1, green: 1, blue: 0), literal: splash,
                    onTap: { ws.editAsset("assets/minecraft/texts/splashes.txt") })
                .rotationEffect(.degrees(-20), anchor: UnitPoint(x: (cx + 90) / guiW, y: 84 / guiH))
                .help("스플래시 문구 (texts/splashes.txt)")
            GuiButton(key: "menu.singleplayer", x: cx - 100, y: top, w: 200)
            GuiButton(key: "menu.multiplayer", x: cx - 100, y: top + 24, w: 200)
            GuiButton(key: "menu.online", x: cx - 100, y: top + 48, w: 200)
            GuiButton(key: "menu.options", x: cx - 100, y: top + 84, w: 98)
            GuiButton(key: "menu.quit", x: cx + 2, y: top + 84, w: 98)
            GuiText(key: "", x: 2, y: guiH - 6, align: .leading, size: 7,
                    literal: "Minecraft " + (ws.mcVersion?.id ?? ""), onTap: {})
            GuiText(key: "title.credits", x: guiW - 2, y: guiH - 6, align: .trailing, size: 7)
        }
    }
}

struct PauseMock: View {
    var body: some View {
        let cx = guiW / 2
        let y0: CGFloat = 54
        ZStack(alignment: .topLeading) {
            WorldBackdrop(dim: 0.45)
            GuiText(key: "menu.game", x: cx, y: 32)
            GuiButton(key: "menu.returnToGame", x: cx - 102, y: y0, w: 204)
            GuiButton(key: "gui.advancements", x: cx - 102, y: y0 + 24, w: 98)
            GuiButton(key: "gui.stats", x: cx + 4, y: y0 + 24, w: 98)
            GuiButton(key: "menu.sendFeedback", x: cx - 102, y: y0 + 48, w: 98)
            GuiButton(key: "menu.reportBugs", x: cx + 4, y: y0 + 48, w: 98)
            GuiButton(key: "menu.options", x: cx - 102, y: y0 + 72, w: 98)
            GuiButton(key: "menu.shareToLan", x: cx + 4, y: y0 + 72, w: 98)
            GuiButton(key: "menu.returnToMenu", x: cx - 102, y: y0 + 96, w: 204)
        }
    }
}

struct InventoryMock: View {
    var body: some View {
        let x = (guiW - 176) / 2, y = (guiH - 166) / 2
        ZStack(alignment: .topLeading) {
            WorldBackdrop(dim: 0.55)
            GuiSprite(rel: guiTex + "container/inventory.png", x: x, y: y, w: 176, h: 166,
                      crop: CGRect(x: 0, y: 0, width: 176, height: 166), baseW: 256)
            GuiText(key: "container.crafting", x: x + 97, y: y + 10, align: .leading,
                    color: Color(white: 0.25), shadow: false)
        }
    }
}

struct HudMock: View {
    var body: some View {
        let cx = guiW / 2
        let hb = guiH - 22
        ZStack(alignment: .topLeading) {
            WorldBackdrop()
            GuiSprite(rel: sprites + "hud/crosshair.png", x: cx - 7.5, y: guiH / 2 - 7.5, w: 15, h: 15)
            GuiSprite(rel: sprites + "hud/hotbar.png", x: cx - 91, y: hb, w: 182, h: 22)
            GuiSprite(rel: sprites + "hud/hotbar_selection.png", x: cx - 92, y: hb - 1, w: 24, h: 23)
            GuiSprite(rel: sprites + "hud/experience_bar_background.png", x: cx - 91, y: hb - 7, w: 182, h: 5)
            GuiSprite(rel: sprites + "hud/experience_bar_progress.png", x: cx - 91, y: hb - 7, w: 120, h: 5,
                      crop: CGRect(x: 0, y: 0, width: 120, height: 5), baseW: 182)
            ForEach(0..<10, id: \.self) { i in
                let hx = cx - 91 + CGFloat(i) * 8
                GuiSprite(rel: sprites + "hud/heart/container.png", x: hx, y: hb - 17, w: 9, h: 9)
                if i < 8 { GuiSprite(rel: sprites + "hud/heart/full.png", x: hx, y: hb - 17, w: 9, h: 9) }
                let fx = cx + 91 - 9 - CGFloat(i) * 8
                GuiSprite(rel: sprites + "hud/food_empty.png", x: fx, y: hb - 17, w: 9, h: 9)
                if i < 7 { GuiSprite(rel: sprites + "hud/food_full.png", x: fx, y: hb - 17, w: 9, h: 9) }
            }
        }
    }
}
