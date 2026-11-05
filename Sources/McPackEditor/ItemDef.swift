import Foundation

/// items/*.json (아이템 모델 정의) 트리 다루기. 경로는 ["model", "cases", 0, "model"] 같은 키/번호 목록.
typealias JPath = [AnyHashable]

enum JTree {
    static func get(_ v: Any?, _ p: ArraySlice<AnyHashable>) -> Any? {
        guard let k = p.first else { return v }
        if let s = k as? String, let d = v as? [String: Any] { return get(d[s], p.dropFirst()) }
        if let i = k as? Int, let a = v as? [Any], a.indices.contains(i) { return get(a[i], p.dropFirst()) }
        return nil
    }

    /// 경로에 값 넣은 새 컨테이너를 돌려준다 (nil이면 지우기)
    static func set(_ v: Any?, _ p: ArraySlice<AnyHashable>, _ new: Any?) -> Any? {
        guard let k = p.first else { return new }
        if let s = k as? String {
            var d = v as? [String: Any] ?? [:]
            d[s] = set(d[s], p.dropFirst(), new)
            return d
        }
        if let i = k as? Int {
            var a = v as? [Any] ?? []
            guard a.indices.contains(i) else { return a }
            if p.count == 1 && new == nil { a.remove(at: i); return a }
            if let n = set(a[i], p.dropFirst(), new) { a[i] = n }
            return a
        }
        return v
    }

    static func id(_ p: JPath) -> String { p.map { "\($0)" }.joined(separator: "/") }
}

enum ItemNodeKind {
    static func short(_ t: String?) -> String {
        guard let t else { return "?" }
        return t.hasPrefix("minecraft:") ? String(t.dropFirst(10)) : t
    }

    static func label(_ node: [String: Any]) -> (title: String, detail: String) {
        let t = short(node["type"] as? String)
        switch t {
        case "model": return ("모델", ModelIDs.split(node["model"] as? String ?? "").1)
        case "select": return ("상황별 선택", propLabel(node["property"] as? String, selectProps))
        case "condition": return ("조건", propLabel(node["property"] as? String, conditionProps))
        case "range_dispatch": return ("범위", propLabel(node["property"] as? String, rangeProps))
        case "composite": return ("겹치기", "\((node["models"] as? [Any])?.count ?? 0)개")
        case "special": return ("특수 렌더러", short((node["model"] as? [String: Any])?["type"] as? String))
        case "empty": return ("안 보임", "")
        case "bundle/selected_item": return ("꾸러미 안 아이템", "")
        default: return (t, "")
        }
    }

    static func propLabel(_ p: String?, _ list: [(String, String)]) -> String {
        guard let p else { return "" }
        return list.first { $0.0 == p }?.1 ?? short(p)
    }

    /// 자식들: (가지 이름, 경로)
    static func children(_ node: [String: Any], _ path: JPath) -> [(String, JPath)] {
        var out: [(String, JPath)] = []
        switch short(node["type"] as? String) {
        case "select":
            let prop = node["property"] as? String
            for (i, c) in ((node["cases"] as? [Any]) ?? []).enumerated() {
                let w = whenList((c as? [String: Any])?["when"])
                let names = prop == "minecraft:display_context" ? w.map { contextLabel($0) } : w
                out.append((names.joined(separator: ", ") + "일 때", path + ["cases", i, "model"]))
            }
            if node["fallback"] != nil { out.append(("그 외", path + ["fallback"])) }
        case "condition":
            out.append(("참일 때", path + ["on_true"]))
            out.append(("거짓일 때", path + ["on_false"]))
        case "range_dispatch":
            for (i, e) in ((node["entries"] as? [Any]) ?? []).enumerated() {
                let th = ((e as? [String: Any])?["threshold"] as? NSNumber)?.doubleValue ?? 0
                out.append(("\(fmt(th)) 이상", path + ["entries", i, "model"]))
            }
            if node["fallback"] != nil { out.append(("기본", path + ["fallback"])) }
        case "composite":
            for i in ((node["models"] as? [Any]) ?? []).indices { out.append(("\(i + 1)번째", path + ["models", i])) }
        default: break
        }
        return out
    }

    static func whenList(_ v: Any?) -> [String] {
        if let s = v as? String { return [s] }
        if let a = v as? [Any] { return a.map { "\($0)" } }
        if let v { return ["\(v)"] }
        return []
    }

    static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    static func contextLabel(_ c: String) -> String {
        if c == "none" { return "없음(none)" }
        return displaySlots.first { $0.0 == c }?.1 ?? c
    }

