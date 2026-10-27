import AppKit
import CryptoKit
import SwiftUI

@main
struct DesktopTests {
    @MainActor static func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
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
        let desktop = DesktopIntegration(player: player, library: library, defaults: defaults)
        let status = desktop.statusItem.button!
        let stack = status.subviews.compactMap { $0 as? NSStackView }.first!
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        assert(buttons.count == 6, "Menu bar must contain lyrics, previous, play, next, favorite and settings in that order")
        assert(buttons[1...3].allSatisfy { !$0.isEnabled }, "Empty player controls must be disabled")
        assert(!buttons[4].isEnabled, "Favorite must be disabled without a song and server connection")
        assert(desktop.lyricLines == ["Resona · 此刻想听什么？"])
        assert(!desktop.desktopLyricsEnabled && desktop.menuLyricsEnabled)

        let audio = root.appendingPathComponent("song.mp3")
        let data = try Data(contentsOf: audio)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let track = Track(id: id, title: "Test Song", artist: "Resona", albumArtist: "Resona", album: "Test Album",
                          year: "2026", number: 1, disc: 1, duration: 12, format: "mp3", bitrate: 128000,
                          sampleRate: 44100, artwork: nil, favorite: false)
        try JSONEncoder().encode(track).write(to: root.appendingPathComponent("track.json"))
        try store.save(track, temporary: audio, cover: nil, lyrics: nil)
        player.append([track], session: nil)
        player.lyrics = Lyrics.parse("[00:01]First line\n[00:03]Second line\n[00:06]Last line")
        player.position = 0
        settle()
        assert(desktop.lyricLines == ["Test Song", "前奏 · Resona"])
        assert(buttons[1...3].allSatisfy(\.isEnabled))
        player.position = 1
        settle()
        assert(desktop.lyricLines == ["First line", "Second line"])
        assert(buttons[0].title == "First line", "Menu bar must follow the active lyric")
        player.position = 6
        settle()
        assert(desktop.lyricLines == ["Last line"] && buttons[0].title == "Last line")
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
        assert(buttons[0].isHidden && desktop.statusItem.length == 146)
        assert(buttons[1...3].allSatisfy { !$0.isHidden && $0.isEnabled }, "Hiding lyrics must preserve resident controls")

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
        func finishFavorite() {
            for _ in 0..<30 {
                if !desktop.favoriting { break }
                settle()
            }
            settle()
            assert(!desktop.favoriting, "Favorite request did not finish")
        }
        assert(buttons[4].isEnabled)
        buttons[4].performClick(nil)
        assert(desktop.favoriting && !buttons[4].isEnabled, "Repeated favorite requests must be blocked")
        finishFavorite()
        assert(player.current?.favorite == true && library.tracks[0].favorite && buttons[4].toolTip == "取消喜欢")
        buttons[4].performClick(nil)
        finishFavorite()
        assert(player.current?.favorite == false && !library.tracks[0].favorite && buttons[4].toolTip == "喜欢")
        library.tracks[0].favorite = true
        settle()
        assert(buttons[4].toolTip == "取消喜欢", "Menu bar must follow favorite changes from the library")
        library.tracks[0].favorite = false
        library.session = Session(server: session.server, username: session.username, token: "expired")
        settle()
        buttons[4].performClick(nil)
        finishFavorite()
        assert(library.error != nil && player.current?.favorite == false && buttons[4].isEnabled,
               "Failed favorite requests must keep the previous state and allow retry")
        library.session = session
        settle()
        buttons[4].performClick(nil)
        finishFavorite()
        assert(library.error == nil && player.current?.favorite == true && buttons[4].toolTip == "取消喜欢",
               "Retrying favorite must clear the stale error and synchronize the liked state")
        let main = NSWindow(contentRect: NSRect(x: 100, y: 160, width: 1240, height: 800),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        main.contentView = NSHostingView(rootView: DesktopView(showingSettings: .constant(false))
            .environmentObject(library).environmentObject(player).tint(Theme.accent).preferredColorScheme(.light))
        main.makeKeyAndOrderFront(nil)
        settle()
        func clickArtwork() {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 270, y: 40),
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: main.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                main.sendEvent(event)
            }
            settle()
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
        buttons[2].performClick(nil)
        settle()
        assert(buttons[2].toolTip == "暂停", "Menu bar must play with the main window closed")
        buttons[2].performClick(nil)
        settle()
        assert(!player.playing && buttons[2].toolTip == "播放", "Menu bar must pause with the main window closed")
        buttons[1].performClick(nil)
        assert(player.position == 0, "Menu bar previous must reach the player")
        var reopened = false
        desktop.openMainWindow = { reopened = true; main.makeKeyAndOrderFront(nil) }
        desktop.showMainWindow()
        assert(reopened && main.isVisible)

        if CommandLine.arguments.contains("--capture") {
            desktop.menuLyricsEnabled = true
            player.lyrics = Lyrics.parse("[00:00]此刻，让音乐留在身边\n[00:03]每一句，都与你同步")
            player.position = 1
            settle()
            let images = root.appendingPathComponent("screenshots")
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
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
            let bitmap = status.bitmapImageRepForCachingDisplay(in: status.bounds)!
            status.cacheDisplay(in: status.bounds, to: bitmap)
            let menuImage = NSImage(size: status.bounds.size)
            menuImage.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: status.bounds).fill()
            NSImage(cgImage: bitmap.cgImage!, size: status.bounds.size)
                .draw(in: status.bounds, from: .zero, operation: .sourceOver, fraction: 1)
            menuImage.unlockFocus()
            let rendered = NSBitmapImageRep(data: menuImage.tiffRepresentation!)!
            try rendered.representation(using: .png, properties: [:])!.write(to: images.appendingPathComponent("menubar.png"))
            let existing = Set(NSApp.windows.map(\.windowNumber))
            buttons[5].performClick(nil)
            settle()
            let popup = NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) }!
            try capture(popup, "popover")
            status.performClick(nil)
            settle()
            assert(!popup.isVisible, "The native menu bar item must support keyboard activation")
            main.setContentSize(NSSize(width: 920, height: 620))
            player.expanded = true
            settle()
            try capture(main, "desktop-compact")
        }
        desktop.desktopLyricsEnabled = false
        main.close()
        NSStatusBar.system.removeStatusItem(desktop.statusItem)
        player.stop()
        print("macOS lyrics, preferences, panel lifecycle and resident playback tests passed")
    }
}
