import SwiftUI

struct DesktopPlaybackBar: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showingSettings: Bool
    @Binding var showQueue: Bool
    @State private var playerBarHovered = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case progress, artwork, previous, play, next, volume, favorite, mode, queue
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
                Theme.ink.opacity(0.12)
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
                                    Text("\(track.artist) · \(track.album)").font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.65))
                                }.opacity(showTrackInfo || lyrics.isEmpty ? 1 : 0)
                                    .accessibilityHidden(!showTrackInfo && !lyrics.isEmpty)
                                if !lyrics.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(lyrics[0]).font(.system(size: 14, weight: .medium))
                                        if lyrics.count > 1 {
                                            Text(lyrics[1]).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.65))
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
                            .frame(width: 40, height: 40).foregroundStyle(.white)
                            .background(Theme.accent, in: Circle())
                    }.help(player.playing ? "暂停" : "播放")
                        .accessibilityLabel(player.playing ? "暂停" : "播放").focused($focusedControl, equals: .play)
                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 26, height: 36)
                    }.help("下一首").accessibilityLabel("下一首").focused($focusedControl, equals: .next)
                }.buttonStyle(.plain).disabled(player.current == nil).fixedSize()
                HStack(spacing: 14) {
                    VStack(spacing: 5) {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.wave.2").font(.system(size: 12))
                            Slider(value: $player.volume, in: 0...1).frame(width: 76)
                                .controlSize(.mini).accessibilityLabel("音量")
                                .focused($focusedControl, equals: .volume)
                        }
                        Text("\(clock(player.position)) / \(clock(player.duration))")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.65))
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
                    Button { withAnimation(.easeOut(duration: 0.2)) { showQueue.toggle() } } label: {
                        Image(systemName: "list.bullet").frame(width: 28, height: 36)
                            .foregroundStyle(showQueue ? Theme.accent : Theme.ink)
                    }.help("播放列表 · \(player.queue.count) 首").accessibilityLabel("播放列表")
                        .focused($focusedControl, equals: .queue)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 20).frame(height: 79)
        }.background(.regularMaterial).contentShape(Rectangle())
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
