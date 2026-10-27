import 'package:flutter/material.dart';
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
              theme: ThemeData(useMaterial3: true, platform: platform),
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
      );
    }
  }
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
