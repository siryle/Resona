import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/android_audio.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/dlna.dart';
import 'package:resona_client/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MusicController normalizes, steps and persists playback speed', () async {
    expect(MusicController.playbackRates, hasLength(16));
    expect(MusicController.playbackRates.first, 0.5);
    expect(MusicController.playbackRates.last, 2.0);
    expect(MusicController.normalizePlaybackRate(double.nan), 1.0);
    expect(MusicController.normalizePlaybackRate(0.1), 0.5);
    expect(MusicController.normalizePlaybackRate(3.0), 2.0);
    expect(MusicController.normalizePlaybackRate(0.1 + 0.2), 0.5);
    expect(MusicController.normalizePlaybackRate(1.1 + 0.2), 1.3);

    final dir = Directory.systemTemp.createTempSync('resona_speed_test_');
    addTearDown(() {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        /* Temp cleanup is best-effort. */
      }
    });

    final c = MusicController(supportDirectory: dir);
    addTearDown(c.dispose);
    expect(c.playbackRate, 1.0);
    expect(c.playbackRateLabel, '1.0x');
    expect(c.compactPlaybackRateLabel, '1x');
    expect(MusicController.formatCompactPlaybackRate(0.5), '0.5x');
    expect(MusicController.formatCompactPlaybackRate(1.2), '1.2x');
    expect(MusicController.formatCompactPlaybackRate(2.0), '2x');

    await c.stepPlaybackRate(2);
    expect(c.playbackRate, 1.2);
    expect(c.playbackRateLabel, '1.2x');

    await c.stepPlaybackRate(100);
    expect(c.playbackRate, 2.0);

    await c.stepPlaybackRate(-100);
    expect(c.playbackRate, 0.5);

    final handler = AndroidAudioHandler(c);
    c.current = Track({'id': 's1', 'title': 'Speed Song', 'duration': 90});
    c.notifyListeners();
    expect(handler.playbackState.value.speed, 0.5);

    await handler.setSpeed(1.6);
    expect(c.playbackRate, 1.6);
    expect(handler.playbackState.value.speed, 1.6);

    c.activeDlnaDevice = const DlnaDevice(
      udn: 'uuid:test',
      name: 'TV',
      location: 'http://192.168.1.50/desc.xml',
      avTransportControlUrl: 'http://192.168.1.50/avt',
    );
    c.notifyListeners();
    expect(handler.playbackState.value.speed, 1.0);
    c.activeDlnaDevice = null;

    final stateFile = File('${dir.path}/playback.json');
    await stateFile.writeAsString(
      jsonEncode({
        'current': c.current!.json,
        'queue': [c.current!.json],
        'position': 0,
        'volume': 0.8,
        'shuffle': false,
        'repeat': false,
        'repeat_one': false,
        'playback_rate': 1.7,
      }),
    );
    final decoded = jsonDecode(await stateFile.readAsString()) as Map;
    expect(
      MusicController.normalizePlaybackRate((decoded['playback_rate'] as num).toDouble()),
      1.7,
    );
  });

  testWidgets('DesktopPlayer renders speed button and updates rate via sheet without overflow', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('resona_speed_ui_');
    addTearDown(() {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        /* Temp cleanup is best-effort. */
      }
    });

    for (final size in const [Size(1280, 720), Size(640, 600)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = MusicController(supportDirectory: dir)
        ..current = Track({
          'id': 's1',
          'title': 'Song One',
          'artist': 'Artist',
          'duration': 180,
        });
      addTearDown(c.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ResonaApp(controller: c).theme(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedBuilder(
                  animation: c,
                  builder: (_, _) => DesktopPlayer(controller: c, onExpand: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('倍速播放 · 1.0x'), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (size.width >= 1200) {
        await tester.tap(find.byTooltip('倍速播放 · 1.0x'));
        await tester.pumpAndSettle();
        expect(find.text('重置 1.0x'), findsOneWidget);
        expect(find.byType(Slider), findsOneWidget);
        expect(find.byType(PlaybackSpeedRuler), findsNothing);

        await tester.tap(find.text('1.5x'));
        await tester.pumpAndSettle();
        expect(c.playbackRate, 1.5);
        expect(find.byTooltip('倍速播放 · 1.5x'), findsOneWidget);

        await tester.tap(find.text('+0.1x'));
        await tester.pumpAndSettle();
        expect(c.playbackRate, 1.6);

        await tester.tap(find.text('-0.1x'));
        await tester.pumpAndSettle();
        expect(c.playbackRate, 1.5);

        await tester.tap(find.text('重置 1.0x'));
        await tester.pumpAndSettle();
        expect(c.playbackRate, 1.0);
        expect(tester.takeException(), isNull);
      }
    }
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets('Mobile speed sheet shows floating tick-ruler slider and dismisses on barrier tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = Directory.systemTemp.createTempSync('resona_mobile_speed_');
    addTearDown(() {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        /* Temp cleanup is best-effort. */
      }
    });

    final c = MusicController(supportDirectory: dir)
      ..current = Track({
        'id': 's1',
        'title': 'Mobile Song',
        'artist': 'Artist',
        'duration': 180,
      });
    addTearDown(c.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ResonaApp(controller: c).theme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showPlaybackSpeedSheet(context, c),
                child: const Text('打开倍速'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开倍速'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackSpeedRuler), findsOneWidget);
    expect(find.text('倍速播放'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(c.playbackRate, 1.5);

    final rulerPaint = find.descendant(
      of: find.byType(PlaybackSpeedRuler),
      matching: find.byType(CustomPaint),
    );
    await tester.drag(rulerPaint, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(c.playbackRate, 2.0);

    await tester.drag(rulerPaint, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(c.playbackRate, 0.5);

    await tester.tap(find.text('1x'));
    await tester.pumpAndSettle();
    expect(c.playbackRate, 1.0);

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackSpeedRuler), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.android}));
}
