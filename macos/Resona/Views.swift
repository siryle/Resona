import SwiftUI
import AppKit

private enum Section: String, CaseIterable {
    case tracks = "全部音乐", albums = "专辑", artists = "艺术家", favorites = "我喜欢的", downloads = "已下载"
    var symbol: String {
        switch self {
        case .tracks: return "music.note.list"
        case .albums: return "square.stack"
        case .artists: return "person.2"
        case .favorites: return "heart"
        case .downloads: return "arrow.down.circle"
        }
    }
}

struct DesktopView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @Binding var showingSettings: Bool
    @State private var section = Section.tracks
    @State private var query = ""
    @State private var album: Album?
    @State private var artist: String?
    @State private var showQueue = false

    private var tracks: [Track] {
        let source = section == .downloads ? library.libraryDownloads : library.tracks
        return source.filter {
            (section != .favorites || $0.favorite) &&
            (album == nil || ($0.album == album?.title && $0.albumArtist == album?.artist)) &&
            (artist == nil || $0.artist == artist || $0.albumArtist == artist) &&
            (query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query))
        }
    }
    private var title: String { showingSettings ? "设置" : album?.title ?? artist ?? section.rawValue }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    Group {
                        if showingSettings { ServerSettings() }
                        else if player.expanded { ListeningView() }
                        else { collection }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showQueue { queue.frame(width: 290).transition(.move(edge: .trailing)) }
                }
                Divider()
                playerBar
            }.background(Theme.paper)
        }.foregroundStyle(Theme.ink)
        .alert("Resona", isPresented: Binding(get: { library.error != nil || player.error != nil }, set: { if !$0 { library.error = nil; player.error = nil } })) {
            Button("好", role: .cancel) { library.error = nil; player.error = nil }
        } message: { Text(player.error ?? library.error ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                if let url = Bundle.main.url(forResource: "BrandIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                Text("Resona.").font(.system(size: 26, weight: .semibold, design: .rounded))
            }.padding(.top, 44).padding(.horizontal, 10)
            Text("你的音乐空间").font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 12)
            Picker("音乐库", selection: Binding(get: { library.libraryScope }, set: { scope in
                album = nil; artist = nil; query = ""
                Task { await library.selectLibrary(scope) }
            })) {
                Text("本地音乐库").tag("local")
                Text("网盘音乐库").tag("cloud")
            }.labelsHidden().padding(.horizontal, 10)
            VStack(spacing: 6) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button {
                        section = item; album = nil; artist = nil; query = ""; player.expanded = false; showingSettings = false
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.symbol).frame(width: 24, height: 20, alignment: .center)
                            Text(item.rawValue).frame(maxWidth: .infinity, alignment: .leading)
                        }
                            .font(.system(size: 14, weight: section == item && !showingSettings ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading).padding(.horizontal, 14)
                            .background(section == item && !showingSettings ? Theme.sage : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            if !library.downloading.isEmpty {
                ProgressView("正在下载 \(library.downloading.count) 首").font(.caption).controlSize(.small).padding(.horizontal, 10)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(library.offline ? "离线音乐空间" : "已连接音乐服务器", systemImage: library.offline ? "internaldrive" : "circle.fill")
                Text("\(library.libraryDownloads.count) 首已下载 · 随时聆听").font(.caption2)
            }.font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 10).padding(.bottom, 18)
        }.padding(.horizontal, 14).frame(width: 204).frame(maxHeight: .infinity, alignment: .top).background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 18) {
            if player.expanded {
                Button { player.expanded = false } label: { Image(systemName: "chevron.down") }.help("收起播放页")
            } else if !showingSettings && (album != nil || artist != nil) {
                Button { album = nil; artist = nil } label: { Image(systemName: "chevron.left") }.help("返回")
            }
            Text(player.expanded ? "正在播放" : title).font(.headline)
            Spacer()
            if library.busy { ProgressView().controlSize(.small) }
            if !showingSettings { HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("搜索歌曲、专辑、艺术家", text: $query).textFieldStyle(.plain)
                    .onSubmit { player.expanded = false; section = .tracks; album = nil; artist = nil }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(10).frame(width: 255).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9)) }
            Button { Task { await library.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(library.busy).help("刷新音乐库")
            Button { player.expanded = false; showingSettings = true } label: { Image(systemName: "gearshape") }.help("设置与服务器登录")
        }.buttonStyle(.borderless).padding(.horizontal, 28).frame(height: 70)
    }

    private var collection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 24) {
                    if let album { Artwork(path: album.artwork).frame(width: 130, height: 130) }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR PERSONAL MUSIC UNIVERSE").font(.system(size: 9, weight: .medium)).tracking(3).foregroundStyle(Theme.muted)
                        Text(title).font(.system(size: 34, weight: .medium, design: .serif))
                        Text(library.offline ? "已下载的旋律，始终在身边。连接服务器请前往设置。" : "让每一份热爱，产生共鸣。")
                            .font(.callout).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }.padding(.vertical, 12)
                if section == .albums && album == nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 24)], spacing: 28) {
                        ForEach(library.albums.filter { query.isEmpty || "\($0.title) \($0.artist)".localizedCaseInsensitiveContains(query) }) { item in
                            Button { album = item } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Artwork(path: item.artwork)
                                    Text(item.title).font(.headline).lineLimit(1)
                                    Text(item.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                } else if section == .artists && artist == nil {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 20)]) {
                        ForEach(library.artists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                            Button { artist = item.name } label: {
                                HStack {
                                    Text(String(item.name.prefix(1))).font(.title2).frame(width: 48, height: 48).background(Theme.sage, in: Circle())
                                    VStack(alignment: .leading) { Text(item.name); Text("\(item.tracks) 首").font(.caption).foregroundStyle(Theme.muted) }
                                    Spacer()
                                }.padding(14).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    HStack(spacing: 18) {
                        Button { playAll() } label: { Label("全部播放", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                        Button { player.append(tracks, session: library.session) } label: { Label("加入播放列表", systemImage: "text.badge.plus") }
                        Button { playAll(shuffle: true) } label: { Label("随机播放", systemImage: "shuffle") }
                        Spacer()
                        Text("\(tracks.count) 首").font(.caption).foregroundStyle(Theme.muted)
                    }.disabled(tracks.isEmpty)
                    if tracks.isEmpty {
                        ContentUnavailableView("等待下一次共鸣", systemImage: "opticaldisc", description: Text("在设置中连接服务器并下载音乐，之后可离线播放。"))
                            .frame(maxWidth: .infinity).padding(.top, 55)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, index: index, queue: tracks)
                            Divider().opacity(0.45)
                        }
                    }
                }
            }.padding(30)
        }
    }

    private func playAll(shuffle: Bool = false) {
        player.shuffle = shuffle
        if let track = shuffle ? tracks.randomElement() : tracks.first { player.play(track, queue: tracks, session: library.session) }
    }

    private func trackRow(_ track: Track, index: Int, queue: [Track]) -> some View {
        HStack(spacing: 14) {
            Button { player.play(track, queue: queue, session: library.session) } label: {
                HStack(spacing: 14) {
                    Text(player.current?.id == track.id && player.playing ? "♫" : String(format: "%02d", index + 1)).font(.caption.monospacedDigit()).frame(width: 24)
                    Artwork(path: track.artwork).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(track.album).font(.caption).foregroundStyle(Theme.muted).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                    Text(clock(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("播放 \(track.title)")
            Button { Task { await library.favorite(track) } } label: {
                Image(systemName: track.favorite ? "heart.fill" : "heart").foregroundStyle(Theme.accent)
            }.buttonStyle(.borderless).disabled(library.offline).help("收藏")
            Menu {
                Button("加入播放列表") { player.append([track], session: library.session) }
                if library.downloaded.contains(where: { $0.id == track.id }) {
                    Text("已下载 · 支持离线播放")
                    Button("删除下载", role: .destructive) {
                        if player.current?.id == track.id { player.stop() }
                        library.removeDownload(track)
                    }
                } else {
                    Button("下载到本机") { Task { await library.download(track) } }
                        .disabled(library.session == nil || library.offline || library.downloading.contains(track.id))
                }
            } label: { Image(systemName: library.downloading.contains(track.id) ? "arrow.down.circle.dotted" : "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 24).help("下载与播放操作")
        }.padding(.vertical, 12).foregroundStyle(player.current?.id == track.id ? Theme.accent : Theme.ink)
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("播放列表").font(.headline); Spacer(); Button { showQueue = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text("\(player.queue.count) 首 · 点击切换播放").font(.caption).foregroundStyle(Theme.muted)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(player.queue) { track in
                            Button { player.play(track, queue: player.queue, session: library.session) } label: {
                                HStack(spacing: 10) {
                                    Artwork(path: track.artwork).frame(width: 36, height: 36)
                                    VStack(alignment: .leading, spacing: 5) { Text(track.title).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                                    Spacer()
                                    if player.current?.id == track.id { Image(systemName: "speaker.wave.2.fill") }
                                }.padding(9).background(player.current?.id == track.id ? Theme.sage : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).id(track.id)
                        }
                    }
                }.onAppear { proxy.scrollTo(player.current?.id, anchor: .center) }
            }
        }.padding(18).background(.regularMaterial)
    }

    private var playerBar: some View {
        HStack(spacing: 22) {
            if let track = player.current {
                let favorite = library.tracks.first(where: { $0.id == track.id }) ?? track
                Button { showingSettings = false; player.expanded.toggle() } label: {
                    HStack(spacing: 12) {
                        Artwork(path: track.artwork).frame(width: 50, height: 50)
                            .overlay(alignment: .bottom) { Image(systemName: player.expanded ? "chevron.down" : "chevron.up").font(.caption.bold()).foregroundStyle(.white).shadow(radius: 3) }
                        VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.headline).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                    }.frame(width: 210, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("展开海报与歌词")
                Button {
                    Task {
                        if let updated = await library.favorite(favorite), player.current?.id == updated.id {
                            player.current = updated
                        }
                    }
                } label: {
                    Image(systemName: favorite.favorite ? "heart.fill" : "heart")
                        .foregroundStyle(favorite.favorite ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.borderless)
                .disabled(library.offline || library.session == nil)
                .help(favorite.favorite ? "取消喜欢" : "喜欢")
                .accessibilityLabel(favorite.favorite ? "取消喜欢" : "喜欢")
            } else {
                Label("选一首，此刻想听的歌", systemImage: "opticaldisc").font(.caption).foregroundStyle(Theme.muted).frame(width: 210)
            }
            VStack(spacing: 10) {
                HStack(spacing: 25) {
                    Button { player.cycleMode() } label: { Image(systemName: player.mode.symbol).foregroundStyle(player.mode == .sequential ? Theme.muted : Theme.accent) }.help(player.mode.title + "，点击切换").accessibilityLabel(player.mode.title)
                    Button { player.previous() } label: { Image(systemName: "backward.end.fill") }.help("上一首")
                    Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 34, height: 34).background(Theme.ink, in: Circle()).foregroundStyle(Theme.paper) }.help(player.playing ? "暂停" : "播放")
                    Button { player.next() } label: { Image(systemName: "forward.end.fill") }.help("下一首")
                }.buttonStyle(.plain)
                HStack(spacing: 8) {
                    Text(clock(player.position))
                    Slider(value: Binding(get: { min(player.position, max(1, player.duration)) }, set: { player.seek($0) }), in: 0...max(1, player.duration)).controlSize(.mini).accessibilityLabel("播放进度")
                    Text(clock(player.duration))
                }.font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.muted)
            }.disabled(player.current == nil)
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2").font(.caption)
                Slider(value: $player.volume, in: 0...1).frame(width: 65).controlSize(.mini).accessibilityLabel("音量")
                Button { withAnimation(.easeInOut(duration: 0.2)) { showQueue.toggle() } } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.plain).foregroundStyle(showQueue ? Theme.accent : Theme.ink).help("播放列表 · \(player.queue.count) 首")
            }
        }.padding(.horizontal, 24).padding(.vertical, 16).frame(height: 94).background(.regularMaterial)
    }
}

struct Artwork: View {
    @EnvironmentObject private var library: LibraryModel
    let path: String?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.sage, Theme.muted.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "opticaldisc").resizable().scaledToFit().padding(15).foregroundStyle(Theme.muted) }
        }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: "\(library.session?.token ?? "")\(path ?? "")") {
            image = nil
            if let path, let id = path.split(separator: "/").dropLast().last,
               let cover = OfflineStore.shared.sidecar(String(id), name: "cover")
                    ?? PlaybackCache.shared.store?.sidecar(String(id), name: "cover") {
                image = NSImage(contentsOf: cover)
                if image != nil { return }
            }
            guard let path, !path.isEmpty, let url = library.resource(path), let token = library.session?.token else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled else { return }
            image = NSImage(data: data)
        }
    }
}

