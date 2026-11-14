import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'api.dart';

class PlaybackCache {
  final Directory root;
  final Map<String, Track> tracks = {};
  final Set<String> downloads = {};
  final Map<String, Future<void>> _pending = {};
  final Map<String, bool> _favorites = {};
  final Set<HttpClient> _clients = {};
  Future<void> _mutations = Future.value();
  bool _clearing = false;
  PlaybackCache(Directory base, Session session)
    : root = Directory(
        '${base.path}/${sha256.convert(utf8.encode('${session.server}\n${session.username}'))}',
      );
  String _key(Track track) => sha256.convert(utf8.encode(track.id)).toString();
  bool _sameContent(Track? saved, Track track) =>
      saved != null &&
      saved.format == track.format &&
      saved.json['hash_algorithm'] == track.json['hash_algorithm'] &&
      (saved.json['content_hash'] ?? '').toString().toLowerCase() ==
          (track.json['content_hash'] ?? '').toString().toLowerCase();
  String _resourceKey(Track track) {
    final saved = tracks[track.id];
    final revision =
        track.json['_cache_revision'] ??
        (_sameContent(saved, track) ? saved!.json['_cache_revision'] : null);
    return revision == null
        ? _key(track)
        : '${_key(track)}.${sha256.convert(utf8.encode(revision.toString()))}';
  }

  File audio(Track track) =>
      File('${root.path}/${_resourceKey(track)}.${track.format}');
  File _metadata(Track track) => File('${root.path}/${_key(track)}.json');
  File lyrics(Track track) => File('${root.path}/${_resourceKey(track)}.lrc');
  File cover(Track track) => File('${root.path}/${_resourceKey(track)}.jpg');
  bool contains(Track track) {
    final snapshot = tracks[track.id];
    if (!_sameContent(snapshot, track)) return false;
    try {
      final expected = snapshot!.json['_cache_bytes'] as int? ?? 0;
      return expected > 0 && audio(track).lengthSync() == expected;
    } on FileSystemException {
      return false;
    }
  }

  int get size => root.existsSync()
      ? root.listSync().whereType<File>().fold(0, (n, f) => n + f.lengthSync())
      : 0;

