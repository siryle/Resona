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
    @StateObject private var multiSelect = TrackMultiSelectController()
    @StateObject private var batch = TrackBatchActions()
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
                if let toast = multiSelect.toastMessage {
                    HStack(spacing: 8) {
                        Text(toast)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.sageInk)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("知道了") { multiSelect.dismissToast() }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.sageInk)
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.sage, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                if batch.busy {
                    BatchProgressBar()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                } else if multiSelect.isSelecting {
                    MultiSelectActionBar()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                } else if player.current != nil {
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
            .environmentObject(multiSelect)
            .environmentObject(batch)
        }
        .environmentObject(multiSelect)
        .environmentObject(batch)
        .onChange(of: selectedTab) { _, _ in
            multiSelect.exit()
        }
        .onChange(of: library.libraryScope) { _, _ in
            batch.cancel()
            multiSelect.exit()
        }
        .onChange(of: library.session?.token) { _, _ in
            if batch.activeAction != .removeDownload {
                batch.cancel()
            }
            multiSelect.exit()
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
    @EnvironmentObject private var multiSelect: TrackMultiSelectController
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
                    TrackCollectionSection(
                        tracks: tracks,
                        scope: selection == 3 ? "collection-favorites" : "collection-tracks",
                        mode: .library
                    )
                }
            }.padding(20)
        }
        .onChange(of: selection) { _, _ in
            multiSelect.exit()
        }
        .foregroundStyle(Theme.ink)
        .background(Theme.paper).navigationTitle("音乐库")
        .refreshable { await library.refresh() }
    }
}

struct AlbumView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var multiSelect: TrackMultiSelectController
    @EnvironmentObject private var batch: TrackBatchActions
    let album: Album
    private var tracks: [Track] {
        library.tracks.filter { $0.album == album.title && $0.albumArtist == album.artist }
            .sorted { $0.disc == $1.disc ? $0.number < $1.number : $0.disc < $1.disc }
    }
    private var scope: String { "album-\(album.id)" }
    private var downloadedIDs: Set<String> { Set(library.downloaded.map(\.id)) }
    private var undownloadedIDs: [String] {
        multiSelect.selection.undownloaded(in: tracks, downloadedIDs: downloadedIDs).map(\.id)
    }
    private var isSelecting: Bool { multiSelect.isSelecting(scope: scope) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Artwork(path: album.artwork).frame(maxWidth: 250).shadow(color: .black.opacity(0.18), radius: 20, y: 12).padding(.vertical, 12)
                Text(album.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text("\(album.artist) · \(album.year) · \(album.tracks) 首").font(.caption).foregroundStyle(Theme.secondary)
                HStack(spacing: 10) {
                    Button {
                        if let first = tracks.first { player.play(first, queue: tracks, session: library.session) }
                    } label: {
                        Label("播放专辑", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .padding(.horizontal, 12)
                            .background(Theme.accentFill, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(Theme.accentOn)
                    }
                    .disabled(tracks.isEmpty)

                    Button {
                        if isSelecting {
                            if batch.busy { batch.cancel() }
                            multiSelect.exit(scope: scope)
                        } else {
                            multiSelect.enter(scope: scope, mode: .library, tracks: tracks, preselect: undownloadedIDs)
                        }
                    } label: {
                        Label(isSelecting ? "退出多选" : "多选下载", systemImage: isSelecting ? "xmark" : "checklist")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .padding(.horizontal, 12)
                            .background(isSelecting ? Theme.selected : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelecting ? Theme.accent : Theme.border))
                            .foregroundStyle(isSelecting ? Theme.accent : Theme.ink)
                    }
                    .disabled(tracks.isEmpty || (batch.busy && !isSelecting))
                    .accessibilityIdentifier("album-multi-select")
                }
                TrackCollectionSection(tracks: tracks, scope: scope, mode: .library, showBrowseHeader: false)
            }.padding(22)
        }.foregroundStyle(Theme.ink).background(Theme.paper).navigationBarTitleDisplayMode(.inline)
    }
}

