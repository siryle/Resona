import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:resona_client/api.dart';
import 'package:resona_client/cache.dart';
import 'package:resona_client/controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('resona-offline-');
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('first launch does not require a session', () async {
    final c = MusicController(supportDirectory: root);
    await c.initialize();
    expect(c.authenticated, false);
    expect(c.loading, false);
    expect(c.error, null);
    c.navigate('缓存');
    await c.load();
    expect(c.tracks, isEmpty);
    c.dispose();
  });
  Future<Session> prepare(String address, {String token = ''}) async {
    final identity = Session(serverAddress(address), 'user', token);
    final cache = PlaybackCache(
      Directory('${root.path}/playback-cache'),
      identity,
    );
    await cache.load();
    final track = Track({
      'id': 'local-song',
      'title': 'Offline Song',
      'format': 'mp3',
      '_downloaded': true,
      'size': 3,
      'duration': 120,
    });
    await cache.audio(track).writeAsBytes([1, 2, 3]);
    final key = cache
        .audio(track)
        .path
        .replaceFirst(RegExp(r'\.mp3$'), '.json');
    await File(key).writeAsString(jsonEncode(track.json));
    FlutterSecureStorage.setMockInitialValues({
      token.isEmpty ? 'identity' : 'session': jsonEncode(identity.toJson()),
    });
    return identity;
  }

  Future<File> playbackState(Session identity) async {
    final cache = PlaybackCache(
      Directory('${root.path}/playback-cache'),
      identity,
    );
    return File('${cache.root.path}.playback.json');
  }

  Future<void> saveQueue(MusicController c) async {
    c.current = c.tracks.single;
    c.queue = [
      Track({'id': 'uncached-song', 'title': 'Remote Song', 'duration': 90}),
      c.current!,
      Track({'id': 'cloud-song', 'library': 'cloud', 'duration': 100}),
    ];
    c.position = const Duration(seconds: 37);
    c.setShuffle(true);
    c.setRepeat(true);
    await c.setVolume(0.35);
  }

  Future<Track> addCached(MusicController c, String id) async {
    final song = Track({
      'id': id,
      'title': id,
      'format': 'mp3',
      'duration': 60,
      '_cache_bytes': 3,
    });
    await c.cache!.audio(song).writeAsBytes([1, 2, 3]);
    c.cache!.tracks[id] = song;
    return song;
  }

  for (final focusFailure in [false, true]) {
    test(
      'failed playback preflight preserves active song ($focusFailure)',
      () async {
        await prepare('http://127.0.0.1:1');
        final engine = RecordingPlayer();
        final c = PlaybackController(root, engine);
        await c.initialize();
        final first = c.tracks.single;
        await c.play(first);
        c.position = const Duration(seconds: 19);
        c.playing = true;
        final next = focusFailure
            ? await addCached(c, 'next')
            : Track({'id': 'missing'});
        c.lyricText = 'Current lyrics';
        if (focusFailure) c.activateAudio = () async => false;
        c.tracks = [next];
        await c.play(next);
        expect(c.current?.id, first.id);
        expect(c.queue.map((t) => t.id), [first.id]);
        expect(c.position.inSeconds, 19);
        expect(c.lyricText, 'Current lyrics');
        expect(c.playing, isTrue);
        expect(c.opening, isFalse);
        expect(c.error, isNotNull);
        expect(engine.opened.length, 1);
        await c.savePlaybackState();
        c.dispose();
        final restored = MusicController(supportDirectory: root);
        await restored.initialize();
        expect(restored.current?.id, first.id);
        expect(restored.position.inSeconds, 19);
        restored.dispose();
      },
    );
  }

  test(
    'decoder failure keeps previous selection paused and retryable',
    () async {
      await prepare('http://127.0.0.1:1');
      final engine = RecordingPlayer();
      final c = PlaybackController(root, engine);
      await c.initialize();
      final first = c.tracks.single;
      await c.play(first);
      c.position = const Duration(seconds: 19);
      c.playing = true;
      final next = await addCached(c, 'next');
      engine.failOpen = true;
      await c.play(next);
      expect(c.current?.id, first.id);
      expect(c.playing, isFalse);
      expect(engine.stops, 1);
      engine.failOpen = false;
      await c.toggle();
      expect(engine.opened.last.start?.inSeconds, 19);
      expect(
        engine.opened.last.uri,
        Media(c.cache!.audio(first).uri.toString()).uri,
      );
      expect(c.current?.id, first.id);
      await c.savePlaybackState();
      c.dispose();
    },
  );

  for (final nextCached in [false, true]) {
    test(
      'delayed decoder cannot publish a superseded song ($nextCached)',
      () async {
        await prepare('http://127.0.0.1:1');
        final engine = RecordingPlayer();
        final c = PlaybackController(root, engine);
        await c.initialize();
        final first = c.tracks.single;
        await c.play(first);
        final second = await addCached(c, 'second');
        final third = nextCached
            ? await addCached(c, 'third')
            : Track({'id': 'missing'});
        final gate = Completer<void>();
        engine.nextOpenGate = gate.future;
        engine.openStarted = Completer<void>();
        final older = c.play(second);
        await engine.openStarted!.future;
        final newer = c.play(third);
        gate.complete();
        await Future.wait([older, newer]);
        expect(c.current?.id, nextCached ? third.id : first.id);
        expect(c.opening, isFalse);
        expect(engine.stops, 1);
        if (!nextCached) expect(c.playing, isFalse);
        await c.savePlaybackState();
        c.dispose();
      },
    );
  }

  test('favorite changes survive offline filtering and restart', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'PUT') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        request.response.write(jsonEncode({'favorite': body['favorite']}));
      } else if (request.uri.path.endsWith('tracks')) {
        request.response.write('{"items":[],"total":0}');
      } else {
        request.response.write('{}');
      }
      await request.response.close();
    });
    try {
      await prepare('http://127.0.0.1:${server.port}', token: 'valid');
      final c = MusicController(supportDirectory: root);
      await c.initialize();
      final song = c.cache!.tracks.values.single;
      await c.favorite(song);
      expect(c.cache!.tracks[song.id]!.favorite, isTrue);
      expect(c.cache!.downloads, contains(song.id));
      await c.favorite(c.cache!.tracks[song.id]!);
      expect(c.cache!.tracks[song.id]!.favorite, isFalse);
      await c.favorite(c.cache!.tracks[song.id]!);
      c.offline = true;
      c.section = '喜欢';
      await c.load();
      expect(c.tracks.single.id, song.id);
      await c.savePlaybackState();
      c.dispose();
      await server.close(force: true);
      final restored = MusicController(supportDirectory: root);
      await restored.initialize();
      restored.section = '喜欢';
      await restored.load();
      expect(restored.tracks.single.id, song.id);
      expect(restored.cache!.contains(song), isTrue);
      restored.offline = false;
      // Test the persisted un-favorite without requiring the closed server.
      await restored.cache!.updateFavorite(song.id, false);
      final reopened = PlaybackCache(
        Directory('${root.path}/playback-cache'),
        restored.session!,
      );
      await reopened.load();
      expect(reopened.tracks[song.id]!.favorite, isFalse);
      expect(reopened.downloads, contains(song.id));
      expect(reopened.contains(song), isTrue);
      restored.dispose();
    } finally {
      await server.close(force: true);
    }
  });

  test(
    'restart restores queue, current song and progress before connecting',
    () async {
      final identity = await prepare('http://127.0.0.1:1');
      final first = MusicController(supportDirectory: root);
      await first.initialize();
      await saveQueue(first);
      first.dispose();

      final engine = RecordingPlayer();
      final restored = PlaybackController(root, engine);
      await restored.initialize();
      expect(restored.current?.title, 'Offline Song');
      expect(restored.queue.map((track) => track.id), [
        'uncached-song',
        'local-song',
        'cloud-song',
      ]);
      expect(restored.position, const Duration(seconds: 37));
      expect(restored.duration, const Duration(seconds: 120));
      expect(restored.playing, false);
      expect(restored.volume, 0.35);
      expect(restored.shuffle && restored.repeat, true);
      expect(engine.opened, isEmpty);
      await restored.seek(42);
      await restored.toggle();
      expect(engine.opened.single.start, const Duration(seconds: 42));
      expect(
        engine.opened.single.uri,
        Media(restored.cache!.audio(restored.current!).uri.toString()).uri,
      );
      expect(restored.queue.length, 3);
      restored.enqueue(Track({'id': 'appended-song'}));
      await restored.savePlaybackState();
      final state =
          jsonDecode(await (await playbackState(identity)).readAsString())
              as Map;
      expect((state['queue'] as List).last['id'], 'appended-song');
      expect(jsonEncode(state), isNot(contains('token')));
      await restored.stopPlayback();
      restored.dispose();

      final stopped = MusicController(supportDirectory: root);
      await stopped.initialize();
      expect(stopped.current, isNull);
      expect(stopped.queue.length, 4);
      stopped.dispose();
    },
  );

  test('single repeat mode survives restart', () async {
    await prepare('http://127.0.0.1:1');
    final c = MusicController(supportDirectory: root);
    await c.initialize();
    c.cycleMode();
    c.cycleMode();
    await c.savePlaybackState();
    c.dispose();
    final restored = MusicController(supportDirectory: root);
    await restored.initialize();
    expect(restored.repeatOne, isTrue);
    expect(restored.modeTitle, '单曲循环');
    restored.dispose();
  });

  test('enqueue prepares paused playback without opening the engine', () async {
    await prepare('http://127.0.0.1:1');
    final engine = RecordingPlayer();
    final c = PlaybackController(root, engine);
    await c.initialize();
    final song = c.tracks.single;
    c.enqueue(song);
    c.enqueue(song);
    expect(c.queue.length, 1);
    expect(c.current?.id, song.id);
    expect(c.duration, const Duration(seconds: 120));
    expect(c.playing, false);
    expect(engine.opened, isEmpty);
    await c.toggle();
    expect(engine.opened.length, 1);
    c.position = const Duration(seconds: 19);
    c.playing = true;
    c.enqueue(Track({'id': 'next-song'}));
    expect(c.position, const Duration(seconds: 19));
    expect(c.current?.id, song.id);
    expect(c.playing, true);
    expect(engine.opened.length, 1);
    await c.savePlaybackState();
    c.dispose();
    final restored = MusicController(supportDirectory: root);
    await restored.initialize();
    expect(restored.queue.map((t) => t.id), [song.id, 'next-song']);
    expect(restored.current?.id, song.id);
    expect(restored.playing, false);
    restored.dispose();
  });

  test('offline bulk play uses the complete filtered local list', () async {
    await prepare('http://127.0.0.1:1');
    final engine = RecordingPlayer();
    final c = PlaybackController(root, engine);
    await c.initialize();
    await c.playAll(shuffled: true);
    expect(c.queue.map((t) => t.id), ['local-song']);
    expect(c.shuffle, true);
    expect(engine.opened.length, 1);
    await c.savePlaybackState();
    c.dispose();
  });

  test('expired credentials preserve the restored playback queue', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 401;
      await request.response.close();
    });
    try {
      final identity = await prepare('http://127.0.0.1:${server.port}');
      final first = MusicController(supportDirectory: root);
      await first.initialize();
      await saveQueue(first);
      first.dispose();
      FlutterSecureStorage.setMockInitialValues({
        'session': jsonEncode(
          Session(identity.server, identity.username, 'expired').toJson(),
        ),
      });
      final restored = MusicController(supportDirectory: root);
      await restored.initialize();
      expect(restored.authenticated, false);
      expect(restored.current?.id, 'local-song');
      expect(restored.queue.length, 3);
      expect(restored.position.inSeconds, 37);
      await restored.logout();
      restored.dispose();
      final loggedOut = MusicController(supportDirectory: root);
      await loggedOut.initialize();
      expect(loggedOut.current, isNull);
      expect(loggedOut.queue, isEmpty);
      loggedOut.dispose();
    } finally {
      await server.close(force: true);
    }
  });

  test('playback state is isolated by server and username', () async {
    await prepare('http://127.0.0.1:1');
    final first = MusicController(supportDirectory: root);
    await first.initialize();
    await saveQueue(first);
    first.dispose();
    for (final identity in [
      Session(serverAddress('http://127.0.0.1:2'), 'user', ''),
      Session(serverAddress('http://127.0.0.1:1'), 'other-user', ''),
    ]) {
      FlutterSecureStorage.setMockInitialValues({
        'identity': jsonEncode(identity.toJson()),
      });
      final other = MusicController(supportDirectory: root);
      await other.initialize();
      expect(other.current, isNull);
      expect(other.queue, isEmpty);
      other.dispose();
    }
  });

  test(
    'damaged playback state does not prevent cached library startup',
    () async {
      final identity = await prepare('http://127.0.0.1:1');
      await (await playbackState(identity)).writeAsString('{"queue": [');
      final c = MusicController(supportDirectory: root);
      await c.initialize();
      expect(c.current, isNull);
      expect(c.queue, isEmpty);
      expect(c.tracks.single.id, 'local-song');
      expect(c.error, isNull);
      c.enqueue(c.tracks.single);
      c.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await c.savePlaybackState();
      c.dispose();
      final restored = MusicController(supportDirectory: root);
      await restored.initialize();
      expect(restored.queue.single.id, 'local-song');
      restored.dispose();
    },
  );

  test(
    'tokenless account identity restores offline library and manual downloads',
    () async {
      await prepare('http://127.0.0.1:1');
      final c = MusicController(supportDirectory: root);
      await c.initialize();
      expect(c.offline, true);
      expect(c.authenticated, false);
      expect(c.tracks.single.title, 'Offline Song');
      c.navigate('缓存');
      await c.load();
      expect(c.total, 1);
      c.navigate('专辑');
      await c.load();
      expect(c.collections.single['tracks'], 1);
      final album = Map<String, dynamic>.from(c.collections.single);
      album['id'] = 'server-album-hash';
      c.openCollection(album);
      await c.load();
      expect(c.tracks.single.title, 'Offline Song');
      c.dispose();
    },
  );
  test(
    'cached library is visible while server credential validation is still pending',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final contacted = Completer<void>(), release = Completer<void>();
      server.listen((request) async {
        if (!contacted.isCompleted) contacted.complete();
        await release.future;
        request.response.statusCode = 401;
        await request.response.close();
      });
      final c = MusicController(supportDirectory: root);
      try {
        final identity = await prepare('http://127.0.0.1:${server.port}');
        final first = MusicController(supportDirectory: root);
        await first.initialize();
        await saveQueue(first);
        first.dispose();
        FlutterSecureStorage.setMockInitialValues({
          'session': jsonEncode(
            Session(identity.server, identity.username, 'pending').toJson(),
          ),
        });
        final initialized = c.initialize();
        await contacted.future;
        expect(c.tracks.single.title, 'Offline Song');
        expect(c.current?.id, 'local-song');
        expect(c.queue.length, 3);
        expect(c.position.inSeconds, 37);
        expect(c.playing, false);
        expect(c.loading, false);
        expect(c.offline, true);
        release.complete();
        await initialized;
      } finally {
        if (!release.isCompleted) release.complete();
        c.dispose();
        await server.close(force: true);
      }
    },
  );
  test(
    'expired token falls back to existing offline audio without a login gate',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 401;
        await request.response.close();
      });
      try {
        await prepare('http://127.0.0.1:${server.port}', token: 'expired');
        final c = MusicController(supportDirectory: root);
        await c.initialize();
        expect(c.authenticated, false);
        expect(c.offline, true);
        expect(c.tracks.single.title, 'Offline Song');
        expect(c.error, contains('登录已过期'));
        expect(await const FlutterSecureStorage().read(key: 'session'), null);
        final identity = jsonDecode(
          (await const FlutterSecureStorage().read(key: 'identity'))!,
        );
        expect(identity['token'], '');
        c.dispose();
      } finally {
        await server.close(force: true);
      }
    },
  );
}

class PlaybackController extends MusicController {
  final RecordingPlayer engine;
  PlaybackController(Directory root, this.engine)
    : super(supportDirectory: root);
  @override
  Player get player => engine;
}

class RecordingPlayer implements Player {
  final List<Media> opened = [];
  bool failOpen = false;
  int stops = 0;
  Future<void>? nextOpenGate;
  Completer<void>? openStarted;
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final gate = nextOpenGate;
    nextOpenGate = null;
    if (gate != null) {
      openStarted!.complete();
      await gate;
    }
    if (failOpen) throw StateError('decoder failed');
    opened.add(playable as Media);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
