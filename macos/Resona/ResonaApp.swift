import SwiftUI
import AppKit

@main
struct ResonaDesktopApp: App {
    @StateObject private var library = LibraryModel()
    @StateObject private var player = PlayerModel()
    @State private var showingSettings = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Resona", id: "main") {
            DesktopView(showingSettings: $showingSettings)
                .environmentObject(library).environmentObject(player)
                .tint(Theme.accent).preferredColorScheme(.light)
                .frame(minWidth: 920, minHeight: 620)
                .task { await library.refresh() }
                .onChange(of: library.session?.token) { _, _ in
                    player.connectionChanged(library.session)
                }
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    openWindow(id: "main")
                    player.expanded = false
                    showingSettings = true
                }.keyboardShortcut(",")
            }
            CommandGroup(after: .newItem) {
                Button("刷新音乐库") { Task { await library.refresh() } }.keyboardShortcut("r")
            }
            CommandMenu("播放") {
                Button(player.playing ? "暂停" : "播放") { player.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("下一首") { player.next() }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("上一首") { player.previous() }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("随机播放") { player.shuffle.toggle() }
                Button("切换播放模式") { player.cycleMode() }
            }
        }
    }
}

enum Theme {
    static let paper = Color(red: 0.965, green: 0.957, blue: 0.937)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.15)
    static let accent = Color(red: 0.77, green: 0.35, blue: 0.22)
    static let sage = Color(red: 0.89, green: 0.92, blue: 0.85)
    static let muted = Color(red: 0.52, green: 0.56, blue: 0.48)
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
}