struct TrackCollectionSection: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var multiSelect: TrackMultiSelectController
    @EnvironmentObject private var batch: TrackBatchActions
    let tracks: [Track]
    let scope: String
    var mode: TrackMultiSelectController.Mode = .library
    var showBrowseHeader: Bool = true

    private var downloadedIDs: Set<String> { Set(library.downloaded.map(\.id)) }
    private var undownloaded: [Track] { multiSelect.selection.undownloaded(in: tracks, downloadedIDs: downloadedIDs) }
    private var isSelecting: Bool { multiSelect.isSelecting(scope: scope) }

    var body: some View {
        VStack(spacing: 10) {
            if isSelecting {
                selectionHeader
            } else if showBrowseHeader && !tracks.isEmpty {
                browseHeader
            }
            TrackRows(tracks: tracks, scope: scope, mode: mode)
        }
        .onAppear { multiSelect.syncTracks(tracks, for: scope) }
        .onChange(of: tracks) { _, updated in
            multiSelect.syncTracks(updated, for: scope)
        }
        .onDisappear { multiSelect.exit(scope: scope) }
    }

    private var browseHeader: some View {
        HStack(spacing: 10) {
            Button {
                if let first = tracks.first {
                    player.play(first, queue: tracks, session: library.session)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accentOn)
                        .frame(width: 28, height: 28)
                        .background(Theme.accentFill, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全部播放")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text(mode == .downloads
                             ? "已下载 \(tracks.count) 首 · 无需登录即可播放"
                             : "共 \(tracks.count) 首 · 未下载 \(undownloaded.count) 首")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Button {
                multiSelect.enter(scope: scope, mode: mode, tracks: tracks)
            } label: {
                Label("多选", systemImage: "checklist")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(Theme.border))
            }
            .buttonStyle(.plain)
            .disabled(batch.busy)
            .accessibilityIdentifier("track-multi-select-\(scope)")
        }
        .frame(minHeight: 44)
    }

    private var selectionHeader: some View {
        let allSelected = multiSelect.selection.allSelected(in: tracks)
        let partialSelected = !allSelected && multiSelect.selection.hasSelection(in: tracks)
        let onlyPendingSelected = multiSelect.selection.allUndownloadedSelected(in: tracks, downloadedIDs: downloadedIDs)

        return HStack(spacing: 8) {
            Button {
                multiSelect.selection.toggleAll(in: tracks)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : (partialSelected ? "minus.circle.fill" : "circle"))
                        .font(.system(size: 19))
                        .foregroundStyle((allSelected || partialSelected) ? Theme.accentFill : Theme.muted)
                    Text("全选")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty || batch.busy)
            .accessibilityLabel("全选当前列表")
            .accessibilityValue(allSelected ? "已全选" : (partialSelected ? "部分选择" : "未全选"))

            if mode == .library && !undownloaded.isEmpty {
                Button {
                    multiSelect.selection.toggleUndownloaded(in: tracks, downloadedIDs: downloadedIDs)
                } label: {
                    Text("选未下载(\(undownloaded.count))")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(onlyPendingSelected ? Theme.accent : Theme.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(onlyPendingSelected ? Theme.selected : Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(onlyPendingSelected ? Theme.accent : Theme.border))
                }
                .buttonStyle(.plain)
                .disabled(batch.busy)
                .accessibilityIdentifier("select-undownloaded-\(scope)")
            }

            Spacer(minLength: 4)

            Button("完成") {
                if batch.busy { batch.cancel() }
                multiSelect.exit(scope: scope)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .frame(minHeight: 36)
            .buttonStyle(.plain)
            .accessibilityIdentifier("track-multi-done-\(scope)")
        }
        .frame(minHeight: 44)
    }
}

