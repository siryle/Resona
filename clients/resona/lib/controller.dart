import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'cache.dart';

class MusicController extends ChangeNotifier with WidgetsBindingObserver {
  static const _credentials = FlutterSecureStorage();
  final Directory? supportDirectory;
  MusicController({this.supportDirectory});
  final Set<String> downloading = {};
  String collectionTitle = "";
  String collectionArtist = '';
  bool shuffle = false;
  double volume = 1;
  ResonaAPI? api;
  PlaybackCache? cache;
  PlaybackRelay? relay;
  Player? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<Track> tracks = [];
  List<Track> queue = [];
  List<Map<String, dynamic>> collections = [];
  final Map<String, Future<Uint8List>> _covers = {};
  Track? current;
  String library = 'local',
      section = '歌曲',
      search = '',
      album = '',
      artist = '';
  String? error;
  bool loading = false,
      busy = false,
      offline = true,
      playing = false,
      opening = false;
  int total = 0, _request = 0, _playRequest = 0;
  Duration position = Duration.zero, duration = Duration.zero;
  String lyricText = '';
  Future<void> _cacheWork = Future.value();
  Future<void> _stateWork = Future.value();
  File? _stateFile;
  bool _restoringPlayback = false;
  bool _needsPlaybackOpen = false;
  Duration _savedPosition = Duration.zero;
  bool _disposed = false;
  bool repeat = false;
  Future<bool> Function()? activateAudio;
  Session? get session => api?.session;
  bool get authenticated => session?.token.isNotEmpty == true;
  String get filterTitle => artist.isNotEmpty
      ? artist
      : album.isNotEmpty
      ? '专辑歌曲'
      : section;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    loading = true;
    notifyListeners();
    try {
      final value =
          await _credentials.read(key: 'session') ??
          await _credentials.read(key: 'identity');
      if (value != null) {
        await _activate(
          Session.fromJson(Map<String, dynamic>.from(jsonDecode(value) as Map)),
        );
        offline = true;
        await load();
        final activeAPI = api;
        if (authenticated) {
          try {
            await activeAPI!.json('GET', 'auth/session');
            if (api != activeAPI) return;
            offline = false;
          } on APIException catch (e) {
            if (api != activeAPI) return;
            if (e.status == 401) {
              await logout(revoke: false);
              error = '登录已过期，本机音乐仍可播放。可在设置中重新连接服务器。';
              return;
            }
            rethrow;
          }
        }
        await load();
      }
    } catch (_) {
      offline = true;
      await load();
      error = api == null ? '无法读取安全凭据，可在设置中连接服务器。' : '服务器暂时无法连接，本机音乐仍可播放。';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _activate(Session session) async {
    api = ResonaAPI(session);
    cache = PlaybackCache(
      Directory(
        '${(supportDirectory ?? await getApplicationSupportDirectory()).path}/playback-cache',
      ),
      session,
    );
    await cache!.load();
    _stateFile = File('${cache!.root.path}.playback.json');
    _restoringPlayback = true;
    try {
      await _restorePlaybackState();
    } finally {
      _restoringPlayback = false;
    }
    final secret = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    relay = PlaybackRelay(api!, secret);
  }

  Future<void> _restorePlaybackState() async {
    await _stateWork;
    try {
      final state = jsonDecode(await _stateFile!.readAsString()) as Map;
      final restoredQueue = (state['queue'] as List)
          .map((value) => Track(Map<String, dynamic>.from(value as Map)))
          .toList();
      final restoredCurrent = state['current'] == null
          ? null
          : Track(Map<String, dynamic>.from(state['current'] as Map));
      if (restoredQueue.any((track) => track.id.isEmpty) ||
          restoredCurrent?.id.isEmpty == true) {
        return;
      }
      final restoredPosition = (state['position'] as num).toInt();
      final restoredVolume = (state['volume'] as num).toDouble();
      final restoredShuffle = state['shuffle'] as bool;
      final restoredRepeat = state['repeat'] as bool;
      if (!restoredVolume.isFinite) return;
      final restoredDuration = Duration(
        milliseconds: ((restoredCurrent?.duration ?? 0) * 1000).round(),
      );
      queue = restoredQueue;
      current = restoredCurrent;
      if (current != null && !queue.any((track) => track.id == current!.id)) {
        queue.add(current!);
      }
      duration = restoredDuration;
      position = Duration(
        milliseconds: restoredPosition.clamp(0, duration.inMilliseconds),
      );
      _savedPosition = position;
      volume = restoredVolume.clamp(0, 1);
      shuffle = restoredShuffle;
      repeat = restoredRepeat;
      playing = false;
      _needsPlaybackOpen = current != null;
    } catch (_) {
      /* Missing or damaged state must not prevent startup. */
    }
  }

  Future<void> savePlaybackState() {
    final file = _stateFile;
    if (file == null || _restoringPlayback) return Future.value();
    final snapshot = jsonEncode({
      'current': current?.json,
      'queue': queue.map((track) => track.json).toList(),
      'position': position.inMilliseconds,
      'volume': volume,
      'shuffle': shuffle,
      'repeat': repeat,
    });
    _savedPosition = position;
    return _stateWork = _stateWork
        .then((_) async {
          final partial = File('${file.path}.part');
          await partial.writeAsString(snapshot, flush: true);
          await partial.rename(file.path);
        })
        .catchError((Object _) {
          error = '无法保存播放状态，请检查本机存储空间。';
          notifyListeners();
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(savePlaybackState());
  }

  Future<void> reconnect() async {
    if (!authenticated || busy) return;
    busy = true;
    notifyListeners();
    try {
      await api!.json('GET', 'auth/session');
      offline = false;
      await load();
    } on APIException catch (e) {
      if (e.status == 401) await logout(revoke: false);
      error = e.message;
    } catch (_) {
      error = '服务器暂时无法连接，本机音乐仍可播放。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> login(String address, String username, String password) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final session = await ResonaAPI.login(address, username, password);
      await _credentials.write(
        key: 'session',
        value: jsonEncode(session.toJson()),
      );
      await _credentials.write(
        key: 'identity',
        value: jsonEncode(
          Session(session.server, session.username, '').toJson(),
        ),
      );
      ++_request;
      ++_playRequest;
      await _player?.stop();
      await relay?.close();
      final oldCache = cache;
      cache = null;
      await oldCache?.stop();
      await _cacheWork;
      api?.close();
      current = null;
      queue = [];
      _covers.clear();
      await _activate(session);
      offline = false;
      await load();
    } catch (e) {
      error = e is APIException || e is FormatException
          ? e.toString()
          : '连接失败，请检查服务器地址、网络和证书。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> load({bool more = false}) async {
    if (api == null) {
      tracks = [];
      collections = [];
      total = 0;
      notifyListeners();
      return;
    }
    final request = ++_request;
    loading = true;
    error = null;
    if (!more) {
      tracks = [];
      collections = [];
      total = 0;
    }
    notifyListeners();
    try {
      if (offline || section == '缓存') {
        tracks =
            cache?.tracks.values
                .where(
                  (t) =>
                      t.library == library &&
                      (section != '缓存' || cache!.downloads.contains(t.id)) &&
                      (section != '喜欢' || t.favorite) &&
                      (album.isEmpty ||
                          (t.album == collectionTitle &&
                              (t.json['album_artist'] ?? t.artist) ==
                                  collectionArtist)) &&
                      (artist.isEmpty ||
                          t.artist == artist ||
                          t.json['album_artist'] == artist) &&
                      '${t.title} ${t.artist} ${t.album}'
                          .toLowerCase()
                          .contains(search.toLowerCase()),
                )
                .toList() ??
            [];
        total = tracks.length;
        if (album.isEmpty && artist.isEmpty) {
          if (section == '专辑') collections = groupAlbums(tracks);
          if (section == '艺术家') {
            final artists = <String, int>{};
            for (final t in tracks) {
              artists.update(t.artist, (count) => count + 1, ifAbsent: () => 1);
            }
            collections = artists.entries
                .map(
                  (entry) => <String, dynamic>{
                    'name': entry.key,
                    'tracks': entry.value,
                  },
                )
                .toList();
          }
        }
      } else if (['专辑', '艺术家'].contains(section) &&
          album.isEmpty &&
          artist.isEmpty) {
        final data = await api!.json(
          'GET',
          section == '专辑' ? 'albums' : 'artists',
          query: {'library': library},
        );
        if (request != _request) return;
        collections = (data['items'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } else {
        final data = await api!.json(
          'GET',
          'tracks',
          query: {
            'library': library,
            'limit': '100',
            'offset': more ? '${tracks.length}' : '0',
            if (search.isNotEmpty) 'search': search,
            if (section == '喜欢') 'favorite': 'true',
            if (album.isNotEmpty) 'album': album,
            if (artist.isNotEmpty) 'artist': artist,
          },
        );
        if (request != _request) return;
        tracks = [
          if (more) ...tracks,
          ...(data['items'] as List).map(
            (e) => Track(Map<String, dynamic>.from(e as Map)),
          ),
        ];
        total = data['total'] as int? ?? tracks.length;
      }
    } catch (e) {
      if (request == _request) {
        if (e is APIException && e.status == 401) {
          await logout(revoke: false);
          error = '登录已过期，可在设置中重新连接。本机音乐仍可播放。';
        } else if (!offline) {
          offline = true;
          await load();
          error = '服务器暂时无法连接，已切换到本机音乐。';
        }
        notifyListeners();
      }
    } finally {
      if (request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void navigate(String value) {
    section = value;
    collectionTitle = '';
    album = '';
    artist = '';
    search = '';
    if (value != '设置') {
      unawaited(load());
    }
    notifyListeners();
  }

  void switchLibrary(String value) {
    library = value;
    collectionTitle = '';
    collectionArtist = '';
    album = '';
    artist = '';
    _covers.clear();
    unawaited(load());
  }

  void openCollection(Map<String, dynamic> value) {
    collectionTitle = (value['title'] ?? value['name']) as String;
    if (section == '专辑') {
      album = value['id'] as String;
      collectionArtist = value['artist'] as String? ?? '';
    } else {
      artist = value['name'] as String;
    }
    unawaited(load());
  }

  Player get player {
    if (_player != null) return _player!;
    final instance = Player();
    _player = instance;
    _subscriptions.addAll([
      instance.stream.playing.listen((value) {
        playing = value;
        if (!value && !busy && !opening && !_needsPlaybackOpen) {
          unawaited(savePlaybackState());
        }
        notifyListeners();
      }),
      instance.stream.position.listen((value) {
        if (busy || opening || _needsPlaybackOpen) return;
        position = value;
        if ((position - _savedPosition).abs() >= const Duration(seconds: 5)) {
          unawaited(savePlaybackState());
        }
        notifyListeners();
      }),
      instance.stream.duration.listen((value) {
        duration = value;
        notifyListeners();
      }),
      instance.stream.completed.listen((value) {
        if (value) {
          unawaited(next());
        }
      }),
      instance.stream.error.listen((value) {
        error = '音频播放失败，请检查登录状态和网络后重试。';
        opening = false;
        notifyListeners();
      }),
    ]);
    return instance;
  }

  Future<void> play(
    Track track, {
    bool replaceQueue = true,
    Duration startPosition = Duration.zero,
  }) async {
    if (busy) return;
    if (api == null ||
        (track.unavailable && !(cache?.contains(track) ?? false))) {
      error = '歌曲暂不可用，请在服务器检查音源状态。';
      notifyListeners();
      return;
    }
    final request = ++_playRequest;
    if (replaceQueue) queue = List.of(tracks);
    if (!queue.any((t) => t.id == track.id)) queue = [track];
    current = track;
    lyricText = '';
    duration = Duration(milliseconds: (track.duration * 1000).round());
    position = startPosition >= duration ? Duration.zero : startPosition;
    _needsPlaybackOpen = true;
    opening = true;
    error = null;
    unawaited(savePlaybackState());
    notifyListeners();
    try {
      final local = cache?.contains(track) ?? false;
      if (offline && !local) throw const APIException('此歌曲尚未缓存，请连接服务器后播放。');
      final uri = local ? cache!.audio(track).uri : await relay!.url(track);
      if (request != _playRequest) return;
      if (activateAudio != null && !await activateAudio!()) {
        throw const APIException("无法取得音频焦点，请稍后重试。");
      }
      if (request != _playRequest) return;
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        // Lyrics belong to our UI; mpv must not reopen the cached LRC as external media.
        await native.setProperty('sub-auto', 'no');
        await native.setProperty('audio-file-auto', 'no');
      }
      if (request != _playRequest) return;
      await player.setVolume(volume * 100);
      await player.open(Media(uri.toString(), start: position));
      if (request != _playRequest) return;
      _needsPlaybackOpen = false;
      unawaited(_lyrics(track, request, local));
      if (!local) {
        final activeCache = cache!, activeAPI = api!;
        _cacheWork = _cacheWork.then((_) async {
          if (cache != activeCache) return;
          try {
            await activeCache.save(activeAPI, track);
          } catch (_) {
            if (cache == activeCache) {
              error = '本机缓存未完成，当前在线播放不受影响。';
            }
          }
          notifyListeners();
        });
      }
    } catch (e) {
      if (request == _playRequest) {
        error = e is APIException ? e.message : '播放失败，请检查音源与网络。';
      }
    } finally {
      if (request == _playRequest) {
        opening = false;
        notifyListeners();
      }
    }
  }

  Future<void> _lyrics(Track track, int request, bool local) async {
    try {
      final file = cache!.lyrics(track);
      final text = local && await file.exists()
          ? await file.readAsString()
          : offline
          ? ''
          : await api!.lyrics(track);
      if (request == _playRequest) {
        lyricText = text;
        notifyListeners();
      }
    } catch (_) {
      /* Lyrics are optional and must not interrupt playback. */
    }
  }

  Future<void> stopPlayback() async {
    ++_playRequest;
    await _player?.stop();
    current = null;
    opening = false;
    playing = false;
    _needsPlaybackOpen = false;
    await savePlaybackState();
    notifyListeners();
  }

  Future<void> next({int delta = 1}) async {
    if (queue.isEmpty || current == null) return;
    final index = queue.indexWhere((t) => t.id == current!.id);
    final next = shuffle && delta > 0
        ? Random().nextInt(queue.length)
        : index + delta;
    if (next >= queue.length && !repeat) {
      await _player?.pause();
      return;
    }
    await play(
      queue[(next % queue.length + queue.length) % queue.length],
      replaceQueue: false,
    );
  }

  Future<void> toggle() async {
    if (current == null) return;
    if (_needsPlaybackOpen) {
      await play(current!, replaceQueue: false, startPosition: position);
      return;
    }
    if (!playing && duration > Duration.zero && position >= duration) {
      await player.seek(Duration.zero);
    }
    if (!playing && activateAudio != null && !await activateAudio!()) return;
    await player.playOrPause();
    await savePlaybackState();
  }

  Future<void> seek(double seconds) async {
    position = Duration(
      milliseconds: (seconds * 1000).round().clamp(0, duration.inMilliseconds),
    );
    if (!_needsPlaybackOpen) await player.seek(position);
    await savePlaybackState();
    notifyListeners();
  }

  void enqueue(Track track) {
    queue.add(track);
    unawaited(savePlaybackState());
    notifyListeners();
  }

  Future<void> favorite(Track track) async {
    if (offline || !authenticated) {
      error = '连接服务器后可修改收藏。';
      notifyListeners();
      return;
    }
    try {
      final updated = await api!.json(
        'PUT',
        'tracks/${Uri.encodeComponent(track.id)}/favorite',
        body: {'favorite': !track.favorite},
      );
      final replacement = Track({
        ...track.json,
        'favorite': updated['favorite'] ?? !track.favorite,
      });
      tracks = tracks.map((t) => t.id == track.id ? replacement : t).toList();
      queue = queue.map((t) => t.id == track.id ? replacement : t).toList();
      if (current?.id == track.id) current = replacement;
      await savePlaybackState();
    } catch (e) {
      error = e is APIException ? e.message : '收藏保存失败，请重试。';
    }
    notifyListeners();
  }

  Future<Uint8List> cover(Track track) {
    if (_covers.length >= 100 && !_covers.containsKey(track.id)) {
      _covers.remove(_covers.keys.first);
    }
    return _covers.putIfAbsent(track.id, () async {
      try {
        final local = cache?.cover(track);
        if (local != null && await local.exists()) {
          return await local.readAsBytes();
        }
        if (!offline && api != null) {
          return Uint8List.fromList(await api!.cover(track));
        }
      } catch (_) {
        /* Use the themed placeholder. */
      }
      return Uint8List(0);
    });
  }

  Future<void> clearCache() async {
    final activeCache = cache;
    busy = true;
    notifyListeners();
    try {
      ++_playRequest;
      await _player?.stop();
      current = null;
      cache = null;
      await activeCache?.stop();
      await _cacheWork;
      await activeCache?.clear();
      cache = activeCache;
      _covers.clear();
      await savePlaybackState();
      if (section == '缓存' || offline) await load();
    } catch (_) {
      error = '缓存清理失败，请关闭占用文件后重试。';
    } finally {
      cache = activeCache;
      busy = false;
      notifyListeners();
    }
  }

  Future<void> logout({bool revoke = true}) async {
    busy = true;
    ++_request;
    ++_playRequest;
    notifyListeners();
    final identity = session == null
        ? null
        : Session(session!.server, session!.username, '');
    try {
      if (!revoke) await savePlaybackState();
      await _player?.stop();
      await relay?.close();
      final activeCache = cache;
      cache = null;
      await activeCache?.stop();
      await _cacheWork;
      if (revoke && authenticated) {
        try {
          await api?.json('POST', 'auth/logout', body: {});
        } catch (_) {
          /* Remove local credentials even when offline. */
        }
      }
      if (identity != null) {
        await _credentials.write(
          key: 'identity',
          value: jsonEncode(identity.toJson()),
        );
      }
      await _credentials.delete(key: 'session');
      api?.close();
      api = null;
      relay = null;
      current = null;
      queue = [];
      if (revoke) await savePlaybackState();
      collections = [];
      _covers.clear();
      album = '';
      artist = '';
      search = '';
      offline = true;
      if (identity != null) await _activate(identity);
      if (section != '设置') await load();
    } catch (_) {
      error = '退出未完成，请重试。';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> download(Track track) async {
    if (downloading.contains(track.id) || busy) return;
    if (!authenticated || offline || cache == null) {
      error = '连接服务器后可下载音乐。';
      notifyListeners();
      return;
    }
    final activeCache = cache!, activeAPI = api!;
    downloading.add(track.id);
    notifyListeners();
    final task = _cacheWork.then((_) async {
      if (cache != activeCache) return;
      await activeCache.save(activeAPI, track);
      await activeCache.pin(track);
    });
    _cacheWork = task.catchError((Object _) {});
    try {
      await task;
    } catch (_) {
      error = '下载未完成，请检查网络和可用空间后重试。';
    } finally {
      downloading.remove(track.id);
      notifyListeners();
    }
  }

  Future<void> removeDownload(Track track) async {
    if (busy ||
        downloading.contains(track.id) ||
        cache?.downloads.contains(track.id) != true) {
      return;
    }
    try {
      if (current?.id == track.id) await stopPlayback();
      await cache?.remove(track);
      _covers.remove(track.id);
      if (section == '缓存' || offline) await load();
    } catch (_) {
      error = '删除下载失败，请关闭占用文件后重试。';
    }
    notifyListeners();
  }

  Future<void> setVolume(double value) async {
    volume = value;
    await _player?.setVolume(value * 100);
    await savePlaybackState();
    notifyListeners();
  }

  void setShuffle(bool value) {
    shuffle = value;
    unawaited(savePlaybackState());
    notifyListeners();
  }

  void setRepeat(bool value) {
    repeat = value;
    unawaited(savePlaybackState());
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(_player?.dispose());
    unawaited(relay?.close());
    unawaited(cache?.stop());
    api?.close();
    super.dispose();
  }
}

List<Map<String, dynamic>> groupAlbums(List<Track> tracks) {
  final albums = <String, Map<String, dynamic>>{};
  for (final track in tracks) {
    final key = '${track.album}\n${track.json['album_artist'] ?? track.artist}';
    final entry = albums.putIfAbsent(
      key,
      () => <String, dynamic>{
        'id': key,
        'title': track.album,
        'artist': track.json['album_artist'] ?? track.artist,
        'tracks': 0,
        'artwork': track.artwork,
        'cover_track': track.json,
      },
    );
    entry['tracks'] = (entry['tracks'] as int) + 1;
  }
  return albums.values.toList();
}
