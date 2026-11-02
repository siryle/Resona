import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'lyrics.dart';

class WindowsDesktop extends ChangeNotifier {
  static const channel = MethodChannel('app.resona/desktop');
  final MusicController controller;
  bool lyricsEnabled = false, lyricsLocked = false;
  double fontSize = 28;
  bool _ready = false,
      _quitting = false,
      _disposed = false,
      _favoriting = false;
  String? _lyricText;
  List<LyricLine> _lyrics = [];
  Map<String, Object>? _lastState;

  WindowsDesktop(this.controller);

  Future<void> initialize() async {
    channel.setMethodCallHandler(_handle);
    try {
      final preferences = await channel.invokeMapMethod<String, Object>(
        'initialize',
      );
      _preferences(preferences);
      if (_disposed) return;
      _ready = true;
      controller.addListener(_update);
      _update();
      if (preferences?['trayAvailable'] == false) {
        controller.error = '系统托盘暂不可用，可从任务栏恢复或退出程序。';
        controller.notifyListeners();
      }
    } on PlatformException {
      controller.error = '无法初始化托盘与桌面歌词，请重启应用后重试。';
      controller.notifyListeners();
    }
  }

  void _preferences(Map<dynamic, dynamic>? values) {
    if (_disposed || values == null) return;
    lyricsEnabled = values['enabled'] == true;
    lyricsLocked = values['locked'] == true;
    final size = values['fontSize'];
    fontSize = size is num && size.isFinite
        ? size.toDouble().clamp(18, 48)
        : 28;
    notifyListeners();
  }

  Future<void> setPreferences({
    bool? enabled,
    bool? locked,
    double? size,
  }) async {
    try {
      _preferences(
        await channel.invokeMapMethod<String, Object>('preferences', {
          'enabled': ?enabled,
          'locked': ?locked,
          if (size != null) 'fontSize': size.clamp(18, 48),
        }),
      );
    } on PlatformException {
      controller.error = '无法保存桌面歌词设置，请重试。';
      controller.notifyListeners();
    }
  }

  String get currentLyric {
    if (_lyricText != controller.lyricText) {
      _lyricText = controller.lyricText;
      _lyrics = parseLyrics(
        controller.lyricText,
      ).where((line) => line.seconds != null && line.text.isNotEmpty).toList();
    }
    final second = controller.position.inMilliseconds / 1000;
    final active = _lyrics.lastIndexWhere((line) => line.seconds! <= second);
    return active >= 0
        ? _lyrics[active].text
        : controller.current?.title ?? 'Resona · 此刻想听什么？';
  }

  void _update() {
    if (!_ready || _disposed || _quitting) return;
    final c = controller, track = c.current;
    final state = <String, Object>{
      'available': track != null,
      'playing': c.playing,
      'opening': c.opening,
      'title': track?.title ?? 'Resona',
      'artist': track?.artist ?? '',
      'album': track?.album ?? '',
      'lyric': currentLyric,
      'favorite': track?.favorite == true,
      'canFavorite':
          track != null &&
          c.authenticated &&
          !c.offline &&
          !c.busy &&
          !_favoriting,
      'mode': c.shuffle
          ? 'shuffle'
          : c.repeatOne
          ? 'repeatOne'
          : c.repeat
          ? 'repeatAll'
          : 'sequential',
    };
    if (mapEquals(_lastState, state)) return;
    _lastState = state;
    unawaited(
      channel.invokeMethod<void>('update', state).catchError((Object _) {
        _lastState = null;
      }),
    );
  }

  Future<void> _handle(MethodCall call) async {
    if (_disposed) return;
    final c = controller;
    switch (call.method) {
      case 'preferences':
        _preferences(call.arguments as Map);
      case 'toggle':
        if (c.current != null && !c.opening) await c.toggle();
      case 'previous':
        await c.next(delta: -1);
      case 'next':
        await c.next();
      case 'favorite':
        final track = c.current;
        if (track != null &&
            c.authenticated &&
            !c.offline &&
            !c.busy &&
            !_favoriting) {
          _favoriting = true;
          _update();
          try {
            await c.favorite(track);
          } finally {
            _favoriting = false;
            _update();
          }
        }
      case 'mode':
        final mode = call.arguments;
        if ([
          'sequential',
          'repeatAll',
          'repeatOne',
          'shuffle',
        ].contains(mode)) {
          c.shuffle = mode == 'shuffle';
          c.repeatOne = mode == 'repeatOne';
          c.repeat = mode == 'repeatAll';
          await c.savePlaybackState();
          c.notifyListeners();
        }
      case 'quit':
        if (_quitting) return;
        _quitting = true;
        await c.savePlaybackState();
        await channel.invokeMethod<void>('quit');
      case 'save':
        await c.savePlaybackState();
      case 'error':
        c.error = call.arguments as String;
        c.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ready = false;
    controller.removeListener(_update);
    channel.setMethodCallHandler(null);
    super.dispose();
  }
}
