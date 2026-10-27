import AppKit
import Combine
import SwiftUI

final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
final class DesktopIntegration: NSObject, ObservableObject {
    @Published var desktopLyricsEnabled: Bool {
        didSet {
            defaults.set(desktopLyricsEnabled, forKey: "desktopLyricsEnabled")
            updatePanel()
        }
    }
    @Published var menuLyricsEnabled: Bool {
        didSet {
            defaults.set(menuLyricsEnabled, forKey: "menuLyricsEnabled")
            updateStatus()
        }
    }
    @Published var lyricsLocked: Bool {
        didSet {
            defaults.set(lyricsLocked, forKey: "desktopLyricsLocked")
            panel?.ignoresMouseEvents = lyricsLocked
        }
    }
    @Published var fontSize: Double {
        didSet {
            let bounded = fontSize.isFinite ? min(48, max(18, fontSize)) : 28
            if fontSize != bounded { fontSize = bounded }
            defaults.set(fontSize, forKey: "desktopLyricsFontSize")
        }
    }
    @Published private(set) var favoriting = false

    var openMainWindow: (() -> Void)?
    let player: PlayerModel
    let library: LibraryModel
    private let defaults: UserDefaults
    private var subscriptions = Set<AnyCancellable>()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var panel: NSPanel?
    private let previousButton = NSButton()
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let favoriteButton = NSButton()
    private let lyricButton = NSButton()
    private var lyricWidth: NSLayoutConstraint?

    var lyricLines: [String] {
        let active = Lyrics.playbackLines(player.lyrics, at: player.position).map(\.text)
        if !active.isEmpty { return active }
        guard let track = player.current else { return ["Resona · 此刻想听什么？"] }
        if !player.lyrics.isEmpty { return [track.title, "前奏 · \(track.artist)"] }
        return [track.title, player.plainLyrics.isEmpty ? "暂无歌词 · \(track.artist)" : "非同步歌词 · \(track.artist)"]
    }

    var currentLyric: String { lyricLines[0].replacingOccurrences(of: "\n", with: " ") }

    var favoriteTrack: Track? {
        guard let track = player.current else { return nil }
        return library.tracks.first(where: { $0.id == track.id }) ?? track
    }

    var canFavorite: Bool { favoriteTrack != nil && library.session != nil && !library.offline && !favoriting }

