import AppKit
import Combine
import SwiftUI

final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    weak var desktop: DesktopIntegration?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { desktop?.makeDockMenu() }
}

enum MenuBarPlacement {
    static let positionKey = "NSStatusItem Preferred Position ResonaMenuBar"

    static func prepare(defaults: UserDefaults, system: UserDefaults?) {
        guard !defaults.bool(forKey: "menuBarSystemPlacementMigrated") else { return }
        let saved = defaults.object(forKey: positionKey) as? NSNumber
        // Replace the old rightmost seed once; preserve positions saved by Command-drag.
        if saved == nil || saved?.doubleValue == 0 {
            let wifi = system?.double(forKey: "NSStatusItem Preferred Position WiFi") ?? 0
            let controls = system?.double(forKey: "NSStatusItem Preferred Position BentoBox") ?? 0
            let battery = system?.double(forKey: "NSStatusItem Preferred Position Battery") ?? 0
            defaults.set(max(224, wifi, controls, battery) + 1, forKey: positionKey)
        }
        defaults.set(true, forKey: "menuBarSystemPlacementMigrated")
    }

    static func reservedLength(safeArea: NSRect, items: [(name: String?, frame: NSRect)]) -> CGFloat? {
        let trailing = items.sorted { $0.frame.maxX > $1.frame.maxX }
        // Window geometry remains available without permission to read other apps' window titles.
        guard let anchor = trailing.first(where: { $0.name == "WiFi" }) ??
                (trailing.count >= 4 ? trailing[3] : nil) else { return nil }
        // Leave a small notch inset and account for the status window's two 8-point end caps.
        return max(150, anchor.frame.minX - safeArea.minX - 24 - 16)
    }

    static func reservedLength(on screen: NSScreen?) -> CGFloat? {
        guard let screen, let safe = screen.auxiliaryTopRightArea else { return nil }
        let systemIDs = Set(NSWorkspace.shared.runningApplications.filter {
            ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight"].contains($0.bundleIdentifier ?? "")
        }.map(\.processIdentifier))
        let top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let items: [(name: String?, frame: NSRect)] = windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, systemIDs.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == NSWindow.Level.statusBar.rawValue,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(frame.minY - top) <= 1, frame.minX >= safe.minX, frame.maxX <= safe.maxX + 4 else { return nil }
            return (window[kCGWindowName as String] as? String, frame)
        }
        return reservedLength(safeArea: safe, items: items)
    }
}

