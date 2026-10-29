import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/cache.dart';
import 'package:resona_client/controller.dart';

Track song(String id, {bool favorite = false}) =>
    Track({'id': id, 'favorite': favorite});

class BatchController extends MusicController {
  final favorites = <String>[], downloads = <String>[];
  String? failID;
  VoidCallback? afterFirst;
  Completer<void>? releaseFirst;

  Future<void> checkpoint(Track track) async {
    if (track.id == failID) error = 'Action failed';
    if (batchCompleted == 0) {
      afterFirst?.call();
      await releaseFirst?.future;
    }
  }

  @override
  Future<void> favorite(Track track) async {
    favorites.add(track.id);
    await checkpoint(track);
    if (error == null) {
      tracks = tracks
          .map(
            (item) =>
                item.id == track.id ? song(item.id, favorite: true) : item,
          )
          .toList();
    }
  }

  @override
  Future<void> download(Track track) async {
    downloads.add(track.id);
    await checkpoint(track);
    if (error == null) cache?.downloads.add(track.id);
  }
}

typedef VoidCallback = void Function();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BatchController c;
  setUp(() {
    final session = Session(
      serverAddress('https://example.invalid'),
      'user',
      'token',
    );
    c = BatchController()
      ..api = ResonaAPI(session)
      ..cache = PlaybackCache(Directory.systemTemp, session)
      ..offline = false
      ..tracks = [song('one'), song('two', favorite: true), song('three')];
  });
  tearDown(() => c.dispose());

  test('batch favorite skips existing favorites and repeated runs', () async {
    expect(
      await c.runTrackBatch(TrackBatchAction.favorite, List.of(c.tracks)),
      isTrue,
    );
    expect(c.favorites, ['one', 'three']);
    expect(c.batchCompleted, 3);
    expect(
      await c.runTrackBatch(TrackBatchAction.favorite, List.of(c.tracks)),
      isTrue,
    );
    expect(c.favorites, ['one', 'three']);
  });

  test(
    'batch download skips pinned songs and stops at the first failure',
    () async {
      c.cache!.downloads.add('one');
      c.failID = 'two';
      expect(
        await c.runTrackBatch(TrackBatchAction.download, List.of(c.tracks)),
        isFalse,
      );
      expect(c.downloads, ['two']);
      expect(c.batchCompleted, 1);
      expect(c.batchBusy, isFalse);
      expect(c.error, 'Action failed');
    },
  );

  for (final action in TrackBatchAction.values) {
    test('$action stops after an account change', () async {
      final oldAPI = c.api!;
      c.afterFirst = () {
        c.api = ResonaAPI(
          Session(serverAddress('https://other.invalid'), 'other', 'token'),
        );
      };
      expect(await c.runTrackBatch(action, List.of(c.tracks)), isFalse);
      expect([...c.favorites, ...c.downloads], ['one']);
      expect(c.batchBusy, isFalse);
      oldAPI.close();
    });
  }

  test(
    'duplicate batches are rejected and offline actions send no work',
    () async {
      c.releaseFirst = Completer<void>();
      final pending = c.runTrackBatch(
        TrackBatchAction.favorite,
        List.of(c.tracks),
      );
      expect(c.batchBusy, isTrue);
      expect(
        await c.runTrackBatch(TrackBatchAction.download, c.tracks),
        isFalse,
      );
      c.releaseFirst!.complete();
      expect(await pending, isTrue);
      c.offline = true;
      expect(
        await c.runTrackBatch(TrackBatchAction.download, c.tracks),
        isFalse,
      );
      expect(c.downloads, isEmpty);
    },
  );

  test(
    'enqueue all keeps order, deduplicates and restores a paused player',
    () {
      c.enqueueAll([c.tracks.first, c.tracks.first, c.tracks.last]);
      expect(c.queue.map((track) => track.id), ['one', 'three']);
      expect(c.current?.id, 'one');
      expect(c.playing, isFalse);
    },
  );
}