    init(player: PlayerModel, library: LibraryModel, defaults: UserDefaults = .standard) {
        self.player = player
        self.library = library
        self.defaults = defaults
        desktopLyricsEnabled = defaults.bool(forKey: "desktopLyricsEnabled")
        menuLyricsEnabled = defaults.object(forKey: "menuLyricsEnabled") as? Bool ?? true
        lyricsLocked = defaults.bool(forKey: "desktopLyricsLocked")
        let size = defaults.object(forKey: "desktopLyricsFontSize") as? Double ?? 28
        fontSize = size.isFinite ? min(48, max(18, size)) : 28
        super.init()
        configureStatusItem()
        // Published changes arrive before their values; render on the next main-loop turn.
        Publishers.Merge(player.objectWillChange, library.objectWillChange).receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.updateStatus()
        }.store(in: &subscriptions)
        updateStatus()
        updatePanel()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.placePanel() }.store(in: &subscriptions)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = "Resona · 歌词与播放设置"
        button.setAccessibilityLabel("Resona 菜单栏播控")
        let menuButton = NSButton(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!,
                                  target: self, action: #selector(togglePopover))
        menuButton.toolTip = "Resona · 歌词与播放设置"
        menuButton.setAccessibilityLabel("歌词与播放设置")
        for (control, symbol, title, action) in [
            (previousButton, "backward.end.fill", "上一首", #selector(previous)),
            (playButton, "play.fill", "播放", #selector(togglePlayback)),
            (nextButton, "forward.end.fill", "下一首", #selector(next)),
            (favoriteButton, "heart", "喜欢", #selector(toggleFavorite))
        ] {
            control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            control.target = self
            control.action = action
            control.toolTip = title
            control.setAccessibilityLabel(title)
        }
        lyricButton.target = self
        lyricButton.action = #selector(togglePopover)
        lyricButton.font = .menuBarFont(ofSize: 12)
        lyricButton.lineBreakMode = .byTruncatingTail
        lyricButton.alignment = .left
        let controls = [lyricButton, previousButton, playButton, nextButton, favoriteButton, menuButton]
        for control in controls {
            control.isBordered = false
            control.contentTintColor = .labelColor
            control.focusRingType = .none
            control.translatesAutoresizingMaskIntoConstraints = false
            control.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness).isActive = true
            if control !== lyricButton { control.widthAnchor.constraint(equalToConstant: 26).isActive = true }
        }
        lyricWidth = lyricButton.widthAnchor.constraint(equalToConstant: 0)
        lyricWidth?.isActive = true
        let stack = NSStackView(views: controls)
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: MenuPlaybackView(desktop: self))
    }

    private func updateStatus() {
        let available = player.current != nil
        [previousButton, playButton, nextButton].forEach { $0.isEnabled = available }
        let title = player.playing ? "暂停" : "播放"
        playButton.image = NSImage(systemSymbolName: player.playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playButton.toolTip = title
        playButton.setAccessibilityLabel(title)
        let liked = favoriteTrack?.favorite == true
        favoriteButton.image = NSImage(systemSymbolName: liked ? "heart.fill" : "heart", accessibilityDescription: nil)
        favoriteButton.contentTintColor = liked ? .systemRed : .labelColor
        favoriteButton.toolTip = canFavorite ? (liked ? "取消喜欢" : "喜欢") : (favoriting ? "正在更新喜欢状态" : "连接服务器后可修改喜欢状态")
        favoriteButton.setAccessibilityLabel(liked ? "取消喜欢" : "喜欢")
        favoriteButton.isEnabled = canFavorite
        let line = currentLyric
        lyricButton.title = line
        lyricButton.toolTip = lyricLines.joined(separator: "\n")
        lyricButton.setAccessibilityLabel("菜单栏歌词：\(line)")
        lyricButton.isHidden = !menuLyricsEnabled
        let width = menuLyricsEnabled ? min(220, max(60, (line as NSString).size(withAttributes: [.font: lyricButton.font!]).width + 8)) : 0
        lyricWidth?.constant = width
        statusItem.length = 146 + (menuLyricsEnabled ? width + 2 : 0)
    }

    private func updatePanel() {
        guard desktopLyricsEnabled else { panel?.orderOut(nil); return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 112),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("desktop-lyrics")
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
            window.contentView = NSHostingView(rootView: DesktopLyricsView(desktop: self))
            panel = window
            let restored = window.setFrameUsingName("ResonaDesktopLyrics")
            placePanel(centered: !restored)
            window.setFrameAutosaveName("ResonaDesktopLyrics")
        }
        panel?.ignoresMouseEvents = lyricsLocked
        panel?.orderFrontRegardless()
    }

    private func placePanel(centered: Bool = false) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(760, visible.width)
        frame.size.height = 112
        if centered { frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 56) }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    @objc private func previous() { player.previous() }
    @objc private func togglePlayback() { player.toggle() }
    @objc private func next() { player.next() }
    @objc func toggleFavorite() {
        guard canFavorite, let track = favoriteTrack else { return }
        library.error = nil
        favoriting = true
        updateStatus()
        Task {
            defer { favoriting = false; updateStatus() }
            if let updated = await library.favorite(track), player.current?.id == updated.id {
                player.current = updated
            }
        }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func showMainWindow() {
        popover.performClose(nil)
        openMainWindow?()
    }

    func quit() {
        player.savePlaybackState()
        NSApp.terminate(nil)
    }
}

private struct MenuPlaybackView: View {
    @ObservedObject var desktop: DesktopIntegration
    private var player: PlayerModel { desktop.player }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(player.current?.title ?? "Resona").font(.headline).lineLimit(2)
                Text(player.current?.artist ?? "选一首，此刻想听的歌").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(desktop.currentLyric)
                .font(.system(size: 14, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 24) {
                Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.help("上一首").accessibilityLabel("上一首")
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }
                    .help(player.playing ? "暂停" : "播放").accessibilityLabel(player.playing ? "暂停" : "播放")
                Button { player.next() } label: { Image(systemName: "forward.end.fill") }.help("下一首").accessibilityLabel("下一首")
                Button { desktop.toggleFavorite() } label: {
                    Image(systemName: desktop.favoriteTrack?.favorite == true ? "heart.fill" : "heart")
                        .foregroundStyle(desktop.favoriteTrack?.favorite == true ? Color.red : .primary)
                }.disabled(!desktop.canFavorite)
                    .help(desktop.favoriteTrack?.favorite == true ? "取消喜欢" : "喜欢")
                    .accessibilityLabel(desktop.favoriteTrack?.favorite == true ? "取消喜欢" : "喜欢")
                Spacer()
                Text("\(clock(player.position)) / \(clock(player.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.buttonStyle(.borderless).disabled(player.current == nil)
            Divider()
            Toggle("桌面歌词", isOn: $desktop.desktopLyricsEnabled)
            Toggle("锁定桌面歌词（鼠标穿透）", isOn: $desktop.lyricsLocked).disabled(!desktop.desktopLyricsEnabled)
            Toggle("菜单栏歌词", isOn: $desktop.menuLyricsEnabled)
            HStack {
                Text("歌词字号").font(.caption)
                Slider(value: $desktop.fontSize, in: 18...48, step: 1).accessibilityLabel("桌面歌词字号")
                Text("\(Int(desktop.fontSize))").font(.caption.monospacedDigit()).frame(width: 22)
            }
            if let error = desktop.library.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("打开 Resona") { desktop.showMainWindow() }
                Spacer()
                Button("退出") { desktop.quit() }
            }.buttonStyle(.borderless)
        }.padding(20).frame(width: 300).foregroundStyle(Theme.ink)
            .background(Theme.paper).tint(Theme.accent).preferredColorScheme(.light)
    }
}

