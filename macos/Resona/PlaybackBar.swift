import AVKit
import SwiftUI

private final class StyledAirPlayRoutePickerView: AVRoutePickerView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyThemeColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyThemeColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    private func applyThemeColors() {
        let ink = NSColor(Theme.ink)
        let accent = NSColor(Theme.accent)
        setRoutePickerButtonColor(ink, for: .normal)
        setRoutePickerButtonColor(ink.withAlphaComponent(0.75), for: .normalHighlighted)
        setRoutePickerButtonColor(accent, for: .active)
        setRoutePickerButtonColor(accent.withAlphaComponent(0.8), for: .activeHighlighted)
    }
}

struct MacAirPlayPicker: NSViewRepresentable {
    let player: PlayerModel
    var onPresentingChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, onPresentingChange: onPresentingChange)
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = StyledAirPlayRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.player = player.avPlayer
        picker.delegate = context.coordinator
        picker.setAccessibilityLabel("AirPlay 隔空播放")
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        context.coordinator.player = player
        context.coordinator.onPresentingChange = onPresentingChange
        if nsView.player !== player.avPlayer {
            nsView.player = player.avPlayer
        }
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var player: PlayerModel
        var onPresentingChange: ((Bool) -> Void)?

        init(player: PlayerModel, onPresentingChange: ((Bool) -> Void)?) {
            self.player = player
            self.onPresentingChange = onPresentingChange
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            MainActor.assumeIsolated {
                player.prepareForAirPlayRouting()
                onPresentingChange?(true)
            }
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            MainActor.assumeIsolated {
                onPresentingChange?(false)
                player.refreshAudioOutputs()
            }
        }
    }
}

