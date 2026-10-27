import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/controller.dart';

class BulkController extends MusicController {
  Track? selected;
  @override
  Future<void> play(
    Track track, {
    bool replaceQueue = true,
    Duration startPosition = Duration.zero,
  }) async {
    selected = track;
    current = track;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late BulkController c;
  late List<Map<String, dynamic>> songs;
  late List<Map<String, String>> queries;
  int failOffset = -1;
  bool emptyPage = false;
  Completer<void>? pageStarted;
  Completer<void>? releasePage;
  setUp(() async {
    HttpOverrides.global = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    songs = List.generate(250, (i) => {'id': 'song-$i', 'title': 'Song $i'});
    queries = [];
    failOffset = -1;
    emptyPage = false;
    pageStarted = null;
    releasePage = null;
    c = BulkController()
      ..api = ResonaAPI(
        Session(
          serverAddress('http://127.0.0.1:${server.port}'),
          'user',
          'secret',
        ),
      )
      ..offline = false
      ..library = 'cloud'
      ..section = '喜欢'
      ..search = 'Song'
      ..album = 'album-id'
      ..artist = 'Artist'
      ..tracks = songs.take(100).map(Track.new).toList()
      ..total = 250;
    server.listen((request) async {
      expect(request.uri.path, '/api/v1/tracks');
      queries.add(request.uri.queryParameters);
      final offset = int.parse(request.uri.queryParameters['offset']!);
      if (offset == 100 && pageStarted != null) {
        pageStarted!.complete();
        await releasePage!.future;
      }
      if (offset == failOffset && !emptyPage) {
        request.response.statusCode = 500;
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'items': offset == failOffset
                ? []
                : songs.skip(offset).take(100).toList(),
            'total': songs.length,
          }),
        );
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    c.dispose();
    await server.close(force: true);
  });

  test(
    'bulk play fetches all matching pages and leaves the view paginated',
    () async {
      await c.playAll();
      expect(c.queue.length, 250);
      expect(c.queue.map((t) => t.id).toSet().length, 250);
      expect(c.selected?.id, 'song-0');
      expect(c.shuffle, false);
      expect(c.tracks.length, 100);
      expect(queries.map((q) => q['offset']), ['0', '100', '200']);
      for (final query in queries) {
        expect(query, containsPair('library', 'cloud'));
        expect(query, containsPair('search', 'Song'));
        expect(query, containsPair('favorite', 'true'));
        expect(query, containsPair('album', 'album-id'));
        expect(query, containsPair('artist', 'Artist'));
      }
      await c.playAll(shuffled: true);
      expect(c.queue.length, 250);
      expect(c.shuffle, true);
      expect(c.queue.map((t) => t.id), contains(c.selected!.id));
    },
  );

  for (final empty in [false, true]) {
    test(
      'failed or incomplete page preserves the existing session ($empty)',
      () async {
        final previous = Track({'id': 'previous'});
        c.queue = [previous];
        c.current = previous;
        failOffset = 100;
        emptyPage = empty;
        await c.playAll(shuffled: true);
        expect(c.queue.single.id, previous.id);
        expect(c.current?.id, previous.id);
        expect(c.shuffle, false);
        expect(c.selected, isNull);
        expect(c.error, isNotNull);
        expect(c.queueLoading, false);
      },
    );
  }

  test(
    'navigation cancels a delayed bulk load without replacing playback',
    () async {
      pageStarted = Completer<void>();
      releasePage = Completer<void>();
      final pending = c.playAll();
      await pageStarted!.future;
      expect(c.queueLoading, true);
      await c.playAll();
      c.navigate('设置');
      releasePage!.complete();
      await pending;
      expect(c.queue, isEmpty);
      expect(c.selected, isNull);
      expect(c.queueLoading, false);
      expect(queries.length, 2);
    },
  );
}
