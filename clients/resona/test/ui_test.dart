import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:resona_client/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/main.dart';
import 'package:resona_client/controller.dart';

void main() {
  test(
    'LRC accepts multiple timestamps, millisecond offsets and plain text',
    () {
      final lines = parseLyrics(
        '[offset:-100]\n[00:01.50][00:03.123]Hello\n[00:02]World',
      );
      expect(lines.map((line) => line.seconds), [1.4, 1.9, 3.023]);
      expect(lines.map((line) => line.text), ['Hello', 'World', 'Hello']);
      expect(parseLyrics('Plain lyrics').single.seconds, null);
    },
  );
  for (final width in [390.0, 800.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('adaptive navigation $width $brightness with large text', (
        tester,
      ) async {
        tester
            .view
            .physicalSize; // Set logical bounds independently of host scaling.
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 1000),
                textScaler: const TextScaler.linear(1.3),
              ),
              child: AdaptiveShell(
                index: 0,
                onDestination: selected.add,
                child: const Center(child: Text('音乐库')),
              ),
            ),
          ),
        );
        expect(
          find.byType(NavigationBar),
          width < 720 ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(NavigationRail),
          width >= 720 ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text('设置'));
        expect(selected, [4]);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final width in [390.0, 800.0, 1280.0]) {
      if (platform == TargetPlatform.windows && width < 800) continue;
      testWidgets(
        'music workspace $platform $width with cached songs and 1.3x text',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = MusicController();
          c.tracks = [
            Track({
              'id': 'cached',
              'title': 'A long song title for adaptive music rows',
              'artist': 'Artist',
              'album': 'Album',
            }),
          ];
          c.total = 1;
          c.current = c.tracks.first;
          addTearDown(c.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: ResonaApp(controller: c).theme(Brightness.light),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1000),
                  textScaler: const TextScaler.linear(1.3),
                ),
                child: MusicPage(controller: c),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text('A long song title for adaptive music rows'),
            findsWidgets,
          );
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
  test('Windows typography uses an explicit CJK family in both themes', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final c = MusicController();
    addTearDown(c.dispose);
    final app = ResonaApp(controller: c);
    for (final brightness in Brightness.values) {
      final theme = app.theme(brightness);
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Microsoft YaHei UI');
      expect(
        theme.textTheme.bodyMedium!.fontFamilyFallback,
        contains('Microsoft YaHei'),
      );
      expect(theme.textTheme.bodyMedium!.fontSize, 15);
      expect(theme.textTheme.bodyMedium!.height, 1.5);
      expect(theme.textTheme.titleSmall!.fontWeight, FontWeight.w500);
      final foreground = theme.colorScheme.onSurfaceVariant.computeLuminance();
      final background = theme.colorScheme.surface.computeLuminance();
      final ratio = foreground > background
          ? (foreground + 0.05) / (background + 0.05)
          : (background + 0.05) / (foreground + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5));
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(
      app.theme(Brightness.light).textTheme.bodyMedium!.fontFamily,
      isNot('Microsoft YaHei UI'),
    );
  });

  for (final width in [800.0, 1280.0, 1920.0]) {
    testWidgets('settings scrollbar stays at the workspace edge at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = MusicController()..section = '设置';
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ResonaApp(controller: c).theme(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 720),
              textScaler: const TextScaler.linear(1.3),
            ),
            child: MusicPage(controller: c),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(ListView);
      expect(tester.getRect(list).right, closeTo(width, 0.1));
      final scrollbar = find.byType(Scrollbar);
      expect(scrollbar, findsOneWidget);
      expect(tester.getRect(scrollbar).right, closeTo(width, 0.1));
      final panel = find
          .ancestor(of: find.text('服务器'), matching: find.byType(Column))
          .first;
      expect(tester.getSize(panel).width, lessThanOrEqualTo(732));
      await tester.drag(list, const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(find.text('开源许可').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({TargetPlatform.windows}));
  }

  testWidgets('Android enqueue exposes the paused mini player', (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = MusicController();
    c.tracks = [
      Track({'id': 'queued', 'title': 'Queued Song', 'duration': 120}),
    ];
    c.total = 1;
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
        home: AnimatedBuilder(
          animation: c,
          builder: (_, _) => MusicPage(controller: c),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayer), findsNothing);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入播放列表'));
    await tester.pumpAndSettle();
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(c.current?.id, 'queued');
    expect(c.queue.length, 1);
    expect(c.playing, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login validates address and never submits an empty password', (
    tester,
  ) async {
    final controller = MusicController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(ResonaApp(controller: controller));
    expect(find.text('音乐，井然有声。'), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('连接服务器'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, '连接服务器'));
    await tester.tap(find.widgetWithText(FilledButton, '连接服务器'));
    await tester.pumpAndSettle();
    expect(find.text('请输入完整的 HTTP / HTTPS 地址'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    expect(controller.session, isNull);
    expect(tester.takeException(), isNull);
  });
}