struct MacAirPlayPopover: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AirPlay")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    player.refreshDirectAirPlayDevices()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }

            if player.directAirPlayOutputs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                    Text("未发现局域网 AirPlay 音箱")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(player.directAirPlayOutputs) { device in
                        let isSelected = player.directAirPlayID == device.id
                        let isConnecting = player.directAirPlayConnectingID == device.id
                        Button {
                            if isSelected {
                                player.disconnectDirectAirPlay()
                            } else {
                                player.selectDirectAirPlay(device.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "airplayaudio")
                                    .font(.system(size: 13))
                                    .frame(width: 18)
                                    .foregroundStyle(isSelected || isConnecting ? Theme.accent : Theme.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                        .lineLimit(1)
                                    Text(isConnecting ? "正在连接…" : (isSelected ? "已连接 · 点击断开" : "点击投送"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.muted)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if isConnecting {
                                    ProgressView().controlSize(.small)
                                } else if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(isSelected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if player.directAirPlayID != nil {
                Divider()
                Button {
                    player.disconnectDirectAirPlay()
                } label: {
                    Label("断开连接，切回本机播放", systemImage: "speaker.wave.2")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }

            if player.hasAirPlay2Targets {
                Divider()
                HStack {
                    Text("其他 AirPlay 2 设备")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    MacAirPlayPicker(player: player)
                        .frame(width: 24, height: 24)
                }
            }

            if let directError = player.directAirPlayError, !directError.isEmpty {
                Text(directError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 248)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
        .onAppear {
            player.refreshDirectAirPlayDevices()
        }
    }
}

struct MacPlaybackSpeedPopover: View {
    @EnvironmentObject private var player: PlayerModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("倍速播放").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                    Text("当前 \(PlayerModel.formatPlaybackRate(player.playbackRate))")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                Spacer()
                Button("重置 1.0x") { player.setPlaybackRate(1.0) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(abs(player.playbackRate - 1.0) > 0.001 ? Theme.accent : Theme.muted)
                    .disabled(abs(player.playbackRate - 1.0) < 0.001)
            }

            HStack(spacing: 8) {
                Button("-0.1x") { player.stepPlaybackRate(by: -1) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(player.playbackRate <= 0.5)
                Slider(
                    value: Binding(
                        get: { Double(player.playbackRate) },
                        set: { player.setPlaybackRate(Float($0)) }
                    ),
                    in: 0.5...2.0,
                    step: 0.1
                ).accessibilityLabel("倍速滑块")
                Button("+0.1x") { player.stepPlaybackRate(by: 1) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(player.playbackRate >= 2.0)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(PlayerModel.supportedPlaybackRates, id: \.self) { rate in
                    let selected = abs(player.playbackRate - rate) < 0.001
                    Button {
                        player.setPlaybackRate(rate)
                    } label: {
                        Text(PlayerModel.formatPlaybackRate(rate))
                            .font(.system(size: 12, weight: selected ? .semibold : .regular).monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? Theme.accentOn : Theme.ink)
                            .background(selected ? Theme.accentFill : Theme.paper, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 268)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
    }
}

struct DesktopPlaybackBar: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showingSettings: Bool
    @Binding var showQueue: Bool
    @State private var playerBarHovered = false
    @State private var showSpeedPicker = false
    @State private var showAirPlayPicker = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case progress, artwork, previous, play, next, volume, favorite, mode, speed, airplay, queue
    }

    private var showTrackInfo: Bool {
        playerBarHovered || focusedControl != nil || !player.playing
    }

    private var barLyrics: [String] {
        Lyrics.playbackLines(player.lyrics, at: player.position).map(\.text)
    }

    private var canSeek: Bool { player.current != nil && player.duration > 0 }

    private var progress: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Theme.border
                Theme.accent.frame(width: geometry.size.width * min(1, max(0, player.position / max(1, player.duration))))
            }
            .overlay {
                Color.clear.frame(height: 16).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        player.seek(min(1, max(0, value.location.x / max(1, geometry.size.width))) * player.duration)
                    })
            }
        }.frame(height: 3)
            .disabled(!canSeek).allowsHitTesting(canSeek)
            .focusable(canSeek).focused($focusedControl, equals: .progress)
            .onKeyPress(.leftArrow) { player.seek(player.position - 5); return .handled }
            .onKeyPress(.rightArrow) { player.seek(player.position + 5); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(clock(player.position)) / \(clock(player.duration))")
            .accessibilityAdjustableAction { direction in
                guard canSeek else { return }
                switch direction {
                case .increment: player.seek(player.position + 5)
                case .decrement: player.seek(player.position - 5)
                @unknown default: break
                }
            }
    }

    var body: some View {
        let lyrics = barLyrics
        VStack(spacing: 0) {
            progress
            HStack(spacing: 22) {
                if let track = player.current {
                    Button { showingSettings = false; player.expanded.toggle() } label: {
                        HStack(spacing: 12) {
                            Artwork(path: track.artwork).frame(width: 46, height: 46)
                            ZStack(alignment: .leading) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(track.title).font(.system(size: 14, weight: .semibold))
                                    Text("\(track.artist) · \(track.album)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                }.opacity(showTrackInfo || lyrics.isEmpty ? 1 : 0)
                                    .accessibilityHidden(!showTrackInfo && !lyrics.isEmpty)
                                if !lyrics.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(lyrics[0]).font(.system(size: 14, weight: .medium))
                                        if lyrics.count > 1 {
                                            Text(lyrics[1]).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                        }
                                    }.opacity(showTrackInfo ? 0 : 1)
                                        .accessibilityHidden(showTrackInfo)
                                }
                            }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(player.expanded ? "收起播放页" : "展开海报与歌词")
                        .accessibilityLabel(player.expanded ? "收起播放页" : "展开海报与歌词")
                        .focused($focusedControl, equals: .artwork)
                } else {
                    Text("选一首，此刻想听的歌").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 18) {
                    Button { player.previous() } label: {
                        Image(systemName: "backward.end.fill").frame(width: 26, height: 36)
                    }.help("上一首").accessibilityLabel("上一首").focused($focusedControl, equals: .previous)
                    Button { player.toggle() } label: {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40).foregroundStyle(Theme.accentOn)
                            .background(Theme.accentFill, in: Circle())
                    }.help(player.playing ? "暂停" : "播放")
                        .accessibilityLabel(player.playing ? "暂停" : "播放").focused($focusedControl, equals: .play)
                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 26, height: 36)
                    }.help("下一首").accessibilityLabel("下一首").focused($focusedControl, equals: .next)
                }.buttonStyle(.plain).disabled(player.current == nil).fixedSize()
                HStack(spacing: 14) {
                    VStack(spacing: 5) {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            Slider(value: $player.volume, in: 0...1).frame(width: 76)
                                .controlSize(.mini).accessibilityLabel("音量")
                                .focused($focusedControl, equals: .volume)
                        }
                        Text("\(clock(player.position)) / \(clock(player.duration))")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                            .lineLimit(1).fixedSize()
                    }.frame(width: 108)
                    if let track = player.current {
                        let favorite = library.tracks.first(where: { $0.id == track.id }) ?? track
                        Button {
                            Task {
                                if let updated = await library.favorite(favorite), player.current?.id == updated.id { player.current = updated }
                            }
                        } label: {
                            Image(systemName: favorite.favorite ? "heart.fill" : "heart")
                                .foregroundStyle(favorite.favorite ? Theme.accent : Theme.ink).frame(width: 28, height: 36)
                        }.disabled(library.offline || library.session == nil).help(favorite.favorite ? "取消喜欢" : "喜欢")
                            .accessibilityLabel(favorite.favorite ? "取消喜欢" : "喜欢").focused($focusedControl, equals: .favorite)
                    }
                    Button { player.cycleMode() } label: {
                        Image(systemName: player.mode.symbol).frame(width: 28, height: 36)
                            .foregroundStyle(player.mode == .sequential ? Theme.ink : Theme.accent)
                    }.help(player.mode.title + "，点击切换").disabled(player.current == nil)
                        .accessibilityLabel(player.mode.title).focused($focusedControl, equals: .mode)
                    Button { showSpeedPicker.toggle() } label: {
                        Text(PlayerModel.formatPlaybackRate(player.playbackRate))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .frame(width: 36, height: 36)
                            .foregroundStyle(abs(player.playbackRate - 1.0) > 0.001 ? Theme.accent : Theme.ink)
                    }.help("倍速播放 · \(PlayerModel.formatPlaybackRate(player.playbackRate))")
                        .accessibilityLabel("倍速播放 · \(PlayerModel.formatPlaybackRate(player.playbackRate))")
                        .focused($focusedControl, equals: .speed)
                        .popover(isPresented: $showSpeedPicker, arrowEdge: .top) {
                            MacPlaybackSpeedPopover()
                        }
                    let directName = player.directAirPlayOutputs.first(where: { $0.id == player.directAirPlayID })?.name
                    let isAirPlay = directName != nil || player.airPlayActive
                    let activeTitle = directName ?? (player.airPlayActive ? player.activeOutput.name : "未连接")
                    Button { showAirPlayPicker.toggle() } label: {
                        Image(systemName: "airplayaudio")
                            .frame(width: 28, height: 36)
                            .foregroundStyle(isAirPlay || player.directAirPlayConnectingID != nil ? Theme.accent : Theme.ink)
                    }.help("AirPlay · \(activeTitle)")
                        .accessibilityLabel("AirPlay · \(activeTitle)")
                        .focused($focusedControl, equals: .airplay)
                        .popover(isPresented: $showAirPlayPicker, arrowEdge: .top) {
                            MacAirPlayPopover()
                        }
                    Button { withAnimation(.easeOut(duration: 0.2)) { showQueue.toggle() } } label: {
                        Image(systemName: "list.bullet").frame(width: 28, height: 36)
                            .foregroundStyle(showQueue ? Theme.accent : Theme.ink)
                    }.help("播放列表 · \(player.queue.count) 首").accessibilityLabel("播放列表")
                        .focused($focusedControl, equals: .queue)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 20).frame(height: 79)
        }.background(Theme.playerBar).contentShape(Rectangle())
            .onHover {
                playerBarHovered = $0
                if !$0 { focusedControl = nil }
            }
            .onKeyPress(.space) {
                guard focusedControl == .progress, player.current != nil else { return .ignored }
                player.toggle()
                return .handled
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showTrackInfo)
    }
}
