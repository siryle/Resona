import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/cache.dart';

void main() {
  test('server addresses retain proxy prefix and reject embedded secrets', () {
    expect(
      serverAddress('https://example.com/music/').resolve('api/v1/tracks').path,
      '/music/api/v1/tracks',
    );
    for (final address in [
      'ftp://example.com',
      'https://user:password@example.com',
      'https://example.com/?token=secret',
      'example.com',
    ]) {
      expect(() => serverAddress(address), throwsFormatException);
    }
    final server = serverAddress('https://example.com/resona');
    expect(
      trustedMedia(Uri.parse('https://cdnfhnfile.115cdn.net/file'), server),
      true,
    );
    expect(
      trustedMedia(Uri.parse('https://115cdn.net.evil.example/file'), server),
      false,
    );
    expect(
      trustedMedia(Uri.parse('https://cdn.115cdn.net:9999/file'), server),
      false,
    );
    expect(trustedMedia(Uri.parse('http://127.0.0.1/file'), server), false);
    expect(trustedMedia(Uri.parse('file:///etc/passwd'), server), false);
  });

  late HttpServer server;
  late Directory directory;
  late ResonaAPI api;
  late Session session;
  late PlaybackCache cache;
  final audio = List<int>.generate(256 * 1024, (i) => i % 256);
  final hash = sha256.convert(audio).toString();
  late Track track;
  int downloads = 0;
  late List<int> servedAudio;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    directory = await Directory.systemTemp.createTemp('resona-cache-test-');
    session = Session(
      serverAddress('http://127.0.0.1:${server.port}/prefix'),
      'user',
      'secret',
    );
    api = ResonaAPI(session);
    cache = PlaybackCache(directory, session);
    await cache.load();
    downloads = 0;
    servedAudio = audio;
    track = Track({
      'id': hash,
      'title': 'Song',
      'artist': 'Artist',
      'format': 'flac',
      'hash_algorithm': 'sha256',
      'content_hash': hash,
    });
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer secret');
      if (request.uri.path.endsWith('/stream')) {
        downloads++;
        if (request.headers.value('range') == 'bytes=10-19') {
          request.response.statusCode = 206;
          request.response.headers.set(
            'content-range',
            'bytes 10-19/${audio.length}',
          );
          request.response.headers.set('accept-ranges', 'bytes');
          request.response.add(audio.sublist(10, 20));
        } else {
          request.response.add(servedAudio);
        }
      } else if (request.uri.path.endsWith('/artists/avatar')) {
        expect(request.uri.path, '/prefix/api/v1/artists/avatar');
        expect(request.uri.queryParameters['name'], 'Artist & 歌手');
        request.response.add([1, 2, 3]);
      } else if (request.uri.path.endsWith('/lyrics')) {
        request.response.write('[00:01]Hello');
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await cache.stop();
    api.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('artist artwork keeps authentication, query and proxy prefix', () async {
    final path =
        '/api/v1/artists/avatar?name=${Uri.encodeQueryComponent('Artist & 歌手')}';
    expect(await api.artistArtwork(path), [1, 2, 3]);
    expect(await api.artistArtwork('https://evil.example/avatar'), isEmpty);
    expect(await api.artistArtwork(''), isEmpty);
  });

  test(
    'complete verified cache is reusable offline and isolated by account',
    () async {
      await Future.wait([cache.save(api, track), cache.save(api, track)]);
      expect(downloads, 1);
      expect(cache.contains(track), true);
      expect(await cache.audio(track).readAsBytes(), audio);
      expect(await cache.lyrics(track).readAsString(), '[00:01]Hello');
      final reopened = PlaybackCache(directory, session);
      await reopened.load();
      expect(reopened.contains(track), true);
      final other = PlaybackCache(
        directory,
        Session(session.server, 'other', 'token'),
      );
      await other.load();
      expect(other.contains(track), false);
      await cache.clear();
      expect(cache.contains(track), false);
      expect(cache.size, 0);
    },
  );

  test(
    'manual downloads survive cache clearing and can be removed explicitly',
    () async {
      await cache.save(api, track);
      await cache.pin(track);
      final other = Track({...track.json, 'id': 'automatic-cache'});
      await cache.save(api, other);
      await cache.clear();
      expect(cache.contains(track), true);
      expect(cache.contains(other), false);
      final reopened = PlaybackCache(directory, session);
      await reopened.load();
      expect(reopened.downloads, {track.id});
      await reopened.remove(track);
      expect(reopened.contains(track), false);
      expect(reopened.downloads, isEmpty);
      expect(reopened.size, 0);
    },
  );

  test(
    'bad hash and incomplete metadata are never published as cached audio',
    () async {
      final bad = Track({...track.json, 'content_hash': 'wrong'});
      await expectLater(cache.save(api, bad), throwsA(isA<APIException>()));
      expect(cache.contains(bad), false);
      expect(await cache.audio(bad).exists(), false);
      expect(
        await directory
            .list(recursive: true)
            .where((f) => f.path.endsWith('.part'))
            .length,
        0,
      );
    },
  );

  test('truncated caches are rejected on disk and repaired by save', () async {
    for (final length in [0, 123]) {
      await cache.save(api, track);
      await cache.audio(track).writeAsBytes(audio.take(length).toList());
      expect(cache.contains(track), false);
      final reopened = PlaybackCache(directory, session);
      await reopened.load();
      expect(reopened.tracks, isEmpty);
      await reopened.save(api, track);
      expect(reopened.contains(track), true);
      expect(await reopened.audio(track).readAsBytes(), audio);
    }
  });

  test('content revision replaces audio without losing a manual pin', () async {
    await cache.save(api, track);
    await cache.pin(track);
    final bytes = List<int>.from(audio.reversed);
    final revised = Track({
      ...track.json,
      'content_hash': sha256.convert(bytes).toString(),
    });
    expect(cache.contains(revised), false);
    await expectLater(cache.save(api, revised), throwsA(isA<APIException>()));
    expect(cache.contains(track), true);
    expect(cache.downloads, {track.id});
    servedAudio = bytes;
    await cache.save(api, revised);
    expect(cache.contains(revised), true);
    expect(cache.contains(track), false);
    expect(await cache.audio(revised).readAsBytes(), bytes);
    final reopened = PlaybackCache(directory, session);
    await reopened.load();
    expect(reopened.contains(revised), true);
    expect(reopened.downloads, {track.id});
    await reopened.clear();
    expect(reopened.contains(revised), true);
  });

  test(
    'favorite set during download reaches persisted cache metadata',
    () async {
      final pending = cache.save(api, track);
      await cache.updateFavorite(track.id, true);
      await pending;
      expect(cache.tracks[track.id]!.favorite, isTrue);
      await cache.pin(track);
      final reopened = PlaybackCache(directory, session);
      await reopened.load();
      expect(reopened.tracks[track.id]!.favorite, isTrue);
      expect(reopened.contains(track), isTrue);
      expect(reopened.downloads, {track.id});
      await reopened.updateFavorite(track.id, false);
      final restarted = PlaybackCache(directory, session);
      await restarted.load();
      expect(restarted.tracks[track.id]!.favorite, isFalse);
      expect(restarted.contains(track), isTrue);
      expect(restarted.downloads, {track.id});
    },
  );

  File metadataFile(Track song) => File(
    '${cache.root.path}/${cache.audio(song).uri.pathSegments.last.split('.').first}.json',
  );

  test(
    'concurrent pin and favorite preserve both changes after restart',
    () async {
      await cache.save(api, track);
      for (var i = 0; i < 10; i++) {
        await Future.wait([
          cache.pin(track),
          cache.updateFavorite(track.id, i.isEven),
        ]);
        final reopened = PlaybackCache(directory, session);
        await reopened.load();
        expect(reopened.downloads, {track.id});
        expect(reopened.tracks[track.id]!.favorite, i.isEven);
      }
      await cache.clear();
      expect(cache.contains(track), isTrue);
    },
  );

  test(
    'failed revision commit retains the previous verified download',
    () async {
      await cache.save(api, track);
      await cache.pin(track);
      final oldPath = cache.audio(track).path;
      final oldLyrics = await cache.lyrics(track).readAsString();
      final revisedBytes = List<int>.from(audio.reversed);
      final revised = Track({
        ...track.json,
        'content_hash': sha256.convert(revisedBytes).toString(),
      });
      final blocked = Directory('${metadataFile(track).path}.part');
      await blocked.create();
      servedAudio = revisedBytes;
      await expectLater(
        cache.save(api, revised),
        throwsA(isA<FileSystemException>()),
      );
      expect(cache.contains(track), isTrue);
      expect(await cache.audio(track).readAsBytes(), audio);
      await blocked.delete();
      final reopened = PlaybackCache(directory, session);
      await reopened.load();
      expect(reopened.contains(track), isTrue);
      expect(reopened.contains(revised), isFalse);
      expect(reopened.downloads, {track.id});
      expect(await reopened.lyrics(track).readAsString(), oldLyrics);
      servedAudio = revisedBytes;
      await reopened.save(api, revised);
      expect(reopened.audio(revised).path, isNot(oldPath));
      expect(await reopened.audio(revised).readAsBytes(), revisedBytes);
      expect(reopened.downloads, {track.id});
    },
  );

  test(
    'legacy migration rejects equal-length audio with a different digest',
    () async {
      await cache.audio(track).writeAsBytes(audio.reversed.toList());
      await metadataFile(track).writeAsString(
        jsonEncode({
          ...track.json,
          '_cache_bytes': audio.length,
          '_downloaded': true,
        }),
      );
      final reopened = PlaybackCache(directory, session);
      await reopened.load();
      expect(reopened.tracks, isEmpty);
      expect(reopened.downloads, isEmpty);
    },
  );

  test(
    'failed legacy migration keeps verified manual downloads usable',
    () async {
      await cache.audio(track).writeAsBytes(audio);
      final original = cache.audio(track).path;
      final metadata = metadataFile(track);
      await metadata.writeAsString(
        jsonEncode({
          ...track.json,
          '_cache_bytes': audio.length,
          '_downloaded': true,
        }),
      );
      final blocked = Directory('${metadata.path}.part');
      await blocked.create();
      final reopened = PlaybackCache(directory, session);
      await reopened.load();
      expect(reopened.contains(track), isTrue);
      expect(reopened.downloads, {track.id});
      expect(await reopened.audio(track).readAsBytes(), audio);
      expect(await File(original).exists(), isTrue);
      await blocked.delete();
      await reopened.load();
      expect(reopened.contains(track), isTrue);
      expect(reopened.downloads, {track.id});
      expect(reopened.audio(track).path, isNot(original));
    },
  );

  test('legacy cache migration verifies hashes before publishing', () async {
    await cache.save(api, track);
    await cache.pin(track);
    final metadata = metadataFile(track);
    final legacy = Map<String, dynamic>.from(
      jsonDecode(await metadata.readAsString()) as Map,
    )..remove('_cache_bytes');
    await metadata.writeAsString(jsonEncode(legacy));
    final reopened = PlaybackCache(directory, session);
    await reopened.load();
    expect(reopened.contains(track), true);
    expect(reopened.downloads, {track.id});
    await metadata.writeAsString(jsonEncode(legacy));
    await cache.audio(track).writeAsBytes([1, 2, 3]);
    final broken = PlaybackCache(directory, session);
    await broken.load();
    expect(broken.tracks, isEmpty);
  });

  test(
    'redirect cannot leak a Resona credential to an unrelated origin',
    () async {
      final redirector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final external = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var contactedExternal = false;
      external.listen((request) async {
        contactedExternal = true;
        await request.response.close();
      });
      redirector.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer private-token');
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${external.port}/stolen',
        );
        await request.response.close();
      });
      final protected = ResonaAPI(
        Session(
          serverAddress('http://127.0.0.1:${redirector.port}'),
          'user',
          'private-token',
        ),
      );
      final transport = HttpClient();
      try {
        await expectLater(
          protected.media(transport, protected.endpoint('tracks/id/stream')),
          throwsA(isA<APIException>()),
        );
        expect(contactedExternal, false);
      } finally {
        transport.close(force: true);
        protected.close();
        await redirector.close(force: true);
        await external.close(force: true);
      }
    },
  );

  test(
    'private relay preserves range and rejects missing capability',
    () async {
      final relay = PlaybackRelay(api, 'unguessable-capability');
      final transport = HttpClient();
      try {
        final url = await relay.url(track);
        final wrong = await (await transport.getUrl(
          url.replace(path: '/wrong/${track.id}'),
        )).close();
        expect(wrong.statusCode, 404);
        await wrong.drain<void>();
        final response = await (await transport.getUrl(url)).close();
        expect(response.statusCode, 200);
        expect(await limitedBytes(response, 1 << 20), audio);
        final rangeRequest = await transport.getUrl(url);
        rangeRequest.headers.set('range', 'bytes=10-19');
        final range = await rangeRequest.close();
        expect(range.statusCode, 206);
        expect(
          range.headers.value('content-range'),
          'bytes 10-19/${audio.length}',
        );
        expect(await limitedBytes(range, 1024), audio.sublist(10, 20));
      } finally {
        transport.close(force: true);
        await relay.close();
      }
    },
  );

  test('JSON API authenticates and uses base URL prefix', () async {
    final jsonServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    jsonServer.listen((request) async {
      expect(request.uri.path, '/prefix/api/v1/tracks');
      expect(request.uri.queryParameters['library'], 'cloud');
      expect(request.headers.value('authorization'), 'Bearer token');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'items': [], 'total': 0}));
      await request.response.close();
    });
    final jsonAPI = ResonaAPI(
      Session(
        serverAddress('http://127.0.0.1:${jsonServer.port}/prefix'),
        'user',
        'token',
      ),
    );
    try {
      expect(
        (await jsonAPI.json(
          'GET',
          'tracks',
          query: {'library': 'cloud'},
        ))['total'],
        0,
      );
    } finally {
      jsonAPI.close();
      await jsonServer.close(force: true);
    }
  });

  test(
    'refreshSession hits auth/refresh and falls back to auth/session on 404',
    () async {
      final authServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      var legacy = false;
      authServer.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        expect(request.headers.value('authorization'), 'Bearer token');
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/prefix/api/v1/auth/refresh') {
          if (legacy) {
            request.response.statusCode = 404;
            request.response.write(jsonEncode({'error': 'not found'}));
          } else {
            request.response.write(
              jsonEncode({'username': 'user', 'expires_in': 31536000}),
            );
          }
        } else if (request.uri.path == '/prefix/api/v1/auth/session') {
          request.response.write(jsonEncode({'username': 'user'}));
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final authAPI = ResonaAPI(
        Session(
          serverAddress('http://127.0.0.1:${authServer.port}/prefix'),
          'user',
          'token',
        ),
      );
      try {
        await authAPI.refreshSession();
        expect(requests, ['POST /prefix/api/v1/auth/refresh']);
        legacy = true;
        await authAPI.refreshSession();
        expect(requests, [
          'POST /prefix/api/v1/auth/refresh',
          'POST /prefix/api/v1/auth/refresh',
          'GET /prefix/api/v1/auth/session',
        ]);
      } finally {
        authAPI.close();
        await authServer.close(force: true);
      }
    },
  );
}
