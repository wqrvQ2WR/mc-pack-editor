import AppKit
import SwiftUI

// MARK: - 색 조정 (색조·채도·밝기·색 입히기)

struct ColorAdjust: Equatable {
    var hue: Double = 0          // -180~180도
    var saturation: Double = 1   // 0~2배
    var brightness: Double = 0   // -1~1
    var contrast: Double = 1     // 0~2
    var tint: RGBA? = nil
    var tintAmount: Double = 0   // 0~1

    var isIdentity: Bool { hue == 0 && saturation == 1 && brightness == 0 && contrast == 1 && (tint == nil || tintAmount == 0) }

    func apply(_ img: PixelImage) -> PixelImage {
        var out = img
        var i = 0
        while i < out.px.count {
            if out.px[i + 3] > 0 {
                var r = Double(out.px[i]) / 255, g = Double(out.px[i + 1]) / 255, b = Double(out.px[i + 2]) / 255
                // RGB -> HSB
                let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
                var h = 0.0
                if d > 0 {
                    if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
                    h *= 60; if h < 0 { h += 360 }
                }
                var s = mx == 0 ? 0 : d / mx
                var v = mx
                h = (h + hue).truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 }
                s = min(1, max(0, s * saturation))
                v = min(1, max(0, (v - 0.5) * contrast + 0.5 + brightness))
                // HSB -> RGB
                let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
                switch Int(h / 60) % 6 {
                case 0: (r, g, b) = (c, x, 0)
                case 1: (r, g, b) = (x, c, 0)
                case 2: (r, g, b) = (0, c, x)
                case 3: (r, g, b) = (0, x, c)
                case 4: (r, g, b) = (x, 0, c)
                default: (r, g, b) = (c, 0, x)
                }
                r += m; g += m; b += m
                if let t = tint, tintAmount > 0 {
                    // 밝기는 살리고 색만 입히기 (곱하기 섞기)
                    r = r * (1 - tintAmount) + r * Double(t.r) / 255 * tintAmount * 1.4
                    g = g * (1 - tintAmount) + g * Double(t.g) / 255 * tintAmount * 1.4
                    b = b * (1 - tintAmount) + b * Double(t.b) / 255 * tintAmount * 1.4
                }
                out.px[i] = UInt8(min(255, max(0, (r * 255).rounded())))
                out.px[i + 1] = UInt8(min(255, max(0, (g * 255).rounded())))
                out.px[i + 2] = UInt8(min(255, max(0, (b * 255).rounded())))
            }
            i += 4
        }
        return out
    }
}

struct ColorAdjustSheet: View {
    @ObservedObject var doc: ImageDoc
    @Environment(\.dismiss) private var dismiss
    @State private var adj = ColorAdjust()
    @State private var tintColor: Color = Color(red: 1, green: 0.4, blue: 0.7)

    var body: some View {
        let after = adj.apply(doc.image)
        VStack(alignment: .leading, spacing: 12) {
            Text("색 조정").font(.title3.bold())
            HStack(spacing: 16) {
                preview(doc.image, "전")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                preview(after, "후")
            }
            row("색조", $adj.hue, -180...180, "°")
            row("채도", $adj.saturation, 0...2, "배")
            row("밝기", $adj.brightness, -1...1, "")
            row("대비", $adj.contrast, 0...2, "배")
            HStack {
                Text("색 입히기").frame(width: 60, alignment: .leading)
                ColorPicker("", selection: $tintColor, supportsOpacity: false).labelsHidden()
                    .onChange(of: tintColor) { syncTint() }
                Slider(value: $adj.tintAmount, in: 0...1).onChange(of: adj.tintAmount) { syncTint() }
                Text("\(Int(adj.tintAmount * 100))%").monospacedDigit().frame(width: 44)
            }
            HStack {
                Button("초기화") { adj = ColorAdjust() }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("적용") { doc.replace(with: after); dismiss() }.keyboardShortcut(.defaultAction).disabled(adj.isIdentity)
            }
        }
        .padding(20).frame(width: 460)
    }

    private func syncTint() {
        let ns = NSColor(tintColor).usingColorSpace(.sRGB) ?? .white
        adj.tint = RGBA(r: UInt8(ns.redComponent * 255), g: UInt8(ns.greenComponent * 255), b: UInt8(ns.blueComponent * 255), a: 255)
    }