private final class MenuBarIconButton: NSButton {
    var usesAccentColor = false { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let cell else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color: NSColor = usesAccentColor ? .systemRed : (dark ? .white : .black)
        // Vibrant menu bars can ignore contentTintColor on template button images.
        let colored = NSImage(size: image.size)
        colored.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
        colored.unlockFocus()
        colored.alignmentRect = image.alignmentRect
        colored.isTemplate = false
        let alignment = colored.alignmentRect
        let target = cell.imageRect(forBounds: bounds)
        guard alignment.width > 0, alignment.height > 0 else { return }
        let scale = min(target.width / alignment.width, target.height / alignment.height)
        // The cell positions the alignment rect; drawing the whole canvas there flattens symbols.
        let topInset = isFlipped ? colored.size.height - alignment.maxY : alignment.minY
        let destination = NSRect(x: target.midX - (alignment.midX * scale),
                                 y: target.midY - (topInset + alignment.height / 2) * scale,
                                 width: colored.size.width * scale, height: colored.size.height * scale)
        colored.draw(in: destination, from: .zero, operation: .sourceOver,
                     fraction: isEnabled ? (isHighlighted ? 0.65 : 1) : 0.35, respectFlipped: true, hints: nil)
    }
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
    @Published var menuControlsEnabled: Bool {
        didSet {
            defaults.set(menuControlsEnabled, forKey: "menuControlsEnabled")
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
    let statusItem: NSStatusItem
    let lyricButton = MenuBarLyricButton()
    private let popover = NSPopover()
    private var panel: NSPanel?
    private let previousButton = MenuBarIconButton()
    private let playButton = MenuBarIconButton()
    private let nextButton = MenuBarIconButton()
    private let favoriteButton = MenuBarIconButton()
    private var lyricWidth: NSLayoutConstraint?
    private var reservedMenuBarLength: CGFloat?

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
        menuControlsEnabled = defaults.object(forKey: "menuControlsEnabled") as? Bool ?? true
        lyricsLocked = defaults.bool(forKey: "desktopLyricsLocked")
        let size = defaults.object(forKey: "desktopLyricsFontSize") as? Double ?? 28
        fontSize = size.isFinite ? min(48, max(18, size)) : 28
        MenuBarPlacement.prepare(defaults: defaults, system: UserDefaults(suiteName: "com.apple.controlcenter"))
        reservedMenuBarLength = MenuBarPlacement.reservedLength(on: NSScreen.main)
        statusItem = NSStatusBar.system.statusItem(withLength: 0)
        super.init()
        statusItem.autosaveName = "ResonaMenuBar"
        configureStatusItem()
        // Published changes arrive before their values; render on the next main-loop turn.
        Publishers.Merge(player.objectWillChange, library.objectWillChange).receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.updateStatus()
        }.store(in: &subscriptions)
        updateStatus()
        statusItem.isVisible = true
        updatePanel()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.placePanel()
                self?.reservedMenuBarLength = MenuBarPlacement.reservedLength(on: self?.statusItem.button?.window?.screen ?? NSScreen.main)
                self?.updateStatus()
            }.store(in: &subscriptions)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Resona · 歌词与播放设置"
        button.setAccessibilityLabel("Resona 菜单栏播控")
        let menuButton = MenuBarIconButton(image: MenuBarLogo.image(),
                                          target: self, action: #selector(togglePopover(_:)))
        menuButton.toolTip = "Resona · 歌词与播放设置"
        menuButton.setAccessibilityLabel("歌词与播放设置")
        for (control, symbol, title, action) in [
            (previousButton, "backward.end.fill", "上一首", #selector(previous)),
            (playButton, "play.fill", "播放", #selector(togglePlayback)),
            (nextButton, "forward.end.fill", "下一首", #selector(next)),
            (favoriteButton, "heart", "喜欢", #selector(toggleFavorite))
        ] {
            control.image = menuImage(symbol)
            control.target = self
            control.action = action
            control.toolTip = title
            control.setAccessibilityLabel(title)
        }
        lyricButton.target = self
        lyricButton.action = #selector(togglePopover(_:))
        lyricButton.font = .menuBarFont(ofSize: 14)
        lyricButton.lineBreakMode = .byClipping
        lyricButton.cell?.usesSingleLineMode = true
        lyricButton.alignment = .center
        lyricButton.isBordered = false
        lyricButton.focusRingType = .none
        lyricButton.translatesAutoresizingMaskIntoConstraints = false
        lyricWidth = lyricButton.widthAnchor.constraint(equalToConstant: MenuBarLyricButton.maximumWidth)
        lyricWidth?.isActive = true
        lyricButton.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness).isActive = true
        let controls = [previousButton, playButton, nextButton, favoriteButton, menuButton]
        for control in controls {
            control.isBordered = false
            control.focusRingType = .none
            control.translatesAutoresizingMaskIntoConstraints = false
            control.heightAnchor.constraint(equalToConstant: NSStatusBar.system.thickness).isActive = true
            control.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let stack = NSStackView(views: [lyricButton] + controls)
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = NSHostingController(rootView: MenuPlaybackView(desktop: self))
    }

    private func menuImage(_ symbol: String) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
    }

    private func updateStatus() {
        let available = player.current != nil
        [previousButton, playButton, nextButton].forEach { $0.isEnabled = available }
        let title = player.playing ? "暂停" : "播放"
        playButton.image = menuImage(player.playing ? "pause.fill" : "play.fill")
        playButton.toolTip = title
        playButton.setAccessibilityLabel(title)
        let liked = favoriteTrack?.favorite == true
        favoriteButton.image = menuImage(liked ? "heart.fill" : "heart")
        favoriteButton.usesAccentColor = liked
        favoriteButton.toolTip = canFavorite ? (liked ? "取消喜欢" : "喜欢") : (favoriting ? "正在更新喜欢状态" : "连接服务器后可修改喜欢状态")
        favoriteButton.setAccessibilityLabel(liked ? "取消喜欢" : "喜欢")
        favoriteButton.isEnabled = canFavorite
        let line = currentLyric
        lyricButton.toolTip = lyricLines.joined(separator: "\n")
        lyricButton.setAccessibilityLabel("菜单栏歌词：\(line)")
        let controls: CGFloat = menuControlsEnabled ? 120 : 24
        let width = reservedMenuBarLength.map { max(40, $0 - controls) } ?? MenuBarLyricButton.maximumWidth
        lyricWidth?.constant = width
        lyricButton.isHidden = !menuLyricsEnabled
        [previousButton, playButton, nextButton, favoriteButton].forEach { $0.isHidden = !menuControlsEnabled }
        let active = Lyrics.playbackLines(player.lyrics, at: player.position).first
        let end = active.flatMap { current in player.lyrics.first { $0.time > current.time }?.time } ??
            max(player.duration, player.current?.duration ?? 0)
        lyricButton.update(text: line, elapsed: active.map { player.position - $0.time },
                           duration: active.map { end - $0.time }, playing: player.playing)
        let length = controls + (menuLyricsEnabled ? width : 0)
        if abs(statusItem.length - length) > 0.5 { statusItem.length = length }
    }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        @discardableResult func item(_ title: String, action: Selector? = nil, enabled: Bool = true,
                  in parent: NSMenu? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled && action != nil
            (parent ?? menu).addItem(entry)
            return entry
        }
        let available = player.current != nil
        item(available ? (player.playing ? "正在播放" : "已暂停") : "尚未播放")
        if let track = player.current {
            item(track.title).indentationLevel = 1
            item([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " - ")).indentationLevel = 1
        }
        item(player.playing ? "暂停" : "播放", action: #selector(togglePlayback), enabled: available)
        item("下一首", action: #selector(next), enabled: available)
        item("上一首", action: #selector(previous), enabled: available)
        let liked = favoriteTrack?.favorite == true
        item(liked ? "取消喜欢" : "喜欢歌曲", action: #selector(toggleFavorite), enabled: canFavorite).state = liked ? .on : .off
        let repeatItem = item("循环播放")
        let repeatMenu = NSMenu(title: "循环播放")
        repeatMenu.autoenablesItems = false
        repeatItem.submenu = repeatMenu
        repeatItem.isEnabled = true
        for mode in [PlaybackMode.sequential, .repeatAll, .repeatOne] {
            let entry = item(mode.title, action: #selector(setPlaybackMode(_:)), in: repeatMenu)
            entry.representedObject = mode.rawValue
            entry.state = player.mode == mode ? .on : .off
        }
        item("随机播放", action: #selector(toggleShuffle)).state = player.shuffle ? .on : .off
        menu.addItem(.separator())
        return menu
    }

    @objc private func setPlaybackMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PlaybackMode(rawValue: raw) else { return }
        player.mode = mode
    }

    @objc private func toggleShuffle() { player.shuffle.toggle() }

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
    @objc private func togglePopover(_ sender: NSButton) {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            popover.show(relativeTo: sender.convert(sender.bounds, to: button), of: button, preferredEdge: .minY)
        }
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
            Toggle("菜单栏播控", isOn: $desktop.menuControlsEnabled)
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
