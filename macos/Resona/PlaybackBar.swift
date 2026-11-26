import AVKit
import SwiftUI

struct MacAirPlayPicker: NSViewRepresentable {
    @ObservedObject var player: PlayerModel

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.player = player.avPlayer
        picker.delegate = context.coordinator
        picker.setAccessibilityLabel("AirPlay 隔空播放")
        applyColors(picker)
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        context.coordinator.player = player
        if nsView.player !== player.avPlayer {
            nsView.player = player.avPlayer
        }
        applyColors(nsView)
    }

    private func applyColors(_ picker: AVRoutePickerView) {
        let ink = NSColor(Theme.ink)
        let accent = NSColor(Theme.accent)
        picker.setRoutePickerButtonColor(ink, for: .normal)
        picker.setRoutePickerButtonColor(ink.withAlphaComponent(0.75), for: .normalHighlighted)
        picker.setRoutePickerButtonColor(accent, for: .active)
        picker.setRoutePickerButtonColor(accent.withAlphaComponent(0.8), for: .activeHighlighted)
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var player: PlayerModel
        init(player: PlayerModel) { self.player = player }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in
                player.prepareForAirPlayRouting()
            }
        }
    }
}

struct MacAudioOutputPopover: View {
    @EnvironmentObject private var player: PlayerModel

    private var sortedOutputs: [AudioOutputDevice] {
        let priority: (AudioOutputKind) -> Int = { kind in
            switch kind {
            case .bluetooth: return 0
            case .airPlay: return 1
            case .headphones: return 2
            case .speaker: return 3
            case .other: return 4
            }
        }
        return player.availableOutputs.sorted {
            let lhs = priority($0.kind), rhs = priority($1.kind)
            if lhs != rhs { return lhs < rhs }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("AirPlay 隔空播放").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    MacAirPlayPicker(player: player).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.airPlayActive ? "AirPlay 正在投送" : "选择 AirPlay 音箱或设备")
                            .font(.system(size: 13, weight: .medium))
                        Text("点击左侧隔空播放图标切换房间的兼容音箱")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("蓝牙与本机输出").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                outputRow(
                    title: "跟随系统默认",
                    subtitle: player.selectedOutputUID == nil ? player.activeOutput.name : "使用 macOS 系统声音输出",
                    symbol: "speaker.wave.2",
                    selected: player.selectedOutputUID == nil
                ) {
                    player.selectAudioOutput(nil)
                }
                ForEach(sortedOutputs) { device in
                    outputRow(
                        title: device.name,
                        subtitle: device.kind.label + (device.isDefault ? " · 系统默认" : ""),
                        symbol: device.kind.symbol,
                        selected: player.selectedOutputUID == device.id
                    ) {
                        player.selectAudioOutput(device.id)
                    }
                }
            }

            Divider()

            Button {
                player.openBluetoothSettings()
            } label: {
                Label("打开系统蓝牙设置…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless).foregroundStyle(Theme.accent)
        }
        .padding(16)
        .frame(width: 290)
        .foregroundStyle(Theme.ink)
        .background(Theme.surface)
        .onAppear { player.refreshAudioOutputs() }
    }

    private func outputRow(title: String, subtitle: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct MacPlaybackSpeedRuler: View {
    @ObservedObject var player: PlayerModel
    var compact: Bool = false

    private static let marks: [(index: Int, rate: Float, label: String)] = [
        (0, 0.5, "0.5x"),
        (5, 1.0, "1x"),
        (10, 1.5, "1.5x"),
        (15, 2.0, "2x"),
    ]

    private var selectedIndex: Int {
        min(max(Int((player.playbackRate * 10).rounded()) - 5, 0), 15)
    }

    var body: some View {
        let inset: CGFloat = compact ? 6 : 8
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            GeometryReader { geometry in
                let usable = max(geometry.size.width - inset * 2, 1)
                let active = selectedIndex
                ZStack {
                    ForEach(0..<16, id: \.self) { index in
                        let isSelected = index == active
                        let isMajor = index % 5 == 0
                        let x = inset + usable * CGFloat(index) / 15
                        Capsule()
                            .fill(isSelected ? Theme.ink : (isMajor ? Theme.secondary.opacity(0.65) : Theme.muted.opacity(0.42)))
                            .frame(
                                width: isSelected ? (compact ? 3.5 : 4) : 2,
                                height: isSelected ? (compact ? 24 : 28) : (isMajor ? (compact ? 14 : 18) : (compact ? 8 : 10))
                            )
                            .shadow(color: isSelected ? Theme.ink.opacity(0.25) : .clear, radius: 5)
                            .position(x: x, y: geometry.size.height / 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = min(max((value.location.x - inset) / usable, 0), 1)
                            let step = min(max(Int((ratio * 15).rounded()), 0), 15)
                            player.setPlaybackRate(Float(5 + step) / 10)
                        }
                )
            }
            .frame(height: compact ? 36 : 42)
            .focusable()
            .onKeyPress(.leftArrow) {
                player.stepPlaybackRate(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                player.stepPlaybackRate(by: 1)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("倍速播放")
            .accessibilityValue(PlayerModel.formatCompactPlaybackRate(player.playbackRate))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.stepPlaybackRate(by: 1)
                case .decrement: player.stepPlaybackRate(by: -1)
                @unknown default: break
                }
            }

            GeometryReader { geometry in
                let usable = max(geometry.size.width - inset * 2, 1)
                let active = selectedIndex
                ZStack(alignment: .leading) {
                    ForEach(Self.marks, id: \.index) { mark in
                        let isActive = mark.index == active
                        let button = Button {
                            player.setPlaybackRate(mark.rate)
                        } label: {
                            Text(mark.label)
                                .font(.system(size: compact ? 11 : 12, weight: isActive ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(isActive ? Theme.ink : Theme.muted)
                        }.buttonStyle(.plain)

                        if mark.index == 0 {
                            button.frame(maxWidth: .infinity, alignment: .leading)
                        } else if mark.index == 15 {
                            button.frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            button.position(x: inset + usable * CGFloat(mark.index) / 15, y: geometry.size.height / 2)
                        }
                    }
                }
            }
            .frame(height: 18)
        }
    }
}

struct MacPlaybackSpeedPopover: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("倍速播放").font(.subheadline).foregroundStyle(Theme.secondary)
                Text(PlayerModel.formatCompactPlaybackRate(player.playbackRate))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            MacPlaybackSpeedRuler(player: player)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 300)
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
    @State private var showOutputPicker = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case progress, artwork, previous, play, next, volume, favorite, mode, speed, output, queue
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
                    Button { showOutputPicker.toggle() } label: {
                        Image(systemName: player.airPlayActive ? "airplayaudio" : player.activeOutput.kind.symbol)
                            .frame(width: 28, height: 36)
                            .foregroundStyle(player.airPlayActive || player.activeOutput.kind == .bluetooth || player.selectedOutputUID != nil ? Theme.accent : Theme.ink)
                    }.help("AirPlay 与蓝牙音频输出 · \(player.activeOutput.name)")
                        .accessibilityLabel("音频输出 · \(player.activeOutput.name)")
                        .focused($focusedControl, equals: .output)
                        .popover(isPresented: $showOutputPicker, arrowEdge: .top) {
                            MacAudioOutputPopover()
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
