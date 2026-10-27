import Foundation
import CryptoKit
import SwiftUI

struct OfflineStore: Sendable {
    static let shared = OfflineStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.resona", isDirectory: true)
        .appendingPathComponent("Downloads", isDirectory: true))
    let root: URL

    private func directory(_ id: String) -> URL? {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    private func audioName(_ track: Track) -> String {
        let formats = ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aiff", "alac", "wma"]
        return "audio." + (formats.contains(track.format.lowercased()) ? track.format.lowercased() : "bin")
    }

    func audio(_ track: Track) -> URL? {
        guard let dir = directory(track.id) else { return nil }
        let url = dir.appendingPathComponent(audioName(track))
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("track.json")),
              let saved = try? JSONDecoder().decode(Track.self, from: data),
              saved.id == track.id, saved.hashAlgorithm == track.hashAlgorithm, saved.contentHash == track.contentHash,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return nil }
        if let expected = try? String(contentsOf: dir.appendingPathComponent("audio.bytes"), encoding: .utf8),
           Int(expected) != size { return nil }
        return url
    }

    func sidecar(_ id: String, name: String) -> URL? {
        guard ["cover", "lyrics"].contains(name), let dir = directory(id) else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func tracks() throws -> [Track] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { dir in
            guard directory(dir.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("track.json")),
                  let track = try? JSONDecoder().decode(Track.self, from: data),
                  track.id == dir.lastPathComponent, audio(track) != nil else { return nil }
            return track
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // Track identity and the audio content digest are separate for remote sources.
    func save(_ track: Track, temporary: URL, cover: Data?, lyrics: Data?) throws {
        guard let dir = directory(track.id) else { throw APIError.message("下载歌曲标识无效") }
        let input = try FileHandle(forReadingFrom: temporary)
        defer { try? input.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        let algorithm = track.hashAlgorithm ?? "sha256"
        let expected = track.contentHash ?? track.id
        guard algorithm == "sha256" || algorithm == "sha1" else {
            throw APIError.message("服务器未提供可用的下载校验值")
        }
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            if algorithm == "sha1" { sha1.update(data: chunk) }
            else { sha256.update(data: chunk) }
        }
        let actual = algorithm == "sha1"
            ? sha1.finalize().map({ String(format: "%02x", $0) }).joined()
            : sha256.finalize().map({ String(format: "%02x", $0) }).joined()
        guard actual == expected.lowercased() else {
            throw APIError.message("下载文件校验失败，请重试")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: temporary, to: staging.appendingPathComponent(audioName(track)))
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try String(size).write(to: staging.appendingPathComponent("audio.bytes"), atomically: true, encoding: .utf8)
        try cover?.write(to: staging.appendingPathComponent("cover"), options: .atomic)
        try lyrics?.write(to: staging.appendingPathComponent("lyrics"), options: .atomic)
        try JSONEncoder().encode(track).write(to: staging.appendingPathComponent("track.json"), options: .atomic)
        if audio(track) != nil { return }
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        try FileManager.default.moveItem(at: staging, to: dir)
    }

    func remove(_ track: Track) throws {
        guard let dir = directory(track.id) else { throw APIError.message("下载歌曲标识无效") }
        try FileManager.default.removeItem(at: dir)
    }

    func fetch(_ track: Track, session: Session) async throws -> Bool {
        var request = URLRequest(url: session.server.appendingPathComponent("api/v1/tracks/\(track.id)/stream"))
        request.timeoutInterval = 120
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.message("下载失败，请检查服务器登录") }
        let cover = await sidecarData("cover", track: track, session: session)
        let lyrics = await sidecarData("lyrics", track: track, session: session)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try save(track, temporary: temporary, cover: cover, lyrics: lyrics)
        }.value
        return (track.artwork == nil || cover != nil) && lyrics != nil
    }

    private func sidecarData(_ name: String, track: Track, session: Session) async -> Data? {
        if name == "cover" && track.artwork == nil { return nil }
        var request = URLRequest(url: session.server.appendingPathComponent("api/v1/tracks/\(track.id)/\(name)"))
        request.timeoutInterval = 20
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        guard !Task.isCancelled, let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

@MainActor
final class PlaybackCache: ObservableObject {
    static let shared = PlaybackCache(root: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.resona", isDirectory: true)
        .appendingPathComponent("Playback", isDirectory: true))
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var clearing = false
    @Published private(set) var message: String?
    private let root: URL
    private(set) var store: OfflineStore?
    private var pending: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var generation = 0

    init(root: URL) { self.root = root }

    func activate(_ session: Session) {
        let scope = SHA256.hash(data: Data((session.server.absoluteString + "\0" + session.username).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let scoped = root.appendingPathComponent(scope, isDirectory: true)
        guard store?.root != scoped else { return }
        store = OfflineStore(root: scoped)
    }

    func audio(_ track: Track) -> URL? { store?.audio(track) }

    func start(_ track: Track, session: Session) {
        guard !clearing else { return }
        activate(session)
        guard let store, store.audio(track) == nil else { return }
        let key = store.root.path + "/" + track.id
        guard pending[key] == nil else { return }
        let generation = generation
        let previous = tail
        let task = Task {
            defer { pending[key] = nil }
            do {
                if let previous { await previous.value }
                try Task.checkCancellation()
                _ = try await store.fetch(track, session: session)
                guard !Task.isCancelled, generation == self.generation else { return }
                await refreshSize()
            } catch {
                if !Task.isCancelled {
                    message = "播放缓存未完成，下次播放将重试。\(error.localizedDescription)"
                }
            }
        }
        pending[key] = task
        tail = task
    }

    func refreshSize() async {
        let root = root
        let generation = generation
        let size = await Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
            var total: Int64 = 0
            while let file = files?.nextObject() as? URL {
                if let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                }
            }
            return total
        }.value
        if generation == self.generation { bytes = size }
    }

    func clear() async {
        guard !clearing else { return }
        clearing = true
        generation += 1
        message = nil
        defer { clearing = false }
        let tasks = Array(pending.values)
        tasks.forEach { $0.cancel() }
        // Wait for any integrity check / atomic save before removing the cache.
        for task in tasks { await task.value }
        tail = nil
        do {
            let root = root
            try await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            }.value
            bytes = 0
            message = "播放缓存已清理，手动下载的音乐已保留。"
        } catch { message = "清理缓存失败：\(error.localizedDescription)" }
    }
}