    private func row(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(t).frame(width: 60, alignment: .leading)
            Slider(value: v, in: r)
            Text(String(format: unit == "°" ? "%.0f" : "%.2f", v.wrappedValue) + unit).monospacedDigit().frame(width: 56, alignment: .trailing)
        }
    }

    private func preview(_ img: PixelImage, _ label: String) -> some View {
        VStack(spacing: 4) {
            if let cg = img.cgImage() {
                Image(decorative: cg, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 170, height: 170)
                    .background(Checker())
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let c: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: c) {
                for x in stride(from: 0, to: size.width, by: c) where (Int(x / c) + Int(y / c)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: c, height: c)), with: .color(Color(white: 0.88)))
                }
            }
        }
    }
}

// MARK: - 바이옴 (색상맵 위치 계산용, jar의 data/minecraft/worldgen/biome)

struct Biome: Identifiable {
    let id: String
    let temperature: Double
    let downfall: Double
    let grassFixed: String?
    let foliageFixed: String?
    let dryFoliageFixed: String?
    let grassModifier: String?

    /// 게임의 색상맵 좌표: 온도·습도를 0~1로 자르고 습도에 온도를 곱한다
    var mapPoint: (x: Int, y: Int) {
        let t = min(1, max(0, temperature))
        let d = min(1, max(0, downfall)) * t
        return (Int((1 - t) * 255), Int((1 - d) * 255))
    }
}

extension Workspace {
    func biomes() -> [Biome] {
        guard let v = mcVersion, vanillaReady else { return [] }
        if let c = biomeCache[v.id] { return c }
        let dir = VanillaAssets.shared.dir(v).appendingPathComponent("data/minecraft/worldgen/biome")
        var out: [Biome] = []
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = (o["temperature"] as? NSNumber)?.doubleValue,
                  let df = (o["downfall"] as? NSNumber)?.doubleValue else { continue }
            let e = o["effects"] as? [String: Any] ?? [:]
            out.append(Biome(id: String(f.dropLast(5)), temperature: t, downfall: df,
                             grassFixed: e["grass_color"] as? String, foliageFixed: e["foliage_color"] as? String,
                             dryFoliageFixed: e["dry_foliage_color"] as? String, grassModifier: e["grass_color_modifier"] as? String))
        }
        out.sort { $0.id < $1.id }
        biomeCache[v.id] = out
        return out
    }
}

func colorFromHex(_ s: String) -> Color {
    let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let n = UInt32(h, radix: 16) ?? 0
    return Color(red: Double(n >> 16 & 255) / 255, green: Double(n >> 8 & 255) / 255, blue: Double(n & 255) / 255)
}

// MARK: - 환경 화면

struct EnvironmentView: View {
    @EnvironmentObject var ws: Workspace
    @State private var time: Double = 6000      // 게임 시간 (0 = 해 뜸, 6000 = 정오, 18000 = 자정)
    @State private var weather = 0              // 0 맑음, 1 비, 2 눈
    @State private var moon = "full_moon"
    @State private var colormap = "grass"
    @State private var hoverBiome: String?

