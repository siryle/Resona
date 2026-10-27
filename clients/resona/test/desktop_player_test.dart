import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/main.dart';

Track song(String id) => Track({
  'id': id,
  'title': 'Song $id',
  'artist': 'Artist',
  'album': 'Album',
  'format': 'flac',
  'sample_rate': 44100,
  'duration': 180,
});

Future<MusicController> workspace(
  WidgetTester tester,
  Size size,
  Brightness brightness,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = MusicController()
    ..tracks = [song('one'), song('two')]
    ..current = song('one')
    ..total = 2
    ..lyricText = '[00:01]First line\n[00:02]Second line';
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ResonaApp(controller: c).theme(brightness),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
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
  return c;
}

Future<void> expand(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(DesktopPlayer),
      matching: find.text('Song one'),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(640, 600),
    const Size(720, 600),
    const Size(800, 600),
    const Size(1280, 720),
    const Size(1920, 1080),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'Windows playback stays in the workspace at $size $brightness',
        (tester) async {
          final c = await workspace(tester, size, brightness);
          final barriers = find.byType(ModalBarrier).evaluate().length;
          await expand(tester);
          expect(find.byType(DesktopListening), findsOneWidget);
          expect(find.text('正在播放'), findsOneWidget);
          expect(find.text('FLAC · 44.1 kHz'), findsOneWidget);
          expect(find.byType(DesktopPlayer), findsOneWidget);
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.byType(ModalBarrier), findsNWidgets(barriers));
          final artwork = tester.getCenter(find.bySemanticsLabel('Album 专辑封面'));
          final lyrics = tester.getCenter(find.byType(LyricView));
          if (size.width >= 1100) {
            expect(artwork.dx, lessThan(lyrics.dx));
          } else {
            expect(artwork.dy, lessThan(lyrics.dy));
          }
          c.current = song('two');
          c.notifyListeners();
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(DesktopListening),
              matching: find.text('Song two'),
            ),
            findsOneWidget,
          );
          c.current = null;
          c.notifyListeners();
          await tester.pumpAndSettle();
          expect(find.byType(DesktopListening), findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({TargetPlatform.windows}),
      );
    }
  }

  testWidgets(
    'collapse, Escape, settings and navigation close Windows details',
    (tester) async {
      await workspace(tester, const Size(1280, 900), Brightness.light);
      await expand(tester);
      await tester.tap(find.byTooltip('收起播放页').first);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopListening), findsNothing);
      await expand(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DesktopListening), findsNothing);
      await expand(tester);
      await tester.tap(find.byTooltip('设置与服务器登录'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopListening), findsNothing);
      expect(find.text('服务器'), findsOneWidget);
      await expand(tester);
      expect(find.byType(DesktopListening), findsOneWidget);
      await tester.tap(find.text('专辑'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopListening), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('desktop lyrics follow playback, wrap long lines and seek', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final seeks = <double>[];
    final text = List.generate(
      40,
      (i) =>
          '[00:${i.toString().padLeft(2, '0')}]Line $i with a long lyric that wraps onto multiple lines',
    ).join('\n');
    Future<void> render(String lyrics, int second) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Scaffold(
              body: LyricView(
                text: lyrics,
                position: Duration(seconds: second),
                seek: seeks.add,
                desktop: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await render(text, 0);
    await render(text, 35);
    final active = find.text(
      'Line 35 with a long lyric that wraps onto multiple lines',
    );
    final center = tester.getCenter(active);
    expect(center.dy, inInclusiveRange(150.0, 350.0));
    await tester.tap(active);
    expect(seeks, [35.0]);
    await render('[00:01]Replacement line', 1);
    expect(find.text('Replacement line').hitTestable(), findsOneWidget);
    await render('Untimed lyrics', 0);
    await tester.tap(find.text('Untimed lyrics'));
    expect(seeks, [35.0]);
    await render('', 0);
    expect(find.textContaining('暂无歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