  Future<void> load() async {
    tracks.clear();
    downloads.clear();
    await root.create(recursive: true);
    await for (final file in root.list()) {
      if (file is! File) continue;
      if (file.path.endsWith('.part')) {
        await file.delete();
        continue;
      }
      if (!file.path.endsWith('.json')) continue;
      try {
        var track = Track(
          Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map,
          ),
        );
        if (file.uri.pathSegments.last != '${_key(track)}.json') continue;
        final length = await audio(track).length();
        if (length <= 0) continue;
        if (track.json['_cache_bytes'] == null ||
            track.json['_cache_revision'] == null) {
          // Verify legacy bytes before moving them to immutable revision paths.
          final expected = track.json['content_hash'] as String? ?? '';
          final hash = switch (track.json['hash_algorithm']) {
            'sha256' => sha256,
            'sha1' => sha1,
            _ => expected.isEmpty ? sha256 : null,
          };
          if (hash == null) continue;
          final actual = (await hash.bind(audio(track).openRead()).first)
              .toString();
          if (expected.isNotEmpty
              ? actual != expected.toLowerCase()
              : (track.json['_cache_bytes'] ?? track.json['size']) != length) {
            continue;
          }
          final originals = [audio(track), lyrics(track), cover(track)];
          final migrated = Track({
            ...track.json,
            '_cache_bytes': length,
            '_cache_revision': actual,
          });
          try {
            for (final pair in [
              (audio(track), audio(migrated)),
              (lyrics(track), lyrics(migrated)),
              (cover(track), cover(migrated)),
            ]) {
              if (pair.$1.path != pair.$2.path && await pair.$1.exists()) {
                await pair.$1.copy(pair.$2.path);
              }
            }
            await _writeMetadata(migrated);
            track = migrated;
          } on FileSystemException {
            /* Keep verified legacy downloads playable if migration cannot finish. */
          }
          for (final old in originals) {
            if (![
                  audio(track).path,
                  lyrics(track).path,
                  cover(track).path,
                ].contains(old.path) &&
                await old.exists()) {
              try {
                await old.delete();
              } on FileSystemException {
                /* Retry cleanup after an open decoder releases the old file. */
              }
            }
          }
        }
        if (track.json['_cache_bytes'] != length) continue;
        tracks[track.id] = track;
        if (track.json['_downloaded'] == true) downloads.add(track.id);
      } catch (_) {
        /* Ignore incomplete cache metadata; never affect the server. */
      }
    }
    await _removeOrphans();
  }

  Future<void> _mutate(Future<void> Function() action) {
    final work = _mutations.then((_) => action());
    _mutations = work.catchError((Object _) {});
    return work;
  }

  Future<void> _writeMetadata(Track track) async {
    final partial = File('${_metadata(track).path}.part');
    await partial.writeAsString(jsonEncode(track.json), flush: true);
    await partial.rename(_metadata(track).path);
    tracks[track.id] = track;
    if (track.json['_downloaded'] == true) downloads.add(track.id);
  }

  Future<void> _removeOrphans() async {
    final retained = tracks.values
        .expand(
          (track) => [audio(track).uri, lyrics(track).uri, cover(track).uri],
        )
        .toSet();
    await for (final file in root.list()) {
      if (file is File &&
          file.uri.pathSegments.last.split('.').length > 2 &&
          !retained.contains(file.uri) &&
          !file.path.endsWith('.part')) {
        try {
          await file.delete();
        } on FileSystemException {
          /* A decoder may still have the previous revision open on Windows. */
        }
      }
    }
  }

  Future<void> save(ResonaAPI api, Track track) async {
    if (_clearing || contains(track)) return;
    final pending = _pending[track.id];
    if (pending != null) {
      await pending;
      if (_clearing || contains(track)) return;
    }
    await _pending.putIfAbsent(
      track.id,
      () => _download(api, track).whenComplete(() {
        _pending.remove(track.id);
      }),
    );
  }

  Future<void> pin(Track track) => _mutate(() async {
    if (!contains(track) || _clearing) throw const APIException('歌曲尚未完成下载');
    final saved = tracks[track.id]!;
    await _writeMetadata(
      Track({
        ...saved.json,
        'favorite': _favorites[track.id] ?? saved.favorite,
        '_downloaded': true,
      }),
    );
  });

  Future<void> updateFavorite(String id, bool favorite) async {
    _favorites[id] = favorite;
    try {
      await _pending[id];
    } catch (_) {
      /* A failed download may leave no metadata to update. */
    }
    await _mutate(() async {
      final saved = tracks[id];
      if (saved == null || _clearing || _favorites[id] != favorite) return;
      await _writeMetadata(Track({...saved.json, 'favorite': favorite}));
    });
  }

  Future<void> remove(Track track) async {
    try {
      await _pending[track.id];
    } catch (_) {
      /* A failed refresh must not prevent removing an older download. */
    }
    await _mutate(() async {
      if (_clearing) return;
      final saved = tracks[track.id] ?? track;
      for (final file in [
        _metadata(saved),
        audio(saved),
        lyrics(saved),
        cover(saved),
      ]) {
        if (await file.exists()) await file.delete();
      }
      tracks.remove(track.id);
      downloads.remove(track.id);
      await _removeOrphans();
    });
  }

  Future<void> _download(ResonaAPI api, Track track) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _clients.add(client);
    final partial = File('${root.path}/${_key(track)}.download.part');
    IOSink? sink;
    try {
      await root.create(recursive: true);
      final response = await api.media(
        client,
        api.endpoint('tracks/${Uri.encodeComponent(track.id)}/stream'),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw APIException('缓存下载失败 (${response.statusCode})');
      }
      sink = partial.openWrite();
      var count = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        count += chunk.length;
        if (count > 2 << 30) throw const APIException('单首缓存最多支持 2 GiB');
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (count == 0 ||
          (response.contentLength >= 0 && count != response.contentLength)) {
        throw const APIException('缓存文件不完整');
      }
      final algorithm = track.json['hash_algorithm'];
      final expected = track.json['content_hash'] as String? ?? '';
      final hash = switch (algorithm) {
        'sha256' => sha256,
        'sha1' => sha1,
        _ => expected.isEmpty ? sha256 : null,
      };
      if (hash == null) throw const APIException('不支持的音频校验算法');
      final actual = (await hash.bind(partial.openRead()).first).toString();
      if (expected.isNotEmpty && actual != expected.toLowerCase()) {
        throw const APIException('缓存音频校验失败');
      }
      final snapshot = await _mutate(() async {
        if (_clearing) return;
        final previous = tracks[track.id];
        final saved = Track({
          ...track.json,
          'favorite': _favorites[track.id] ?? track.favorite,
          '_cache_bytes': count,
          '_cache_revision': actual,
          if (downloads.contains(track.id)) '_downloaded': true,
        });
        // Publish metadata only after this immutable audio revision is complete.
        await partial.rename(audio(saved).path);
        await _writeMetadata(saved);
        if (previous != null) {
          final retained = {
            audio(saved).path,
            lyrics(saved).path,
            cover(saved).path,
          };
          for (final old in [
            audio(previous),
            lyrics(previous),
            cover(previous),
          ]) {
            if (!retained.contains(old.path)) {
              try {
                if (await old.exists()) await old.delete();
              } on FileSystemException {
                /* Clean up an open decoder's old revision on the next launch. */
              }
            }
          }
        }
      }).then((_) => tracks[track.id]);
      if (_clearing || snapshot == null || !_sameContent(snapshot, track)) {
        return;
      }
      try {
        await lyrics(snapshot).writeAsString(await api.lyrics(track));
      } catch (_) {
        /* Audio remains usable without lyrics. */
      }
      try {
        final bytes = await api.cover(track);
        if (bytes.isNotEmpty) await cover(snapshot).writeAsBytes(bytes);
      } catch (_) {
        /* Artwork is optional. */
      }
    } finally {
      await sink?.close();
      client.close(force: true);
      _clients.remove(client);
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> clear() async {
    _clearing = true;
    try {
      for (final client in _clients.toList()) {
        client.close(force: true);
      }
      await Future.wait(
        _pending.values.toList().map((task) => task.catchError((Object _) {})),
      );
      await _mutations;
      final preserved = tracks.values
          .where((t) => downloads.contains(t.id))
          .map(_key)
          .toSet();
      if (await root.exists()) {
        await for (final file in root.list()) {
          if (file is File &&
              !preserved.contains(
                file.uri.pathSegments.last.split('.').first,
              )) {
            await file.delete();
          }
        }
      }
      tracks.removeWhere((id, _) => !downloads.contains(id));
      await root.create(recursive: true);
      await _removeOrphans();
    } finally {
      _clearing = false;
    }
  }

  Future<void> stop() async {
    _clearing = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    await Future.wait(
      _pending.values.toList().map((task) => task.catchError((Object _) {})),
    );
    await _mutations;
  }
}

