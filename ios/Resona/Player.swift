import AVFoundation
import AVKit
import MediaPlayer
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
import CoreAudio
typealias PlatformImage = NSImage
#endif

enum AudioOutputKind: String, Equatable, Codable {
    case speaker, headphones, bluetooth, airPlay, other

    var symbol: String {
        switch self {
        case .airPlay: return "airplayaudio"
        case .bluetooth, .headphones: return "headphones"
        case .speaker: return "speaker.wave.2"
        case .other: return "hifispeaker"
        }
    }

    var label: String {
        switch self {
        case .airPlay: return "AirPlay"
        case .bluetooth: return "蓝牙"
        case .headphones: return "耳机 / 外接音频"
        case .speaker: return "本机扬声器"
        case .other: return "音频输出"
        }
    }
}

struct AudioOutputDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: AudioOutputKind
    let isDefault: Bool
}

#if os(macOS)
private final class CoreAudioListeners {
    private var entries: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    func register(selector: AudioObjectPropertySelector, queue: DispatchQueue, handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status == noErr {
            entries.append((selector, block))
        }
    }

    deinit {
        for (selector, block) in entries {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
            )
        }
    }
}

@MainActor
protocol MacDirectAirPlayBackend: AnyObject {
    var devices: [AudioOutputDevice] { get }
    var activeDeviceID: String? { get }
    var connectingDeviceID: String? { get }
    var hasAirPlay2Targets: Bool { get }
    var lastError: String? { get }
    var onStateChange: (() -> Void)? { get set }
    var onDisconnect: ((String?) -> Void)? { get set }
    func startDiscovery()
    func refreshDiscovery()
    func connect(deviceID: String, initialVolume: Float) async throws
    func disconnect()
    func setVolume(_ volume: Float)
    func flush()
    func attachTap(to item: AVPlayerItem) async
    func detachTap(from item: AVPlayerItem)
}
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
    let playbackRate: Float?
}

@MainActor
final class PlayerModel: ObservableObject {
    static let supportedPlaybackRates: [Float] = (5...20).map { Float($0) / 10 }

    static func normalizePlaybackRate(_ value: Float) -> Float {
        guard value.isFinite else { return 1.0 }
        let clamped = min(max(value, 0.5), 2.0)
        return (clamped * 10).rounded() / 10
    }

    static func formatPlaybackRate(_ value: Float) -> String {
        String(format: "%.1fx", normalizePlaybackRate(value))
    }

