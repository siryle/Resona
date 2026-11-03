import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/windows_desktop.dart';

class DesktopController extends MusicController {
  int saves = 0, toggles = 0, nexts = 0, favorites = 0;
  Completer<void>? saving;

  @override
  Future<void> savePlaybackState() async {
    saves++;
    await saving?.future;
  }

  @override
  Future<void> toggle() async {
    toggles++;
  }

  @override
  Future<void> next({int delta = 1, bool completed = false}) async {
    nexts += delta;
  }

  @override
  Future<void> favorite(Track track) async {
    favorites++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DesktopController c;
  late WindowsDesktop desktop;
  late List<MethodCall> sent;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> native(String method, [Object? argument]) async {
    final response = Completer<void>();
    await messenger.handlePlatformMessage(
      WindowsDesktop.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, argument),
      ),
      (_) => response.complete(),
    );
    await response.future;
  }

  setUp(() {
    sent = [];
    c = DesktopController();
    desktop = WindowsDesktop(c);
    messenger.setMockMethodCallHandler(WindowsDesktop.channel, (call) async {
      sent.add(call);
      if (call.method == 'initialize') {
        return {'enabled': true, 'locked': true, 'fontSize': 32.0};
      }
      if (call.method == 'preferences') return call.arguments;
      return null;
    });
  });
  tearDown(() {
    desktop.dispose();
    c.dispose();
    messenger.setMockMethodCallHandler(WindowsDesktop.channel, null);
  });

  test('lyrics use offsets, track fallback, seeks and song replacement', () {
    c.current = Track({'id': 'one', 'title': 'First song'});
    c.lyricText = '[offset:500]\n[00:01]First line\n[00:02]Second line';
    expect(desktop.currentLyric, 'First song');
    c.position = const Duration(milliseconds: 1500);
    expect(desktop.currentLyric, 'First line');
    c.position = const Duration(seconds: 3);
    expect(desktop.currentLyric, 'Second line');
    c.position = const Duration(seconds: 1);
    expect(desktop.currentLyric, 'First song');
    c.current = Track({'id': 'two', 'title': 'Replacement'});
    c.lyricText = 'Plain lyrics';
    expect(desktop.currentLyric, 'Replacement');
    c.current = null;
    c.lyricText = '';
    expect(desktop.currentLyric, contains('Resona'));
  });

  test('restores preferences and sends only changed playback state', () async {
    await desktop.initialize();
    expect(desktop.lyricsEnabled, isTrue);
    expect(desktop.lyricsLocked, isTrue);
    expect(desktop.fontSize, 32);
    c.notifyListeners();
    c.position = const Duration(seconds: 1);
    c.notifyListeners();
    expect(sent.where((call) => call.method == 'update'), hasLength(1));
    c.current = Track({'id': 'one', 'title': 'First song'});
    c.notifyListeners();
    await Future<void>.delayed(Duration.zero);
    final state = sent.last.arguments as Map;
    expect(state['title'], 'First song');
    expect(state['canFavorite'], isFalse);
    await native('preferences', {
      'enabled': true,
      'locked': false,
      'fontSize': 99.0,
    });
    expect(desktop.lyricsLocked, isFalse);
    expect(desktop.fontSize, 48);
    await native('preferences', {'fontSize': double.nan});
    expect(desktop.fontSize, 28);
  });

  test('tray permission failures explain how to restore access', () async {
    messenger.setMockMethodCallHandler(WindowsDesktop.channel, (call) async {
      if (call.method == 'initialize') {
        return {'trayAvailable': false, 'trayError': 5};
      }
      return null;
    });
    await desktop.initialize();
    expect(c.error, contains('与资源管理器相同的权限'));
    expect(desktop.currentLyric, contains('Resona'));
  });

  test('native controls guard unavailable actions and persist modes', () async {
    await desktop.initialize();
    await native('toggle');
    expect(c.toggles, 0);
    c.current = Track({'id': 'one', 'title': 'First song'});
    await native('toggle');
    expect(c.toggles, 1);
    c.opening = true;
    await native('toggle');
    expect(c.toggles, 1);
    await native('next');
    await native('previous');
    expect(c.nexts, 0);
    await native('favorite');
    expect(c.favorites, 0);
    for (final mode in ['repeatAll', 'repeatOne', 'shuffle', 'sequential']) {
      await native('mode', mode);
      expect(c.shuffle, mode == 'shuffle');
      expect(c.repeatOne, mode == 'repeatOne');
      expect(c.repeat, mode == 'repeatAll');
    }
    expect(c.saves, 4);
    await native('mode', 'invalid');
    expect(c.saves, 4);
  });

  test(
    'quit waits for the final playback snapshot and ignores duplicate exits',
    () async {
      await desktop.initialize();
      c.saving = Completer<void>();
      final exiting = native('quit');
      await Future<void>.delayed(Duration.zero);
      expect(c.saves, 1);
      expect(sent.where((call) => call.method == 'quit'), isEmpty);
      await native('quit');
      expect(c.saves, 1);
      c.saving!.complete();
      await exiting;
      expect(sent.where((call) => call.method == 'quit'), hasLength(1));
    },
  );
}
