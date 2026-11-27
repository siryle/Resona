import Foundation
#if os(macOS)
import Darwin
#else
import Security
#endif
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
#if os(macOS)
    private static let defaultURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.resona.macos", isDirectory: true)
        .appendingPathComponent("session.json")

    static func load(from url: URL? = nil) -> Session? {
        let target = url ?? defaultURL
        let fd = open(target.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session, to url: URL? = nil) throws {
        let target = url ?? defaultURL
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw APIError.message("无法安全保存登录凭据 (\(errno))") }
        var closed = false
        var moved = false
        defer {
            if !closed { close(fd) }
            if !moved { unlink(temporary.path) }
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else {
            throw APIError.message("无法安全保存登录凭据 (\(errno))")
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw APIError.message("无法安全保存登录凭据 (\(errno))")
                }
                if written == 0 {
                    throw APIError.message("无法安全保存登录凭据 (\(EIO))")
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw APIError.message("无法安全保存登录凭据 (\(errno))") }
        closed = true
        guard close(fd) == 0 else { throw APIError.message("无法安全保存登录凭据 (\(errno))") }
        var excluded = temporary
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        guard rename(temporary.path, target.path) == 0 else {
            throw APIError.message("无法安全保存登录凭据 (\(errno))")
        }
        moved = true
    }

    static func clear(at url: URL? = nil) {
        let target = url ?? defaultURL
        do {
            try FileManager.default.removeItem(at: target)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {}
    }
#else
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
#endif
}

private final class RenewalCancel: @unchecked Sendable {
    var task: Task<Void, Never>?
    deinit { task?.cancel() }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var session: Session? {
        didSet {
            if oldValue?.token != session?.token || oldValue?.server != session?.server {
                lastSessionRenewal = nil
                restartSessionKeepalive()
            }
        }
    }
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
    private let sessionRenewalInterval: TimeInterval
    private let renewalHandle = RenewalCancel()
    private var lastSessionRenewal: Date?
    private var renewingSession = false
    private var refreshGeneration = 0
    private var favorites: [String: Bool] = [:]

    var libraryDownloads: [Track] {
        downloaded.filter { ($0.library ?? "local") == libraryScope }
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(downloads: OfflineStore = .shared, persistsSession: Bool = true, cache: PlaybackCache? = nil, sessionRenewalInterval: TimeInterval = 12 * 3600) {
        self.downloads = downloads
        self.cache = cache ?? .shared
        self.persistsSession = persistsSession
        self.sessionRenewalInterval = sessionRenewalInterval
        do { downloaded = try downloads.tracks() }
        catch { self.error = "无法读取已下载音乐：\(error.localizedDescription)" }
        session = persistsSession ? Credentials.load() : nil
        if let session {
            self.cache.activate(session)
            serverInput = session.server.absoluteString
            username = session.username
            restartSessionKeepalive()
        } else if let identity = self.cache.identity {
            serverInput = identity.server.absoluteString
            username = identity.username
        }
        useDownloads()
    }

    func resource(_ path: String) -> URL? {
        guard let server = session?.server else { return nil }
        let base = server.absoluteString.hasSuffix("/") ? server.absoluteString : server.absoluteString + "/"
        return URL(string: base + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func buildRequest(_ path: String, method: String = "GET", body: Data? = nil, server: URL? = nil) throws -> URLRequest {
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
        return request
    }

    private func requestStatus(_ path: String, method: String = "GET", body: Data? = nil, server: URL? = nil) async throws -> Int {
        let request = try buildRequest(path, method: method, body: body, server: server)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.message("服务器响应无效") }
        return response.statusCode
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, server: URL? = nil) async throws -> Data {
        let request = try buildRequest(path, method: method, body: body, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.message("服务器响应无效") }
        if response.statusCode == 401 && server == nil { throw APIError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.message(message ?? "请求失败 (\(response.statusCode))")
        }
        return data
    }

    private func restartSessionKeepalive() {
        renewalHandle.task?.cancel()
        renewalHandle.task = nil
        guard let current = session, sessionRenewalInterval > 0 else { return }
        let nanoseconds = UInt64(max(0.01, sessionRenewalInterval) * 1_000_000_000)
        renewalHandle.task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let self, self.session?.token == current.token else { return }
                await self.renewSessionIfNeeded()
            }
        }
    }

    func renewSessionIfNeeded(force: Bool = false) async {
        guard let current = session, !renewingSession else { return }
        if !force, let lastSessionRenewal, Date().timeIntervalSince(lastSessionRenewal) < sessionRenewalInterval {
            return
        }
        renewingSession = true
        defer { renewingSession = false }
        do {
            var status = try await requestStatus("auth/refresh", method: "POST", body: Data("{}".utf8))
            guard session?.token == current.token, session?.server == current.server else { return }
            if status == 404 || status == 405 || status == 501 {
                status = try await requestStatus("auth/session", method: "GET")
                guard session?.token == current.token, session?.server == current.server else { return }
            }
            if (200..<300).contains(status) {
                lastSessionRenewal = Date()
            } else if status == 401 {
                clearSession()
                error = APIError.unauthorized.localizedDescription
            }
        } catch {
            /* Keep the saved session across transient network or server outages. */
        }
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
            lastSessionRenewal = Date()
            favorites = [:]
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
            lastSessionRenewal = Date()
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

    func download(_ track: Track, reportPartialSidecars: Bool = true) async {
        guard let current = session, !downloading.contains(track.id), downloads.audio(track) == nil else { return }
        downloading.insert(track.id)
        defer { downloading.remove(track.id) }
        do {
            let complete = try await downloads.fetch(track, session: current)
            if let favorite = favorites[track.id] {
                try downloads.updateFavorite(track.id, favorite: favorite)
            }
            downloaded = try downloads.tracks()
            if offline { useDownloads() }
            if !complete && reportPartialSidecars {
                error = "歌曲已下载。部分海报或歌词未能获取，离线播放仍然可用。"
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
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
        guard let current = session, !offline else { error = "连接服务器后可修改收藏。"; return nil }
        do {
            let data = try await request("tracks/\(track.id)/favorite", method: "PUT",
                                         body: JSONSerialization.data(withJSONObject: ["favorite": !track.favorite]))
            guard session?.token == current.token, session?.server == current.server,
                  session?.username == current.username else { return nil }
            let updated = try decoder.decode(Track.self, from: data)
            favorites[updated.id] = updated.favorite
            if let index = tracks.firstIndex(where: { $0.id == updated.id }) { tracks[index] = updated }
            if let index = downloaded.firstIndex(where: { $0.id == updated.id }) { downloaded[index].favorite = updated.favorite }
            do {
                try downloads.updateFavorite(updated.id, favorite: updated.favorite)
                try cache.updateFavorite(updated)
            } catch {
                self.error = "收藏已保存，但本机缓存信息更新失败。\(error.localizedDescription)"
            }
            return updated
        } catch is CancellationError {
            return nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            return nil
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
        renewalHandle.task?.cancel()
        renewalHandle.task = nil
        lastSessionRenewal = nil
        if persistsSession { Credentials.clear() }
        session = nil
        useDownloads()
    }
}
