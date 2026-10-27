import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(spacing: 11) {
                    Image("BrandIcon").resizable().frame(width: 43, height: 43).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("Resona.").font(.system(size: 34, weight: .semibold, design: .rounded))
                }
                .padding(.top, 55)
                VStack(alignment: .leading, spacing: 13) {
                    Text("A HOME FOR YOUR SOUND").font(.system(size: 10, weight: .medium)).tracking(3).foregroundStyle(Theme.muted)
                    Text("收藏热爱，\n聆听共鸣。").font(.system(size: 42, weight: .medium, design: .serif)).lineSpacing(7)
                    Text("连接你的私人音乐服务器。").font(.subheadline).foregroundStyle(Theme.muted)
                }.padding(.vertical, 20)
                VStack(alignment: .leading, spacing: 17) {
                    field("服务器地址") {
                        TextField("https://music.example.com", text: $library.serverInput)
                            .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    field("用户名") {
                        TextField("admin", text: $library.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    field("密码") { SecureField("管理员密码", text: $library.password).textContentType(.password) }
                }
                if let error = library.error { Text(error).font(.footnote).foregroundStyle(Theme.accent).accessibilityAddTraits(.updatesFrequently) }
                Button { Task { await library.login() } } label: {
                    HStack { Text("进入音乐空间"); Spacer(); if library.busy { ProgressView().tint(.white) } else { Image(systemName: "arrow.up.right") } }
                        .font(.subheadline.weight(.semibold)).padding(18).background(Theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }.disabled(library.busy || library.serverInput.isEmpty || library.password.isEmpty)
                Text("YOUR MUSIC. YOUR SPACE.").font(.system(size: 9)).tracking(3).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 15)
                Text("首次使用？请先在服务端网页设置管理员密码。").font(.caption2).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }.padding(30).frame(maxWidth: 530).frame(maxWidth: .infinity)
        }
        .background(LinearGradient(colors: [Theme.sage, Theme.paper, Theme.paper], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            content().font(.subheadline).padding(15).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct Artwork: View {
    @EnvironmentObject private var library: LibraryModel
    let path: String?
    var radius: CGFloat = 12
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.sage, Color(red: 0.77, green: 0.81, blue: 0.69)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                GeometryReader { proxy in
                    Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(Theme.ink.opacity(0.65))
                        .padding(proxy.size.width * 0.16)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .task(id: "\(library.session?.server.absoluteString ?? "")\(path ?? "")") {
            image = nil
            if let path, let id = path.split(separator: "/").dropLast().last,
               let cover = OfflineStore.shared.sidecar(String(id), name: "cover")
                    ?? PlaybackCache.shared.store?.sidecar(String(id), name: "cover") {
                image = UIImage(contentsOfFile: cover.path)
                if image != nil { return }
            }
            guard let path, !path.isEmpty, let url = library.resource(path), let token = library.session?.token else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled else { return }
            image = UIImage(data: data)
        }
    }
}

private enum MusicTab: String, CaseIterable {
    case listen = "聆听", collection = "音乐库", downloads = "已下载", search = "搜索", settings = "设置"
    var symbol: String {
        switch self {
        case .listen: return "waveform"
        case .collection: return "square.stack"
        case .downloads: return "arrow.down.circle"
        case .search: return "magnifyingglass"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @State private var selectedTab = MusicTab.listen

    var body: some View {
        TabView(selection: $selectedTab) {
            tabContent { HomeView() }.tag(MusicTab.listen)
            tabContent { CollectionView() }.tag(MusicTab.collection)
            tabContent { DownloadsView() }.tag(MusicTab.downloads)
            tabContent { SearchView() }.tag(MusicTab.search)
            tabContent { SettingsView() }.tag(MusicTab.settings)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if player.current != nil {
                    MiniPlayer().padding(.horizontal, 14).padding(.vertical, 8)
                }
                Divider()
                HStack(spacing: 0) {
                    ForEach(MusicTab.allCases, id: \.self) { tab in
                        Button { selectedTab = tab } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tab.symbol).font(.system(size: 20))
                                Text(tab.rawValue).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedTab == tab ? Theme.accent : Theme.muted)
                        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                        .accessibilityIdentifier("main-tab-\(tab.rawValue)")
                    }
                }
                .accessibilityIdentifier("main-tab-bar")
            }
            .background(Theme.paper)
        }
        .fullScreenCover(isPresented: $player.expanded) { NowPlayingView() }
        .alert("Resona", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("好", role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
        .alert("播放提示", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("好", role: .cancel) { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private func tabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("本地音乐库") { Task { await library.selectLibrary("local") } }
                        Button("网盘音乐库") { Task { await library.selectLibrary("cloud") } }
                    } label: {
                        Label(library.libraryScope == "cloud" ? "网盘音乐库" : "本地音乐库",
                              systemImage: library.libraryScope == "cloud" ? "cloud" : "internaldrive")
                            .font(.caption)
                    }.accessibilityIdentifier("library-scope")
                }
            }
        }
            .toolbar(.hidden, for: .tabBar)
    }
}

struct HomeView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("YOUR MUSIC UNIVERSE").font(.system(size: 9)).tracking(2).foregroundStyle(Theme.muted)
                        Text("音乐，井然有声。").font(.system(size: 29, weight: .medium, design: .serif))
                    }
                    Spacer()
                    Image("BrandIcon").resizable().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 11))
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("OWN YOUR SOUND").font(.system(size: 8)).tracking(2).foregroundStyle(Theme.muted)
                        Text("好音乐，\n值得好好收藏。").font(.system(size: 25, weight: .medium, design: .serif)).lineSpacing(4)
                        Button {
                            if let first = library.tracks.first { player.play(first, queue: library.tracks, session: library.session) }
                        } label: {
                            Label("开始聆听", systemImage: "play.fill").font(.caption.weight(.medium)).padding(.horizontal, 15).padding(.vertical, 11).background(Theme.ink, in: Capsule()).foregroundStyle(.white)
                        }.disabled(library.tracks.isEmpty)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "opticaldisc").resizable().scaledToFit().frame(maxWidth: 120).foregroundStyle(Theme.ink).rotationEffect(.degrees(-20))
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading).background(LinearGradient(colors: [Theme.sage, Theme.sage.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
                HStack {
                    stat("\(library.tracks.count)", "首音乐")
                    Spacer()
                    stat("\(library.albums.count)", "张专辑")
                    Spacer()
                    stat("\(library.artists.count)", "位艺术家")
                }.padding(.horizontal, 15)
                Text("最近入库").font(.title3.weight(.medium))
                if library.albums.isEmpty {
                    EmptyLibrary(title: "第一张唱片，等你入库", message: "在服务端导入音乐后，下拉刷新，开始聆听。")
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(library.albums.prefix(12)) { album in
                            NavigationLink { AlbumView(album: album) } label: { AlbumTile(album: album) }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(22)
        }
        .background(Theme.paper).toolbar(.hidden, for: .navigationBar)
        .refreshable { await library.refresh() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 28, weight: .regular, design: .serif))
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}

struct AlbumTile: View {
    let album: Album
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Artwork(path: album.artwork)
            Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(Theme.ink)
            Text(album.artist).font(.caption).lineLimit(1).foregroundStyle(Theme.muted)
        }
    }
}

