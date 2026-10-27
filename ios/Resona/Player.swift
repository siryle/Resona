import AVFoundation
import MediaPlayer
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

enum PlaybackMode: String, Codable, CaseIterable {
    case sequential, repeatAll, repeatOne, shuffle

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机循环"
        }
    }

    var symbol: String {
        switch self {
        case .sequential: return "arrow.right"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
}

private struct PlaybackState: Codable {
    let server: URL?
    let username: String?
    let current: Track?
    let queue: [Track]
    let position: Double
    let mode: PlaybackMode
    let volume: Float
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var current: Track?
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var lyrics: [LyricLine] = []
    @Published var plainLyrics = ""
    @Published var error: String?
    @Published var mode = PlaybackMode.sequential { didSet { savePlaybackState() } }
    @Published var expanded = false
    @Published private(set) var queue: [Track] = []
    @Published var volume: Float = 0.8 {
        didSet { player.volume = volume; savePlaybackState() }
    }

    private let player: AVPlayer
    private let downloads: OfflineStore
    private let cache: PlaybackCache
    private let stateURL: URL
    private var restored = false
    private var restoring = false
    private var savedPosition: Double = 0
    private var cacheRequested = false
    private var session: Session?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var lyricTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var linkRetried = false
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var interrupted = false
    private var playbackObserver: NSKeyValueObservation?
    private var playbackRequested = false
    private var reachedEnd = false
    var shuffle: Bool {
        get { mode == .shuffle }
        set { if newValue { mode = .shuffle } else if shuffle { mode = .sequential } }
    }
    var isLocal: Bool { player.currentItem?.asset is AVURLAsset && (player.currentItem?.asset as? AVURLAsset)?.url.isFileURL == true }

    init(downloads: OfflineStore = .shared, cache: PlaybackCache? = nil, player: AVPlayer = AVPlayer()) {
        self.player = player
        self.downloads = downloads
        self.cache = cache ?? .shared
        self.stateURL = downloads.root.appendingPathComponent("playback.json")
        player.volume = volume
        playbackObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playing = self.player.timeControlStatus != .paused
                self.updateNowPlaying()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if let value = self.player.currentItem?.duration.seconds, value.isFinite, value > 0 { self.duration = value }
                if abs(self.position - self.savedPosition) >= 5 { self.savePlaybackState() }
                if self.position > 0, !self.isLocal, !self.cacheRequested,
                   let track = self.current, let session = self.session {
                    self.cacheRequested = true
                    self.cache.start(track, session: session)
                }
            }
        }
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true
                    // Preserve user intent even when AVPlayer has already reported the system pause.
                    self.player.pause()
                    self.playing = false
                    self.updateNowPlaying()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self.interrupted = false
                    let shouldResume = self.playbackRequested &&
                        AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.playbackRequested = false
                    if shouldResume { self.resume() }
                }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: value) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch reason {
                case .oldDeviceUnavailable:
                    self.pause()
                case .newDeviceAvailable, .routeConfigurationChange:
                    // Recover a system pause during routing without waiting for the UI to become active.
                    if self.playbackRequested && !self.interrupted { self.resume() }
                default:
                    break
                }
            }
        }
        #endif
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }
            return .success
        }
    }

    func restorePlayback(session: Session?) {
        guard !restored else { return }
        restored = true
        guard current == nil,
              let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PlaybackState.self, from: data),
              state.server == session?.server, state.username == session?.username,
              state.position.isFinite, state.volume.isFinite else { return }
        restoring = true
        defer { restoring = false }
        self.session = session
        if let session { cache.activate(session) }
        queue = state.queue
        current = state.current
        if let current, !queue.contains(where: { $0.id == current.id }) { queue.append(current) }
        duration = max(0, current?.duration ?? 0)
        position = min(max(0, state.position), duration)
        savedPosition = position
        mode = state.mode
        volume = min(max(0, state.volume), 1)
    }

    func savePlaybackState() {
        guard restored, !restoring else { return }
        let state = PlaybackState(server: session?.server, username: session?.username,
                                  current: current, queue: queue, position: position, mode: mode, volume: volume)
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            savedPosition = position
        } catch {
            self.error = "无法保存播放状态：\(error.localizedDescription)"
        }
    }

    func play(_ track: Track, queue: [Track], session: Session?, recovering: Bool = false, startPosition: Double = 0) {
        if let session { cache.activate(session) }
        let local = localAudio(track)
        guard local != nil || session != nil else { error = "请在设置中连接服务器，或播放已下载的歌曲。"; return }
        restored = true
        self.queue = session == nil ? queue.filter { localAudio($0) != nil } : queue
        self.session = session
        if !recovering { linkRetried = false }
        playbackRequested = false
        reachedEnd = false
        cacheRequested = false
        current = track
        artworkTask?.cancel()
        #if os(iOS)
        let brand = PlatformImage(named: "BrandIcon")
        #else
        let brand = Bundle.main.url(forResource: "BrandIcon", withExtension: "png").flatMap { PlatformImage(contentsOf: $0) }
        #endif
        nowPlayingArtwork = brand.map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        let localStore = downloads.audio(track) != nil ? downloads : cache.store
        if let cover = localStore?.sidecar(track.id, name: "cover"),
           let image = PlatformImage(contentsOfFile: cover.path) {
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        duration = track.duration
        position = min(max(0, startPosition), duration)
        lyrics = []
        plainLyrics = ""
        error = nil
        let asset: AVURLAsset
        if let local {
            asset = AVURLAsset(url: local)
        } else if let session {
            var url = session.server.appendingPathComponent("api/v1/tracks/\(track.id)/stream")
            if recovering { url.append(queryItems: [URLQueryItem(name: "refresh", value: "1")]) }
            // AVFoundation's documented cookie option also authenticates byte-range requests.
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: url.host ?? "", .path: "/", .name: "resona_session", .value: session.token,
                .expires: Date().addingTimeInterval(7 * 24 * 3600)
            ]
            if url.scheme == "https" { properties[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties) else { error = "无法建立播放会话"; return }
            asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: [cookie]])
        } else { return }
        let item = AVPlayerItem(asset: asset)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "音频格式不受支持"
            Task { @MainActor [weak self] in
                guard let self, self.current?.id == track.id else { return }
                if track.library == "cloud", !self.linkRetried, let session = self.session {
                    self.linkRetried = true
                    let position = self.position
                    let resume = self.playbackRequested
                    self.play(track, queue: self.queue, session: session, recovering: true)
                    self.seek(position)
                    if !resume { self.pause() }
                } else {
                    self.error = message
                    self.pause()
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next(automatic: true) }
        }
        player.replaceCurrentItem(with: item)
        if position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        savePlaybackState()
        resume()
        artworkTask = Task { [weak self] in
            guard local == nil, let session, track.artwork != nil else { return }
            var request = URLRequest(url: session.server.appendingPathComponent("api/v1/tracks/\(track.id)/cover"))
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 5 * 1024 * 1024, let image = PlatformImage(data: data),
                  !Task.isCancelled, let self, self.current?.id == track.id,
                  self.session?.token == session.token else { return }
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateNowPlaying()
        }
        lyricTask?.cancel()
        if let url = localStore?.sidecar(track.id, name: "lyrics"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            lyrics = Lyrics.parse(text)
            plainLyrics = lyrics.isEmpty ? text : ""
        }
        lyricTask = Task { [weak self] in
            guard local == nil, let session else { return }
            var request = URLRequest(url: session.server.appendingPathComponent("api/v1/tracks/\(track.id)/lyrics"))
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !Task.isCancelled, self?.current?.id == track.id,
                  let text = String(data: data, encoding: .utf8) else { return }
            self?.lyrics = Lyrics.parse(text)
            self?.plainLyrics = self?.lyrics.isEmpty == true ? text : ""
        }
    }

    func resume() {
        guard let current else { return }
        if player.currentItem == nil {
            play(current, queue: queue, session: session, startPosition: position)
            return
        }
        if reachedEnd || (duration > 0 && position >= duration) { seek(0) }
        do {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try audioSession.setActive(true)
            #endif
            playbackRequested = true
            player.play()
            playing = player.timeControlStatus != .paused
            updateNowPlaying()
        } catch {
            self.error = error.localizedDescription
            pause()
        }
    }
    func pause() {
        playbackRequested = false
        player.pause()
        playing = false
        updateNowPlaying()
        savePlaybackState()
    }
    func toggle() { playing ? pause() : resume() }

    func seek(_ seconds: Double) {
        reachedEnd = false
        position = min(max(0, seconds), duration)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        updateNowPlaying()
        savePlaybackState()
    }

    func next(automatic: Bool = false) {
        guard let current, !queue.isEmpty,
              let index = queue.firstIndex(where: { $0.id == current.id }) else { return }
        if automatic && mode == .repeatOne {
            play(current, queue: queue, session: session)
        } else if shuffle {
            let candidates = queue.filter { $0.id != current.id }
            play(candidates.randomElement() ?? current, queue: queue, session: session)
        } else if index + 1 < queue.count {
            play(queue[index + 1], queue: queue, session: session)
        } else if mode == .repeatAll || mode == .repeatOne {
            play(queue[0], queue: queue, session: session)
        } else if automatic { pause(); seek(duration); reachedEnd = true }
    }

    func previous() {
        guard let current, let index = queue.firstIndex(where: { $0.id == current.id }) else { return }
        if position > 3 || index == 0 { seek(0) }
        else { play(queue[index - 1], queue: queue, session: session) }
    }

    func append(_ tracks: [Track], session: Session?) {
        var existing = Set(queue.map(\.id))
        let added = tracks.filter { (session != nil || localAudio($0) != nil) && existing.insert($0.id).inserted }
        if isLocal { self.session = session }
        if current == nil, let first = added.first {
            play(first, queue: added, session: session)
            pause()
        } else { queue += added }
        savePlaybackState()
    }

    func connectionChanged(_ session: Session?) {
        let previous = self.session
        if previous?.server == session?.server && previous?.username == session?.username {
            self.session = session
            if let session { cache.activate(session) }
            return
        }
        if isLocal || (player.currentItem == nil && current.flatMap({ localAudio($0) }) != nil) {
            self.session = session
            if let session { cache.activate(session) }
            queue = queue.filter { localAudio($0) != nil }
            savePlaybackState()
        } else { stop() }
    }

    private func localAudio(_ track: Track) -> URL? { downloads.audio(track) ?? cache.audio(track) }

    func cycleMode() {
        let modes = PlaybackMode.allCases
        mode = modes[(modes.firstIndex(of: mode)! + 1) % modes.count]
    }

    func stop() {
        pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        session = nil
        queue = []
        lyrics = []
        plainLyrics = ""
        lyricTask?.cancel()
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        position = 0
        duration = 0
        savePlaybackState()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func updateNowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyAlbumTitle: current.album, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #endif
    }
}
