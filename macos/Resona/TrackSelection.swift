import Foundation
import Combine

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
}

@MainActor
final class TrackBatchActions: ObservableObject {
    enum Action { case download, favorite }
    @Published private(set) var busy = false
    @Published private(set) var completed = 0
    @Published private(set) var total = 0

    func run(_ action: Action, tracks: [Track], library: LibraryModel, player: PlayerModel) async -> Bool {
        guard !busy, !tracks.isEmpty, let session = library.session, !library.offline else { return false }
        busy = true
        completed = 0
        total = tracks.count
        library.error = nil
        defer { busy = false }
        for track in tracks {
            // Never send the rest of a batch to a different account after switching servers.
            guard !Task.isCancelled, library.session?.server == session.server,
                  library.session?.token == session.token, !library.offline else { return false }
            switch action {
            case .favorite:
                let current = library.tracks.first { $0.id == track.id } ?? track
                if !current.favorite {
                    guard let updated = await library.favorite(current) else { return false }
                    if player.current?.id == updated.id { player.current = updated }
                }
            case .download:
                if !library.downloaded.contains(where: { $0.id == track.id }) {
                    await library.download(track)
                    guard library.error == nil, library.downloaded.contains(where: { $0.id == track.id }) else { return false }
                }
            }
            completed += 1
        }
        return true
    }
}
