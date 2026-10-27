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
  final Set<HttpClient> _clients = {};
  bool _clearing = false;
  PlaybackCache(Directory base, Session session)
    : root = Directory(
        '${base.path}/${sha256.convert(utf8.encode('${session.server}\n${session.username}'))}',
      );
  String _key(Track track) => sha256.convert(utf8.encode(track.id)).toString();
  File audio(Track track) =>
      File('${root.path}/${_key(track)}.${track.format}');
  File _metadata(Track track) => File('${root.path}/${_key(track)}.json');
  File lyrics(Track track) => File('${root.path}/${_key(track)}.lrc');
  File cover(Track track) => File('${root.path}/${_key(track)}.jpg');
  bool contains(Track track) =>
      tracks.containsKey(track.id) && audio(track).existsSync();
  int get size => root.existsSync()
      ? root.listSync().whereType<File>().fold(0, (n, f) => n + f.lengthSync())
      : 0;

  Future<void> load() async {
    await root.create(recursive: true);
    await for (final file in root.list()) {
      if (file is! File) continue;
      if (file.path.endsWith('.part')) {
        await file.delete();
        continue;
      }
      if (!file.path.endsWith('.json')) continue;
      try {
        final track = Track(
          Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map,
          ),
        );
        if (await audio(track).exists()) {
          tracks[track.id] = track;
          if (track.json['_downloaded'] == true) downloads.add(track.id);
        }
      } catch (_) {
        /* Ignore incomplete cache metadata; never affect the server. */
      }
    }
  }

  Future<void> save(ResonaAPI api, Track track) {
    if (_clearing || contains(track)) return Future.value();
    return _pending.putIfAbsent(
      track.id,
      () => _download(api, track).whenComplete(() {
        _pending.remove(track.id);
      }),
    );
  }

  Future<void> pin(Track track) async {
    if (!contains(track) || _clearing) throw const APIException('歌曲尚未完成下载');
    final snapshot = Track({...track.json, '_downloaded': true});
    final partial = File('${_metadata(track).path}.part');
    await partial.writeAsString(jsonEncode(snapshot.json), flush: true);
    await partial.rename(_metadata(track).path);
    tracks[track.id] = snapshot;
    downloads.add(track.id);
  }

  Future<void> remove(Track track) async {
    for (final file in [
      audio(track),
      lyrics(track),
      cover(track),
      _metadata(track),
    ]) {
      if (await file.exists()) await file.delete();
    }
    tracks.remove(track.id);
    downloads.remove(track.id);
  }

  Future<void> _download(ResonaAPI api, Track track) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _clients.add(client);
    final partial = File('${audio(track).path}.part');
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
      if (expected.isNotEmpty) {
        final Hash hash;
        if (algorithm == 'sha256') {
          hash = sha256;
        } else if (algorithm == 'sha1') {
          hash = sha1;
        } else {
          throw const APIException('不支持的音频校验算法');
        }
        if ((await hash.bind(partial.openRead()).first)
                .toString()
                .toLowerCase() !=
            expected.toLowerCase()) {
          throw const APIException('缓存音频校验失败');
        }
      }
      if (_clearing) return;
      await partial.rename(audio(track).path);
      // Metadata is the commit marker; interrupted downloads are never offered offline.
      final metadata = File('${_metadata(track).path}.part');
      await metadata.writeAsString(jsonEncode(track.json), flush: true);
      await metadata.rename(_metadata(track).path);
      tracks[track.id] = track;
      try {
        await lyrics(track).writeAsString(await api.lyrics(track));
      } catch (_) {
        /* Audio remains usable without lyrics. */
      }
      try {
        final bytes = await api.cover(track);
        if (bytes.isNotEmpty) await cover(track).writeAsBytes(bytes);
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