private struct DesktopLyricsView: View {
    @ObservedObject var desktop: DesktopIntegration
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                Image(systemName: "line.3.horizontal").help("拖动空白处移动歌词")
                Button { desktop.player.previous() } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("上一首").disabled(desktop.player.current == nil)
                Button { desktop.player.toggle() } label: { Image(systemName: desktop.player.playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(desktop.player.playing ? "暂停" : "播放").disabled(desktop.player.current == nil)
                Button { desktop.player.next() } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("下一首").disabled(desktop.player.current == nil)
                Spacer()
                Button { desktop.lyricsLocked = true } label: { Image(systemName: "lock") }
                    .help("锁定后鼠标穿透，可在菜单栏解锁").accessibilityLabel("锁定桌面歌词")
                Button { desktop.desktopLyricsEnabled = false } label: { Image(systemName: "xmark") }
                    .help("关闭桌面歌词").accessibilityLabel("关闭桌面歌词")
            }.font(.system(size: 13)).buttonStyle(.plain)
                .opacity(hovered && !desktop.lyricsLocked ? 1 : 0)
                .allowsHitTesting(hovered && !desktop.lyricsLocked)
                .accessibilityHidden(!hovered || desktop.lyricsLocked)
            Text(desktop.currentLyric).font(.system(size: desktop.fontSize, weight: .semibold))
                .shadow(color: .black, radius: 2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.9), radius: 4, x: 0, y: 2)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .help(desktop.currentLyric)
        }.padding(.horizontal, 22).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(hovered && !desktop.lyricsLocked ? .black.opacity(0.72) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .onHover { hovered = $0 }
            .onChange(of: desktop.lyricsLocked) { _, _ in hovered = false }
    }
}
