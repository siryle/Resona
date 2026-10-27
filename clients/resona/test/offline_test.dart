import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
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
        await prepare('http://127.0.0.1:${server.port}', token: 'pending');
        final initialized = c.initialize();
        await contacted.future;
        expect(c.tracks.single.title, 'Offline Song');
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
