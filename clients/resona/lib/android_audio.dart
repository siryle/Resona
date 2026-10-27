import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'controller.dart';

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
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: track == null
            ? AudioProcessingState.idle
            : controller.opening
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: controller.playing && track != null,
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
  Future<void> skipToNext() => controller.next();
  @override
  Future<void> skipToPrevious() => controller.next(delta: -1);
  @override
  Future<void> stop() => controller.stopPlayback();
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
  await session.configure(const AudioSessionConfiguration.music());
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
}
