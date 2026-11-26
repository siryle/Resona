import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'controller.dart';

const androidAudioChannel = MethodChannel('app.resona/android_audio');

class AndroidAudioHandler extends BaseAudioHandler {
  final MusicController controller;
  String? _trackID;
  AndroidAudioHandler(this.controller) {
    controller.addListener(_update);
  }
  void _update() {
    final track = controller.current;
    if (track?.id != _trackID) {
      _trackID = track?.id;
      mediaItem.add(
        track == null
            ? null
            : MediaItem(
                id: track.id,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: Duration(
                  milliseconds: (track.duration * 1000).round(),
                ),
              ),
      );
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          controller.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.play,
          MediaAction.pause,
          MediaAction.playPause,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
          MediaAction.seek,
          MediaAction.fastForward,
          MediaAction.rewind,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: track == null
            ? AudioProcessingState.idle
            : controller.opening
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: controller.playing && track != null,
        speed: controller.isCastingDlna ? 1.0 : controller.playbackRate,
        updatePosition: controller.position,
        bufferedPosition: controller.position,
      ),
    );
  }

  @override
  Future<void> play() async {
    if (!controller.playing) await controller.toggle();
  }

  @override
  Future<void> pause() async {
    if (controller.playing) await controller.toggle();
  }

  @override
  Future<void> seek(Duration position) =>
      controller.seek(position.inMilliseconds / 1000);
  @override
  Future<void> fastForward() =>
      controller.seek(controller.position.inMilliseconds / 1000 + 10);
  @override
  Future<void> rewind() => controller.seek(
    (controller.position.inMilliseconds / 1000 - 10).clamp(0, double.infinity),
  );
  @override
  Future<void> skipToNext() => controller.next();
  @override
  Future<void> skipToPrevious() => controller.next(delta: -1);
  @override
  Future<void> stop() => controller.stopPlayback();
  @override
  Future<void> setSpeed(double speed) => controller.setPlaybackRate(speed);
}

Future<void> bindAndroidAudioChannel(MusicController controller) async {
  androidAudioChannel.setMethodCallHandler((call) async {
    if (call.method == 'outputsChanged' && call.arguments is Map) {
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final rawDevices = (args['devices'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      controller.updateNativeAudioOutputs(
        rawDevices,
        bluetoothDisconnected: args['bluetoothDisconnected'] == true,
      );
    }
  });
  controller.onDlnaScanStart = () async {
    try {
      await androidAudioChannel.invokeMethod<void>('acquireMulticastLock');
    } catch (_) {
      /* MulticastLock is optional on hosts without the native Android channel. */
    }
  };
  controller.onDlnaScanEnd = () async {
    try {
      await androidAudioChannel.invokeMethod<void>('releaseMulticastLock');
    } catch (_) {
      /* Ignore lock release failures when channel or lock is unavailable. */
    }
  };
  controller.onOpenOutputSwitcher = () async {
    try {
      await androidAudioChannel.invokeMethod<void>('openOutputSwitcher');
    } catch (_) {
      /* Older Android versions or tests may not implement system output switcher. */
    }
  };
  controller.onOpenBluetoothSettings = () async {
    try {
      await androidAudioChannel.invokeMethod<void>('openBluetoothSettings');
    } catch (_) {
      /* Ignore settings launch failure if no Bluetooth settings activity exists. */
    }
  };
  try {
    final initial = await androidAudioChannel.invokeListMethod<dynamic>(
      'getAudioOutputs',
    );
    if (initial != null) {
      controller.updateNativeAudioOutputs(
        initial.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList(),
      );
    }
  } catch (_) {
    /* Older or mocked hosts may not expose android_audio method handlers. */
  }
}

Future<void> initializeAndroidAudio(MusicController controller) async {
  await AudioService.init(
    builder: () => AndroidAudioHandler(controller),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'app.resona.client.playback',
      androidNotificationChannelName: '音乐播放',
      androidNotificationIcon: 'drawable/resona_notification',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  final session = await AudioSession.instance;
  await session.configure(
    const AudioSessionConfiguration.music().copyWith(
      androidWillPauseWhenDucked: true,
    ),
  );
  controller.activateAudio = () async => await session.setActive(true);
  String? interruptedTrack;
  session.interruptionEventStream.listen((event) {
    if (event.begin) {
      interruptedTrack = controller.playing ? controller.current?.id : null;
      if (controller.playing) unawaited(controller.toggle());
    } else if (event.type == AudioInterruptionType.pause &&
        interruptedTrack != null &&
        interruptedTrack == controller.current?.id &&
        !controller.playing) {
      interruptedTrack = null;
      unawaited(controller.toggle());
    }
  });
  session.becomingNoisyEventStream.listen((_) {
    interruptedTrack = null;
    if (controller.playing) unawaited(controller.toggle());
  });

  await bindAndroidAudioChannel(controller);
}