struct TrackRows: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var multiSelect: TrackMultiSelectController
    @EnvironmentObject private var batch: TrackBatchActions
    let tracks: [Track]
    var scope: String? = nil
    var mode: TrackMultiSelectController.Mode = .library

    private var downloadedIDs: Set<String> { Set(library.downloaded.map(\.id)) }
    private var isSelecting: Bool { scope.map { multiSelect.isSelecting(scope: $0) } ?? false }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tracks) { track in
                if isSelecting {
                    selectingRow(track)
                } else {
                    browseRow(track)
                    Divider().overlay(Theme.borderSubtle)
                }
            }
        }
    }

    private func selectingRow(_ track: Track) -> some View {
        let isSelected = multiSelect.selection.selectedIDs.contains(track.id)
        let isDownloading = batch.currentTrackID == track.id || library.downloading.contains(track.id)
        let isQueued = batch.busy && batch.queuedTrackIDs.contains(track.id)
        let isDownloaded = downloadedIDs.contains(track.id)

        return VStack(spacing: 0) {
            Button {
                if !batch.busy {
                    multiSelect.selection.toggle(track.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Theme.accentFill : Theme.muted)
                        .frame(width: 24, height: 44)
                    Artwork(path: track.artwork, radius: 8).frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundStyle(player.current?.id == track.id ? Theme.accent : Theme.ink)
                        Text(track.artist)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    selectionTrailing(
                        for: track,
                        isDownloading: isDownloading,
                        isQueued: isQueued,
                        isDownloaded: isDownloaded
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(isSelected ? Theme.selected : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(batch.busy)
            .accessibilityLabel("\(isSelected ? "取消选择" : "选择") \(track.title)")
            .accessibilityValue(isSelected ? "已选择" : "未选择")

            if !isSelected {
                Divider().overlay(Theme.borderSubtle)
            }
        }
    }

    @ViewBuilder
    private func selectionTrailing(
        for track: Track,
        isDownloading: Bool,
        isQueued: Bool,
        isDownloaded: Bool
    ) -> some View {
        if isDownloading {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text("下载中").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(0.14), in: Capsule())
        } else if isQueued {
            Text("等待中")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.muted)
        } else if isDownloaded {
            Label("已下载", systemImage: "checkmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.sageInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.sage, in: Capsule())
        } else {
            Text(clock(track.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
    }

    private func browseRow(_ track: Track) -> some View {
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
                if let scope {
                    Button {
                        multiSelect.enter(scope: scope, mode: mode, tracks: tracks, preselect: [track.id])
                    } label: {
                        Label("多选歌曲", systemImage: "checklist")
                    }
                    .disabled(batch.busy)
                }
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
    }
}

struct MultiSelectActionBar: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var multiSelect: TrackMultiSelectController
    @EnvironmentObject private var batch: TrackBatchActions
    @State private var confirmDelete = false

    private var downloadedIDs: Set<String> { Set(library.downloaded.map(\.id)) }
    private var selected: [Track] { multiSelect.selection.selected(in: multiSelect.currentTracks) }
    private var pendingDownloads: [Track] {
        multiSelect.selection.pendingDownloads(in: multiSelect.currentTracks, downloadedIDs: downloadedIDs)
    }
    private var pendingFavorites: [Track] {
        multiSelect.selection.pendingFavorites(in: multiSelect.currentTracks)
    }

    private var summaryHint: String {
        if multiSelect.mode == .downloads {
            return "离线文件管理"
        }
        if library.session == nil {
            return "登录后可下载或喜欢"
        }
        if library.offline {
            return "离线模式 · 仅可加入列表"
        }
        let skipped = selected.count - pendingDownloads.count
        if skipped > 0 {
            return "自动跳过 \(skipped) 首已下载"
        }
        if !pendingDownloads.isEmpty {
            return "全部待下载"
        }
        return "请选择歌曲"
    }

    private var primaryLabel: String {
        if multiSelect.mode == .downloads {
            return selected.isEmpty ? "删除下载" : "删除下载 (\(selected.count))"
        }
        if !pendingDownloads.isEmpty {
            return "下载 (\(pendingDownloads.count))"
        }
        return selected.isEmpty ? "下载" : "所选均已下载"
    }

    private var primaryDisabled: Bool {
        if multiSelect.mode == .downloads {
            return batch.busy || selected.isEmpty
        }
        return batch.busy || library.session == nil || library.offline || pendingDownloads.isEmpty
    }

    private var favoriteDisabled: Bool {
        batch.busy || library.session == nil || library.offline || pendingFavorites.isEmpty
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text("已选 \(selected.count) 首")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 6)
                Text(summaryHint)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    if multiSelect.mode == .downloads {
                        confirmDelete = true
                    } else {
                        runBatch(.download, tracks: pendingDownloads)
                    }
                } label: {
                    Label(
                        primaryLabel,
                        systemImage: multiSelect.mode == .downloads ? "trash" : "arrow.down.to.line"
                    )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 10)
                    .background(
                        multiSelect.mode == .downloads ? Theme.dangerSurface : Theme.accentFill,
                        in: RoundedRectangle(cornerRadius: 11)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(multiSelect.mode == .downloads ? Theme.danger.opacity(0.35) : Color.clear)
                    )
                    .foregroundStyle(multiSelect.mode == .downloads ? Theme.danger : Theme.accentOn)
                }
                .buttonStyle(.plain)
                .disabled(primaryDisabled)
                .opacity(primaryDisabled ? 0.42 : 1)
                .accessibilityIdentifier("batch-primary")

                Button {
                    runBatch(.favorite, tracks: pendingFavorites)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "heart")
                            .foregroundStyle(favoriteDisabled ? Theme.muted : Theme.accent)
                        Text("喜欢")
                    }
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
                    .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(favoriteDisabled)
                .opacity(favoriteDisabled ? 0.42 : 1)
                .accessibilityLabel("喜欢所选歌曲")
                .accessibilityIdentifier("batch-favorite")

                Button {
                    let count = selected.count
                    player.append(selected, session: library.session)
                    multiSelect.exit()
                    multiSelect.showToast("已将 \(count) 首歌曲加入播放列表")
                } label: {
                    Label("加入列表", systemImage: "text.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.border))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .disabled(batch.busy || selected.isEmpty)
                .opacity((batch.busy || selected.isEmpty) ? 0.42 : 1)
                .accessibilityIdentifier("batch-queue")
            }
        }
        .confirmationDialog(
            "确定删除所选 \(selected.count) 首离线下载？",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("删除 \(selected.count) 首离线文件", role: .destructive) {
                runBatch(.removeDownload, tracks: selected)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将从本机移除已保存的音频、封面与歌词，正在播放的选中曲目会先停止。")
        }
    }

    private func runBatch(_ action: TrackBatchActions.Action, tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        batch.start(action, tracks: tracks, library: library, player: player) { outcome in
            if outcome.succeeded {
                multiSelect.exit()
                switch outcome.action {
                case .download:
                    multiSelect.showToast("已完成下载 \(outcome.completed) 首，可离线播放")
                case .favorite:
                    multiSelect.showToast("已收藏 \(outcome.completed) 首歌曲")
                case .removeDownload:
                    multiSelect.showToast("已删除 \(outcome.completed) 首离线下载")
                }
            } else if outcome.cancelled {
                if outcome.action == .download {
                    let existing = Set(library.downloaded.map(\.id))
                    multiSelect.selection.selectedIDs.subtract(existing)
                }
                let msg = outcome.completed > 0
                    ? "已取消剩余任务（已完成 \(outcome.completed) 首）"
                    : "已取消批量操作"
                multiSelect.showToast(msg)
            }
        }
    }
}

struct BatchProgressBar: View {
    @EnvironmentObject private var batch: TrackBatchActions

    private var titlePrefix: String {
        switch batch.activeAction {
        case .download, .none: return "正在下载"
        case .favorite: return "正在收藏"
        case .removeDownload: return "正在删除"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("\(titlePrefix) \(min(batch.completed + 1, max(batch.total, 1))) / \(batch.total)\(batch.currentTrackTitle.map { " · \($0)" } ?? "")")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("取消") { batch.cancel() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("batch-cancel")
            }
            ProgressView(value: Double(batch.completed), total: Double(max(batch.total, 1)))
                .tint(Theme.accentFill)
        }
    }
}

struct TrackListView: View {
    @EnvironmentObject private var library: LibraryModel
    let title: String
    let tracks: [Track]

    private var resolvedTracks: [Track] {
        let current = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tracks.map { current[$0.id] ?? $0 }
    }

    var body: some View {
        ScrollView {
            TrackCollectionSection(tracks: resolvedTracks, scope: "artist-\(title)", mode: .library)
                .padding(20)
        }
        .foregroundStyle(Theme.ink)
        .background(Theme.paper)
        .navigationTitle(title)
    }
}

struct SearchView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var multiSelect: TrackMultiSelectController
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
                else { TrackCollectionSection(tracks: results, scope: "search-results", mode: .library).padding(20) }
            }.scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: query) { _, _ in
            if results.isEmpty {
                multiSelect.exit(scope: "search-results")
            }
        }
        .foregroundStyle(Theme.ink).background(Theme.paper).navigationTitle("寻找共鸣")
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
                .onAppear {
                    if let id = player.current?.id {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.paper)
            .navigationTitle("播放列表 · \(player.queue.count) 首").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

private struct NowPlayingLyricsTrigger: Equatable {
    let activeLine: Int?
    let lyrics: [LyricLine]
    let revision: Int
}

struct NowPlayingLyricsView: View {
    let lyrics: [LyricLine]
    let plainLyrics: String
    let activeLine: Int?
    let scrollRevision: Int
    let dragging: Bool
    @State private var hasAlignedInitial = false

    private var scrollTrigger: NowPlayingLyricsTrigger {
        NowPlayingLyricsTrigger(activeLine: activeLine, lyrics: lyrics, revision: scrollRevision)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if lyrics.isEmpty {
                        Text(plainLyrics.isEmpty ? "纯粹聆听，也是共鸣。\n暂无歌词" : plainLyrics)
                            .font(.title2).foregroundStyle(Theme.muted).lineSpacing(12).padding(.top, 40)
                    }
                    ForEach(lyrics) { line in
                        Text(line.text)
                            .font(.system(size: activeLine == line.id ? 22 : 19, weight: activeLine == line.id ? .semibold : .regular))
                            .foregroundStyle(activeLine == line.id ? Theme.ink : Theme.muted.opacity(0.68))
                            .multilineTextAlignment(.leading)
                            .id(line.id)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 30)
            }
            .onDisappear { hasAlignedInitial = false }
            .task(id: scrollTrigger) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                guard !lyrics.isEmpty else {
                    hasAlignedInitial = false
                    return
                }
                guard let targetID = activeLine ?? lyrics.first?.id else { return }
                let anchor: UnitPoint = activeLine == nil ? .top : .center
                if hasAlignedInitial {
                    withAnimation(.easeInOut(duration: dragging ? 0.12 : 0.35)) {
                        proxy.scrollTo(targetID, anchor: anchor)
                    }
                } else {
                    proxy.scrollTo(targetID, anchor: anchor)
                    hasAlignedInitial = true
                }
            }
        }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var player: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var showSpeedOverlay = false
    @State private var dragging = false
    @State private var seekValue = 0.0
    @State private var lyricsScrollRevision = 0
    private var displayedPosition: Double {
        dragging ? seekValue : min(player.position, max(player.duration, 1))
    }
    private var activeLine: Int? { Lyrics.activeLineID(player.lyrics, at: displayedPosition) }

    var body: some View {
        ZStack(alignment: .bottom) {
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
                        AirPlayRoutePicker(player: player).frame(width: 44, height: 44)
                    }
                    if let track = player.current {
                        Group {
                            if showLyrics {
                                NowPlayingLyricsView(
                                    lyrics: player.lyrics,
                                    plainLyrics: player.plainLyrics,
                                    activeLine: activeLine,
                                    scrollRevision: lyricsScrollRevision,
                                    dragging: dragging
                                )
                                .id(track.id)
                            } else {
                                Artwork(path: track.artwork, radius: 18)
                                    .shadow(color: .black.opacity(0.24), radius: 24, y: 14)
                                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showLyrics = true } }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: min(geometry.size.width - 60, geometry.size.height * 0.43, 360))
                        .contentShape(Rectangle())
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
                            Slider(value: Binding(get: { displayedPosition }, set: { seekValue = $0 }),
                                   in: 0...max(player.duration, 1), onEditingChanged: { editing in
                                if editing { seekValue = player.position }
                                dragging = editing
                                if !editing {
                                    player.seek(seekValue)
                                    lyricsScrollRevision &+= 1
                                }
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
                            Button {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                                    showSpeedOverlay.toggle()
                                }
                            } label: {
                                Label(PlayerModel.formatPlaybackRate(player.playbackRate), systemImage: "speedometer")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(abs(player.playbackRate - 1.0) > 0.001 ? Theme.accent : Theme.secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.border))
                            }.buttonStyle(.plain)
                                .accessibilityLabel("倍速播放 · \(PlayerModel.formatPlaybackRate(player.playbackRate))")
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
            }
            if showSpeedOverlay {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { showSpeedOverlay = false }
                    }
                    .accessibilityLabel("关闭倍速滑动条")
                    .accessibilityAddTraits(.isButton)
                PlaybackSpeedRulerCard(player: player)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 22)
                    .frame(maxWidth: 460)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }.foregroundStyle(Theme.ink)
            .onChange(of: player.current?.id) { _, id in
                if id == nil { showSpeedOverlay = false }
                lyricsScrollRevision &+= 1
            }
            .sheet(isPresented: $showQueue) { PlaybackQueueView() }
    }
}

