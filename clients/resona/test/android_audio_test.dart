import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/android_audio.dart';
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
}
