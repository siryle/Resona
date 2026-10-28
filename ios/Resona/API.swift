import Foundation
import Security
import SwiftUI

struct Track: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let albumArtist: String
    let album: String
    let year: String
    let number: Int
    let disc: Int
    let duration: Double
    let format: String
    let bitrate: Int
    let sampleRate: Int
    let artwork: String?
    var favorite: Bool
    var library: String? = nil
    var hashAlgorithm: String? = nil
    var contentHash: String? = nil
    var unavailable: Bool? = nil
}

struct Album: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let year: String
    let artwork: String
    let tracks: Int
}

struct Artist: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let tracks: Int
    var artwork: String? = nil
}

struct Page<T: Decodable>: Decodable {
    let items: [T]
    let total: Int?
}

struct Session: Codable {
    let server: URL
    let username: String
    let token: String
}

enum APIError: LocalizedError {
    case message(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .unauthorized: return "登录已过期，请重新登录。"
        }
    }
}

enum Credentials {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.resona.session",
        kSecAttrAccount as String: "current"
    ]

    static func load() -> Session? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let existing = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        let status = existing == errSecItemNotFound ? SecItemAdd(q as CFDictionary, nil) : existing
        guard status == errSecSuccess else { throw APIError.message("无法安全保存登录凭据 (\(status))") }
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var session: Session?
    @Published var tracks: [Track] = []
    @Published var downloaded: [Track] = []
    @Published var downloading: Set<String> = []
    @Published var offline = false
    @Published var albums: [Album] = []
    @Published var artists: [Artist] = []
    @Published var busy = false
    @Published var libraryScope = "local"
    @Published var error: String?
    @Published var serverInput = ""
    @Published var username = "admin"
    @Published var password = ""

    private let downloads: OfflineStore
    private let cache: PlaybackCache
    private let persistsSession: Bool
    private var refreshGeneration = 0

    var libraryDownloads: [Track] {
        downloaded.filter { ($0.library ?? "local") == libraryScope }
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(downloads: OfflineStore = .shared, persistsSession: Bool = true, cache: PlaybackCache? = nil) {
        self.downloads = downloads
        self.cache = cache ?? .shared
        self.persistsSession = persistsSession
        do { downloaded = try downloads.tracks() }
        catch { self.error = "无法读取已下载音乐：\(error.localizedDescription)" }
        session = persistsSession ? Credentials.load() : nil
        if let session {
            self.cache.activate(session)
            serverInput = session.server.absoluteString
            username = session.username
        }
        useDownloads()
    }

    func resource(_ path: String) -> URL? {
        guard let server = session?.server else { return nil }
        let base = server.absoluteString.hasSuffix("/") ? server.absoluteString : server.absoluteString + "/"
        return URL(string: base + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, server: URL? = nil) async throws -> Data {
        guard let base = server ?? session?.server,
              let url = URL(string: path, relativeTo: base.appendingPathComponent("api/v1/"))?.absoluteURL else {
            throw APIError.message("服务器地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = session?.token, server == nil { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.message("服务器响应无效") }
        if response.statusCode == 401 && server == nil { throw APIError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.message(message ?? "请求失败 (\(response.statusCode))")
        }
        return data
    }

    func login() async {
        busy = true
        error = nil
        defer { busy = false }
        guard let url = URL(string: serverInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            error = "请输入完整的服务器地址，例如 https://music.example.com"
            return
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
            let data = try await request("auth/login", method: "POST", body: body, server: url)
            struct Login: Decodable { let token: String }
            let login = try decoder.decode(Login.self, from: data)
            let newSession = Session(server: url, username: username, token: login.token)
            if persistsSession { try Credentials.save(newSession) }
            session = newSession
            cache.activate(newSession)
            password = ""
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard let current = session else { useDownloads(); return }
        cache.activate(current)
        refreshGeneration += 1
        let generation = refreshGeneration
        let scope = libraryScope
        busy = true
        defer { if generation == refreshGeneration { busy = false } }
        do {
            var all: [Track] = []
            while true {
                let data = try await request("tracks?limit=500&offset=\(all.count)&library=\(scope)")
                let page = try decoder.decode(Page<Track>.self, from: data)
                guard generation == refreshGeneration, session?.token == current.token, libraryScope == scope else { return }
                all += page.items
                tracks = all
                offline = false
                if page.items.isEmpty || all.count >= (page.total ?? all.count) { break }
            }
            async let albumRequest = request("albums?library=\(scope)")
            async let artistRequest = request("artists?library=\(scope)")
            let (albumData, artistData) = try await (albumRequest, artistRequest)
            guard generation == refreshGeneration, session?.token == current.token, libraryScope == scope else { return }
            tracks = all
            offline = false
            albums = try decoder.decode(Page<Album>.self, from: albumData).items
            artists = try decoder.decode(Page<Artist>.self, from: artistData).items
            error = nil
        } catch APIError.unauthorized {
            guard generation == refreshGeneration, session?.token == current.token else { return }
            clearSession()
            error = APIError.unauthorized.localizedDescription
        } catch {
            guard generation == refreshGeneration, session?.token == current.token else { return }
            useDownloads()
            self.error = "服务器暂时无法连接，可继续播放已下载音乐。\(error.localizedDescription)"
        }
    }

    func selectLibrary(_ scope: String) async {
        guard ["local", "cloud"].contains(scope), scope != libraryScope else { return }
        libraryScope = scope
        tracks = []
        albums = []
        artists = []
        await refresh()
    }

    private func useDownloads() {
        offline = true
        let cached = (try? cache.store?.tracks()) ?? []
        let downloadedIDs = Set(downloaded.map(\.id))
        tracks = libraryDownloads + cached.filter {
            ($0.library ?? "local") == libraryScope && !downloadedIDs.contains($0.id)
        }
        let grouped = Dictionary(grouping: tracks, by: { $0.albumArtist + "\0" + $0.album })
        albums = grouped.keys.sorted().compactMap { key in
            guard let items = grouped[key], let first = items.first else { return nil }
            return Album(id: key, title: first.album, artist: first.albumArtist, year: first.year,
                         artwork: first.artwork ?? "", tracks: items.count)
        }
        let byArtist = Dictionary(grouping: tracks, by: \.artist)
        artists = byArtist.keys.sorted().map { name in
            Artist(name: name, tracks: byArtist[name]?.count ?? 0)
        }
    }

    func download(_ track: Track) async {
        guard let current = session, !downloading.contains(track.id), downloads.audio(track) == nil else { return }
        downloading.insert(track.id)
        defer { downloading.remove(track.id) }
        do {
            let complete = try await downloads.fetch(track, session: current)
            downloaded = try downloads.tracks()
            if offline { useDownloads() }
            if !complete {
                error = "歌曲已下载。部分海报或歌词未能获取，离线播放仍然可用。"
            }
        } catch { self.error = error.localizedDescription }
    }

    func clearPlaybackCache() async {
        await cache.clear()
        if offline { useDownloads() }
    }

    func removeDownload(_ track: Track) {
        do {
            try downloads.remove(track)
            downloaded = try downloads.tracks()
            if offline { useDownloads() }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func favorite(_ track: Track) async -> Track? {
        guard session != nil, !offline else { error = "连接服务器后可修改收藏。"; return nil }
        do {
            let data = try await request("tracks/\(track.id)/favorite", method: "PUT",
                                         body: JSONSerialization.data(withJSONObject: ["favorite": !track.favorite]))
            let updated = try decoder.decode(Track.self, from: data)
            if let index = tracks.firstIndex(where: { $0.id == updated.id }) { tracks[index] = updated }
            return updated
        } catch { self.error = error.localizedDescription }
        return nil
    }

    func scan() async {
        do {
            _ = try await request("jobs/scan", method: "POST", body: Data("{}".utf8))
            error = "扫描已开始。完成后下拉刷新音乐库即可查看新音乐。"
        } catch { self.error = error.localizedDescription }
    }

    func logout() async {
        defer { clearSession() }
        do {
            _ = try await request("auth/logout", method: "POST", body: Data("{}".utf8))
        } catch APIError.unauthorized {}
        catch { self.error = "已在本机退出。服务器暂时无法连接，远端会话将在到期后失效。" }
    }

    private func clearSession() {
        if persistsSession { Credentials.clear() }
        session = nil
        useDownloads()
    }
}
