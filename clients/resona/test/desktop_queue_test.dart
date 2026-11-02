import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/main.dart';

class QueueController extends MusicController {
  bool? replacedQueue;
  @override
  Future<void> play(
    Track track, {
    bool replaceQueue = true,
    Duration startPosition = Duration.zero,
    List<Track>? fromTracks,
  }) async {
    replacedQueue = replaceQueue;
    current = track;
    notifyListeners();
  }
}

void main() {
  for (final width in [640.0, 920.0, 1280.0, 1920.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'Windows queue stays bounded, locates current song and preserves controls at $width $brightness',
        (tester) async {
          tester.view.physicalSize = Size(width, 720);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = QueueController();
          c.queue = List.generate(
            100,
            (i) => Track({
              'id': '$i',
              'title': 'Queue song $i',
              'artist': 'Artist $i',
              'album': 'Album',
              'format': 'flac',
              'bitrate': 850000,
              'duration': 259,
            }),
          );
          c.current = c.queue[95];
          c.tracks = List.of(c.queue);
          c.total = c.tracks.length;
          addTearDown(c.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: ResonaApp(controller: c).theme(brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 720),
                  textScaler: const TextScaler.linear(1.3),
                ),
                child: AnimatedBuilder(
                  animation: c,
                  builder: (_, _) => MusicPage(controller: c),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final barriers = find.byType(ModalBarrier).evaluate().length;
          await tester.tap(find.byTooltip('播放列表'));
          await tester.pumpAndSettle();
          expect(find.byType(DesktopQueue), findsOneWidget);
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.byType(ModalBarrier), findsNWidgets(barriers));
          final queue = find.byType(DesktopQueue);
          final active = find.descendant(
            of: queue,
            matching: find.text('Queue song 95'),
          );
          expect(active.hitTestable(), findsOneWidget);
          final footer = tester.getRect(find.byType(DesktopPlayer));
          expect(tester.getRect(queue).bottom, lessThanOrEqualTo(footer.top));
          await tester.tap(
            find.descendant(of: queue, matching: find.text('Queue song 96')),
          );
          await tester.pumpAndSettle();
          expect(c.current?.id, '96');
          expect(c.replacedQueue, isFalse);
          expect(c.queue, hasLength(100));
          expect(find.byType(DesktopQueue), findsOneWidget);
          await tester.tap(find.byTooltip('关闭播放列表'));
          await tester.pumpAndSettle();
          expect(find.byType(DesktopQueue), findsNothing);
          await tester.tap(find.byTooltip('播放列表'));
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(DesktopQueue), findsNothing);
          await tester.tap(find.byTooltip('播放列表'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('专辑').first);
          await tester.pumpAndSettle();
          expect(find.byType(DesktopQueue), findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({TargetPlatform.windows}),
      );
    }
  }

  testWidgets(
    'Windows empty queue has an explicit state and toggle closes it',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = MusicController();
      addTearDown(c.dispose);
      await tester.pumpWidget(ResonaApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放列表'));
      await tester.pumpAndSettle();
      expect(find.text('播放列表为空'), findsOneWidget);
      c.queue = List.generate(
        100,
        (i) => Track({'id': '$i', 'title': 'Restored song $i'}),
      );
      c.current = c.queue.last;
      c.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find
            .descendant(
              of: find.byType(DesktopQueue),
              matching: find.text('Restored song 99'),
            )
            .hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('播放列表'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopQueue), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
