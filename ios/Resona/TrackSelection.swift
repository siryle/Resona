import Combine
import Foundation

struct TrackSelection {
    enum SearchField: String, CaseIterable {
        case all = "全部", title = "歌曲", album = "专辑", artist = "歌手"
    }

    var selectedIDs = Set<String>()
    var query = ""
    var searchField = SearchField.all
    var favoritesOnly = false
    var downloadsOnly = false

    var hasFilters: Bool { searchField != .all || favoritesOnly || downloadsOnly }

    func filtered(_ tracks: [Track], downloadedIDs: Set<String>) -> [Track] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tracks.filter { track in
            guard !favoritesOnly || track.favorite,
                  !downloadsOnly || downloadedIDs.contains(track.id) else { return false }
            let text: String
            switch searchField {
            case .all: text = "\(track.title) \(track.album) \(track.artist) \(track.albumArtist)"
            case .title: text = track.title
            case .album: text = track.album
            case .artist: text = "\(track.artist) \(track.albumArtist)"
            }
            return term.isEmpty || text.localizedCaseInsensitiveContains(term)
        }
    }

    func allSelected(in tracks: [Track]) -> Bool {
        !tracks.isEmpty && tracks.allSatisfy { selectedIDs.contains($0.id) }
    }

    func hasSelection(in tracks: [Track]) -> Bool {
        tracks.contains { selectedIDs.contains($0.id) }
    }

    mutating func toggle(_ id: String) {
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }

    mutating func toggleAll(in tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        if allSelected(in: tracks) { selectedIDs.subtract(ids) }
        else { selectedIDs.formUnion(ids) }
    }

    func selected(in tracks: [Track]) -> [Track] {
        tracks.filter { selectedIDs.contains($0.id) }
    }

    func undownloaded(in tracks: [Track], downloadedIDs: Set<String>) -> [Track] {
        tracks.filter { !downloadedIDs.contains($0.id) }
    }

    func allUndownloadedSelected(in tracks: [Track], downloadedIDs: Set<String>) -> Bool {
        let pendingIDs = Set(undownloaded(in: tracks, downloadedIDs: downloadedIDs).map(\.id))
        guard !pendingIDs.isEmpty else { return false }
        let visibleSelectedIDs = Set(tracks.map(\.id)).intersection(selectedIDs)
        return visibleSelectedIDs == pendingIDs
    }

    mutating func toggleUndownloaded(in tracks: [Track], downloadedIDs: Set<String>) {
        let visibleIDs = Set(tracks.map(\.id))
        let shouldClear = allUndownloadedSelected(in: tracks, downloadedIDs: downloadedIDs)
        selectedIDs.subtract(visibleIDs)
        if !shouldClear {
            selectedIDs.formUnion(undownloaded(in: tracks, downloadedIDs: downloadedIDs).map(\.id))
        }
    }

    func pendingDownloads(in tracks: [Track], downloadedIDs: Set<String>) -> [Track] {
        selected(in: tracks).filter { !downloadedIDs.contains($0.id) }
    }

    func pendingFavorites(in tracks: [Track]) -> [Track] {
        selected(in: tracks).filter { !$0.favorite }
    }
}

@MainActor
final class TrackBatchActions: ObservableObject {
    enum Action: Equatable {
        case download, favorite, removeDownload
    }

    struct Outcome: Equatable {
        let action: Action
        let completed: Int
        let total: Int
        let succeeded: Bool
        let cancelled: Bool
    }

    @Published private(set) var busy = false
    @Published private(set) var activeAction: Action?
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var currentTrackID: String?
    @Published private(set) var currentTrackTitle: String?
    @Published private(set) var queuedTrackIDs: [String] = []
    @Published private(set) var lastOutcome: Outcome?

    private var activeTask: Task<Bool, Never>?
    private var cancelRequested = false

    func cancel() {
        cancelRequested = true
        activeTask?.cancel()
    }

