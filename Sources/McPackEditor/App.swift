import AppKit
import SwiftUI

enum Theme {
    static let gradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.36, blue: 0.62), Color(red: 1.0, green: 0.62, blue: 0.2), Color(red: 0.25, green: 0.78, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        // 검증/자동화용: 실행 인자로 폴더를 주면 바로 연다
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let p = args.first, FileManager.default.fileExists(atPath: p) {
            Workspace.shared.open(URL(fileURLWithPath: p))
            if args.count > 1 {
                let a = args[args.index(after: args.startIndex)]
                Workspace.shared.selection = a.hasPrefix("mock:") ? a : URL(fileURLWithPath: p).appendingPathComponent(a).path
            }
        } else {
            Workspace.shared.reopenLast()
        }
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

    var body: some Scene {
        WindowGroup("MC 팩 편집기") {
            ContentView()
                .environmentObject(ws)
                .preferredColorScheme(.light)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("폴더 열기…") { ws.openPanel() }.keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("모두 저장") { ws.saveAll() }.keyboardShortcut("s", modifiers: .command)
                Button("zip으로 내보내기…") { ws.exportZip() }
                    .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(ws.root == nil)
                Button("마인크래프트에 설치") { ws.installToMinecraft() }.disabled(ws.root == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("새로고침") { ws.reload() }.keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
