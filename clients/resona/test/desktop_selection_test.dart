import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/main.dart';

Track song(String id, {String? title, bool favorite = false}) => Track({
  'id': id,
  'title': title ?? 'Song $id',
  'artist': 'Artist',
  'album': 'Album',
  'format': 'mp3',
  'bitrate': 320000,
  'duration': 330,
  'favorite': favorite,
});

class SelectionController extends MusicController {
  List<Track> nextPage = [];
  Completer<void>? pageReady;
  bool incompletePage = false;
  Track? played;
  int toggles = 0;

  @override
  Future<void> toggle() async {
    toggles++;
  }

  @override
  Future<void> load({bool more = false}) async {
    if (!more) {
      notifyListeners();
      return;
    }
    loading = true;
    notifyListeners();
    await pageReady?.future;
    if (!incompletePage) tracks = [...tracks, ...nextPage];
    nextPage = [];
    loading = false;
    notifyListeners();
  }

  @override
  Future<void> play(
    Track track, {
    bool replaceQueue = true,
    Duration startPosition = Duration.zero,
    List<Track>? fromTracks,
  }) async {
    played = track;
    if (replaceQueue) queue = List.of(fromTracks ?? tracks);
  }
}

Future<SelectionController> workspace(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
  Brightness brightness = Brightness.light,
  String section = '歌曲',
  String album = '',
  String artist = '',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = SelectionController()
    ..tracks = [song('one'), song('two', favorite: true)]
    ..section = section
    ..album = album
    ..artist = artist
    ..total = 2
    ..current = song('playing');
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

Finder get searchField => find.widgetWithText(TextField, '搜索歌曲 / 专辑 / 歌手');
Finder get actions => find.byKey(const ValueKey('track-selection-actions'));
Finder row(String id) => find.byKey(ValueKey('desktop-track-$id'));

void main() {
  for (final section in ['歌曲', '专辑', '艺术家', '喜欢', '缓存']) {
    testWidgets('$section uses the same compact desktop song row', (
      tester,
    ) async {
      await workspace(
        tester,
        section: section,
        album: section == '专辑' ? 'album-id' : '',
        artist: section == '艺术家' ? 'Artist' : '',
      );
      expect(searchField, findsOneWidget);
      expect(find.text('MP3 320K'), findsNWidgets(2));
      expect(
        find.descendant(of: row('one'), matching: find.text('Artist · Album')),
        findsOneWidget,
      );
      final covers = find.descendant(
        of: row('one'),
        matching: find.byType(Cover),
      );
      expect(tester.getSize(covers), const Size(44, 44));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({TargetPlatform.windows}));
  }

  for (final size in [
    const Size(640, 600),
    const Size(800, 720),
    const Size(1440, 960),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'selection replaces playback at $size $brightness with scaled text',
        (tester) async {
          final c = await workspace(tester, size: size, brightness: brightness);
          final footer = tester.getRect(find.byType(DesktopPlayer));
          final rowTop = tester.getTopLeft(row('one'));
          expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
          await tester.tap(find.byTooltip('选歌'));
          await tester.pumpAndSettle();
          expect(tester.getRect(actions), footer);
          expect(tester.getTopLeft(row('one')), rowTop);
          expect(find.byType(DesktopPlayer).hitTestable(), findsNothing);
          expect(find.byTooltip('播放').hitTestable(), findsNothing);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          expect(c.toggles, 0);
          await tester.tap(row('one'));
          await tester.pumpAndSettle();
          expect(find.text('已选 1 首'), findsNWidgets(2));
          expect(c.played, isNull);
          expect(find.byTooltip('下载与播放操作'), findsNothing);
          await tester.tap(find.text('完成'));
          await tester.pumpAndSettle();
          expect(actions, findsNothing);
          expect(tester.getRect(find.byType(DesktopPlayer)), footer);
          expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
          expect(tester.getTopLeft(row('one')), rowTop);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({TargetPlatform.windows}),
      );
    }
  }

  testWidgets(
    'filtered selections survive searches and enqueue once in collection order',
    (tester) async {
      final c = await workspace(tester);
      await tester.tap(find.byTooltip('选歌'));
      await tester.pumpAndSettle();
      await tester.tap(row('one'));
      await tester.enterText(searchField, 'two');
      await tester.pumpAndSettle();
      expect(row('one'), findsNothing);
      expect(find.text('已选 1 首'), findsNWidgets(2));
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 首'), findsNWidgets(2));
      c.queue = [c.tracks.first];
      await tester.tap(find.byTooltip('加入播放列表'));
      await tester.pumpAndSettle();
      expect(c.queue.map((track) => track.id), ['one', 'two']);
      expect(actions, findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'filter popover changes results and resets without dropping selection',
    (tester) async {
      await workspace(tester);
      await tester.tap(find.byTooltip('选歌'));
      await tester.pumpAndSettle();
      await tester.tap(row('one'));
      await tester.tap(find.byTooltip('筛选歌曲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仅我喜欢的'));
      await tester.pumpAndSettle();
      expect(row('one'), findsNothing);
      expect(row('two'), findsOneWidget);
      await tester.tap(find.text('重置筛选'));
      await tester.pumpAndSettle();
      expect(row('one'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 首'), findsNWidgets(2));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(actions, findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('search and select all include songs beyond the first page', (
    tester,
  ) async {
    final c = await workspace(tester);
    c.nextPage = [song('three', title: 'Later page')];
    c.total = 3;
    await tester.enterText(searchField, 'Later');
    await tester.pumpAndSettle();
    expect(row('three'), findsOneWidget);
    expect(c.tracks.length, 3);
    await tester.tap(find.byTooltip('选歌'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 首'), findsNWidgets(2));
    await tester.tap(find.byTooltip('清除歌曲搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 首'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('filtered playback excludes hidden songs', (tester) async {
    final c = await workspace(tester);
    await tester.enterText(searchField, 'two');
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部播放'));
    await tester.pumpAndSettle();
    expect(c.queue.map((track) => track.id), ['two']);
    expect(c.played?.id, 'two');
    await tester.tap(row('two'));
    await tester.pumpAndSettle();
    expect(c.queue.map((track) => track.id), ['two']);
    expect(c.played?.id, 'two');
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('library changes cancel selection and delayed selection work', (
    tester,
  ) async {
    final c = await workspace(tester);
    c.nextPage = [song('three')];
    c.total = 3;
    c.pageReady = Completer<void>();
    await tester.tap(find.byTooltip('选歌'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(c.loading, isTrue);
    c.library = 'cloud';
    c.notifyListeners();
    await tester.pump();
    c.pageReady!.complete();
    await tester.pumpAndSettle();
    expect(actions, findsNothing);
    await tester.tap(find.byTooltip('选歌'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 首'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'incomplete pages report an error instead of selecting a partial collection',
    (tester) async {
      final c = await workspace(tester);
      c.total = 3;
      c.incompletePage = true;
      await tester.tap(find.byTooltip('选歌'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(c.error, '歌曲列表不完整，请刷新后重试。');
      expect(find.text('已选 0 首'), findsNWidgets(2));
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
}
