import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/android_audio.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/audio_output.dart';
import 'package:resona_client/controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('music interruptions use paired pause events when ducked', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const service = MethodChannel('com.ryanheise.audio_service.client.methods');
    const handler = MethodChannel(
      'com.ryanheise.audio_service.handler.methods',
    );
    const audio = MethodChannel('com.ryanheise.audio_session');
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
    addTearDown(() {
      messenger.setMockMethodCallHandler(service, null);
      messenger.setMockMethodCallHandler(handler, null);
      messenger.setMockMethodCallHandler(audio, null);
    });
    final controller = MusicController();
    addTearDown(controller.dispose);
    await initializeAndroidAudio(controller);
    expect(configured?['androidWillPauseWhenDucked'], isTrue);
    final session = await AudioSession.instance;
    expect(session.configuration?.androidWillPauseWhenDucked, isTrue);
    expect(controller.activateAudio, isNotNull);
  });

  test('android audio channel tracks Bluetooth outputs, AVRCP actions and disconnect pause', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const service = MethodChannel('com.ryanheise.audio_service.client.methods');
    const handler = MethodChannel(
      'com.ryanheise.audio_service.handler.methods',
    );
    const audio = MethodChannel('com.ryanheise.audio_session');
    final nativeCalls = <String>[];

    messenger.setMockMethodCallHandler(
      service,
      (_) async => <String, dynamic>{},
    );
    messenger.setMockMethodCallHandler(
      handler,
      (_) async => <String, dynamic>{},
    );
    messenger.setMockMethodCallHandler(audio, (_) async => null);
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
      messenger.setMockMethodCallHandler(service, null);
      messenger.setMockMethodCallHandler(handler, null);
      messenger.setMockMethodCallHandler(audio, null);
      messenger.setMockMethodCallHandler(androidAudioChannel, null);
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    final controller = MusicController(supportDirectory: tempDir);
    addTearDown(controller.dispose);
    await initializeAndroidAudio(controller);

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
