import AppKit
import CryptoKit
import SwiftUI

@main
struct DesktopTests {
    @MainActor static func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
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
        placementTests()
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
        assert(!desktop.desktopLyricsEnabled && desktop.menuLyricsEnabled && desktop.menuControlsEnabled)
        assert(desktop.statusItem.autosaveName == "ResonaMenuBar")
        assert(lyrics.window === status.window && buttons.allSatisfy { $0.window === status.window },
               "Lyrics and every playback control must occupy the same native status item")
        assert(defaults.double(forKey: MenuBarPlacement.positionKey) > 0)
        desktop.menuControlsEnabled = false
        settle()
        assert(buttons[0...3].allSatisfy(\.isHidden) && !buttons[4].isHidden)
        assert(!lyrics.isHidden && desktop.statusItem.isVisible, "Lyrics can remain visible with playback controls off")
        desktop.menuLyricsEnabled = false
        assert(lyrics.isHidden && desktop.statusItem.length == 24, "The app logo remains when both switches are off")
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
            assert(abs(statusFrame.minX - safe.minX - 24) <= 1,
                   "The lyric item must reserve the right-hand segment: frame \(statusFrame), safe \(safe), length \(desktop.statusItem.length), button \(status.frame)")
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

        let main = NSWindow(contentRect: NSRect(x: 100, y: 160, width: 1240, height: 800),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        func showLibrary() {
            main.contentView = NSHostingView(rootView: DesktopView(showingSettings: .constant(false))
                .environmentObject(library).environmentObject(player).environmentObject(desktop).tint(Theme.accent).preferredColorScheme(.light))
            main.makeKeyAndOrderFront(nil)
            settle()
        }
        showLibrary()
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
        settle()
        assert(player.playing && desktop.makeDockMenu().items.first?.title == "正在播放",
               "Dock playback must work with the main window closed")
        selectDock(dockItem("暂停"))
        settle()
        assert(!player.playing)
        player.position = 6
        selectDock(dockItem("上一首"))
        assert(player.position == 0, "Dock previous must reach the shared player")
        buttons[1].performClick(nil)
        settle()
        assert(buttons[1].toolTip == "暂停", "Menu bar must play with the main window closed")
        buttons[1].performClick(nil)
        settle()
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
        for (name, appearance, background) in [
            ("menubar", NSAppearance.Name.vibrantDark, NSColor.black),
            ("menubar-light", NSAppearance.Name.aqua, NSColor.white)
        ] {
            status.appearance = NSAppearance(named: appearance)
            settle()
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
            let existing = Set(NSApp.windows.map(\.windowNumber))
            buttons[4].performClick(nil)
            settle()
            let popup = NSApp.windows.first { $0.isVisible && !existing.contains($0.windowNumber) }!
            try capture(popup, "popover")
            status.performClick(nil)
            settle()
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
        let previousRect = NSRect(x: 835, y: 20, width: 30, height: 42)
        let nextRect = NSRect(x: 937, y: 20, width: 30, height: 42)
        let previousPaused = snapshot(previousRect)
        let nextPaused = snapshot(nextRect)
        // Drive the playing state without audio timing or pointer movement masking the regression.
        player.playing = true
        settle()
        settle()
        try snapshot(main.contentView!.bounds).write(to: root.appendingPathComponent("playing.png"))
        assert(snapshot(previousRect) == previousPaused && snapshot(nextRect) == nextPaused,
               "Previous and next must stay visible during playback without hover or keyboard focus")
        click(NSPoint(x: 900, y: 40))
        assert(!player.playing, "The visible pause button must work without first hovering the playback bar")
        desktop.desktopLyricsEnabled = false
        main.close()
        NSStatusBar.system.removeStatusItem(desktop.statusItem)
        player.stop()
        print("macOS selection, filters, batch actions, lyrics, preferences, panel lifecycle and resident playback tests passed")
    }
}