    static func formatCompactPlaybackRate(_ value: Float) -> String {
        let normalized = normalizePlaybackRate(value)
        let tenths = Int((normalized * 10).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)x" : String(format: "%.1fx", normalized)
    }

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
        didSet {
            #if os(macOS)
            if directAirPlayID != nil {
                player.volume = 0
                directAirPlay?.setVolume(volume)
            } else {
                player.volume = volume
            }
            #else
            player.volume = volume
            #endif
            savePlaybackState()
        }
    }
    @Published var playbackRate: Float = 1.0 {
        didSet {
            let normalized = Self.normalizePlaybackRate(playbackRate)
            if abs(playbackRate - normalized) > 0.0001 {
                playbackRate = normalized
                return
            }
            player.defaultRate = playbackRate
            if playing || player.timeControlStatus != .paused {
                player.rate = playbackRate
            }
            updateNowPlaying()
            savePlaybackState()
        }
    }
    @Published private(set) var activeOutput = AudioOutputDevice(id: "system", name: "本机输出", kind: .speaker, isDefault: true)
    @Published private(set) var availableOutputs: [AudioOutputDevice] = []
    @Published private(set) var selectedOutputUID: String?
    @Published private(set) var airPlayActive = false
    #if os(macOS)
    @Published private(set) var directAirPlayOutputs: [AudioOutputDevice] = []
    @Published private(set) var directAirPlayID: String?
    @Published private(set) var directAirPlayConnectingID: String?
    @Published private(set) var directAirPlayError: String?
    @Published private(set) var hasAirPlay2Targets = false
    #endif
    var avPlayer: AVPlayer { player }

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
    #if os(iOS)
    let nowPlayingSession: MPNowPlayingSession
    var nowPlayingInfoCenter: MPNowPlayingInfoCenter { nowPlayingSession.nowPlayingInfoCenter }
    #else
    var nowPlayingInfoCenter: MPNowPlayingInfoCenter { MPNowPlayingInfoCenter.default() }
    #endif

    private var linkRetried = false
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var interrupted = false
    private var playbackObserver: NSKeyValueObservation?
    private var externalPlaybackObserver: NSKeyValueObservation?
    #if os(macOS)
    private let audioListeners = CoreAudioListeners()
    private var directAirPlay: (any MacDirectAirPlayBackend)?
    private var tapAttachTask: Task<Void, Never>?
    #endif
    private var playbackRequested = false
    private var reachedEnd = false
    private var pendingSeekTarget: Double?
    private var seekGeneration = 0
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
        #if os(iOS)
        self.nowPlayingSession = MPNowPlayingSession(players: [player])
        player.allowsExternalPlayback = false
        nowPlayingSession.automaticallyPublishesNowPlayingInfo = true
        nowPlayingSession.becomeActiveIfPossible()
        Task { @MainActor in
            if Bundle.main.bundleURL.pathExtension == "app" {
                UIApplication.shared.beginReceivingRemoteControlEvents()
            }
        }
        #else
        player.allowsExternalPlayback = true
        #endif
        player.volume = volume
        player.defaultRate = playbackRate
        playbackObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let active = self.player.timeControlStatus != .paused
                if active && !self.playbackRequested && self.player.rate == 0 {
                    return
                }
                self.playing = active
                self.updateNowPlaying()
            }
        }
        externalPlaybackObserver = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioOutputs()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil else { return }
                if self.pendingSeekTarget == nil {
                    self.position = time.seconds.isFinite ? time.seconds : 0
                }
                if let value = self.player.currentItem?.duration.seconds, value.isFinite, value > 0 {
                    let changed = abs(value - self.duration) >= 0.5
                    self.duration = value
                    if changed { self.updateNowPlaying() }
                }
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
                self.refreshAudioOutputs()
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
        try? configureAudioSession()
        activateNowPlayingSession()
        refreshAudioOutputs()
        let center = nowPlayingSession.remoteCommandCenter
        #else
        audioListeners.register(selector: kAudioHardwarePropertyDevices, queue: .main) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshAudioOutputs() }
        }
        audioListeners.register(selector: kAudioHardwarePropertyDefaultOutputDevice, queue: .main) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshAudioOutputs() }
        }
        refreshAudioOutputs()
        let center = MPRemoteCommandCenter.shared()
        #endif
        [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.changePlaybackPositionCommand,
            center.changePlaybackRateCommand,
        ].forEach { $0.isEnabled = true }
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.supportedPlaybackRates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.setPlaybackRate(event.playbackRate) }
            return .success
        }
    }

    func setPlaybackRate(_ value: Float) {
        playbackRate = Self.normalizePlaybackRate(value)
    }

    func stepPlaybackRate(by tenths: Int) {
        let currentTenths = Int((playbackRate * 10).rounded())
        setPlaybackRate(Float(currentTenths + tenths) / 10)
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
        playbackRate = Self.normalizePlaybackRate(state.playbackRate ?? 1.0)
        player.defaultRate = playbackRate
        if let current {
            loadNowPlayingArtwork(for: current, session: session)
            loadLyrics(for: current, session: session)
            updateNowPlaying()
        }
    }

    func savePlaybackState() {
        guard restored, !restoring else { return }
        let state = PlaybackState(server: session?.server, username: session?.username,
                                  current: current, queue: queue, position: position, mode: mode,
                                  volume: volume, playbackRate: playbackRate)
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            savedPosition = position
        } catch {
            self.error = "无法保存播放状态：\(error.localizedDescription)"
        }
    }

    private func localStore(for track: Track) -> OfflineStore? {
        downloads.audio(track) != nil ? downloads : cache.store
    }

    private func loadNowPlayingArtwork(for track: Track, session: Session?) {
        artworkTask?.cancel()
        #if os(iOS)
        let brand = PlatformImage(named: "BrandIcon")
        #else
        let brand = Bundle.main.url(forResource: "BrandIcon", withExtension: "png").flatMap { PlatformImage(contentsOf: $0) }
        #endif
        nowPlayingArtwork = brand.map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        if let cover = localStore(for: track)?.sidecar(track.id, name: "cover"),
           let image = PlatformImage(contentsOfFile: cover.path) {
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            return
        }
        guard let session, track.artwork != nil else { return }
        artworkTask = Task { [weak self] in
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
    }

    private func loadLyrics(for track: Track, session: Session?) {
        lyricTask?.cancel()
        if let url = localStore(for: track)?.sidecar(track.id, name: "lyrics"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            lyrics = Lyrics.parse(text)
            plainLyrics = lyrics.isEmpty ? text : ""
            return
        }
        guard let session else { return }
        lyricTask = Task { [weak self] in
            var request = URLRequest(url: session.server.appendingPathComponent("api/v1/tracks/\(track.id)/lyrics"))
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !Task.isCancelled, self?.current?.id == track.id,
                  self?.session?.token == session.token,
                  let text = String(data: data, encoding: .utf8) else { return }
            self?.lyrics = Lyrics.parse(text)
            self?.plainLyrics = self?.lyrics.isEmpty == true ? text : ""
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
        seekGeneration &+= 1
        pendingSeekTarget = nil
        current = track
        loadNowPlayingArtwork(for: track, session: session)
        duration = track.duration
        position = min(max(0, startPosition), duration)
        lyrics = []
        plainLyrics = ""
        error = nil
        loadLyrics(for: track, session: session)
        let asset: AVURLAsset
        if let local {
            asset = AVURLAsset(url: local)
        } else if let session {
            var url = session.server.appendingPathComponent("api/v1/tracks/\(track.id)/stream")
            if recovering { url.append(queryItems: [URLQueryItem(name: "refresh", value: "1")]) }
            // AVFoundation's documented cookie option also authenticates byte-range requests.
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: url.host ?? "", .path: "/", .name: "resona_session", .value: session.token,
                .expires: Date().addingTimeInterval(365 * 24 * 3600)
            ]
            if url.scheme == "https" { properties[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties) else { error = "无法建立播放会话"; return }
            asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: [cookie]])
        } else { return }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        #if os(iOS)
        nowPlayingSession.automaticallyPublishesNowPlayingInfo = true
        item.nowPlayingInfo = nowPlayingMetadata(for: track, includePlaybackTiming: false)
        #endif
        player.defaultRate = playbackRate
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
        #if os(macOS)
        if directAirPlayID != nil {
            player.volume = 0
            directAirPlay?.flush()
            scheduleDirectAirPlayTap(for: item)
        }
        #endif
        if position > 0 {
            let generation = seekGeneration
            pendingSeekTarget = position
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.seekGeneration == generation else { return }
                    self.pendingSeekTarget = nil
                    self.updateNowPlaying()
                }
            }
        }
        savePlaybackState()
        resume()
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
            try configureAudioSession()
            try AVAudioSession.sharedInstance().setActive(true)
            refreshAudioOutputs()
            #endif
            playbackRequested = true
            player.defaultRate = playbackRate
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
        #if os(macOS)
        if directAirPlayID != nil {
            directAirPlay?.flush()
        }
        #endif
        playing = false
        updateNowPlaying()
        savePlaybackState()
    }
    func toggle() { playing ? pause() : resume() }

    func seek(_ seconds: Double) {
        reachedEnd = false
        let clamped = min(max(0, seconds), duration)
        position = clamped
        seekGeneration &+= 1
        let generation = seekGeneration
        if player.currentItem != nil {
            pendingSeekTarget = clamped
            player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.seekGeneration == generation else { return }
                    self.pendingSeekTarget = nil
                    if self.player.currentItem != nil {
                        let currentSeconds = self.player.currentTime().seconds
                        if currentSeconds.isFinite {
                            self.position = min(max(0, currentSeconds), max(self.duration, currentSeconds))
                        }
                    }
                    self.updateNowPlaying()
                }
            }
        } else {
            pendingSeekTarget = nil
        }
        #if os(macOS)
        if directAirPlayID != nil {
            directAirPlay?.flush()
        }
        #endif
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
        seekGeneration &+= 1
        pendingSeekTarget = nil
        #if os(macOS)
        if directAirPlayID != nil {
            directAirPlay?.flush()
        }
        #endif
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
        #if os(iOS)
        nowPlayingSession.automaticallyPublishesNowPlayingInfo = false
        nowPlayingInfoCenter.nowPlayingInfo = nil
        #else
        nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingInfoCenter.playbackState = .stopped
        #endif
    }

    private func nowPlayingMetadata(for track: Track, includePlaybackTiming: Bool) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        if includePlaybackTiming {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
            info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(playbackRate) : 0.0
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Double(playbackRate)
        }
        if let index = queue.firstIndex(where: { $0.id == track.id }) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        return info
    }

    private func updateNowPlaying() {
        guard let current else { return }
        #if os(iOS)
        activateNowPlayingSession()
        if let item = player.currentItem {
            nowPlayingSession.automaticallyPublishesNowPlayingInfo = true
            item.nowPlayingInfo = nowPlayingMetadata(for: current, includePlaybackTiming: false)
        } else {
            nowPlayingSession.automaticallyPublishesNowPlayingInfo = false
            nowPlayingInfoCenter.nowPlayingInfo = nowPlayingMetadata(for: current, includePlaybackTiming: true)
        }
        #else
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingMetadata(for: current, includePlaybackTiming: true)
        nowPlayingInfoCenter.playbackState = playing ? .playing : .paused
        #endif
    }

    #if os(iOS)
    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.category == .playback,
           audioSession.mode == .default,
           audioSession.routeSharingPolicy == .longFormAudio {
            return
        }
        try audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func activateNowPlayingSession() {
        nowPlayingSession.becomeActiveIfPossible()
    }

    func prepareForAudioRouteSelection() {
        try? configureAudioSession()
        if current != nil {
            try? AVAudioSession.sharedInstance().setActive(true)
            activateNowPlayingSession()
            updateNowPlaying()
        }
        refreshAudioOutputs()
    }

    func handleAudioRouteSelectionEnded() {
        refreshAudioOutputs()
        if current != nil {
            activateNowPlayingSession()
            updateNowPlaying()
        }
    }

    static func classifyPort(_ port: AVAudioSession.Port) -> AudioOutputKind {
        switch port {
        case .airPlay:
            return .airPlay
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return .bluetooth
        case .headphones, .headsetMic, .usbAudio, .lineOut, .carAudio:
            return .headphones
        case .builtInSpeaker, .builtInReceiver:
            return .speaker
        default:
            return .other
        }
    }

    func refreshAudioOutputs() {
        let routeOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let mapped = routeOutputs.map { output -> AudioOutputDevice in
            let kind = Self.classifyPort(output.portType)
            let trimmedName = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmedName.isEmpty ? kind.label : trimmedName
            let id = output.uid.isEmpty ? kind.rawValue : output.uid
            return AudioOutputDevice(
                id: id,
                name: name,
                kind: kind,
                isDefault: true
            )
        }
        availableOutputs = mapped
        if let primary = mapped.first {
            activeOutput = primary
        } else {
            activeOutput = AudioOutputDevice(id: "system", name: "本机扬声器", kind: .speaker, isDefault: true)
        }
        airPlayActive = player.isExternalPlaybackActive || activeOutput.kind == .airPlay
    }
    #else
    static func classifyTransport(_ transport: UInt32) -> AudioOutputKind {
        switch transport {
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            return .speaker
        default:
            return .other
        }
    }

    func refreshAudioOutputs() {
        handleAudioOutputChange(devices: Self.enumerateCoreAudioOutputs())
    }

    func handleAudioOutputChange(devices: [AudioOutputDevice]) {
        if let uid = selectedOutputUID, !devices.contains(where: { $0.id == uid }) {
            selectedOutputUID = nil
            player.audioOutputDeviceUniqueID = nil
            if playing || playbackRequested { pause() }
        } else if selectedOutputUID == nil,
                  (activeOutput.kind == .bluetooth || activeOutput.kind == .headphones),
                  !devices.contains(where: { $0.id == activeOutput.id }) {
            if playing || playbackRequested { pause() }
        }
        availableOutputs = devices
        if let uid = selectedOutputUID, let match = devices.first(where: { $0.id == uid }) {
            activeOutput = match
        } else if let fallback = devices.first(where: { $0.isDefault }) ?? devices.first {
            activeOutput = fallback
        } else {
            activeOutput = AudioOutputDevice(id: "system", name: "本机输出", kind: .speaker, isDefault: true)
        }
        if let activeID = directAirPlayID {
            activeOutput = directAirPlayOutputs.first(where: { $0.id == activeID })
                ?? AudioOutputDevice(id: activeID, name: activeOutput.name, kind: .airPlay, isDefault: false)
            airPlayActive = true
        } else {
            airPlayActive = player.isExternalPlaybackActive || activeOutput.kind == .airPlay
        }
    }

    func selectAudioOutput(_ uid: String?) {
        if directAirPlayID != nil || directAirPlayConnectingID != nil {
            disconnectDirectAirPlay()
        }
        selectedOutputUID = uid
        player.audioOutputDeviceUniqueID = uid
        handleAudioOutputChange(devices: availableOutputs)
    }

    func prepareForAirPlayRouting() {
        if directAirPlayID != nil || directAirPlayConnectingID != nil {
            disconnectDirectAirPlay()
        }
        guard selectedOutputUID != nil || player.audioOutputDeviceUniqueID != nil else { return }
        selectedOutputUID = nil
        player.audioOutputDeviceUniqueID = nil
        handleAudioOutputChange(devices: availableOutputs)
    }

    func configureDirectAirPlay(_ backend: any MacDirectAirPlayBackend) {
        directAirPlay = backend
        backend.onStateChange = { [weak self] in
            self?.syncDirectAirPlayState()
        }
        backend.onDisconnect = { [weak self] reason in
            guard let self else { return }
            if self.playing || self.playbackRequested {
                self.pause()
            }
            self.disconnectDirectAirPlay(errorMessage: reason ?? "AirPlay 连接已断开")
        }
        backend.startDiscovery()
        syncDirectAirPlayState()
    }

    func refreshDirectAirPlayDevices() {
        directAirPlay?.refreshDiscovery()
    }

    func selectDirectAirPlay(_ deviceID: String) {
        if directAirPlayID == deviceID {
            disconnectDirectAirPlay()
            return
        }
        guard let backend = directAirPlay else { return }
        selectedOutputUID = nil
        player.audioOutputDeviceUniqueID = nil
        directAirPlayError = nil
        directAirPlayConnectingID = deviceID
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await backend.connect(deviceID: deviceID, initialVolume: self.volume)
                guard self.directAirPlayConnectingID == deviceID else {
                    if self.directAirPlayID == nil {
                        backend.disconnect()
                    }
                    return
                }
                self.directAirPlayID = deviceID
                self.directAirPlayConnectingID = nil
                self.player.volume = 0
                backend.setVolume(self.volume)
                self.syncDirectAirPlayState()
                if let item = self.player.currentItem {
                    self.scheduleDirectAirPlayTap(for: item)
                }
            } catch {
                if self.directAirPlayConnectingID == deviceID {
                    self.directAirPlayConnectingID = nil
                }
                if self.directAirPlayID == nil {
                    self.player.volume = self.volume
                }
                self.directAirPlayError = error.localizedDescription
                self.refreshAudioOutputs()
            }
        }
    }

    func disconnectDirectAirPlay(errorMessage: String? = nil) {
        tapAttachTask?.cancel()
        tapAttachTask = nil
        if let item = player.currentItem {
            directAirPlay?.detachTap(from: item)
        }
        directAirPlay?.disconnect()
        directAirPlayID = nil
        directAirPlayConnectingID = nil
        directAirPlayError = errorMessage
        player.volume = volume
        refreshAudioOutputs()
    }

    private func scheduleDirectAirPlayTap(for item: AVPlayerItem) {
        tapAttachTask?.cancel()
        tapAttachTask = Task { @MainActor [weak self] in
            guard let self, let backend = self.directAirPlay,
                  self.directAirPlayID != nil, self.player.currentItem === item else { return }
            await backend.attachTap(to: item)
        }
    }

    private func syncDirectAirPlayState() {
        guard let backend = directAirPlay else { return }
        directAirPlayOutputs = backend.devices
        hasAirPlay2Targets = backend.hasAirPlay2Targets
        handleAudioOutputChange(devices: availableOutputs)
    }

    func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func enumerateCoreAudioOutputs() -> [AudioOutputDevice] {
        var defaultDevice = AudioObjectID(kAudioObjectUnknown)
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultSize = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &defaultSize, &defaultDevice
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devicesSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &devicesSize
        ) == noErr, devicesSize > 0 else { return [] }
        let count = Int(devicesSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &devicesSize, &ids
        ) == noErr else { return [] }

        return ids.compactMap { deviceID in
            guard hasOutputStreams(deviceID),
                  let uid = coreAudioStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = coreAudioStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) else {
                return nil
            }
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport)
            return AudioOutputDevice(
                id: uid,
                name: name,
                kind: classifyTransport(transport),
                isDefault: deviceID == defaultDevice
            )
        }
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return false }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).contains { $0.mNumberChannels > 0 }
    }

    private static func coreAudioStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
    #endif
}