struct CollectionView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var selection = 0
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("音乐分类", selection: $selection) {
                    Text("歌曲").tag(0); Text("专辑").tag(1); Text("艺术家").tag(2); Text("喜欢").tag(3)
                }.pickerStyle(.segmented)
                if selection == 1 {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 18)], spacing: 22) {
                        ForEach(library.albums) { album in NavigationLink { AlbumView(album: album) } label: { AlbumTile(album: album) }.buttonStyle(.plain) }
                    }
                } else if selection == 2 {
                    LazyVStack(spacing: 12) {
                        ForEach(library.artists) { artist in
                            NavigationLink {
                                TrackListView(title: artist.name, tracks: library.tracks.filter { $0.artist == artist.name || $0.albumArtist == artist.name })
                            } label: {
                                HStack(spacing: 15) {
                                    Text(String(artist.name.prefix(1))).font(.title2).frame(width: 52, height: 52).background(Theme.sage, in: Circle())
                                    VStack(alignment: .leading, spacing: 5) { Text(artist.name).font(.subheadline); Text("\(artist.tracks) 首歌曲").font(.caption).foregroundStyle(Theme.muted) }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption)
                                }.padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                            }.buttonStyle(.plain)
                        }
                    }
                } else {
                    let tracks = selection == 3 ? library.tracks.filter(\.favorite) : library.tracks
                    if tracks.isEmpty { EmptyLibrary(title: "等待下一次心动", message: "导入音乐，或为喜欢的歌曲点亮一颗心。") }
                    TrackRows(tracks: tracks)
                }
            }.padding(20)
        }
        .background(Theme.paper).navigationTitle("音乐库")
        .refreshable { await library.refresh() }
    }
}

