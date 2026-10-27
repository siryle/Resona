import SwiftUI
import AppKit

@main
struct ResonaDesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var appDelegate
    @StateObject private var library: LibraryModel
    @StateObject private var player: PlayerModel
    @StateObject private var desktop: DesktopIntegration
    @State private var showingSettings = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryModel()
        let player = PlayerModel()
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: player)
        _desktop = StateObject(wrappedValue: DesktopIntegration(player: player, library: library))
    }

    var body: some Scene {
        Window("Resona", id: "main") {
            DesktopView(showingSettings: $showingSettings)
                .environmentObject(library).environmentObject(player).environmentObject(desktop)
                .tint(Theme.accent).preferredColorScheme(.light)
                .frame(minWidth: 920, minHeight: 620)
                .task {
                    desktop.openMainWindow = {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    player.restorePlayback(session: library.session)
                    await library.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { player.savePlaybackState() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    player.savePlaybackState()
                }
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
                Divider()
                Toggle("桌面歌词", isOn: $desktop.desktopLyricsEnabled)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Toggle("锁定桌面歌词（鼠标穿透）", isOn: $desktop.lyricsLocked)
                    .disabled(!desktop.desktopLyricsEnabled)
                Toggle("菜单栏歌词", isOn: $desktop.menuLyricsEnabled)
                Toggle("菜单栏播控", isOn: $desktop.menuControlsEnabled)
            }
        }
    }
}