    @discardableResult
    func start(
        _ action: Action,
        tracks: [Track],
        library: LibraryModel,
        player: PlayerModel,
        onFinish: ((Outcome) -> Void)? = nil
    ) -> Task<Bool, Never>? {
        guard !busy, !tracks.isEmpty else { return nil }
        if action != .removeDownload && (library.session == nil || library.offline) {
            return nil
        }
        cancelRequested = false
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let ok = await self.run(action, tracks: tracks, library: library, player: player)
            if let outcome = self.lastOutcome, outcome.action == action {
                onFinish?(outcome)
            }
            return ok
        }
        activeTask = task
        return task
    }

    @discardableResult
    func run(_ action: Action, tracks: [Track], library: LibraryModel, player: PlayerModel) async -> Bool {
        guard !busy, !tracks.isEmpty else { return false }
        let requiresOnline = action != .removeDownload
        let session = library.session
        if requiresOnline && (session == nil || library.offline) {
            return false
        }
        let initialScope = library.libraryScope
        busy = true
        activeAction = action
        completed = 0
        total = tracks.count
        currentTrackID = nil
        currentTrackTitle = nil
        queuedTrackIDs = tracks.map(\.id)
        library.error = nil

        var succeeded = false
        var finishedCount = 0

        defer {
            let wasCancelled = cancelRequested || Task.isCancelled
            lastOutcome = Outcome(
                action: action,
                completed: finishedCount,
                total: tracks.count,
                succeeded: succeeded,
                cancelled: !succeeded && wasCancelled
            )
            busy = false
            activeAction = nil
            currentTrackID = nil
            currentTrackTitle = nil
            queuedTrackIDs = []
            activeTask = nil
            cancelRequested = false
        }

        for (index, track) in tracks.enumerated() {
            // Never send the rest of a batch to a different account or library scope after switching.
            guard !cancelRequested && !Task.isCancelled else { return false }
            if requiresOnline {
                guard library.session?.server == session?.server,
                      library.session?.token == session?.token,
                      !library.offline,
                      library.libraryScope == initialScope else { return false }
            } else {
                guard library.libraryScope == initialScope else { return false }
            }

            currentTrackID = track.id
            currentTrackTitle = track.title
            queuedTrackIDs = Array(tracks.dropFirst(index + 1).map(\.id))

            switch action {
            case .favorite:
                let current = library.tracks.first { $0.id == track.id } ?? track
                if !current.favorite {
                    guard let updated = await library.favorite(current) else { return false }
                    if cancelRequested || Task.isCancelled { return false }
                    if player.current?.id == updated.id { player.current = updated }
                }
            case .download:
                if !library.downloaded.contains(where: { $0.id == track.id }) {
                    await library.download(track, reportPartialSidecars: false)
                    if cancelRequested || Task.isCancelled { return false }
                    guard library.error == nil, library.downloaded.contains(where: { $0.id == track.id }) else {
                        return false
                    }
                }
            case .removeDownload:
                if library.downloaded.contains(where: { $0.id == track.id }) {
                    if player.current?.id == track.id { player.stop() }
                    library.removeDownload(track)
                    guard library.error == nil else { return false }
                }
            }
            finishedCount += 1
            completed = finishedCount
        }
        succeeded = true
        return true
    }
}

@MainActor
final class TrackMultiSelectController: ObservableObject {
    enum Mode: Equatable {
        case library
        case downloads
    }

    @Published var activeScopeID: String?
    @Published var mode: Mode = .library
    @Published var selection = TrackSelection()
    @Published var currentTracks: [Track] = []
    @Published var toastMessage: String?

    private var toastTask: Task<Void, Never>?

    var isSelecting: Bool { activeScopeID != nil }

    func isSelecting(scope: String) -> Bool {
        activeScopeID == scope
    }

    func enter(scope: String, mode: Mode, tracks: [Track], preselect: [String] = []) {
        dismissToast()
        activeScopeID = scope
        self.mode = mode
        currentTracks = tracks
        selection = TrackSelection()
        let validIDs = Set(tracks.map(\.id))
        selection.selectedIDs = Set(preselect).intersection(validIDs)
    }

    func syncTracks(_ tracks: [Track], for scope: String) {
        guard activeScopeID == scope else { return }
        currentTracks = tracks
        let validIDs = Set(tracks.map(\.id))
        selection.selectedIDs.formIntersection(validIDs)
    }

    func exit(scope: String? = nil) {
        if let scope, activeScopeID != scope { return }
        activeScopeID = nil
        currentTracks = []
        selection.selectedIDs.removeAll()
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, let self, self.toastMessage == message else { return }
            self.toastMessage = nil
            self.toastTask = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toastMessage = nil
    }
}
