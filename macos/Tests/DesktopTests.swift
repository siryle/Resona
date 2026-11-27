import AVFoundation
import AppKit
import AudioToolbox
import CommonCrypto
import CoreAudio
import CryptoKit
import Darwin
import SwiftUI

private final class DesktopTestWindow: NSWindow {
    // Keep scripted content coordinates stable on smaller CI displays.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main
struct DesktopTests {
    @MainActor static func settle(until condition: () -> Bool = { true }) {
        let deadline = Date(timeIntervalSinceNow: 3)
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        } while !condition() && Date() < deadline
    }

    static func credentialsTests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resona-credentials-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.json")
        assert(Credentials.load(from: file) == nil, "Missing session file must return nil")

        let first = Session(server: URL(string: "https://music.example.com/")!, username: "admin", token: "token-1")
        let second = Session(server: URL(string: "https://music.example.com/")!, username: "admin", token: "token-2")
        try Credentials.save(first, to: file)
        let loadedFirst = Credentials.load(from: file)
        assert(loadedFirst?.server == first.server && loadedFirst?.username == first.username &&
               loadedFirst?.token == first.token, "Saved macOS session did not round-trip")

        let firstAttrs = try FileManager.default.attributesOfItem(atPath: file.path)
        assert((firstAttrs[.posixPermissions] as? Int) == 0o600, "macOS session file must keep 0600 permissions")
        let resourceValues = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        assert(resourceValues.isExcludedFromBackup == true, "macOS session file must be excluded from backups")

