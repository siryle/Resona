import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/android_audio.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/audio_output.dart';
import 'package:resona_client/controller.dart';

const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cacheDir;

  setUpAll(() {
    cacheDir = Directory.systemTemp.createTempSync('resona_audio_cache_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getTemporaryDirectory' ||
              call.method == 'getApplicationSupportDirectory' ||
              call.method == 'getApplicationDocumentsDirectory') {
            return cacheDir.path;
          }
          return null;
        });
  });

  tearDownAll(() async {
    await Future<void>.delayed(Duration.zero);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    try {
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    } catch (_) {
      /* Ignore locked cache handles during teardown on Windows. */
    }
  });

  test('music interruptions use paired pause events when ducked', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const service = MethodChannel('com.ryanheise.audio_service.client.methods');
    const handler = MethodChannel(
      'com.ryanheise.audio_service.handler.methods',
    );
    const audio = MethodChannel('com.ryanheise.audio_session');
    final supportDir = Directory.systemTemp.createTempSync('resona_audio_init_');
    Map<dynamic, dynamic>? configured;

    messenger.setMockMethodCallHandler(
      service,
      (_) async => <String, dynamic>{},
    );
    messenger.setMockMethodCallHandler(
      handler,
      (_) async => <String, dynamic>{},
    );
    messenger.setMockMethodCallHandler(audio, (call) async {
      if (call.method == 'setConfiguration') {
        configured = (call.arguments as List).single as Map;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(androidAudioChannel, (_) async => null);

    addTearDown(() async {
      await Future<void>.delayed(Duration.zero);
      messenger.setMockMethodCallHandler(service, null);
      messenger.setMockMethodCallHandler(handler, null);
      messenger.setMockMethodCallHandler(audio, null);
      messenger.setMockMethodCallHandler(androidAudioChannel, null);
      try {
        if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
      } catch (_) {
        /* Ignore transient temp cleanup errors on Windows. */
      }
    });

    final controller = MusicController(supportDirectory: supportDir);
    addTearDown(controller.dispose);
    await initializeAndroidAudio(controller);
    final cacheSubdir = Directory(
      '${cacheDir.path}${Platform.pathSeparator}libCachedImageData',
    );
    for (var i = 0; i < 50 && !cacheSubdir.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(configured?['androidWillPauseWhenDucked'], isTrue);
    final session = await AudioSession.instance;
    expect(session.configuration?.androidWillPauseWhenDucked, isTrue);
    expect(controller.activateAudio, isNotNull);
  });

  test('android audio channel tracks Bluetooth outputs, AVRCP actions, speed and disconnect pause', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final nativeCalls = <String>[];

    messenger.setMockMethodCallHandler(androidAudioChannel, (call) async {
      nativeCalls.add(call.method);
      if (call.method == 'getAudioOutputs') {
        return [
          {
            'id': '7',
            'name': 'Pixel Buds Pro',
            'type': 'bluetooth',
            'bluetooth': true,
          },
        ];
      }
      return null;
    });

    final tempDir = Directory.systemTemp.createTempSync('resona_android_audio_');
    addTearDown(() {
      messenger.setMockMethodCallHandler(androidAudioChannel, null);
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {
        /* Ignore transient temp cleanup errors on Windows. */
      }
    });

    final controller = MusicController(supportDirectory: tempDir);
    addTearDown(controller.dispose);
    await bindAndroidAudioChannel(controller);

    expect(
      controller.localOutputs.any(
        (o) => o.type == AudioOutputType.bluetooth && o.name == 'Pixel Buds Pro',
      ),
      isTrue,
    );

    await controller.onDlnaScanStart?.call();
    await controller.onDlnaScanEnd?.call();
    await controller.onOpenOutputSwitcher?.call();
    await controller.onOpenBluetoothSettings?.call();
    expect(
      nativeCalls,
      containsAll([
        'getAudioOutputs',
        'acquireMulticastLock',
        'releaseMulticastLock',
        'openOutputSwitcher',
        'openBluetoothSettings',
      ]),
    );

    final audioHandler = AndroidAudioHandler(controller);
    controller.current = Track({
      'id': 't1',
      'title': 'Bluetooth Track',
      'duration': 120.0,
    });
    controller.notifyListeners();
    expect(
      audioHandler.playbackState.value.systemActions,
      containsAll([
        MediaAction.playPause,
        MediaAction.fastForward,
        MediaAction.rewind,
      ]),
    );
    expect(audioHandler.playbackState.value.speed, 1.0);
    await audioHandler.setSpeed(1.5);
    expect(controller.playbackRate, 1.5);
    expect(audioHandler.playbackState.value.speed, 1.5);

    controller.playing = true;
    await messenger.handlePlatformMessage(
      androidAudioChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('outputsChanged', {
          'devices': <Object>[],
          'bluetoothDisconnected': true,
        }),
      ),
      (_) {},
    );
    expect(controller.playing, isFalse);
  });
}