private struct PlaybackSpeedRulerCard: View {
    @ObservedObject var player: PlayerModel
    @State private var lastStep: Int?

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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("倍速播放")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                Text(PlayerModel.formatCompactPlaybackRate(player.playbackRate))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            GeometryReader { geometry in
                let inset: CGFloat = 10
                let usable = max(geometry.size.width - inset * 2, 1)
                let active = selectedIndex
                ZStack {
                    ForEach(0..<16, id: \.self) { index in
                        let isSelected = index == active
                        let isMajor = index % 5 == 0
                        let x = inset + usable * CGFloat(index) / 15
                        Capsule()
                            .fill(isSelected ? Theme.ink : (isMajor ? Theme.secondary.opacity(0.65) : Theme.muted.opacity(0.42)))
                            .frame(width: isSelected ? 4 : 2, height: isSelected ? 28 : (isMajor ? 18 : 10))
                            .shadow(color: isSelected ? Theme.ink.opacity(0.28) : .clear, radius: 6)
                            .position(x: x, y: geometry.size.height / 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = min(max((value.location.x - inset) / usable, 0), 1)
                            let step = min(max(Int((ratio * 15).rounded()), 0), 15)
                            if step != lastStep {
                                lastStep = step
                                UISelectionFeedbackGenerator().selectionChanged()
                                player.setPlaybackRate(Float(5 + step) / 10)
                            }
                        }
                        .onEnded { _ in
                            lastStep = nil
                        }
                )
            }
            .frame(height: 46)
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
                let inset: CGFloat = 10
                let usable = max(geometry.size.width - inset * 2, 1)
                let active = selectedIndex
                ZStack(alignment: .leading) {
                    ForEach(Self.marks, id: \.index) { mark in
                        let isActive = mark.index == active
                        let button = Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            player.setPlaybackRate(mark.rate)
                        } label: {
                            Text(mark.label)
                                .font(.caption.weight(isActive ? .semibold : .regular).monospacedDigit())
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
            .frame(height: 22)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.surface.opacity(0.92))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.border, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
    }
}

struct AirPlayRoutePicker: UIViewRepresentable {
    let player: PlayerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor(Theme.secondary)
        picker.activeTintColor = UIColor(Theme.accent)
        picker.delegate = context.coordinator
        picker.accessibilityLabel = "AirPlay 与蓝牙音频输出"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        if context.coordinator.player !== player {
            context.coordinator.player = player
        }
        if uiView.delegate !== context.coordinator {
            uiView.delegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var player: PlayerModel

        init(player: PlayerModel) {
            self.player = player
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { player.prepareForAudioRouteSelection() }
            } else {
                Task { @MainActor [player] in player.prepareForAudioRouteSelection() }
            }
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { player.handleAudioRouteSelectionEnded() }
            } else {
                Task { @MainActor [player] in player.handleAudioRouteSelectionEnded() }
            }
        }
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
    @EnvironmentObject private var batch: TrackBatchActions

    private var resolvedTracks: [Track] {
        let current = Dictionary(library.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return library.libraryDownloads.map { current[$0.id] ?? $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if !library.downloading.isEmpty && !batch.busy {
                    ProgressView("正在下载 \(library.downloading.count) 首")
                }
                if resolvedTracks.isEmpty {
                    Text("已下载 0 首 · 无需登录即可播放").font(.caption).foregroundStyle(Theme.muted)
                    EmptyLibrary(title: "把喜欢的音乐，带在身边", message: "在设置中连接服务器，通过歌曲右侧菜单下载。退出登录后仍可聆听。")
                } else {
                    TrackCollectionSection(tracks: resolvedTracks, scope: "downloads", mode: .downloads)
                }
            }.padding(20)
        }.foregroundStyle(Theme.ink).background(Theme.paper).navigationTitle("已下载")
    }
}