        try Credentials.save(second, to: file)
        let loadedSecond = Credentials.load(from: file)
        assert(loadedSecond?.token == second.token, "Saving must atomically replace an existing session")
        let secondAttrs = try FileManager.default.attributesOfItem(atPath: file.path)
        assert((secondAttrs[.posixPermissions] as? Int) == 0o600, "Replaced session file must preserve 0600 permissions")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".session-") }
        assert(leftovers.isEmpty, "Atomic session save must not leave temporary files behind")

        let decoy = root.appendingPathComponent("decoy.json")
        let decoyBytes = try JSONEncoder().encode(first)
        try decoyBytes.write(to: decoy)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: decoy)
        assert(Credentials.load(from: file) == nil, "Refuse to follow symlinks when loading credentials")

        try Credentials.save(second, to: file)
        let replacedAttrs = try FileManager.default.attributesOfItem(atPath: file.path)
        assert((replacedAttrs[.type] as? FileAttributeType) == .typeRegular,
               "Saving over a symlink must replace it with a regular file")
        assert((replacedAttrs[.posixPermissions] as? Int) == 0o600)
        assert(Credentials.load(from: file)?.token == second.token)
        let currentDecoy = try Data(contentsOf: decoy)
        assert(currentDecoy == decoyBytes, "Symlink target must remain untouched")

        Credentials.clear(at: file)
        assert(!FileManager.default.fileExists(atPath: file.path) && Credentials.load(from: file) == nil)
        Credentials.clear(at: file)
    }

    @MainActor static func audioOutputTests() {
        assert(PlayerModel.classifyTransport(kAudioDeviceTransportTypeAirPlay) == .airPlay)
        assert(PlayerModel.classifyTransport(kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        assert(PlayerModel.classifyTransport(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        assert(PlayerModel.classifyTransport(kAudioDeviceTransportTypeBuiltIn) == .speaker)
        assert(PlayerModel.classifyTransport(kAudioDeviceTransportTypeUSB) == .headphones)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resona-audio-output-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OfflineStore(root: root.appendingPathComponent("downloads"))
        let cache = PlaybackCache(root: root.appendingPathComponent("cache"))
        let model = PlayerModel(downloads: store, cache: cache)

        let builtIn = AudioOutputDevice(id: "BuiltInSpeaker", name: "MacBook Speakers", kind: .speaker, isDefault: true)
        let bluetooth = AudioOutputDevice(id: "BT-AirPods", name: "AirPods Pro", kind: .bluetooth, isDefault: false)
        let airPlay = AudioOutputDevice(id: "AirPlay-HomePod", name: "HomePod", kind: .airPlay, isDefault: false)

        model.handleAudioOutputChange(devices: [builtIn, bluetooth, airPlay])
        assert(model.availableOutputs.count == 3)
        assert(model.activeOutput.id == builtIn.id && !model.airPlayActive)

        model.selectAudioOutput(bluetooth.id)
        assert(model.selectedOutputUID == bluetooth.id)
        assert(model.avPlayer.audioOutputDeviceUniqueID == bluetooth.id)
        assert(model.activeOutput.id == bluetooth.id)

        model.playing = true
        model.handleAudioOutputChange(devices: [builtIn, airPlay])
        assert(!model.playing, "Disconnecting the active Bluetooth device must pause playback")
        assert(model.selectedOutputUID == nil && model.avPlayer.audioOutputDeviceUniqueID == nil)
        assert(model.activeOutput.id == builtIn.id)

        model.selectAudioOutput(airPlay.id)
        assert(model.airPlayActive, "Selecting an AirPlay device must report active AirPlay state")
        model.prepareForAirPlayRouting()
        assert(model.selectedOutputUID == nil && model.avPlayer.audioOutputDeviceUniqueID == nil)
    }

    @MainActor static func playbackRateTests() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = OfflineStore(root: root.appendingPathComponent("downloads"))
        let cache = PlaybackCache(root: root.appendingPathComponent("cache"))
        let model = PlayerModel(downloads: store, cache: cache)
        assert(PlayerModel.supportedPlaybackRates.count == 16 &&
               PlayerModel.supportedPlaybackRates.first == 0.5 &&
               PlayerModel.supportedPlaybackRates.last == 2.0,
               "macOS supported playback rates must cover 0.5x to 2.0x per 0.1x")
        assert(model.playbackRate == 1.0 && model.avPlayer.defaultRate == 1.0)
        model.stepPlaybackRate(by: 2)
        assert(model.playbackRate == 1.2 && PlayerModel.formatPlaybackRate(model.playbackRate) == "1.2x")
        assert(PlayerModel.formatCompactPlaybackRate(0.5) == "0.5x" &&
               PlayerModel.formatCompactPlaybackRate(1.0) == "1x" &&
               PlayerModel.formatCompactPlaybackRate(1.2) == "1.2x" &&
               PlayerModel.formatCompactPlaybackRate(1.5) == "1.5x" &&
               PlayerModel.formatCompactPlaybackRate(2.0) == "2x")
        model.stepPlaybackRate(by: 100)
        assert(model.playbackRate == 2.0)
        model.stepPlaybackRate(by: -100)
        assert(model.playbackRate == 0.5)
        model.setPlaybackRate(.nan)
        assert(model.playbackRate == 1.0)
    }

    static func placementTests() {
        let domain = "app.resona.placement-tests." + UUID().uuidString
        let systemDomain = domain + ".system"
        let defaults = UserDefaults(suiteName: domain)!
        let system = UserDefaults(suiteName: systemDomain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            system.removePersistentDomain(forName: systemDomain)
        }
        system.set(240, forKey: "NSStatusItem Preferred Position WiFi")
        system.set(150, forKey: "NSStatusItem Preferred Position BentoBox")
        defaults.set(0, forKey: MenuBarPlacement.positionKey)
        MenuBarPlacement.prepare(defaults: defaults, system: system)
        assert(defaults.integer(forKey: MenuBarPlacement.positionKey) == 241,
               "The old rightmost seed must move to the left of the system cluster")
        defaults.set(0, forKey: MenuBarPlacement.positionKey)
        MenuBarPlacement.prepare(defaults: defaults, system: system)
        assert(defaults.integer(forKey: MenuBarPlacement.positionKey) == 0,
               "Migration must run only once, including a later drag to the far right")
        defaults.removeObject(forKey: "menuBarSystemPlacementMigrated")
        defaults.set(400, forKey: MenuBarPlacement.positionKey)
        MenuBarPlacement.prepare(defaults: defaults, system: system)
        assert(defaults.integer(forKey: MenuBarPlacement.positionKey) == 400,
               "Existing custom positions must survive migration")
        let safe = NSRect(x: 825, y: 924, width: 645, height: 32)
        let items = [
            (name: "Battery", frame: NSRect(x: 1159, y: 0, width: 42, height: 33)),
            (name: "WiFi", frame: NSRect(x: 1201, y: 0, width: 38, height: 33)),
            (name: "Item-0", frame: NSRect(x: 1239, y: 0, width: 32, height: 33)),
            (name: "BentoBox-0", frame: NSRect(x: 1271, y: 0, width: 42, height: 33)),
            (name: "Clock", frame: NSRect(x: 1313, y: 0, width: 159, height: 33))
        ]
        assert(MenuBarPlacement.reservedLength(safeArea: safe, items: items) == 336,
               "Reserve the segment up to Wi-Fi, excluding battery and other items")
        assert(MenuBarPlacement.reservedLength(safeArea: safe, items: items.map { (nil, $0.frame) }) == 336,
               "Placement must also work when window titles require screen-recording permission")
        assert(MenuBarPlacement.reservedLength(safeArea: safe, items: []) == nil,
               "Unavailable system geometry must fall back to the compact item")
    }

    static func selectionTests(_ track: Track) {
        func song(_ id: String, _ title: String, _ artist: String, _ album: String, liked: Bool = false) -> Track {
            Track(id: id, title: title, artist: artist, albumArtist: artist, album: album, year: "2026", number: 1,
                  disc: 1, duration: 12, format: "flac", bitrate: 1000000, sampleRate: 44100, artwork: nil, favorite: liked)
        }
        let a = song("a", "秋风词", "龚一", "古琴演奏法", liked: true)
        let b = song("b", "爱情", "刘惜君", "爱情")
        let c = song("c", "Love 2", "Singer", "Album")
        let d = song("d", "Love 10", "Singer", "Album")
        let songs = [d, b, a, c, track]
        var selection = TrackSelection()
        assert(selection.filtered(songs, downloadedIDs: []).count == 5)
        assert(!selection.allSelected(in: []))
        selection.query = "  love  "
        assert(selection.filtered(songs, downloadedIDs: []).map(\.id) == ["d", "c"], "Search trims spaces and ignores case")
        selection.toggleAll(in: selection.filtered(songs, downloadedIDs: []))
        assert(selection.selectedIDs == ["c", "d"])
        selection.query = "古琴"
        assert(selection.filtered(songs, downloadedIDs: []).map(\.id) == ["a"])
        selection.toggleAll(in: selection.filtered(songs, downloadedIDs: []))
        assert(selection.selectedIDs == ["a", "c", "d"], "Selecting results must preserve hidden selections")
        selection.toggleAll(in: [a])
        assert(selection.selectedIDs == ["c", "d"], "Deselecting results must preserve hidden selections")
        selection.query = "Singer"
        selection.searchField = .title
        assert(selection.filtered(songs, downloadedIDs: []).isEmpty)
        selection.searchField = .artist
        assert(selection.filtered(songs, downloadedIDs: []).map(\.id) == ["d", "c"])
        selection.searchField = .album
        selection.query = "古琴"
        assert(selection.filtered(songs, downloadedIDs: []).map(\.id) == ["a"])
        selection.query = ""
        selection.favoritesOnly = true
        selection.downloadsOnly = true
        assert(selection.filtered(songs, downloadedIDs: ["b"]).isEmpty)
        assert(selection.filtered(songs, downloadedIDs: ["a"]).map(\.id) == ["a"])
        selection.favoritesOnly = false
        selection.downloadsOnly = false
        assert(selection.filtered([d, c, c], downloadedIDs: []).map(\.id) == ["d", "c", "c"],
               "Filtering must preserve the collection's original order")
        assert(selection.selected(in: songs).map(\.id) == ["d", "c"], "Queue additions preserve source order")
        assert(selection.selected(in: [a]).isEmpty, "Out-of-scope or deleted tracks cannot be appended")
        selection.toggle("c")
        selection.toggleAll(in: [])
        assert(selection.selectedIDs == ["d"])
    }

    @MainActor static func menuLyricTests() {
        let button = MenuBarLyricButton(frame: NSRect(x: 0, y: 0, width: 216, height: 22))
        button.font = .menuBarFont(ofSize: 14)
        button.update(text: "Short", elapsed: 0, playing: false)
        let center = button.textDrawingRect.midX
        button.update(text: "A longer line", elapsed: 0, playing: false)
        assert(abs(button.textDrawingRect.midX - center) < 0.01 && center == button.viewport.midX,
               "Short lines must share the same center inside the fixed lyric viewport")
        assert(button.viewport.width == 182 && button.viewport.maxX == button.bounds.maxX - 1)
        let long = String(repeating: "Long lyric ", count: 8)
        button.update(text: long, elapsed: 0, duration: 8, playing: false)
        assert(button.textDrawingRect.minX == button.viewport.minX, "A long line must start at its head")
        button.update(text: long, elapsed: 0.1, duration: 8, playing: false)
        assert(button.textDrawingRect.minX == button.viewport.minX, "The head must remain readable before scrolling")
        button.update(text: long, elapsed: 100, duration: 8, playing: false)
        assert(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ||
               abs(button.textDrawingRect.maxX - button.viewport.maxX) < 0.01,
               "Scrolling must stop at the tail without wrapping or restarting")
        button.update(text: long, elapsed: 4, duration: 8, playing: false)
        let paused = button.textDrawingRect
        button.update(text: long, elapsed: 2, duration: 4, playing: false)
        assert(button.textDrawingRect == paused, "Equal line progress must produce the same offset at different speeds")
        settle()
        assert(button.textDrawingRect == paused, "Paused playback must freeze the lyric offset")
        button.update(text: long, elapsed: 0, duration: 8, playing: false)
        assert(button.textDrawingRect.minX == button.viewport.minX, "Seeking or repeating a line must reset its head")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.update(text: long, elapsed: 4, duration: 8, playing: true)
            let start = button.textDrawingRect.minX
            settle()
            assert(button.textDrawingRect.minX < start, "Scrolling must advance between player position samples")
            button.update(text: long, elapsed: 4, duration: 8, playing: false)
            let stopped = button.textDrawingRect
            settle()
            assert(button.textDrawingRect == stopped, "Pausing between position samples must preserve the visible offset")
            button.update(text: long, elapsed: 4, duration: 8, playing: true)
            assert(abs(button.textDrawingRect.minX - stopped.minX) < 1, "Resuming must not jump back to the last raw sample")
        }
        button.update(text: long, elapsed: nil, playing: true)
        assert(button.textDrawingRect.minX == button.viewport.minX, "Unsynchronized metadata must not invent lyric timing")
        button.update(text: "Next line", elapsed: 0, playing: false)
        assert(button.textDrawingRect.midX == center, "Changing lines must restore the fixed center")
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let domain = "app.resona.desktop-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = OfflineStore(root: root.appendingPathComponent("downloads"))
        let cache = PlaybackCache(root: root.appendingPathComponent("cache"))
        let player = PlayerModel(downloads: store, cache: cache)
        let library = LibraryModel(downloads: store, persistsSession: false, cache: cache)
        player.volume = 0
        menuLyricTests()
        placementTests()
        audioOutputTests()
        try raopTests()
        playbackRateTests()
        try credentialsTests()
        MenuBarPlacement.prepare(defaults: defaults, system: UserDefaults(suiteName: "com.apple.controlcenter"))
        let oldPosition = UserDefaults.standard.object(forKey: MenuBarPlacement.positionKey)
        UserDefaults.standard.set(defaults.double(forKey: MenuBarPlacement.positionKey), forKey: MenuBarPlacement.positionKey)
        defer {
            if let oldPosition { UserDefaults.standard.set(oldPosition, forKey: MenuBarPlacement.positionKey) }
            else { UserDefaults.standard.removeObject(forKey: MenuBarPlacement.positionKey) }
        }
        let desktop = DesktopIntegration(player: player, library: library, defaults: defaults)
        let delegate = DesktopAppDelegate()
        delegate.desktop = desktop
        let emptyDock = delegate.applicationDockMenu(NSApp)!
        assert(emptyDock.items.first?.title == "尚未播放")
        assert(emptyDock.items.filter { ["播放", "下一首", "上一首", "喜欢歌曲"].contains($0.title) }.allSatisfy { !$0.isEnabled })
        let status = desktop.statusItem.button!
        let lyrics = desktop.lyricButton
        let stack = status.subviews.compactMap { $0 as? NSStackView }.first!
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0 !== lyrics }
        assert(buttons.count == 5, "Compact menu bar must contain previous, play, next, favorite and settings")
        assert(buttons[0...2].allSatisfy { !$0.isEnabled }, "Empty player controls must be disabled")
        assert(!buttons[3].isEnabled, "Favorite must be disabled without a song and server connection")
        assert(desktop.lyricLines == ["Resona · 此刻想听什么？"])
        assert(!desktop.desktopLyricsEnabled && desktop.menuLyricsEnabled && desktop.menuControlsEnabled && desktop.menuIconEnabled)
        assert(desktop.statusItem.autosaveName == "ResonaMenuBar")
        assert(lyrics.window === status.window && buttons.allSatisfy { $0.window === status.window },
               "Lyrics and every playback control must occupy the same native status item")
        assert(defaults.double(forKey: MenuBarPlacement.positionKey) > 0)
        desktop.menuControlsEnabled = false
        settle()
        assert(buttons[0...3].allSatisfy(\.isHidden) && !buttons[4].isHidden)
        assert(!lyrics.isHidden && desktop.statusItem.isVisible, "Lyrics can remain visible with playback controls off")
        desktop.menuLyricsEnabled = false
        settle()
        assert(lyrics.isHidden && desktop.statusItem.length == 24, "The app logo remains when both switches are off")
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        buttons[4].performClick(nil)
        settle()
        let popup = NSApp.windows.first { $0.isVisible && !existingWindows.contains($0.windowNumber) }!
        if let screen = status.window?.screen ?? NSScreen.main {
            let contentInWindow = popup.contentView!.convert(popup.contentView!.bounds, to: nil)
            let contentOnScreen = popup.convertToScreen(contentInWindow)
            assert(contentOnScreen.height <= screen.visibleFrame.height &&
                   contentOnScreen.maxY <= screen.visibleFrame.maxY + 2 &&
                   contentOnScreen.minY >= screen.frame.minY,
                   "Menu bar popover content \(contentOnScreen) must fit inside screen \(screen.frame) without covering the menu bar")
            if (status.window?.frame.minY ?? 0) >= screen.visibleFrame.maxY - 1,
               abs(contentOnScreen.maxY - screen.visibleFrame.maxY) < 60 {
                assert(contentOnScreen.minY >= screen.visibleFrame.minY,
                       "Menu bar popover content \(contentOnScreen) must stay within visible screen \(screen.visibleFrame)")
            }
        }
        desktop.menuIconEnabled = false
        settle(until: { !popup.isVisible })
        assert(!desktop.statusItem.isVisible && desktop.statusItem.length == 0,
               "Disabling all menu bar content must remove the entire status item")
        assert(!popup.isVisible, "Hiding the entire status item must dismiss its popover")
        let saved = DesktopIntegration(player: player, library: library, defaults: defaults)
        assert(!saved.menuIconEnabled && !saved.statusItem.isVisible,
               "The hidden icon and status item must stay hidden after reopening")
        saved.menuIconEnabled = true
        assert(saved.statusItem.isVisible && saved.statusItem.length == 24,
               "The icon must be recoverable when all menu bar content was hidden")
        NSStatusBar.system.removeStatusItem(saved.statusItem)
        for showLyrics in [false, true] {
            for showControls in [false, true] {
                for showIcon in [false, true] {
                    desktop.menuLyricsEnabled = showLyrics
                    desktop.menuControlsEnabled = showControls
                    desktop.menuIconEnabled = showIcon
                    settle()
                    assert(lyrics.isHidden == !showLyrics && buttons[4].isHidden == !showIcon)
                    assert(buttons[0...3].allSatisfy { $0.isHidden == !showControls })
                    assert(desktop.statusItem.isVisible == (showLyrics || showControls || showIcon))
                    if desktop.statusItem.isVisible {
                        assert(abs(stack.fittingSize.width - desktop.statusItem.length) <= 1,
                               "Every combination must allocate only the visible menu bar content")
                    }
                    if !showLyrics {
                        assert(desktop.statusItem.length == CGFloat((showControls ? 96 : 0) + (showIcon ? 24 : 0)))
                    }
                    assert(defaults.bool(forKey: "menuIconEnabled") == showIcon)
                }
            }
        }
        desktop.menuLyricsEnabled = true
        desktop.menuControlsEnabled = true
        assert(defaults.object(forKey: "menuControlsEnabled") as? Bool == true)
        settle()
        assert(abs(stack.fittingSize.width - desktop.statusItem.length) <= 1,
               "Combined allocation: stack \(stack.fittingSize.width), item \(desktop.statusItem.length)")
        assert(lyrics.font?.pointSize == 14 && buttons.allSatisfy { abs($0.alignmentRect(forFrame: $0.frame).width - 24) < 0.5 },
               "Lyrics and all five controls must use the full-size menu bar layout")
        let statusFrame = status.window!.frame
        if let safe = status.window?.screen?.auxiliaryTopRightArea {
            assert(statusFrame.minX >= safe.minX && statusFrame.maxX <= safe.maxX,
                   "Initial combined item must not be parked behind the notch")
        }
        let reservedLength = desktop.statusItem.length

        let audio = root.appendingPathComponent("song.mp3")
        let data = try Data(contentsOf: audio)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let track = Track(id: id, title: "Test Song", artist: "Resona", albumArtist: "Resona", album: "Test Album",
                          year: "2026", number: 1, disc: 1, duration: 12, format: "mp3", bitrate: 128000,
                          sampleRate: 44100, artwork: nil, favorite: false)
        selectionTests(track)
        try JSONEncoder().encode(track).write(to: root.appendingPathComponent("track.json"))
        try store.save(track, temporary: audio, cover: nil, lyrics: nil)
        player.append([track], session: nil)
        player.lyrics = Lyrics.parse("[00:01]First line\n[00:03]Second line\n[00:06]Last line")
        player.position = 0
        settle()
        assert(desktop.lyricLines == ["Test Song", "前奏 · Resona"])
        assert(buttons[0...2].allSatisfy(\.isEnabled))
        player.position = 1
        settle()
        assert(desktop.lyricLines == ["First line", "Second line"])
        assert(lyrics.title == "First line", "Menu bar must follow the active lyric")
        player.position = 6
        settle()
        assert(desktop.lyricLines == ["Last line"] && lyrics.title == "Last line")
        player.position = 3
        settle()
        assert(desktop.lyricLines == ["Second line", "Last line"], "Backward seeks must restore lyrics")
        player.lyrics = []
        settle()
        assert(desktop.lyricLines == ["Test Song", "暂无歌词 · Resona"])
        player.plainLyrics = "Unsynchronized text"
        assert(desktop.lyricLines == ["Test Song", "非同步歌词 · Resona"])
        desktop.menuLyricsEnabled = false
        settle()
        assert(lyrics.isHidden && desktop.statusItem.length == 120)
        assert(buttons[0...2].allSatisfy { !$0.isHidden && $0.isEnabled }, "Hiding lyrics must preserve resident controls")
        desktop.menuLyricsEnabled = true
        player.lyrics = Lyrics.parse("[00:00]" + String(repeating: "很长的歌词", count: 20))
        player.position = 0
        settle()
        assert(abs(desktop.statusItem.length - reservedLength) <= 1 && abs(stack.fittingSize.width - reservedLength) <= 1,
               "Long lyrics must truncate without pushing controls out of their allocation")
        assert(abs(status.window!.frame.minX - statusFrame.minX) <= 1 &&
               abs(status.window!.frame.maxX - statusFrame.maxX) <= 1,
               "Switches and lyric updates must preserve the native menu bar position")
        for control in buttons {
            let icon = control.cell!.imageRect(forBounds: control.bounds)
            assert(status.bounds.contains(control.convert(icon, to: status)),
                   "Every playback icon must remain inside the actual status button")
        }
        let playbackIconHeight = buttons[0].cell!.imageRect(forBounds: buttons[0].bounds).height
        assert(buttons[3].cell!.imageRect(forBounds: buttons[3].bounds).height >= playbackIconHeight &&
               buttons[4].cell!.imageRect(forBounds: buttons[4].bounds).height >= playbackIconHeight,
               "Favorite and app entry must have at least the visual height of playback icons")
        desktop.menuLyricsEnabled = false

        desktop.desktopLyricsEnabled = true
        settle()
        let panel = NSApp.windows.first { $0.identifier?.rawValue == "desktop-lyrics" } as! NSPanel
        assert(panel.isVisible && !panel.isOpaque && panel.level == .floating)
        assert(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        desktop.lyricsLocked = true
        assert(panel.ignoresMouseEvents)
        desktop.lyricsLocked = false
        assert(!panel.ignoresMouseEvents && panel.isMovableByWindowBackground)
        desktop.fontSize = 100
        assert(desktop.fontSize == 48 && defaults.double(forKey: "desktopLyricsFontSize") == 48)
        desktop.fontSize = 10
        assert(desktop.fontSize == 18)
        desktop.fontSize = .nan
        assert(desktop.fontSize == 28)
        desktop.fontSize = 32
        desktop.desktopLyricsEnabled = false
        assert(!panel.isVisible, "Desktop lyrics must close independently of playback")
        desktop.desktopLyricsEnabled = true
        assert(panel.isVisible)
        assert(defaults.bool(forKey: "desktopLyricsEnabled") && !defaults.bool(forKey: "desktopLyricsLocked"))
        assert(defaults.object(forKey: "menuLyricsEnabled") as? Bool == false)
        player.lyrics = Lyrics.parse("[00:00]Current desktop line\n[00:03]Next desktop line")
        player.position = 1
        settle()
        assert(desktop.currentLyric == "Current desktop line", "Desktop lyrics must display only the current line")
        assert(panel.frame.height == 112)

        let session = Session(server: URL(string: CommandLine.arguments[2])!, username: "test", token: "test-session")
        library.session = session
        library.offline = false
        library.tracks = [track]
        settle()
        func dockItem(_ title: String) -> NSMenuItem {
            desktop.makeDockMenu().items.first { $0.title == title }!
        }
        func selectDock(_ entry: NSMenuItem) {
            assert(entry.isEnabled && entry.action != nil)
            assert(NSApp.sendAction(entry.action!, to: entry.target, from: entry))
        }
        let pausedDock = desktop.makeDockMenu()
        assert(pausedDock.items.prefix(3).map(\.title) == ["已暂停", track.title, "\(track.artist) - \(track.album)"])
        assert(pausedDock.items[1].indentationLevel == 1 && pausedDock.items[2].indentationLevel == 1)
        assert(pausedDock.items[0...2].allSatisfy { !$0.isEnabled })
        player.mode = .sequential
        for mode in [PlaybackMode.sequential, .repeatAll, .repeatOne] {
            let entry = dockItem("循环播放").submenu!.items.first { $0.representedObject as? String == mode.rawValue }!
            selectDock(entry)
            assert(player.mode == mode)
            assert(dockItem("循环播放").submenu!.items.filter { $0.state == .on }.map(\.title) == [mode.title])
        }
        selectDock(dockItem("随机播放"))
        assert(player.shuffle && dockItem("随机播放").state == .on)
        assert(dockItem("循环播放").submenu!.items.allSatisfy { $0.state == .off })
        selectDock(dockItem("随机播放"))
        assert(player.mode == .sequential && dockItem("随机播放").state == .off)
        selectDock(dockItem("喜欢歌曲"))
        assert(desktop.favoriting && !dockItem("喜欢歌曲").isEnabled,
               "Dock favorites must share the in-flight guard with every other surface")
        func finishFavorite() {
            for _ in 0..<30 {
                if !desktop.favoriting { break }
                settle()
            }
            settle()
            assert(!desktop.favoriting, "Favorite request did not finish")
        }
        finishFavorite()
        assert(dockItem("取消喜欢").state == .on && player.current?.favorite == true)
        selectDock(dockItem("取消喜欢"))
        finishFavorite()
        assert(dockItem("喜欢歌曲").state == .off && player.current?.favorite == false)
        assert(buttons[3].isEnabled)
        buttons[3].performClick(nil)
        assert(desktop.favoriting && !buttons[3].isEnabled, "Repeated favorite requests must be blocked")
        finishFavorite()
        assert(player.current?.favorite == true && library.tracks[0].favorite && buttons[3].toolTip == "取消喜欢")
        buttons[3].performClick(nil)
        finishFavorite()
        assert(player.current?.favorite == false && !library.tracks[0].favorite && buttons[3].toolTip == "喜欢")
        library.tracks[0].favorite = true
        settle()
        assert(buttons[3].toolTip == "取消喜欢", "Menu bar must follow favorite changes from the library")
        library.tracks[0].favorite = false
        library.session = Session(server: session.server, username: session.username, token: "expired")
        settle()
        buttons[3].performClick(nil)
        finishFavorite()
        assert(library.error != nil && player.current?.favorite == false && buttons[3].isEnabled,
               "Failed favorite requests must keep the previous state and allow retry")
        library.session = session
        settle()
        buttons[3].performClick(nil)
        finishFavorite()
        assert(library.error == nil && player.current?.favorite == true && buttons[3].toolTip == "取消喜欢",
               "Retrying favorite must clear the stale error and synchronize the liked state")

        let batch = TrackBatchActions()
        func performBatch(_ action: TrackBatchActions.Action, _ tracks: [Track]) -> Bool {
            var result: Bool?
            Task { result = await batch.run(action, tracks: tracks, library: library, player: player) }
            for _ in 0..<80 {
                if result != nil { break }
                settle()
            }
            assert(result != nil && !batch.busy, "Batch request did not finish")
            return result!
        }
        library.tracks = [track]
        assert(performBatch(.favorite, [track, track]) && batch.completed == 2)
        assert(library.tracks[0].favorite && player.current?.favorite == true, "Batch liking must not toggle an already-liked song off")
        assert(!performBatch(.favorite, []) && !batch.busy)
        library.tracks = [track]
        library.session = Session(server: session.server, username: session.username, token: "expired")
        assert(!performBatch(.favorite, [track]) && batch.completed == 0 && library.error != nil)
        assert(!library.tracks[0].favorite, "Failed batches preserve favorite state and selection for retry")
        library.session = session
        library.error = nil
        library.removeDownload(track)
        assert(performBatch(.download, [track]) && batch.completed == 1)
        assert(library.downloaded.contains { $0.id == track.id }, "Batch download must save verified offline audio")
        assert(store.sidecar(track.id, name: "lyrics") != nil)
        assert(performBatch(.download, [track, track]) && batch.completed == 2, "Downloaded songs are skipped safely")
        library.offline = true
        assert(!performBatch(.favorite, [track]) && !performBatch(.download, [track]))
        library.offline = false

        let main = DesktopTestWindow(contentRect: NSRect(x: 100, y: 160, width: 1240, height: 800),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        func showLibrary() {
            main.contentView = NSHostingView(rootView: DesktopView(showingSettings: .constant(false))
                .environmentObject(library).environmentObject(player).environmentObject(desktop).tint(Theme.accent).preferredColorScheme(.light))
            main.makeKeyAndOrderFront(nil)
            settle()
        }
        showLibrary()
        assert(main.contentView!.bounds.size == NSSize(width: 1240, height: 800),
               "Scripted UI interactions require the requested content size on every display")
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: main.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                main.sendEvent(event)
            }
            settle()
        }
        func snapshot(_ rect: NSRect) -> Data {
            let view = main.contentView!
            let area = view.convert(rect, from: nil)
            let bitmap = view.bitmapImageRepForCachingDisplay(in: area)!
            view.cacheDisplay(in: area, to: bitmap)
            return bitmap.representation(using: .png, properties: [:])!
        }
        try snapshot(main.contentView!.bounds).write(to: root.appendingPathComponent("initial.png"))
        let footerRect = NSRect(x: 204, y: 0, width: 1036, height: 82)
        let normalFooter = snapshot(footerRect)
        let navigation = snapshot(NSRect(x: 0, y: 0, width: 204, height: 800))
        func selectSongs() {
            let before = snapshot(footerRect)
            click(NSPoint(x: 1149, y: 594))
            assert(snapshot(footerRect) != before, "Selection actions must cover the playback footer")
        }
        selectSongs()
        assert(snapshot(NSRect(x: 0, y: 0, width: 204, height: 800)) == navigation,
               "Selecting songs must not cover or alter the sidebar")
        try snapshot(main.contentView!.bounds).write(to: root.appendingPathComponent("selection-empty.png"))
        click(NSPoint(x: 270, y: 600))
        try snapshot(main.contentView!.bounds).write(to: root.appendingPathComponent("selection.png"))
        let queueIDs = player.queue.map(\.id)
        let currentID = player.current?.id
        click(NSPoint(x: 1193, y: 41))
        assert(player.queue.map(\.id) == queueIDs && player.current?.id == currentID,
               "Appending selections must deduplicate and preserve current playback")
        assert(snapshot(footerRect) == normalFooter, "Adding songs restores the playback footer")
        selectSongs()
        click(NSPoint(x: 1190, y: 600))
        assert(snapshot(footerRect) == normalFooter && player.queue.map(\.id) == queueIDs,
               "Done exits selection without modifying the queue")

        library.albums = [Album(id: "test-album", title: track.album, artist: track.albumArtist,
                                year: track.year, artwork: "", tracks: 1)]
        library.artists = [Artist(name: track.artist, tracks: 1)]
        func checkSongCollection(_ name: String) throws {
            let footer = snapshot(footerRect)
            selectSongs()
            try snapshot(main.contentView!.bounds).write(to: root.appendingPathComponent(name + "-selection.png"))
            click(NSPoint(x: 1190, y: 600))
            assert(snapshot(footerRect) == footer, "Every song collection must restore the same playback bar")
        }
        click(NSPoint(x: 100, y: 531))
        click(NSPoint(x: 315, y: 550))
        try checkSongCollection("album")
        click(NSPoint(x: 100, y: 481))
        click(NSPoint(x: 350, y: 570))
        try checkSongCollection("artist")
        library.tracks[0].favorite = true
        click(NSPoint(x: 100, y: 431))
        try checkSongCollection("favorites")
        click(NSPoint(x: 100, y: 381))
        try checkSongCollection("downloads")
        library.offline = true
        library.session = nil
        selectSongs()
        click(NSPoint(x: 270, y: 600))
        click(NSPoint(x: 1193, y: 41))
        assert(player.queue.map(\.id) == queueIDs && player.current?.id == currentID,
               "Downloaded selections can be appended offline without interrupting playback")
        library.session = session
        library.offline = false
        library.tracks[0].favorite = false
        click(NSPoint(x: 100, y: 581))
        func clickArtwork() {
            click(NSPoint(x: 270, y: 40))
        }
        clickArtwork()
        assert(player.expanded, "Clicking the playback artwork must open the listening page")
        clickArtwork()
        assert(!player.expanded, "Clicking the playback artwork again must restore the library")
        player.expanded = true
        settle()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: main.windowNumber,
                                      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        main.sendEvent(escape)
        settle()
        assert(!player.expanded, "Escape must restore the library from the listening page")
        main.close()
        assert(!DesktopAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
        selectDock(dockItem("播放"))
        settle(until: { player.playing })
        assert(player.playing && desktop.makeDockMenu().items.first?.title == "正在播放",
               "Dock playback must work with the main window closed")
        selectDock(dockItem("暂停"))
        settle(until: { !player.playing })
        assert(!player.playing)
        player.position = 6
        selectDock(dockItem("上一首"))
        assert(player.position == 0, "Dock previous must reach the shared player")
        buttons[1].performClick(nil)
        settle(until: { player.playing && buttons[1].toolTip == "暂停" })
        assert(buttons[1].toolTip == "暂停", "Menu bar must play with the main window closed")
        buttons[1].performClick(nil)
        settle(until: { !player.playing && buttons[1].toolTip == "播放" })
        assert(!player.playing && buttons[1].toolTip == "播放", "Menu bar must pause with the main window closed")
        buttons[0].performClick(nil)
        assert(player.position == 0, "Menu bar previous must reach the player")
        var reopened = false
        desktop.openMainWindow = { reopened = true; main.makeKeyAndOrderFront(nil) }
        desktop.showMainWindow()
        assert(reopened && main.isVisible)

        desktop.menuLyricsEnabled = true
        player.lyrics = Lyrics.parse("[00:00]此刻，让音乐留在身边\n[00:03]每一句，都与你同步")
        player.position = 1
        settle()
        let images = root.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        func captureMenuBar(_ name: String, background: NSColor) throws -> NSBitmapImageRep {
            var rendered: NSBitmapImageRep!
            status.effectiveAppearance.performAsCurrentDrawingAppearance {
                let bitmap = status.bitmapImageRepForCachingDisplay(in: status.bounds)!
                status.cacheDisplay(in: status.bounds, to: bitmap)
                let image = NSImage(size: status.bounds.size)
                image.lockFocus()
                background.setFill()
                NSBezierPath(rect: status.bounds).fill()
                NSImage(cgImage: bitmap.cgImage!, size: status.bounds.size)
                    .draw(in: status.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                image.unlockFocus()
                rendered = NSBitmapImageRep(data: image.tiffRepresentation!)!
            }
            try rendered.representation(using: .png, properties: [:])!.write(to: images.appendingPathComponent(name + ".png"))
            return rendered
        }
        for (name, appearance, background) in [
            ("menubar", NSAppearance.Name.vibrantDark, NSColor.black),
            ("menubar-light", NSAppearance.Name.aqua, NSColor.white)
        ] {
            status.appearance = NSAppearance(named: appearance)
            settle()
            let rendered = try captureMenuBar(name, background: background)
            let scale = CGFloat(rendered.pixelsWide) / status.bounds.width
            for control in buttons {
                let icon = control.convert(control.bounds, to: status).intersection(status.bounds)
                var ink = NSRect.null
                for y in Int((status.bounds.maxY - icon.maxY) * scale)..<Int((status.bounds.maxY - icon.minY) * scale) {
                    for x in Int(icon.minX * scale)..<Int(icon.maxX * scale) {
                        guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        if appearance == .vibrantDark ? brightness > 0.5 : brightness < 0.5 {
                            ink = ink.union(NSRect(x: x, y: y, width: 1, height: 1))
                        }
                    }
                }
                assert(!ink.isNull, "\(control.toolTip ?? "") must remain visible on the \(appearance.rawValue) menu bar")
                let source = NSBitmapImageRep(data: control.image!.tiffRepresentation!)!
                var sourceInk = NSRect.null
                for y in 0..<source.pixelsHigh {
                    for x in 0..<source.pixelsWide where source.colorAt(x: x, y: y)!.alphaComponent > 0.5 {
                        sourceInk = sourceInk.union(NSRect(x: x, y: y, width: 1, height: 1))
                    }
                }
                let expectedHeight = sourceInk.height * control.image!.size.height / CGFloat(source.pixelsHigh)
                assert(abs(ink.height / scale - expectedHeight) <= 1.5,
                       "\(control.toolTip ?? "") must retain its configured symbol height")
                assert(abs(ink.width / ink.height - sourceInk.width / sourceInk.height) < 0.2,
                       "\(control.toolTip ?? "") must retain its native proportions without flattening")
            }
        }
        status.appearance = nil
        if CommandLine.arguments.contains("--capture") {
            let controlsFrame = buttons.map(\.frame)
            status.appearance = NSAppearance(named: .vibrantDark)
            for (name, elapsed) in [("head", 0.0), ("middle", 4.0), ("tail", 8.0)] {
                lyrics.update(text: "让每一份热爱产生共鸣，让音乐陪你走过漫长的旅途", elapsed: elapsed,
                              duration: 8, playing: false)
                settle()
                _ = try captureMenuBar("menubar-lyric-" + name, background: .black)
                assert(buttons.map(\.frame) == controlsFrame, "Scrolling lyrics must never move the controls")
            }
            status.appearance = nil
            player.position = 1
            settle()
        }

        if CommandLine.arguments.contains("--capture") {
            func capture(_ window: NSWindow, _ name: String) throws {
                window.orderFrontRegardless()
                window.displayIfNeeded()
                settle()
                let view = window.contentView!
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: images.appendingPathComponent(name + ".png"))
            }
            try capture(main, "desktop")
            try capture(panel, "lyrics")
            buttons[4].performClick(nil)
            settle()
            assert(popup.isVisible, "The icon must reopen the same popover after being restored")
            try capture(popup, "popover")
            status.performClick(nil)
            settle(until: { !popup.isVisible })
            assert(!popup.isVisible, "The native menu bar item must support keyboard activation")
            main.setContentSize(NSSize(width: 920, height: 620))
            player.expanded = false
            settle()
            try capture(main, "songs-compact")
            click(NSPoint(x: 829, y: 414))
            try capture(main, "selection-compact")
            click(NSPoint(x: 870, y: 420))
            player.expanded = true
            settle()
            try capture(main, "desktop-compact")
            let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 740),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            settings.contentView = NSHostingView(rootView: ServerSettings().environmentObject(library).environmentObject(desktop)
                .tint(Theme.accent).preferredColorScheme(.light))
            try capture(settings, "settings")
            settings.close()
            defaults.set(120, forKey: "NSStatusItem Preferred Position ResonaMenuBar")
            let saved = DesktopIntegration(player: player, library: library, defaults: defaults)
            assert(saved.desktopLyricsEnabled && saved.menuLyricsEnabled && saved.menuControlsEnabled && saved.fontSize == 32)
            assert(defaults.integer(forKey: "NSStatusItem Preferred Position ResonaMenuBar") == 120,
                   "Reopening must preserve a position the user has already saved")
            saved.desktopLyricsEnabled = false
            NSStatusBar.system.removeStatusItem(saved.statusItem)
        }
        player.pause()
        player.expanded = false
        main.setContentSize(NSSize(width: 1240, height: 800))
        showLibrary()
        func editableField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { editableField(in: $0) }.first
        }
        main.makeFirstResponder(editableField(in: main.contentView!)!)
        settle()
        let previousRect = NSRect(x: 743, y: 20, width: 30, height: 42)
        let nextRect = NSRect(x: 845, y: 20, width: 30, height: 42)
        let previousPaused = snapshot(previousRect)
        let nextPaused = snapshot(nextRect)
        // Drive the playing state without audio timing or pointer movement masking the regression.
        player.playing = true
        settle()
        settle()
        try snapshot(main.contentView!.bounds).write(to: root.appendingPathComponent("playing.png"))
        assert(snapshot(previousRect) == previousPaused && snapshot(nextRect) == nextPaused,
               "Previous and next must stay visible during playback without hover or keyboard focus")
        click(NSPoint(x: 808, y: 40))
        assert(!player.playing, "The visible pause button must work without first hovering the playback bar")
        desktop.desktopLyricsEnabled = false
        main.close()
        NSStatusBar.system.removeStatusItem(desktop.statusItem)
        player.stop()
        print("macOS selection, filters, batch actions, lyrics, preferences, panel lifecycle and resident playback tests passed")
    }

    private final class MockDirectAirPlayBackend: MacDirectAirPlayBackend {
        var devices: [AudioOutputDevice] = []
        var activeDeviceID: String?
        var connectingDeviceID: String?
        var hasAirPlay2Targets = false
        var lastError: String?
        var onStateChange: (() -> Void)?
        var onDisconnect: ((String?) -> Void)?

        var refreshCount = 0
        var lastVolume: Float?
        var flushCount = 0
        var disconnectCount = 0
        var shouldFailConnect = false

        func startDiscovery() {}

        func refreshDiscovery() {
            refreshCount += 1
        }

        func connect(deviceID: String, initialVolume: Float) async throws {
            connectingDeviceID = deviceID
            lastVolume = initialVolume
            onStateChange?()
            if shouldFailConnect {
                connectingDeviceID = nil
                lastError = "模拟连接失败"
                onStateChange?()
                throw RAOPError.connectionFailed("模拟连接失败")
            }
            connectingDeviceID = nil
            activeDeviceID = deviceID
            lastError = nil
            onStateChange?()
        }

        func disconnect() {
            disconnectCount += 1
            activeDeviceID = nil
            connectingDeviceID = nil
            onStateChange?()
        }

        func setVolume(_ volume: Float) {
            lastVolume = volume
        }

        func flush() {
            flushCount += 1
        }

        func attachTap(to item: AVPlayerItem) async {}

        func detachTap(from item: AVPlayerItem) {}
    }

    private final class MockRAOPServer {
        private let lock = NSLock()
        private let tcpListenFD: Int32
        let rtspPort: UInt16
        private let audioFD: Int32
        private let audioPort: UInt16
        private let controlFD: Int32
        private let controlPort: UInt16
        private let timingFD: Int32
        private let timingPort: UInt16

        private var clientControlPort: UInt16 = 0
        private var clientTimingPort: UInt16 = 0
        private var running = true
        private let queue = DispatchQueue(label: "app.resona.test.mock-raop", attributes: .concurrent)

        private(set) var rtspRequests: [(method: String, uri: String, body: String)] = []
        private(set) var audioPackets: [Data] = []
        private(set) var syncPackets: [Data] = []
        private(set) var resendPackets: [Data] = []
        private(set) var timingReplies: [Data] = []
        private(set) var teardownReceived = false

        init() throws {
            let (tFD, tPort) = try Self.bindTCP()
            self.tcpListenFD = tFD
            self.rtspPort = tPort
            let (aFD, aPort) = try Self.bindUDP()
            let (cFD, cPort) = try Self.bindUDP()
            let (timFD, timPort) = try Self.bindUDP()
            self.audioFD = aFD
            self.audioPort = aPort
            self.controlFD = cFD
            self.controlPort = cPort
            self.timingFD = timFD
            self.timingPort = timPort

            queue.async { [weak self] in self?.acceptRTSP() }
            queue.async { [weak self] in self?.readUDP(fd: aFD, kind: .audio) }
            queue.async { [weak self] in self?.readUDP(fd: cFD, kind: .control) }
            queue.async { [weak self] in self?.readUDP(fd: timFD, kind: .timing) }
        }

        deinit {
            stop()
        }

        func stop() {
            lock.lock()
            let wasRunning = running
            running = false
            lock.unlock()
            guard wasRunning else { return }
            for fd in [tcpListenFD, audioFD, controlFD, timingFD] where fd >= 0 {
                Darwin.close(fd)
            }
        }

        func sendResendRequest(firstSeq: UInt16, count: UInt16) {
            let port = locked { clientControlPort }
            guard port > 0 else { return }
            var pkt = Data([0x80, 0xD5, 0x00, 0x01])
            pkt.append(UInt8((firstSeq >> 8) & 0xFF))
            pkt.append(UInt8(firstSeq & 0xFF))
            pkt.append(UInt8((count >> 8) & 0xFF))
            pkt.append(UInt8(count & 0xFF))
            Self.sendUDP(fd: controlFD, data: pkt, port: port)
        }

        func sendTimingRequest(marker: [UInt8]) {
            let port = locked { clientTimingPort }
            guard port > 0, marker.count == 8 else { return }
            var pkt = Data(repeating: 0, count: 32)
            pkt[0] = 0x80
            pkt[1] = 0xD2
            pkt[3] = 0x07
            pkt.replaceSubrange(24..<32, with: marker)
            Self.sendUDP(fd: timingFD, data: pkt, port: port)
        }

        func snapshot() -> (
            rtsp: [(method: String, uri: String, body: String)],
            audio: [Data],
            sync: [Data],
            resend: [Data],
            timing: [Data],
            teardown: Bool
        ) {
            locked {
                (
                    rtsp: rtspRequests,
                    audio: audioPackets,
                    sync: syncPackets,
                    resend: resendPackets,
                    timing: timingReplies,
                    teardown: teardownReceived
                )
            }
        }

        private func locked<T>(_ work: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return work()
        }

        private enum UDPKind { case audio, control, timing }

        private func readUDP(fd: Int32, kind: UDPKind) {
            var buf = [UInt8](repeating: 0, count: 2048)
            while locked({ running }) {
                let n = Darwin.recvfrom(fd, &buf, buf.count, 0, nil, nil)
                if n <= 0 {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                        usleep(2_000)
                        continue
                    }
                    break
                }
                let data = Data(buf[0..<n])
                locked {
                    switch kind {
                    case .audio:
                        audioPackets.append(data)
                    case .control:
                        if data.count >= 2 && data[1] == 0xD4 {
                            syncPackets.append(data)
                        } else if data.count >= 2 && data[1] == 0xD6 {
                            resendPackets.append(data)
                        }
                    case .timing:
                        if data.count >= 2 && data[1] == 0xD3 {
                            timingReplies.append(data)
                        }
                    }
                }
            }
        }

        private func acceptRTSP() {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let conn = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(tcpListenFD, sa, &len)
                }
            }
            guard conn >= 0 else { return }
            defer { Darwin.close(conn) }

            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while locked({ running }) {
                if let sepRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer[..<sepRange.lowerBound]
                    let headerText = String(data: headerData, encoding: .utf8) ?? ""
                    let lines = headerText.components(separatedBy: "\r\n")
                    var contentLength = 0
                    var cseq = "1"
                    var transport = ""
                    for line in lines.dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                            if key == "content-length" { contentLength = Int(val) ?? 0 }
                            else if key == "cseq" { cseq = val }
                            else if key == "transport" { transport = val }
                        }
                    }
                    let bodyEnd = sepRange.upperBound + contentLength
                    if buffer.count >= bodyEnd {
                        let bodyData = buffer[sepRange.upperBound..<bodyEnd]
                        let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                        buffer.removeSubrange(..<bodyEnd)

                        let reqParts = (lines.first ?? "").split(separator: " ")
                        let method = reqParts.count > 0 ? String(reqParts[0]) : ""
                        let uri = reqParts.count > 1 ? String(reqParts[1]) : ""

                        if method == "SETUP" {
                            let cPort = Self.extractParam("control_port", from: transport) ?? 0
                            let tPort = Self.extractParam("timing_port", from: transport) ?? 0
                            locked {
                                clientControlPort = cPort
                                clientTimingPort = tPort
                            }
                        }

                        var replyLines = [
                            "RTSP/1.0 200 OK",
                            "CSeq: \(cseq)",
                            "Server: MockRAOP/1.0"
                        ]
                        if method == "OPTIONS" {
                            replyLines.append("Public: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, SET_PARAMETER")
                        } else if method == "SETUP" {
                            replyLines.append("Session: 1")
                            replyLines.append("Transport: RTP/AVP/UDP;unicast;mode=record;server_port=\(audioPort);control_port=\(controlPort);timing_port=\(timingPort)")
                        } else if method == "RECORD" {
                            replyLines.append("Audio-Latency: 88200")
                        }
                        replyLines.append("")
                        replyLines.append("")
                        let replyData = Data(replyLines.joined(separator: "\r\n").utf8)
                        replyData.withUnsafeBytes { raw in
                            if let base = raw.baseAddress {
                                _ = Darwin.send(conn, base, replyData.count, 0)
                            }
                        }

                        locked {
                            rtspRequests.append((method, uri, bodyStr))
                            if method == "TEARDOWN" {
                                teardownReceived = true
                            }
                        }
                        if method == "TEARDOWN" { break }
                        continue
                    }
                }

                let n = Darwin.recv(conn, &chunk, chunk.count, 0)
                if n <= 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }

        private static func extractParam(_ key: String, from header: String) -> UInt16? {
            for part in header.split(separator: ";") {
                let s = part.trimmingCharacters(in: .whitespaces)
                if s.lowercased().hasPrefix(key.lowercased() + "="),
                   let eq = s.firstIndex(of: "=") {
                    return UInt16(s[s.index(after: eq)...])
                }
            }
            return nil
        }

        private static func bindTCP() throws -> (Int32, UInt16) {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw RAOPError.connectionFailed("mock tcp socket failed") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0, Darwin.listen(fd, 4) == 0 else {
                Darwin.close(fd)
                throw RAOPError.connectionFailed("mock tcp bind/listen failed")
            }
            return (fd, try boundPort(fd))
        }

        private static func bindUDP() throws -> (Int32, UInt16) {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw RAOPError.connectionFailed("mock udp socket failed") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0 else {
                Darwin.close(fd)
                throw RAOPError.connectionFailed("mock udp bind failed")
            }
            return (fd, try boundPort(fd))
        }

        private static func boundPort(_ fd: Int32) throws -> UInt16 {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let res = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &len)
                }
            }
            guard res == 0 else { throw RAOPError.connectionFailed("getsockname failed") }
            return UInt16(bigEndian: addr.sin_port)
        }

        private static func sendUDP(fd: Int32, data: Data, port: UInt16) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = port.bigEndian
            _ = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    data.withUnsafeBytes { raw in
                        Darwin.sendto(fd, raw.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval = 5.0, message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        assert(condition(), message)
    }

    @MainActor
    private static func awaitResult<T>(timeout: TimeInterval = 5.0, _ work: @escaping @Sendable () async throws -> T) throws -> T {
        var box: Result<T, Error>?
        Task { @MainActor in
            do {
                box = .success(try await work())
            } catch {
                box = .failure(error)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while box == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let result = box else {
            throw NSError(domain: "DesktopTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Async task timed out"])
        }
        return try result.get()
    }

    @MainActor
    private static func raopTests() throws {
        // 1. Service discovery classifier
        let r1 = RAOPDiscovery.classifyRAOPService(
            serviceName: "FC7C02B3CFAD@Phicomm_R1_CFAD",
            txt: ["et": "0,1", "cn": "0,1", "pw": "false"],
            isLoopback: false,
            localAirPlayDeviceIDs: ["56216656FB6D"],
            localMACs: ["AA1122334455"],
            interfaceIndex: 6
        )
        assert(r1?.id == "raop:FC7C02B3CFAD", "Valid RAOP speaker must be accepted")
        assert(r1?.displayName == "Phicomm_R1_CFAD")
        assert(r1?.codecs == [0, 1] && r1?.encryptionTypes == [0, 1] && r1?.requiresPassword == false)

        assert(RAOPDiscovery.classifyRAOPService(
            serviceName: "FC7C02B3CFAD@Phicomm_R1_CFAD",
            txt: ["et": "0,1", "cn": "0,1"],
            isLoopback: true,
            localAirPlayDeviceIDs: [],
            localMACs: []
        ) == nil, "Loopback RAOP service must be filtered")

        assert(RAOPDiscovery.classifyRAOPService(
            serviceName: "56216656FB6D@MacBook Air",
            txt: ["et": "0,1", "cn": "0,1"],
            isLoopback: false,
            localAirPlayDeviceIDs: ["56216656FB6D"],
            localMACs: []
        ) == nil, "Local AirPlay deviceid must be filtered")

        assert(RAOPDiscovery.classifyRAOPService(
            serviceName: "AA1122334455@LocalMac",
            txt: ["et": "0,1", "cn": "0,1"],
            isLoopback: false,
            localAirPlayDeviceIDs: [],
            localMACs: ["AA1122334455"]
        ) == nil, "Local hardware MAC must be filtered")

        assert(RAOPDiscovery.classifyRAOPService(
            serviceName: "112233445566@HAPOnly",
            txt: ["pk": "abcdef", "et": "3", "cn": "0,1"],
            isLoopback: false,
            localAirPlayDeviceIDs: [],
            localMACs: []
        ) == nil, "HAP-only endpoint without RSA et=1 must be excluded")

        let pwSpeaker = RAOPDiscovery.classifyRAOPService(
            serviceName: "112233445566@LockedSpeaker",
            txt: ["et": "0,1", "cn": "0,1", "pw": "true"],
            isLoopback: false,
            localAirPlayDeviceIDs: [],
            localMACs: []
        )
        assert(pwSpeaker?.requiresPassword == true, "pw=true must set requiresPassword")

        // 2. RAOPCrypto RSA key wrapping & AES-CBC partial-block handling
        let randomCrypto = try RAOPCrypto()
        assert(randomCrypto.aesKey.count == 16 && randomCrypto.aesIV.count == 16)
        let wrapped = try randomCrypto.encryptedAESKeyBase64()
        assert(!wrapped.contains("="), "RAOP SDP base64 must strip '=' padding")
        let paddedWrapped = wrapped + String(repeating: "=", count: (4 - wrapped.count % 4) % 4)
        assert(Data(base64Encoded: paddedWrapped)?.count == 256, "RSA-2048 OAEP key blob must be 256 bytes")

        let testKey = Data((0..<16).map { UInt8($0) })
        let testIV = Data((16..<32).map { UInt8($0) })
        let fixedCrypto = try RAOPCrypto(aesKey: testKey, aesIV: testIV)
        let plain23 = Data((0..<23).map { UInt8($0 * 7 &+ 3) })
        let enc23 = fixedCrypto.encryptAudioPayload(plain23)
        assert(enc23.count == 23, "AES-CBC RAOP encryption must preserve exact payload length")
        assert(enc23[16..<23] == plain23[16..<23], "Trailing sub-16-byte tail must remain unencrypted per RAOP")
        var expectedFirstBlock = [UInt8](repeating: 0, count: 16)
        var outLen = 0
        let ccStatus = testKey.withUnsafeBytes { keyPtr in
            testIV.withUnsafeBytes { ivPtr in
                plain23.withUnsafeBytes { inPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0),
                        keyPtr.baseAddress, kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        inPtr.baseAddress, 16,
                        &expectedFirstBlock, 16,
                        &outLen
                    )
                }
            }
        }
        assert(ccStatus == kCCSuccess && outLen == 16)
        assert(Array(enc23[0..<16]) == expectedFirstBlock, "First 16 bytes must match AES-128-CBC")
        let shortPlain = Data([1, 2, 3, 4, 5])
        assert(fixedCrypto.encryptAudioPayload(shortPlain) == shortPlain, "<16 bytes must remain unencrypted")

        // 3. Bit-exact 352-frame ALAC roundtrip & L16 fallback
        var pcmSamples = [Int16](repeating: 0, count: RAOPAudioEncoder.framesPerPacket * 2)
        for i in 0..<RAOPAudioEncoder.framesPerPacket {
            let left = Int16((i * 193 - 12000) & 0x7FFF)
            let right = Int16(truncatingIfNeeded: -i * 131 + 9000)
            pcmSamples[i * 2] = left
            pcmSamples[i * 2 + 1] = right
        }

        let alacEncoder = RAOPAudioEncoder(supportedCodecs: [0, 1])
        assert(alacEncoder.codec == .alac && alacEncoder.magicCookie?.count == 24, "ALAC encoder must supply 24-byte magicCookie")
        let encodedALAC = alacEncoder.encode(interleavedStereoInt16: pcmSamples)
        assert(!encodedALAC.isEmpty)

        var alacDesc = AudioStreamBasicDescription(
            mSampleRate: RAOPAudioEncoder.sampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: UInt32(kAppleLosslessFormatFlag_16BitSourceData),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(RAOPAudioEncoder.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: RAOPAudioEncoder.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!
        var pcmDesc = pcmFmt.streamDescription.pointee
        var convRef: AudioConverterRef?
        let newStatus = AudioConverterNew(&alacDesc, &pcmDesc, &convRef)
        assert(newStatus == noErr && convRef != nil, "AudioConverterNew failed: \(newStatus)")
        defer { if let convRef { AudioConverterDispose(convRef) } }
        let cookie = alacEncoder.magicCookie!
        let cookieStatus = cookie.withUnsafeBytes {
            AudioConverterSetProperty(convRef!, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
        }
        assert(cookieStatus == noErr, "Magic cookie setup failed: \(cookieStatus)")

        struct ALACDecodeCtx {
            var ptr: UnsafeMutableRawPointer
            var count: UInt32
            var desc: AudioStreamPacketDescription
            var fed = false
        }
        var encodedBytes = [UInt8](encodedALAC)
        var decodedSamples = [Int16](repeating: 0, count: pcmSamples.count)
        var ioFrames = UInt32(RAOPAudioEncoder.framesPerPacket)
        let decStatus = encodedBytes.withUnsafeMutableBytes { encRaw in
            decodedSamples.withUnsafeMutableBytes { outRaw in
                var ctx = ALACDecodeCtx(
                    ptr: encRaw.baseAddress!,
                    count: UInt32(encRaw.count),
                    desc: AudioStreamPacketDescription(
                        mStartOffset: 0,
                        mVariableFramesInPacket: UInt32(RAOPAudioEncoder.framesPerPacket),
                        mDataByteSize: UInt32(encRaw.count)
                    )
                )
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: RAOPAudioEncoder.channels,
                        mDataByteSize: UInt32(outRaw.count),
                        mData: outRaw.baseAddress
                    )
                )
                return withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                    AudioConverterFillComplexBuffer(convRef!, { _, ioPackets, ioData, outDesc, userData in
                        let c = userData!.assumingMemoryBound(to: ALACDecodeCtx.self)
                        if c.pointee.fed {
                            ioPackets.pointee = 0
                            return noErr
                        }
                        c.pointee.fed = true
                        ioPackets.pointee = 1
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = RAOPAudioEncoder.channels
                        ioData.pointee.mBuffers.mDataByteSize = c.pointee.count
                        ioData.pointee.mBuffers.mData = c.pointee.ptr
                        if let outDesc {
                            withUnsafeMutablePointer(to: &c.pointee.desc) { outDesc.pointee = $0 }
                        }
                        return noErr
                    }, ctxPtr, &ioFrames, &abl, nil)
                }
            }
        }
        assert(decStatus == noErr && ioFrames == UInt32(RAOPAudioEncoder.framesPerPacket), "ALAC decode failed: \(decStatus)")
        assert(decodedSamples == pcmSamples, "ALAC decode must be bit-exact")

        let l16Encoder = RAOPAudioEncoder(supportedCodecs: [0])
        assert(l16Encoder.codec == .pcmL16)
        let l16Data = l16Encoder.encode(interleavedStereoInt16: pcmSamples)
        assert(l16Data.count == RAOPAudioEncoder.framesPerPacket * 4)
        let firstU = UInt16(bitPattern: pcmSamples[0])
        assert(l16Data[0] == UInt8(firstU >> 8) && l16Data[1] == UInt8(firstU & 0xFF))

        // 4. RAOPPCMBuffer ring behavior
        let ring = RAOPPCMBuffer()
        let ringInput = pcmSamples + Array(pcmSamples.prefix(96)) // 352 + 48 = 400 frames
        ringInput.withUnsafeBufferPointer {
            ring.append(interleavedStereoInt16: $0.baseAddress!, frameCount: 400)
        }
        assert(ring.availableFrames == 400)
        let popped = ring.popFrames(352)
        assert(popped == pcmSamples && ring.availableFrames == 48)
        ring.clear()
        assert(ring.availableFrames == 0)

        // 5. Loopback mock RAOP server RTSP + UDP + Resend + Timing + Flush + Teardown
        assert(RAOPSession.airPlayVolumeDB(for: 0.0) == -144.0)
        let mockServer = try MockRAOPServer()
        defer { mockServer.stop() }
        let streamBuf = RAOPPCMBuffer()
        let session = try RAOPSession(
            host: "127.0.0.1",
            port: mockServer.rtspPort,
            deviceName: "Mock R1",
            codecs: [0, 1],
            encryptionTypes: [1],
            buffer: streamBuf
        )
        try awaitResult {
            try await session.connect(initialVolume: 0.0)
        }

        let silentFrames = [Int16](repeating: 0, count: RAOPAudioEncoder.framesPerPacket * 4 * 2)
        silentFrames.withUnsafeBufferPointer {
            streamBuf.append(interleavedStereoInt16: $0.baseAddress!, frameCount: RAOPAudioEncoder.framesPerPacket * 4)
        }
        waitUntil(message: "RAOPSession must emit RTP audio packets and initial sync packet") {
            let snap = mockServer.snapshot()
            return snap.audio.count >= 2 && snap.sync.count >= 1
        }
        let initialSnap = mockServer.snapshot()
        assert(initialSnap.audio[0][0] == 0x80 && initialSnap.audio[0][1] == 0xE0, "First RTP packet must carry marker bit (0xE0)")
        assert(initialSnap.audio[1][0] == 0x80 && initialSnap.audio[1][1] == 0x60, "Subsequent RTP packet payload type must be 0x60")
        assert(initialSnap.sync[0][0] == 0x90 && initialSnap.sync[0][1] == 0xD4, "First sync packet must start with 0x90 0xD4")

        let firstAudioPkt = initialSnap.audio[0]
        let firstSeq = (UInt16(firstAudioPkt[2]) << 8) | UInt16(firstAudioPkt[3])
        mockServer.sendResendRequest(firstSeq: firstSeq, count: 1)
        waitUntil(message: "RAOPSession must respond to 0xD5 resend request with 0xD6 packet") {
            !mockServer.snapshot().resend.isEmpty
        }
        let resendPkt = mockServer.snapshot().resend[0]
        assert(resendPkt.prefix(4) == Data([0x80, 0xD6, 0x00, 0x01]) && Data(resendPkt.dropFirst(4)) == firstAudioPkt)

        let marker: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        mockServer.sendTimingRequest(marker: marker)
        waitUntil(message: "RAOPSession must reply to 0xD2 timing request with 0xD3") {
            !mockServer.snapshot().timing.isEmpty
        }
        let timingReply = mockServer.snapshot().timing[0]
        assert(timingReply.count == 32 && timingReply[0] == 0x80 && timingReply[1] == 0xD3)
        assert(Array(timingReply[8..<16]) == marker, "Timing reply must echo client transmit timestamp")

        session.setVolume(0.5)
        waitUntil(message: "RAOPSession setVolume must send SET_PARAMETER volume") {
            mockServer.snapshot().rtsp.filter { $0.method == "SET_PARAMETER" }.count >= 2
        }
        session.flush()
        waitUntil(message: "RAOPSession flush must send FLUSH") {
            mockServer.snapshot().rtsp.contains { $0.method == "FLUSH" }
        }
        session.disconnect()
        waitUntil(message: "RAOPSession disconnect must send TEARDOWN") {
            mockServer.snapshot().teardown
        }

        let rtsp = mockServer.snapshot().rtsp
        assert(rtsp.first?.method == "OPTIONS" && rtsp.first?.uri == "*", "OPTIONS must target *")
        let nonOptions = rtsp.filter { $0.method != "OPTIONS" }
        assert(nonOptions.allSatisfy { $0.uri.hasPrefix("rtsp://127.0.0.1/") }, "RTSP URIs must use local IP")
        let announceReq = rtsp.first { $0.method == "ANNOUNCE" }
        assert(announceReq?.body.contains("a=rsaaeskey:") == true && announceReq?.body.contains("a=aesiv:") == true && announceReq?.body.contains("a=fmtp:96 352") == true)
        let initVolReq = rtsp.first { $0.method == "SET_PARAMETER" }
        assert(initVolReq?.body.contains("volume: -144.000000") == true)

        // 6. PlayerModel direct AirPlay backend integration
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("resona-raop-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let testPlayer = PlayerModel(
            downloads: OfflineStore(root: tmpDir.appendingPathComponent("dl")),
            cache: PlaybackCache(root: tmpDir.appendingPathComponent("cache"))
        )
        let mockBackend = MockDirectAirPlayBackend()
        let mockDevice = RAOPDeviceInfo(
            id: "raop:FC7C02B3CFAD",
            macHex: "FC7C02B3CFAD",
            serviceName: "FC7C02B3CFAD@Mock R1",
            displayName: "Mock R1",
            codecs: [0, 1],
            encryptionTypes: [1],
            requiresPassword: false,
            interfaceIndex: 0
        ).asAudioOutputDevice
        mockBackend.devices = [mockDevice]
        testPlayer.configureDirectAirPlay(mockBackend)
        assert(testPlayer.directAirPlayOutputs == [mockDevice])

        testPlayer.refreshDirectAirPlayDevices()
        assert(mockBackend.refreshCount == 1)

        testPlayer.selectDirectAirPlay(mockDevice.id)
        waitUntil(message: "PlayerModel must update directAirPlayID after connecting") {
            testPlayer.directAirPlayID == mockDevice.id && testPlayer.directAirPlayConnectingID == nil
        }
        assert(testPlayer.directAirPlayError == nil)

        testPlayer.volume = 0.42
        assert(mockBackend.lastVolume == 0.42, "Volume changes must propagate to active direct AirPlay backend")

        mockBackend.activeDeviceID = nil
        mockBackend.onDisconnect?("连接已断开")
        waitUntil(message: "Backend disconnect callback must clear directAirPlayID and surface error") {
            testPlayer.directAirPlayID == nil && testPlayer.directAirPlayError == "连接已断开"
        }

        mockBackend.shouldFailConnect = true
        testPlayer.selectDirectAirPlay(mockDevice.id)
        waitUntil(message: "Failed direct AirPlay connect must clear connecting state and surface error") {
            testPlayer.directAirPlayConnectingID == nil &&
            testPlayer.directAirPlayID == nil &&
            testPlayer.directAirPlayError?.contains("模拟连接失败") == true
        }

        mockBackend.shouldFailConnect = false
        testPlayer.selectDirectAirPlay(mockDevice.id)
        waitUntil(message: "Second direct AirPlay connect must succeed") {
            testPlayer.directAirPlayID == mockDevice.id
        }
        testPlayer.selectAudioOutput(testPlayer.availableOutputs.first?.id)
        assert(testPlayer.directAirPlayID == nil && mockBackend.disconnectCount >= 1, "Selecting a CoreAudio output must disconnect direct AirPlay")
        testPlayer.disconnectDirectAirPlay()
    }
}
