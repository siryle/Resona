import AVKit
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
                    HStack { Text("进入音乐空间"); Spacer(); if library.busy { ProgressView().tint(Theme.accentOn) } else { Image(systemName: "arrow.up.right") } }
                        .font(.subheadline.weight(.semibold)).padding(18).background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.accentOn)
                }.disabled(library.busy || library.serverInput.isEmpty || library.password.isEmpty)
                Text("首次使用？请先在服务端网页设置管理员密码。").font(.caption).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 10)
            }.padding(30).frame(maxWidth: 530).frame(maxWidth: .infinity)
        }
        .foregroundStyle(Theme.ink)
        .background(LinearGradient(colors: [Theme.listeningStart, Theme.paper, Theme.listeningEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(Theme.secondary)
            content().font(.subheadline).padding(15)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
    }
}

struct Artwork: View {
    @EnvironmentObject private var library: LibraryModel
    let path: String?
    var radius: CGFloat = 12
    var fallback: String? = nil
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.surfaceElevated, Theme.selected], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if let fallback { Text(fallback).font(.title2).foregroundStyle(Theme.ink) }
            else {
                GeometryReader { proxy in
                    Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(Theme.muted)
                        .padding(proxy.size.width * 0.18)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.borderSubtle, lineWidth: 0.75))
        .task(id: "\(library.session?.server.absoluteString ?? "")\(library.session?.token ?? "")\(path ?? "")") {
            image = nil
            if let path, path.hasPrefix("/api/v1/tracks/"), let id = path.split(separator: "/").dropLast().last,
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
                Rectangle().fill(Theme.border).frame(height: 0.75)
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
            .background(Theme.playerBar)
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
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("音乐，井然有声。").font(.system(size: 27, weight: .semibold))
                        Text("让每一份热爱，产生共鸣。").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image("BrandIcon").resizable().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("好音乐，\n值得好好收藏。").font(.system(size: 22, weight: .semibold)).lineSpacing(4)
                        Button {
                            if let first = library.tracks.first { player.play(first, queue: library.tracks, session: library.session) }
                        } label: {
                            Label("开始聆听", systemImage: "play.fill").font(.caption.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Theme.accentFill, in: Capsule()).foregroundStyle(Theme.accentOn)
                        }.disabled(library.tracks.isEmpty)
                    }
                    Spacer(minLength: 0)
                    ZStack {
                        Circle().fill(Color(red: 0.09, green: 0.09, blue: 0.08))
                            .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
                        ForEach(0..<5) { i in
                            Circle().stroke(.white.opacity(0.06), lineWidth: 1).padding(CGFloat(i) * 7 + 8)
                        }
                        Circle().fill(Theme.accentFill).frame(width: 34, height: 34)
                        Circle().fill(Theme.paper).frame(width: 9, height: 9)
                    }.frame(width: 104, height: 104)
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Theme.heroStart, Theme.heroEnd], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border))
                HStack(spacing: 0) {
                    stat("\(library.tracks.count)", "首音乐")
                    Divider().frame(height: 30).overlay(Theme.borderSubtle)
                    stat("\(library.albums.count)", "张专辑")
                    Divider().frame(height: 30).overlay(Theme.borderSubtle)
                    stat("\(library.artists.count)", "位艺术家")
                }
                .padding(.vertical, 14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
                Text("最近入库").font(.title3.weight(.semibold))
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
        .foregroundStyle(Theme.ink)
        .background(Theme.paper).toolbar(.hidden, for: .navigationBar)
        .refreshable { await library.refresh() }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity)
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
                                    Artwork(path: artist.artwork, fallback: String(artist.name.prefix(1)))
                                        .frame(width: 52, height: 52).clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 5) { Text(artist.name).font(.subheadline.weight(.medium)); Text("\(artist.tracks) 首歌曲").font(.caption).foregroundStyle(Theme.muted) }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                                }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
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
        .foregroundStyle(Theme.ink)
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
                Artwork(path: album.artwork).frame(maxWidth: 250).shadow(color: .black.opacity(0.18), radius: 20, y: 12).padding(.vertical, 12)
                Text(album.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text("\(album.artist) · \(album.year) · \(album.tracks) 首").font(.caption).foregroundStyle(Theme.secondary)
                Button {
                    if let first = tracks.first { player.play(first, queue: tracks, session: library.session) }
                } label: {
                    Label("播放专辑", systemImage: "play.fill").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(14).background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Theme.accentOn)
                }
                TrackRows(tracks: tracks)
            }.padding(22)
        }.foregroundStyle(Theme.ink).background(Theme.paper).navigationBarTitleDisplayMode(.inline)
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
                Divider().overlay(Theme.borderSubtle)
            }
        }
    }
}