    // 알려진 속성들 (바닐라 items 폴더에서 쓰는 것 + 문서에 있는 것). 목록에 없으면 직접 입력.
    static let selectProps: [(String, String)] = [
        ("minecraft:display_context", "보이는 곳 (손·인벤토리·머리…)"),
        ("minecraft:main_hand", "주로 쓰는 손"),
        ("minecraft:charge_type", "쇠뇌 장전 종류"),
        ("minecraft:trim_material", "갑옷 장식 재료"),
        ("minecraft:block_state", "블록 상태"),
        ("minecraft:local_time", "현실 시간"),
        ("minecraft:context_dimension", "있는 차원"),
        ("minecraft:context_entity_type", "들고 있는 엔티티"),
        ("minecraft:custom_model_data", "custom_model_data (명령어로 지정)"),
        ("minecraft:component", "컴포넌트 값"),
    ]
    static let conditionProps: [(String, String)] = [
        ("minecraft:using_item", "쓰는 중 (활 당기기·방패 막기)"),
        ("minecraft:broken", "부서지기 직전"),
        ("minecraft:damaged", "닳음"),
        ("minecraft:selected", "핫바에서 고름"),
        ("minecraft:carried", "마우스로 집어 듦"),
        ("minecraft:extended_view", "Shift로 자세히 보기"),
        ("minecraft:fishing_rod/cast", "낚싯대 던짐"),
        ("minecraft:bundle/has_selected_item", "꾸러미에서 고른 아이템 있음"),
        ("minecraft:has_component", "컴포넌트 있음"),
        ("minecraft:component", "컴포넌트 조건"),
        ("minecraft:keybind_down", "키 누르는 중"),
        ("minecraft:view_entity", "카메라 주인"),
        ("minecraft:custom_model_data", "custom_model_data 플래그"),
    ]
    static let rangeProps: [(String, String)] = [
        ("minecraft:use_duration", "쓴 시간 (활 당긴 정도)"),
        ("minecraft:use_cycle", "쓰는 동안 반복"),
        ("minecraft:crossbow/pull", "쇠뇌 당김"),
        ("minecraft:compass", "나침반 방향"),
        ("minecraft:time", "게임 시간 (시계)"),
        ("minecraft:damage", "닳은 정도"),
        ("minecraft:count", "개수"),
        ("minecraft:cooldown", "재사용 대기"),
        ("minecraft:bundle/fullness", "꾸러미 찬 정도"),
        ("minecraft:custom_model_data", "custom_model_data 숫자"),
    ]
    static let contexts = ["none"] + displaySlots.map { $0.0 }
}

/// 미리보기용 "지금 상황"
struct ItemContext {
    var display = "gui"
    var selects: [String: String] = [:]   // property -> 고른 값
    var conds: [String: Bool] = [:]
    var ranges: [String: Double] = [:]
}

enum ItemEval {
    /// 이 상황에서 그려질 모델 id들과 지나간 노드 경로들
    static func run(_ node: Any?, _ path: JPath, _ ctx: ItemContext, _ visited: inout Set<String>) -> [String] {
        guard let n = node as? [String: Any] else { return [] }
        visited.insert(JTree.id(path))
        switch ItemNodeKind.short(n["type"] as? String) {
        case "model":
            return (n["model"] as? String).map { [$0] } ?? []
        case "special":
            return (n["base"] as? String).map { [$0] } ?? []
        case "composite":
            var out: [String] = []
            for i in ((n["models"] as? [Any]) ?? []).indices { out += run(JTree.get(n, ["models", i]), path + ["models", i], ctx, &visited) }
            return out
        case "condition":
            let v = ctx.conds[n["property"] as? String ?? ""] ?? false
            let k = v ? "on_true" : "on_false"
            return run(n[k], path + [k], ctx, &visited)
        case "select":
            let prop = n["property"] as? String ?? ""
            let value = prop == "minecraft:display_context" ? ctx.display : ctx.selects[prop]
            for (i, c) in ((n["cases"] as? [Any]) ?? []).enumerated() {
                if let value, ItemNodeKind.whenList((c as? [String: Any])?["when"]).contains(value) {
                    return run((c as? [String: Any])?["model"], path + ["cases", i, "model"], ctx, &visited)
                }
            }
            return run(n["fallback"], path + ["fallback"], ctx, &visited)
        case "range_dispatch":
            let v = ctx.ranges[n["property"] as? String ?? ""] ?? 0
            var best: Int?
            var bestTh = -Double.infinity
            for (i, e) in ((n["entries"] as? [Any]) ?? []).enumerated() {
                let th = ((e as? [String: Any])?["threshold"] as? NSNumber)?.doubleValue ?? 0
                if th <= v && th >= bestTh { best = i; bestTh = th }
            }
            if let best { return run(JTree.get(n, ["entries", best, "model"]), path + ["entries", best, "model"], ctx, &visited) }
            return run(n["fallback"], path + ["fallback"], ctx, &visited)
        default:
            return []
        }
    }

    /// 트리 전체에서 쓰인 select/condition/range 속성과 그 값 후보 (미리보기 조작판용)
    static func controls(_ node: Any?) -> (selects: [String: [String]], conds: Set<String>, ranges: [String: Double]) {
        var s: [String: [String]] = [:], c = Set<String>(), r: [String: Double] = [:]
        func walk(_ v: Any?) {
            guard let n = v as? [String: Any] else { return }
            let prop = n["property"] as? String ?? ""
            switch ItemNodeKind.short(n["type"] as? String) {
            case "select" where prop != "minecraft:display_context":
                var vals = s[prop] ?? []
                for cs in (n["cases"] as? [Any]) ?? [] {
                    for w in ItemNodeKind.whenList((cs as? [String: Any])?["when"]) where !vals.contains(w) { vals.append(w) }
                }
                s[prop] = vals
            case "condition": c.insert(prop)
            case "range_dispatch":
                let mx = ((n["entries"] as? [Any]) ?? []).compactMap { (($0 as? [String: Any])?["threshold"] as? NSNumber)?.doubleValue }.max() ?? 1
                r[prop] = max(r[prop] ?? 0, mx)
            default: break
            }
            for (_, child) in n {
                if let d = child as? [String: Any] { walk(d) }
                if let a = child as? [Any] { for x in a { if let d = x as? [String: Any] { walk(d["model"] ?? d) } } }
            }
        }
        walk(node)
        return (s, c, r)
    }
}
