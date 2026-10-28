import 'dart:ui' show PointerDeviceKind;

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

class SeekController extends MusicController {
  @override
  Future<void> seek(double seconds) async {
    position = Duration(
      milliseconds: (seconds * 1000).round().clamp(0, duration.inMilliseconds),
    );
    notifyListeners();
  }

  @override
  Future<void> toggle() async {
    playing = !playing;
    notifyListeners();
  }
}

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
  testWidgets(
    'Windows progress responds to pointer and five-second keyboard seeking',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = SeekController()
        ..current = song('seek')
        ..duration = const Duration(seconds: 100);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedBuilder(
                animation: c,
                builder: (_, _) =>
                    DesktopPlayer(controller: c, onExpand: () {}),
              ),
            ),
          ),
        ),
      );
      final seek = find.byKey(const ValueKey('desktop-progress'));
      await tester.tapAt(tester.getRect(seek).center);
      await tester.pumpAndSettle();
      expect(c.position.inSeconds, closeTo(50, 2));
      final before = c.position;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(c.position, before + const Duration(seconds: 5));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(c.position, before);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(c.playing, isTrue);
      await tester.drag(seek, const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(c.position, greaterThan(before));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

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

  testWidgets('Windows footer cycles all four macOS playback modes', (
    tester,
  ) async {
    final c = await workspace(tester, const Size(1280, 720), Brightness.light);
    await expand(tester);
    await tester.tap(find.byTooltip('顺序播放'));
    await tester.pumpAndSettle();
    expect(c.repeat, isTrue);
    expect(c.shuffle, isFalse);
    await tester.tap(find.byTooltip('列表循环'));
    await tester.pumpAndSettle();
    expect(c.repeat, isFalse);
    expect(c.repeatOne, isTrue);
    expect(c.shuffle, isFalse);
    await tester.tap(find.byTooltip('单曲循环'));
    await tester.pumpAndSettle();
    expect(c.repeatOne, isFalse);
    expect(c.shuffle, isTrue);
    await tester.tap(find.byTooltip('随机循环'));
    await tester.pumpAndSettle();
    expect(c.repeat, isFalse);
    expect(c.shuffle, isFalse);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Windows footer shows lyrics until hovered, focused or paused', (
    tester,
  ) async {
    final c = await workspace(tester, const Size(1280, 720), Brightness.light);
    c.playing = true;
    c.position = const Duration(milliseconds: 1500);
    c.notifyListeners();
    await tester.pumpAndSettle();
    final bar = find.byType(DesktopPlayer);
    Finder text(String value) =>
        find.descendant(of: bar, matching: find.text(value));
    expect(text('First line'), findsOneWidget);
    expect(text('Second line'), findsOneWidget);
    expect(text('Song one'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(bar));
    await tester.pumpAndSettle();
    expect(text('Song one'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(text('First line'), findsOneWidget);
    final play = find.descendant(of: bar, matching: find.byTooltip('暂停'));
    Focus.of(tester.element(play)).requestFocus();
    await tester.pumpAndSettle();
    expect(text('Song one'), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    c.playing = false;
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(text('Song one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

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
