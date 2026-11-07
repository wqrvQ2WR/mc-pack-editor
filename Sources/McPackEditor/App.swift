import AppKit
import SwiftUI

enum Theme {
    /// 0 시스템 따라, 1 밝게, 2 어둡게 (기본은 밝게)
    static var appearanceMode: Int { UserDefaults.standard.object(forKey: "appearance") as? Int ?? 1 }

    static func applyAppearance() {
        switch appearanceMode {
        case 0: NSApp.appearance = nil
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    static var colorScheme: ColorScheme? {
        switch appearanceMode { case 0: return nil; case 2: return .dark; default: return .light }
    }

    /// 3D 뷰 배경 (밝을 땐 하늘색, 어두울 땐 남색)
    static func sceneBackground(for v: NSView) -> NSColor {
        v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.24, alpha: 1)
            : NSColor(calibratedRed: 0.82, green: 0.9, blue: 1, alpha: 1)
    }

    static let gradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.36, blue: 0.62), Color(red: 1.0, green: 0.62, blue: 0.2), Color(red: 0.25, green: 0.78, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Theme.applyAppearance()
        // 검증/자동화용: 실행 인자로 폴더를 주면 바로 연다
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let p = args.first, FileManager.default.fileExists(atPath: p) {
            Workspace.shared.open(URL(fileURLWithPath: p))
            if args.count > 1 {
                let a = args[args.index(after: args.startIndex)]
                Workspace.shared.pendingSelection = (a.hasPrefix("mock:") || a.hasPrefix("tex:") || a.hasPrefix("ctab:") || a == "changes") ? a : URL(fileURLWithPath: p).appendingPathComponent(a).path
            }
        } else {
            Workspace.shared.reopenLast()
        }
        if let sel = ProcessInfo.processInfo.environment["MCPE_SEL"] { Workspace.shared.pendingSelection = sel } // 검증용
        if ProcessInfo.processInfo.environment["MCPE_NEWPACK"] != nil { Workspace.shared.showNewPack = true } // 검증용
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let n = Workspace.shared.dirtyCount
        guard n > 0 else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "저장 안 한 파일이 \(n)개 있어요"
        a.addButton(withTitle: "모두 저장하고 종료")
        a.addButton(withTitle: "저장 안 하고 종료")
        a.addButton(withTitle: "취소")
        switch a.runModal() {
        case .alertFirstButtonReturn: Workspace.shared.saveAll(); return .terminateNow
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

@main
struct McPackEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var ws = Workspace.shared
    @AppStorage("appearance") private var appearance = 1

    var body: some Scene {
        WindowGroup("MC 팩 편집기") {
            ContentView()
                .environmentObject(ws)
                .preferredColorScheme(appearance == 0 ? nil : appearance == 2 ? .dark : .light)
                .onChange(of: appearance) { Theme.applyAppearance() }
                .frame(minWidth: 1100, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 팩 만들기…") { ws.showNewPack = true }.keyboardShortcut("n", modifiers: .command)
                Button("폴더 열기…") { ws.openPanel() }.keyboardShortcut("o", modifiers: .command)
                Button("처음 화면으로") { ws.closePack() }.disabled(ws.root == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("모두 저장") { ws.saveAll() }.keyboardShortcut("s", modifiers: .command)
                Button("zip으로 내보내기…") { ws.exportZip() }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(ws.root == nil)
                Button("마인크래프트에 설치") { ws.installToMinecraft() }.disabled(ws.root == nil)
            }
            CommandGroup(after: .toolbar) {
                Picker("화면 모드", selection: $appearance) {
                    Text("밝게").tag(1); Text("어둡게").tag(2); Text("시스템 따라").tag(0)
                }
            }
            CommandGroup(after: .sidebar) {
                Button("새로고침") { ws.reload() }.keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