struct TrackListView: View {
    let title: String
    let tracks: [Track]
    var body: some View {
        ScrollView { TrackRows(tracks: tracks).padding(20) }.foregroundStyle(Theme.ink).background(Theme.paper).navigationTitle(title)
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
                TextField("歌曲、艺术家、专辑", text: $query, prompt: Text("歌曲、艺术家、专辑").foregroundStyle(Theme.muted))
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
            .padding(.horizontal, 20).padding(.bottom, 12)
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty { EmptyLibrary(title: "找一首，此刻想听的歌", message: "搜索歌曲、专辑或艺术家。").padding(.top, 60) }
                else if results.isEmpty { EmptyLibrary(title: "还没有找到这段旋律", message: "试试其他关键词。").padding(.top, 60) }
                else { TrackRows(tracks: results).padding(20) }
            }.scrollDismissesKeyboard(.interactively)
        }.foregroundStyle(Theme.ink).background(Theme.paper).navigationTitle("寻找共鸣")
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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(Theme.ink)
                            HStack(spacing: 5) {
                                Text(track.artist).lineLimit(1)
                                if player.activeOutput.kind == .airPlay || player.activeOutput.kind == .bluetooth {
                                    Text("·").foregroundStyle(Theme.border)
                                    Label(player.activeOutput.name, systemImage: player.activeOutput.kind.symbol)
                                        .lineLimit(1)
                                        .foregroundStyle(Theme.accent)
                                }
                            }.font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentOn)
                        .frame(width: 34, height: 34)
                        .background(Theme.accentFill, in: Circle())
                        .frame(width: 40, height: 44)
                }.accessibilityLabel(player.playing ? "暂停" : "播放")
                Button { showQueue = true } label: { Image(systemName: "list.bullet").foregroundStyle(Theme.secondary).frame(width: 35, height: 44) }.accessibilityLabel("播放列表")
            }.padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
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
                        Button { dismiss() } label: { Image(systemName: "chevron.down").foregroundStyle(Theme.secondary).frame(width: 44, height: 44) }.accessibilityLabel("收起播放器")
                        Spacer()
                        HStack(spacing: 2) {
                            Button { withAnimation(.easeInOut(duration: 0.2)) { showLyrics = false } } label: {
                                Text("唱片").font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(!showLyrics ? Theme.selected : .clear, in: Capsule())
                                    .foregroundStyle(!showLyrics ? Theme.ink : Theme.muted)
                            }.buttonStyle(.plain)
                            Button { withAnimation(.easeInOut(duration: 0.2)) { showLyrics = true } } label: {
                                Text("歌词").font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(showLyrics ? Theme.selected : .clear, in: Capsule())
                                    .foregroundStyle(showLyrics ? Theme.ink : Theme.muted)
                            }.buttonStyle(.plain)
                        }
                        .padding(3)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.border))
                        Spacer()
                        AirPlayRoutePicker().frame(width: 44, height: 44)
                    }
                    if let track = player.current {
                        Group {
                          if showLyrics {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 22) {
                                        if player.lyrics.isEmpty {
                                            Text(player.plainLyrics.isEmpty ? "纯粹聆听，也是共鸣。\n暂无歌词" : player.plainLyrics)
                                                .font(.title2).foregroundStyle(Theme.muted).lineSpacing(12).padding(.top, 40)
                                        }
                                        ForEach(player.lyrics) { line in
                                            Text(line.text).font(.system(size: activeLine == line.id ? 22 : 19, weight: activeLine == line.id ? .semibold : .regular)).foregroundStyle(activeLine == line.id ? Theme.ink : Theme.muted.opacity(0.68)).multilineTextAlignment(.leading).id(line.id)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 30)
                                }
                                .onChange(of: activeLine) { _, value in withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(value, anchor: .center) } }
                            }
                          } else {
                            Artwork(path: track.artwork, radius: 18).shadow(color: .black.opacity(0.24), radius: 24, y: 14)
                          }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: min(geometry.size.width - 60, geometry.size.height * 0.43, 360))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showLyrics.toggle() } }
                        .accessibilityAction(named: Text(showLyrics ? "显示海报" : "显示歌词")) { showLyrics.toggle() }
                        .accessibilityIdentifier("now-playing-artwork-lyrics")
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(track.title).font(.title2.weight(.semibold)).lineLimit(2)
                                Text(track.artist).font(.subheadline).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            let favorite = library.tracks.first(where: { $0.id == track.id }) ?? track
                            Button { Task { await library.favorite(favorite) } } label: {
                                Image(systemName: favorite.favorite ? "heart.fill" : "heart")
                                    .foregroundStyle(favorite.favorite ? Theme.accent : Theme.secondary)
                                    .font(.title3).frame(width: 44, height: 44)
                            }.accessibilityLabel(favorite.favorite ? "取消收藏" : "收藏")
                        }
                        VStack(spacing: 8) {
                            Slider(value: Binding(get: { dragging ? seekValue : min(player.position, max(player.duration, 1)) }, set: { seekValue = $0 }),
                                   in: 0...max(player.duration, 1), onEditingChanged: { editing in
                                if editing { seekValue = player.position }
                                dragging = editing
                                if !editing { player.seek(seekValue) }
                            }).tint(Theme.accent).accessibilityLabel("播放进度")
                            HStack { Text(clock(dragging ? seekValue : player.position)); Spacer(); Text(clock(player.duration)) }.font(.caption2.monospacedDigit()).foregroundStyle(Theme.muted)
                        }
                        HStack {
                            Button { player.cycleMode() } label: { Image(systemName: player.mode.symbol).foregroundStyle(player.mode == .sequential ? Theme.muted : Theme.accent).frame(width: 44, height: 44) }.accessibilityLabel(player.mode.title).accessibilityHint("切换播放模式")
                            Spacer()
                            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 50) }.accessibilityLabel("上一首")
                            Spacer()
                            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.title).frame(width: 72, height: 72).background(Theme.accentFill, in: Circle()).foregroundStyle(Theme.accentOn) }.accessibilityLabel(player.playing ? "暂停" : "播放")
                            Spacer()
                            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 50) }.accessibilityLabel("下一首")
                            Spacer()
                            Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("播放列表")
                        }
                        HStack(spacing: 8) {
                            Text("\(track.format.uppercased()) · \(track.sampleRate / 1000) kHz · \(track.bitrate / 1000) kbps")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(Theme.sageInk)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Theme.sage, in: Capsule())
                            Menu {
                                Button("减速 (-0.1x)") { player.stepPlaybackRate(by: -1) }
                                    .disabled(player.playbackRate <= 0.5)
                                Button("加速 (+0.1x)") { player.stepPlaybackRate(by: 1) }
                                    .disabled(player.playbackRate >= 2.0)
                                Button("恢复原速 (1.0x)") { player.setPlaybackRate(1.0) }
                                    .disabled(abs(player.playbackRate - 1.0) < 0.001)
                                Divider()
                                ForEach(PlayerModel.supportedPlaybackRates, id: \.self) { rate in
                                    Button {
                                        player.setPlaybackRate(rate)
                                    } label: {
                                        if abs(player.playbackRate - rate) < 0.001 {
                                            Label(PlayerModel.formatPlaybackRate(rate), systemImage: "checkmark")
                                        } else {
                                            Text(PlayerModel.formatPlaybackRate(rate))
                                        }
                                    }
                                }
                            } label: {
                                Label(PlayerModel.formatPlaybackRate(player.playbackRate), systemImage: "speedometer")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(abs(player.playbackRate - 1.0) > 0.001 ? Theme.accent : Theme.secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.border))
                            }.accessibilityLabel("倍速播放 · \(PlayerModel.formatPlaybackRate(player.playbackRate))")
                        }
                        if player.activeOutput.kind == .airPlay || player.activeOutput.kind == .bluetooth {
                            Label("\(player.activeOutput.kind.label) · \(player.activeOutput.name)",
                                  systemImage: player.activeOutput.kind.symbol)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Theme.surface, in: Capsule())
                                .overlay(Capsule().stroke(Theme.border))
                        }
                    }
                }.padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 35).frame(maxWidth: 500).frame(maxWidth: .infinity)
            }.background(LinearGradient(colors: [Theme.listeningStart, Theme.paper, Theme.listeningEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
        }.foregroundStyle(Theme.ink)
            .sheet(isPresented: $showQueue) { PlaybackQueueView() }
    }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor(Theme.secondary)
        picker.activeTintColor = UIColor(Theme.accent)
        picker.accessibilityLabel = "AirPlay 与蓝牙音频输出"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(Theme.secondary)
        uiView.activeTintColor = UIColor(Theme.accent)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @ObservedObject private var cache = PlaybackCache.shared
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
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
            }.listRowBackground(Theme.surface)
            Section("外观主题") {
                Picker("主题模式", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }.pickerStyle(.segmented)
                Text("支持跟随系统自动切换，或固定使用「日间纸韵」与「夜间黑胶」。")
                    .font(.caption).foregroundStyle(Theme.muted)
            }.listRowBackground(Theme.surface)
            Section("你的服务器") {
                LabeledContent("状态", value: library.offline ? "离线 · 已下载音乐可播放" : "已连接")
                LabeledContent("地址", value: library.session?.server.absoluteString ?? "尚未连接").font(.caption)
                LabeledContent("账号", value: library.session?.username ?? "")
                LabeledContent("音乐", value: "\(library.tracks.count) 首")
                if library.session == nil { Button("登录服务器") { showLogin = true } }
                Button("刷新音乐库") { Task { await library.refresh() } }.disabled(library.busy)
            }.listRowBackground(Theme.surface)
            Section("播放缓存") {
                LabeledContent("占用空间", value: ByteCountFormatter.string(fromByteCount: cache.bytes, countStyle: .file))
                Text("播放时自动缓存完整歌曲，再次播放优先读取本地。清理缓存会保留手动下载的音乐。")
                    .font(.caption).foregroundStyle(Theme.muted)
                Button(cache.clearing ? "正在清理…" : "清理缓存") { Task { await library.clearPlaybackCache() } }
                    .disabled(cache.clearing)
                if let message = cache.message { Text(message).font(.caption).foregroundStyle(Theme.muted) }
            }.listRowBackground(Theme.surface)
            Section("关于") {
                LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                Text("支持后台播放、锁屏控制、同步 LRC 与纯文本歌词。可在服务端网页获取歌词。音乐格式的播放能力取决于 iOS 原生解码支持。").font(.caption).foregroundStyle(Theme.muted)
            }.listRowBackground(Theme.surface)
            if library.session != nil {
                Section { Button("退出服务器登录", role: .destructive) { Task { await library.logout() } } }.listRowBackground(Theme.surface)
            }
        }.foregroundStyle(Theme.ink).scrollContentBackground(.hidden).background(Theme.paper).navigationTitle("音乐空间")
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