    private let env = "assets/minecraft/textures/environment/"
    private let moons = ["full_moon", "waning_gibbous", "third_quarter", "waning_crescent", "new_moon", "waxing_crescent", "first_quarter", "waxing_gibbous"]
    private let moonKo = ["보름달", "기우는 볼록달", "하현달", "그믐달", "삭(안 보임)", "초승달", "상현달", "차오르는 볼록달"]

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("하늘·날씨·색").font(.title2.bold()).foregroundStyle(Theme.gradient)
                skySection
                texturesSection
                colormapSection.id("colormap")
                Text("하늘·안개·물 색과 바이옴 온도는 데이터팩(worldgen) 값이라 리소스팩으로는 못 바꿔요. 여기선 그 값을 읽어서 보여주기만 해요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["MCPE_SCROLL"] != nil { // 검증용
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { proxy.scrollTo("colormap", anchor: .top) }
            }
        }
        }
        .id(ws.assetsVersion)
        .onAppear { ws.lastMock = "mock:environment" }
    }

    // MARK: 하늘 미리보기

    private var skySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("하늘 미리보기").font(.headline)
            HStack(spacing: 14) {
                Text("시간")
                Slider(value: $time, in: 0...24000).frame(width: 220)
                Text(timeLabel).monospacedDigit().frame(width: 90, alignment: .leading)
                Picker("날씨", selection: $weather) { Text("맑음").tag(0); Text("비").tag(1); Text("눈").tag(2) }
                    .pickerStyle(.segmented).frame(width: 180)
                Picker("달", selection: $moon) {
                    ForEach(Array(moons.enumerated()), id: \.offset) { i, m in Text(moonKo[i]).tag(m) }
                }
                .frame(width: 200)
            }
            .lineLimit(1)
            GeometryReader { g in sky(g.size) }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("해·달·구름·비를 누르면 그림판으로 열려요. 위치와 크기는 느낌만 맞춘 미리보기예요.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var timeLabel: String {
        let h = (Int(time) / 1000 + 6) % 24
        let m = Int(Double(Int(time) % 1000) * 0.06)
        return String(format: "%02d:%02d (%d)", h, m, Int(time))
    }

    /// 해 높이: -1(자정) ~ 1(정오)
    private var sunHeight: Double { sin((time / 24000) * 2 * .pi) }

    private func sky(_ size: CGSize) -> some View {
        let day = max(0, min(1, sunHeight * 1.6 + 0.35))
        let rainDim = weather == 0 ? 1.0 : 0.6
        let top = Color(red: (0.02 + 0.45 * day) * rainDim, green: (0.03 + 0.62 * day) * rainDim, blue: (0.1 + 0.9 * day) * rainDim)
        let bottom = Color(red: (0.05 + 0.7 * day) * rainDim, green: (0.06 + 0.78 * day) * rainDim, blue: (0.15 + 0.85 * day) * rainDim)
        let w = size.width, h = size.height
        // 해는 시간에 따라 반원으로 돈다 (0=동쪽 지평선, 6000=꼭대기)
        let ang = (time / 24000) * 2 * Double.pi
        let cx = w / 2 - CGFloat(cos(ang)) * w * 0.42
        let cy = h * 0.92 - CGFloat(sin(ang)) * h * 0.8
        let mx = w / 2 + CGFloat(cos(ang)) * w * 0.42
        let my = h * 0.92 + CGFloat(sin(ang)) * h * 0.8
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            // 게임은 해·달을 더하기 섞기로 그려서 검은 부분이 안 보인다
            tex(env + "celestial/sun.png", 70).blendMode(.plusLighter).position(x: cx, y: cy).opacity(weather == 0 ? 1 : 0.35)
            tex(env + "celestial/moon/\(moon).png", 60).blendMode(.plusLighter).position(x: mx, y: my).opacity(weather == 0 ? 1 : 0.35)
            // 구름: 위에서 본 지도의 일부를 크게 (게임처럼 각진 구름 덩어리)
            tex(env + "clouds.png", 0, stretch: CGSize(width: w, height: 80), crop: CGRect(x: 0, y: 0, width: 96, height: 10))
                .position(x: w / 2, y: 50).opacity(0.9)
            if weather > 0 {
                let rel = env + (weather == 1 ? "rain.png" : "snow.png")
                HStack(spacing: 0) {
                    ForEach(0..<Int(w / 32) + 1, id: \.self) { _ in tex(rel, 0, stretch: CGSize(width: 32, height: h), tap: false) }
                }
                .allowsHitTesting(false)
                tex(rel, 46).position(x: w - 40, y: h - 40) // 누를 수 있는 작은 표본
            }
            // 땅
            VStack { Spacer(); Color(red: 0.36, green: 0.62, blue: 0.27).frame(height: 36) }
                .allowsHitTesting(false)
        }
    }

    /// 텍스처 하나 (누르면 편집)
    private func tex(_ rel: String, _ side: CGFloat, stretch: CGSize? = nil, crop: CGRect? = nil, tap: Bool = true) -> some View {
        Group {
            if let full = ws.pixelImage(rel), let cg = (crop.map { full.crop(CGRect(x: $0.minX * CGFloat(full.w) / 256, y: $0.minY * CGFloat(full.h) / 256,
                                                                                     width: $0.width * CGFloat(full.w) / 256, height: $0.height * CGFloat(full.h) / 256)) } ?? full).cgImage() {
                Image(decorative: cg, scale: 1).interpolation(.none).resizable()
            } else {
                Color.pink.opacity(0.4)
            }
        }
        .frame(width: stretch?.width ?? side, height: stretch?.height ?? side)
        .contentShape(Rectangle())
        .onTapGesture { if tap { ws.editAsset(rel) } }
        .help(tap ? rel.replacingOccurrences(of: "assets/minecraft/textures/", with: "") : "")
    }

    // MARK: 텍스처 목록

    private var texturesSection: some View {
        let items: [(String, String)] = [
            ("celestial/sun.png", "해"), ("clouds.png", "구름 (위에서 본 지도)"), ("rain.png", "비"), ("snow.png", "눈"),
            ("end_sky.png", "엔드 하늘"), ("celestial/end_flash.png", "엔드 섬광"),
        ] + moons.enumerated().map { ("celestial/moon/\($0.element).png", "달: " + moonKo[$0.offset]) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("하늘 그림들").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                ForEach(items, id: \.0) { f, label in
                    let rel = env + f
                    Button { ws.editAsset(rel) } label: {
                        VStack(spacing: 4) {
                            if let img = ws.pixelImage(rel), let cg = img.cgImage() {
                                Image(decorative: cg, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit)
                                    .frame(height: 64).background(Checker())
                                Text("\(img.w)x\(img.h)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(label).font(.caption.bold()).lineLimit(1)
                            Text(ws.inPack(rel) ? "팩에 있음" : "바닐라").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ws.inPack(rel) ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.2)), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 색상맵

    private var colormapSection: some View {
        let rel = "assets/minecraft/textures/colormap/\(colormap).png"
        let img = ws.pixelImage(rel)
        let biomes = ws.biomes()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("풀·잎 색상맵").font(.headline)
                Picker("", selection: $colormap) {
                    Text("풀 (grass)").tag("grass"); Text("잎 (foliage)").tag("foliage"); Text("마른 잎 (dry_foliage)").tag("dry_foliage")
                }
                .pickerStyle(.segmented).frame(width: 360)
                Spacer()
                Button("그림판으로 열기") { ws.editAsset(rel) }
            }
            Text("바이옴마다 온도·습도로 이 그림의 한 점을 골라 풀·잎 색으로 써요. 왼쪽 = 더움, 위 = 습함. 오른쪽 위 삼각형은 안 쓰여요. 점에 마우스를 올리면 바이옴 이름이 나와요.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .topLeading) {
                    if let cg = img?.cgImage() {
                        Image(decorative: cg, scale: 1).interpolation(.none).resizable().frame(width: 320, height: 320)
                    }
                    ForEach(biomes.filter { fixed($0) == nil }) { b in
                        let p = b.mapPoint
                        Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1.5))
                            .frame(width: hoverBiome == b.id ? 12 : 8, height: hoverBiome == b.id ? 12 : 8)
                            .position(x: CGFloat(p.x) / 255 * 320, y: CGFloat(p.y) / 255 * 320)
                            .onHover { hoverBiome = $0 ? b.id : (hoverBiome == b.id ? nil : hoverBiome) }
                            .help(biomeName(b.id))
                    }
                }
                .frame(width: 320, height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    if let h = hoverBiome, let b = biomes.first(where: { $0.id == h }) {
                        Text(biomeName(b.id)).font(.headline)
                        Text("온도 \(b.temperature, specifier: "%.2f") · 습도 \(b.downfall, specifier: "%.2f")").font(.caption)
                    }
                    Text("바이옴별 색 (\(biomes.count)개)").font(.subheadline.bold()).padding(.top, 4)
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], alignment: .leading, spacing: 4) {
                            ForEach(biomes) { b in
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 3).fill(color(b, img)).frame(width: 18, height: 18)
                                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.15)))
                                    Text(biomeName(b.id)).font(.caption).lineLimit(1)
                                    if fixed(b) != nil { Text("고정").font(.caption2).foregroundStyle(.orange).help("이 바이옴은 색상맵 대신 정해진 색을 써요") }
                                }
                                .onHover { if $0 { hoverBiome = b.id } }
                            }
                        }
                    }
                    .frame(height: 280)
                }
            }
        }
    }

    private func fixed(_ b: Biome) -> String? {
        switch colormap {
        case "grass": return b.grassFixed
        case "foliage": return b.foliageFixed
        default: return b.dryFoliageFixed
        }
    }

    private func color(_ b: Biome, _ img: PixelImage?) -> Color {
        if let f = fixed(b) { return colorFromHex(f) }
        guard let img, img.w >= 256, img.h >= 256 else { return .gray }
        let p = b.mapPoint
        let x = p.x * img.w / 256, y = p.y * img.h / 256
        let i = img.index(min(x, img.w - 1), min(y, img.h - 1))
        return Color(red: Double(img.px[i]) / 255, green: Double(img.px[i + 1]) / 255, blue: Double(img.px[i + 2]) / 255)
    }

    private func biomeName(_ id: String) -> String {
        let t = ws.mockText("biome.minecraft.\(id)")
        return t.hasPrefix("biome.") ? id : t
    }
}