// A private loopback relay keeps authentication out of the native decoder's redirect handling.
class PlaybackRelay {
  final ResonaAPI api;
  final String secret;
  HttpServer? _server;
  final Set<HttpClient> _clients = {};
  PlaybackRelay(this.api, this.secret);
  Future<Uri> url(Track track) async {
    if (_server == null) {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen((request) async {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 15);
        _clients.add(client);
        try {
          if (!['GET', 'HEAD'].contains(request.method) ||
              request.uri.pathSegments.length != 2 ||
              request.uri.pathSegments[0] != secret) {
            request.response.statusCode = 404;
            return;
          }
          final id = request.uri.pathSegments[1];
          final response = await api.media(
            client,
            api.endpoint('tracks/${Uri.encodeComponent(id)}/stream'),
            range: request.headers.value('range'),
          );
          request.response.statusCode = response.statusCode;
          for (final header in [
            'content-type',
            'content-length',
            'content-range',
            'accept-ranges',
          ]) {
            final value = response.headers.value(header);
            if (value != null) request.response.headers.set(header, value);
          }
          if (request.method != 'HEAD') {
            await request.response.addStream(
              response.timeout(const Duration(seconds: 30)),
            );
          }
        } catch (_) {
          try {
            request.response.statusCode = 502;
          } catch (_) {
            /* Response may already be streaming. */
          }
        } finally {
          client.close(force: true);
          _clients.remove(client);
          await request.response.close().catchError((Object _) {});
        }
      });
    }
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server!.port,
      pathSegments: [secret, track.id],
    );
  }

  Future<void> close() async {
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    await _server?.close(force: true);
    _server = null;
  }
}