struct AlbumView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    let album: Album
    private var tracks: [Track] {
        library.tracks.filter { $0.album == album.title && $0.albumArtist == album.artist }
            .sorted { $0.disc == $1.disc ? $0.number < $1.number : $0.disc < $1.disc }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Artwork(path: album.artwork).frame(maxWidth: 250).shadow(color: Theme.ink.opacity(0.13), radius: 20, y: 12).padding(.vertical, 12)
                Text(album.title).font(.title2.weight(.medium)).multilineTextAlignment(.center)
                Text("\(album.artist) · \(album.year) · \(album.tracks) 首").font(.caption).foregroundStyle(Theme.muted)
                Button {
                    if let first = tracks.first { player.play(first, queue: tracks, session: library.session) }
                } label: {
                    Label("播放专辑", systemImage: "play.fill").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(14).background(Theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }
                TrackRows(tracks: tracks)
            }.padding(22)
        }.background(Theme.paper).navigationBarTitleDisplayMode(.inline)
    }
}

struct TrackRows: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    let tracks: [Track]
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tracks) { track in
                HStack(spacing: 12) {
                    Button {
                        player.play(track, queue: tracks, session: library.session)
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(path: track.artwork, radius: 8).frame(width: 46, height: 46)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(track.title).font(.subheadline).lineLimit(1).foregroundStyle(player.current?.id == track.id ? Theme.accent : Theme.ink)
                                Text(track.artist).font(.caption).lineLimit(1).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 4)
                            Text(clock(track.duration)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { Task { await library.favorite(track) } } label: {
                        Image(systemName: track.favorite ? "heart.fill" : "heart").font(.subheadline).foregroundStyle(track.favorite ? Theme.accent : Theme.muted).frame(width: 35, height: 44)
                    }.accessibilityLabel(track.favorite ? "取消收藏" : "收藏")
                    Menu {
                        if library.downloaded.contains(where: { $0.id == track.id }) {
                            Label("已下载，可离线播放", systemImage: "checkmark.circle")
                            Button("删除下载", role: .destructive) {
                                if player.current?.id == track.id { player.stop() }
                                library.removeDownload(track)
                            }
                        } else {
                            Button("下载歌曲") { Task { await library.download(track) } }
                                .disabled(library.session == nil || library.offline || library.downloading.contains(track.id))
                        }
                        Button("加入播放列表") { player.append([track], session: library.session) }
                    } label: {
                        Image(systemName: library.downloading.contains(track.id) ? "arrow.down.circle.dotted" :
                            library.downloaded.contains(where: { $0.id == track.id }) ? "checkmark.circle.fill" : "ellipsis")
                            .frame(width: 30, height: 44).foregroundStyle(Theme.muted)
                    }.accessibilityLabel("下载与播放操作 · \(track.title)")
                }.padding(.vertical, 10)
                Divider().overlay(Theme.sage.opacity(0.5))
            }
        }
    }
}

struct TrackListView: View {
    let title: String
    let tracks: [Track]
    var body: some View {
        ScrollView { TrackRows(tracks: tracks).padding(20) }.background(Theme.paper).navigationTitle(title)
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var results: [Track] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return library.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("歌曲、艺术家、专辑", text: $query, prompt: Text("歌曲、艺术家、专辑").foregroundStyle(Theme.ink.opacity(0.75)))
                    .focused($searchFocused)
                    .frame(minHeight: 28)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel("搜索歌曲、艺术家、专辑")
                    .accessibilityIdentifier("search-field")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                            .frame(width: 32, height: 36)
                    }.accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }
            .background(Theme.sage.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20).padding(.bottom, 12)
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty { EmptyLibrary(title: "找一首，此刻想听的歌", message: "搜索歌曲、专辑或艺术家。").padding(.top, 60) }
                else if results.isEmpty { EmptyLibrary(title: "还没有找到这段旋律", message: "试试其他关键词。").padding(.top, 60) }
                else { TrackRows(tracks: results).padding(20) }
            }.scrollDismissesKeyboard(.interactively)
        }.background(Theme.paper).navigationTitle("寻找共鸣")
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var showQueue = false
    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Button { player.expanded = true } label: {
                    HStack(spacing: 12) {
                        Artwork(path: track.artwork, radius: 7).frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.caption.weight(.medium)).lineLimit(1).foregroundStyle(Theme.ink)
                            Text(track.artist).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 35, height: 44) }.accessibilityLabel(player.playing ? "暂停" : "播放")
                Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 35, height: 44) }.accessibilityLabel("播放列表")
            }.padding(.horizontal, 12).padding(.vertical, 7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.muted.opacity(0.12)))
                .sheet(isPresented: $showQueue) { PlaybackQueueView() }
        }
    }
}