struct ListeningView: View {
    @EnvironmentObject private var player: PlayerModel
    private var active: Int? { player.lyrics.last { $0.time <= player.position }?.id }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 40) {
                if let track = player.current {
                    VStack(spacing: 22) {
                        ZStack {
                            Circle().fill(.black.gradient).shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                            ForEach(0..<12) { index in Circle().stroke(.white.opacity(0.045), lineWidth: 1).padding(CGFloat(index) * 4 + 8) }
                            Artwork(path: track.artwork).clipShape(Circle()).padding(geometry.size.width * 0.048)
                        }.aspectRatio(1, contentMode: .fit).frame(maxWidth: 350)
                        Text(track.title).font(.title2.weight(.medium))
                        Text("\(track.artist) · \(track.album)").font(.callout).foregroundStyle(Theme.muted).lineLimit(2)
                        Text("\(track.format.uppercased()) · \(track.sampleRate / 1000) kHz").font(.caption).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if player.lyrics.isEmpty {
                                Text(player.plainLyrics.isEmpty ? "纯粹聆听，也是共鸣。\n暂无歌词" : player.plainLyrics).font(.title3).foregroundStyle(Theme.muted).lineSpacing(12)
                            }
                            ForEach(player.lyrics) { line in
                                Button { player.seek(line.time) } label: {
                                    Text(line.text).font(.system(size: 22, weight: active == line.id ? .semibold : .regular))
                                        .foregroundStyle(active == line.id ? Theme.ink : Theme.muted.opacity(0.6)).multilineTextAlignment(.leading)
                                }.buttonStyle(.plain).id(line.id)
                            }
                        }.padding(.vertical, 100).frame(maxWidth: .infinity, alignment: .leading)
                    }.onChange(of: active) { _, value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
                }.frame(maxWidth: .infinity)
            }.padding(40).frame(width: geometry.size.width, height: geometry.size.height)
        }.background(LinearGradient(colors: [Theme.sage.opacity(0.7), Theme.paper], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

struct ServerSettings: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject private var cache = PlaybackCache.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                settingsSection("服务器") {
                    if let session = library.session {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                            informationRow("地址", value: session.server.absoluteString)
                            informationRow("账号", value: session.username)
                            GridRow(alignment: .firstTextBaseline) {
                                fieldLabel("状态")
                                Label(library.offline ? "离线，已下载音乐可播放" : "已连接", systemImage: library.offline ? "wifi.slash" : "checkmark.circle.fill")
                                    .foregroundStyle(library.offline ? Theme.ink.opacity(0.7) : Theme.ink)
                            }
                        }
                        Divider().overlay(Theme.ink.opacity(0.06)).padding(.vertical, 4)
                        HStack(spacing: 12) {
                            Button("重新连接与刷新") { Task { await library.refresh() } }
                            Spacer(minLength: 12)
                            Button("退出服务器登录", role: .destructive) { Task { await library.logout() } }
                        }.disabled(library.busy)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                            GridRow { fieldLabel("地址"); TextField("https://music.example.com", text: $library.serverInput) }
                            GridRow { fieldLabel("账号"); TextField("用户名", text: $library.username) }
                            GridRow {
                                fieldLabel("密码")
                                SecureField("密码", text: $library.password).onSubmit {
                                    if !library.busy { Task { await library.login() } }
                                }
                            }
                        }.textFieldStyle(.roundedBorder).disabled(library.busy)
                        explanation("首次使用，请先在服务端网页设置管理员密码。未登录时也可播放已下载音乐。")
                        HStack(spacing: 12) {
                            Button("连接服务器") { Task { await library.login() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(library.busy || library.serverInput.isEmpty || library.username.isEmpty || library.password.isEmpty)
                            if library.busy { ProgressView().controlSize(.small) }
                        }
                    }
                }
                settingsSection("离线音乐") {
                    HStack {
                        Text("本机下载")
                        Spacer()
                        Text("\(library.downloaded.count) 首").fontWeight(.medium).monospacedDigit()
                    }
                    explanation("通过歌曲右侧菜单下载音频、海报和歌词。退出登录、登录过期或服务器离线后，下载内容仍保存在本机，可从「已下载」播放和删除。")
                }
                settingsSection("播放缓存") {
                    HStack {
                        Text("占用空间")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: cache.bytes, countStyle: .file))
                            .fontWeight(.medium).monospacedDigit()
                    }
                    explanation("播放时自动缓存完整歌曲，再次播放优先读取本地。清理缓存会保留手动下载的音乐。")
                    HStack(spacing: 12) {
                        Button(cache.clearing ? "正在清理…" : "清理缓存") { Task { await library.clearPlaybackCache() } }
                            .disabled(cache.clearing)
                        if cache.clearing { ProgressView().controlSize(.small) }
                    }
                    if let message = cache.message { explanation(message).accessibilityAddTraits(.updatesFrequently) }
                }
                if let error = library.error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.accent)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("关于 Resona").font(.system(size: 14, weight: .semibold))
                        explanation("让每一份热爱，产生共鸣。")
                    }
                    Spacer()
                    Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.7))
                }.padding(.horizontal, 4)
            }
            .font(.system(size: 14)).foregroundStyle(Theme.ink).controlSize(.large)
            .frame(maxWidth: 760).padding(32).frame(maxWidth: .infinity)
        }.background(Theme.paper).task { await cache.refreshSize() }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 16, weight: .semibold)).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ink.opacity(0.08)) }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).foregroundStyle(Theme.ink.opacity(0.7)).frame(width: 64, alignment: .leading)
    }

    private func informationRow(_ title: String, value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            fieldLabel(title)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.7))
            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }
}