struct PlaybackQueueView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(player.queue) { track in
                    Button { player.play(track, queue: player.queue, session: library.session) } label: {
                        HStack(spacing: 12) {
                            Artwork(path: track.artwork, radius: 6).frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(track.title).font(.subheadline).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer()
                            if player.current?.id == track.id { Image(systemName: "speaker.wave.2.fill") }
                        }.foregroundStyle(player.current?.id == track.id ? Theme.accent : Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).id(track.id).listRowBackground(Theme.paper)
                }
                .onAppear { proxy.scrollTo(player.current?.id, anchor: .center) }
            }
            .scrollContentBackground(.hidden).background(Theme.paper)
            .navigationTitle("播放列表 · \(player.queue.count) 首").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var dragging = false
    @State private var seekValue = 0.0
    private var activeLine: Int? { player.lyrics.last(where: { $0.time <= player.position })?.id }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("收起播放器")
                        Spacer()
                        VStack(spacing: 5) { Text("NOW PLAYING").font(.system(size: 9)).tracking(3); Text("你的私人音乐空间").font(.caption2).foregroundStyle(Theme.muted) }
                        Spacer()
                        Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                    }
                    if let track = player.current {
                        Group {
                          if showLyrics {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 23) {
                                        if player.lyrics.isEmpty {
                                            Text(player.plainLyrics.isEmpty ? "纯粹聆听，也是共鸣。\n暂无歌词" : player.plainLyrics)
                                                .font(.title2).foregroundStyle(Theme.muted).lineSpacing(12).padding(.top, 40)
                                        }
                                        ForEach(player.lyrics) { line in
                                            Text(line.text).font(.system(size: 23, weight: activeLine == line.id ? .semibold : .regular)).foregroundStyle(activeLine == line.id ? Theme.ink : Theme.muted.opacity(0.65)).multilineTextAlignment(.leading).id(line.id)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 30)
                                }
                                .onChange(of: activeLine) { _, value in withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(value, anchor: .center) } }
                            }
                          } else {
                            Artwork(path: track.artwork, radius: 18).shadow(color: Theme.ink.opacity(0.16), radius: 25, y: 15)
                          }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: min(geometry.size.width - 60, geometry.size.height * 0.43, 360))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showLyrics.toggle() } }
                        .accessibilityAction(named: Text(showLyrics ? "显示海报" : "显示歌词")) { showLyrics.toggle() }
                        .accessibilityIdentifier("now-playing-artwork-lyrics")
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(track.title).font(.title2.weight(.semibold)).lineLimit(2)
                                Text(track.artist).font(.subheadline).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            let favorite = library.tracks.first(where: { $0.id == track.id }) ?? track
                            Button { Task { await library.favorite(favorite) } } label: {
                                Image(systemName: favorite.favorite ? "heart.fill" : "heart").font(.title3).frame(width: 44, height: 44)
                            }.accessibilityLabel(favorite.favorite ? "取消收藏" : "收藏")
                        }
                        VStack(spacing: 8) {
                            Slider(value: Binding(get: { dragging ? seekValue : min(player.position, max(player.duration, 1)) }, set: { seekValue = $0 }),
                                   in: 0...max(player.duration, 1), onEditingChanged: { editing in
                                if editing { seekValue = player.position }
                                dragging = editing
                                if !editing { player.seek(seekValue) }
                            }).tint(Theme.ink).accessibilityLabel("播放进度")
                            HStack { Text(clock(dragging ? seekValue : player.position)); Spacer(); Text(clock(player.duration)) }.font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
                        }
                        HStack {
                            Button { player.cycleMode() } label: { Image(systemName: player.mode.symbol).foregroundStyle(player.mode == .sequential ? Theme.muted : Theme.accent).frame(width: 44, height: 44) }.accessibilityLabel(player.mode.title).accessibilityHint("切换播放模式")
                            Spacer()
                            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 50) }.accessibilityLabel("上一首")
                            Spacer()
                            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title).frame(width: 76, height: 76).background(Theme.ink, in: Circle()).foregroundStyle(Theme.paper) }.accessibilityLabel(player.playing ? "暂停" : "播放")
                            Spacer()
                            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 50) }.accessibilityLabel("下一首")
                            Spacer()
                            Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放列表")
                        }
                        Text("\(track.format.uppercased()) · \(track.sampleRate / 1000) kHz · \(track.bitrate / 1000) kbps").font(.system(size: 9)).tracking(1.5).foregroundStyle(Theme.muted).padding(.top, 5)
                    }
                }.padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 35).frame(maxWidth: 500).frame(maxWidth: .infinity)
            }.background(LinearGradient(colors: [Theme.sage, Theme.paper], startPoint: .topLeading, endPoint: .bottomTrailing))
        }.foregroundStyle(Theme.ink)
            .sheet(isPresented: $showQueue) { PlaybackQueueView() }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject private var cache = PlaybackCache.shared
    @State private var showLogin = false
    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image("BrandIcon").resizable().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Resona").font(.title2.weight(.semibold))
                        Text("让每一份热爱，产生共鸣。").font(.caption).foregroundStyle(Theme.muted)
                    }
                }.padding(.vertical, 8)
            }
            Section("你的服务器") {
                LabeledContent("状态", value: library.offline ? "离线 · 已下载音乐可播放" : "已连接")
                LabeledContent("地址", value: library.session?.server.absoluteString ?? "尚未连接").font(.caption)
                LabeledContent("账号", value: library.session?.username ?? "")
                LabeledContent("音乐", value: "\(library.tracks.count) 首")
                if library.session == nil { Button("登录服务器") { showLogin = true } }
                Button("刷新音乐库") { Task { await library.refresh() } }.disabled(library.busy)
            }
            Section("播放缓存") {
                LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: cache.bytes, countStyle: .file))
                Text("播放时自动缓存完整歌曲，再次播放优先读取本地。清理缓存会保留手动下载的音乐。")
                    .font(.caption).foregroundStyle(Theme.muted)
                Button(cache.clearing ? "正在清理…" : "清理缓存") { Task { await library.clearPlaybackCache() } }
                    .disabled(cache.clearing)
                if let message = cache.message { Text(message).font(.caption).foregroundStyle(Theme.muted) }
            }
            Section("关于") {
                LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                Text("支持后台播放、锁屏控制、同步 LRC 与纯文本歌词。可在服务端网页获取歌词。音乐格式的播放能力取决于 iOS 原生解码支持。").font(.caption).foregroundStyle(Theme.muted)
            }
            if library.session != nil {
                Section { Button("退出服务器登录", role: .destructive) { Task { await library.logout() } } }
            }
        }.scrollContentBackground(.hidden).background(Theme.paper).navigationTitle("音乐空间")
        .task { await cache.refreshSize() }
        .sheet(isPresented: $showLogin) {
            NavigationStack {
                LoginView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showLogin = false } } }
            }.onChange(of: library.session?.token) { _, token in if token != nil { showLogin = false } }
        }
    }
}

struct EmptyLibrary: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(Theme.muted)
            Text(title).font(.subheadline.weight(.medium))
            Text(message).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(5)
        }.frame(maxWidth: .infinity).padding(.vertical, 35).padding(.horizontal, 20)
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
}

struct DownloadsView: View {
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("已下载 \(library.libraryDownloads.count) 首 · 无需登录即可播放").font(.caption).foregroundStyle(Theme.muted)
                if !library.downloading.isEmpty { ProgressView("正在下载 \(library.downloading.count) 首") }
                if library.libraryDownloads.isEmpty {
                    EmptyLibrary(title: "把喜欢的音乐，带在身边", message: "在设置中连接服务器，通过歌曲右侧菜单下载。退出登录后仍可聆听。")
                }
                TrackRows(tracks: library.libraryDownloads)
            }.padding(20)
        }.background(Theme.paper).navigationTitle("已下载")
    }
}
