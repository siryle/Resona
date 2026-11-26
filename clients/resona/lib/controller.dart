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
import 'audio_output.dart';
import 'cache.dart';
import 'dlna.dart';

enum TrackBatchAction { download, favorite }

class MusicController extends ChangeNotifier with WidgetsBindingObserver {
  static const _credentials = FlutterSecureStorage();
  final Directory? supportDirectory;
  final Duration sessionRenewalInterval;
  final DlnaClient dlnaClient;
  MusicController({
    this.supportDirectory,
    this.sessionRenewalInterval = const Duration(hours: 12),
    DlnaClient? dlnaClient,
  }) : dlnaClient = dlnaClient ?? DlnaClient();
  Timer? _sessionRenewalTimer;
  Timer? _dlnaPollTimer;
  DateTime? _lastSessionRenewal;
  bool _renewingSession = false;
  bool _manualOffline = false;
  final Set<String> downloading = {};
  static const double minPlaybackRate = 0.5;
  static const double maxPlaybackRate = 2.0;
  static final List<double> playbackRates = List.unmodifiable([
    for (var i = 5; i <= 20; i++) i / 10.0,
  ]);

  static double normalizePlaybackRate(double value) {
    if (!value.isFinite) return 1.0;
    final clamped = value.clamp(minPlaybackRate, maxPlaybackRate);
    return (clamped * 10).round() / 10.0;
  }

  String collectionTitle = "";
  String collectionArtist = '';
  bool shuffle = false;
  double volume = 1;
  double playbackRate = 1.0;
  String get playbackRateLabel => '${playbackRate.toStringAsFixed(1)}x';
  ResonaAPI? api;
  PlaybackCache? cache;
  PlaybackRelay? relay;
  DlnaMediaRelay? _dlnaRelay;
  Player? _player;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<DlnaDevice> dlnaDevices = [];
  bool dlnaScanning = false;
  DlnaDevice? activeDlnaDevice;
  String? dlnaError;
  bool _dlnaManualStop = false;
  String _lastDlnaState = '';
  String? _dlnaActiveTrackId;
  List<AudioDevice> _mpvDevices = [];
  AudioDevice? _activeMpvDevice;
  List<Map<String, dynamic>> _nativeOutputs = [];
  List<LocalAudioOutput> localOutputs = const [
    LocalAudioOutput(
      id: 'auto',
      name: '跟随系统默认输出',
      type: AudioOutputType.systemDefault,
      isDefault: true,
      isActive: true,
    ),
  ];
  String selectedLocalOutputId = 'auto';
  Future<void> Function()? onDlnaScanStart;
  Future<void> Function()? onDlnaScanEnd;
  Future<void> Function()? onOpenBluetoothSettings;
  Future<void> Function()? onOpenOutputSwitcher;
  List<Track> tracks = [];
  List<Track> queue = [];
  List<Map<String, dynamic>> collections = [];
  final Map<String, Future<Uint8List>> _covers = {};
  int coverEpoch = 0;
  Track? current;
  String library = 'local',
      section = '歌曲',
      search = '',
      album = '',
      artist = '';
  String? error;
  bool loading = false,
      queueLoading = false,
      busy = false,
      offline = true,
      playing = false,
      opening = false;
  int total = 0, _request = 0, _playRequest = 0;
  Duration position = Duration.zero, duration = Duration.zero;
  String lyricText = '';
  Future<void> _cacheWork = Future.value();
  Future<void> _playWork = Future.value();
  Future<void> _stateWork = Future.value();
  File? _stateFile;
  File? _prefsFile;
  String themePreference = 'system';
  bool _restoringPlayback = false;
  bool _needsPlaybackOpen = false;
  Duration _savedPosition = Duration.zero;
  bool _disposed = false;
  bool repeat = false;
  bool repeatOne = false;
  bool batchBusy = false;
  int batchCompleted = 0, batchTotal = 0;
  String get modeTitle => shuffle
      ? '随机循环'
      : repeatOne
      ? '单曲循环'
      : repeat
      ? '列表循环'
      : '顺序播放';
  Future<bool> Function()? activateAudio;
  bool get isCastingDlna => activeDlnaDevice != null;
  LocalAudioOutput? get activeBluetoothOutput {
    final explicit = localOutputs
        .where((o) => o.id == selectedLocalOutputId && o.type == AudioOutputType.bluetooth)
        .firstOrNull;
    if (explicit != null) return explicit;
    if (selectedLocalOutputId != 'auto') return null;
    final defaultBt = localOutputs
        .where((o) => o.isDefault && o.type == AudioOutputType.bluetooth)
        .firstOrNull;
    if (defaultBt != null) return defaultBt;
    if (Platform.isAndroid) {
      return localOutputs.where((o) => o.type == AudioOutputType.bluetooth).firstOrNull;
    }
    return null;
  }

  String get activeOutputLabel {
    if (activeDlnaDevice != null) return 'DLNA · ${activeDlnaDevice!.name}';
    if (activeBluetoothOutput != null) return '蓝牙 · ${activeBluetoothOutput!.name}';
    if (selectedLocalOutputId != 'auto') {
      final selected = localOutputs.where((o) => o.id == selectedLocalOutputId).firstOrNull;
      if (selected != null) return selected.name;
    }
    return '跟随系统';
  }

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
    await _loadThemePreference();
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
            await activeAPI!.refreshSession();
            if (api != activeAPI) return;
            _manualOffline = false;
            _lastSessionRenewal = DateTime.now();
            offline = false;
            _invalidateCovers();
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
    _startSessionKeepalive();
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
      repeatOne = state['repeat_one'] == true;
      final rawRate = state['playback_rate'];
      playbackRate = rawRate is num ? normalizePlaybackRate(rawRate.toDouble()) : 1.0;
      playing = false;
      _needsPlaybackOpen = current != null;
    } catch (_) {
      /* Missing or damaged state must not prevent startup. */
    }
  }

  Future<void> _loadThemePreference() async {
    try {
      final dir = supportDirectory ?? await getApplicationSupportDirectory();
      _prefsFile = File('${dir.path}/appearance.json');
      if (await _prefsFile!.exists()) {
        final data = jsonDecode(await _prefsFile!.readAsString());
        final mode = data is Map ? data['theme'] : null;
        if (mode is String &&
            (mode == 'light' || mode == 'dark' || mode == 'system')) {
          themePreference = mode;
          notifyListeners();
        }
      }
    } catch (_) {
      /* Missing or unreadable preferences fall back to system appearance. */
    }
  }

  Future<void> setThemePreference(String mode) async {
    if (mode != 'light' && mode != 'dark' && mode != 'system') return;
    if (themePreference == mode) return;
    themePreference = mode;
    notifyListeners();
    try {
      final file = _prefsFile ??
          File(
            '${(supportDirectory ?? await getApplicationSupportDirectory()).path}/appearance.json',
          );
      _prefsFile = file;
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsString(jsonEncode({'theme': mode}), flush: true);
      await partial.rename(file.path);
    } catch (_) {
      /* Keep the chosen theme active for the current session. */
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
      'repeat_one': repeatOne,
      'playback_rate': playbackRate,
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

  void _startSessionKeepalive() {
    _stopSessionKeepalive();
    if (_disposed ||
        !authenticated ||
        sessionRenewalInterval <= Duration.zero) {
      return;
    }
    _sessionRenewalTimer = Timer.periodic(
      sessionRenewalInterval,
      (_) => unawaited(renewSessionIfNeeded()),
    );
  }

  void _stopSessionKeepalive() {
    _sessionRenewalTimer?.cancel();
    _sessionRenewalTimer = null;
  }

  void setOfflineMode(bool value) {
    if (!value) {
      _manualOffline = false;
      unawaited(reconnect());
      return;
    }
    _manualOffline = true;
    offline = true;
    notifyListeners();
  }

  Future<void> renewSessionIfNeeded({bool force = false}) async {
    if (_disposed ||
        !authenticated ||
        busy ||
        _manualOffline ||
        _renewingSession) {
      return;
    }
    if (!force &&
        _lastSessionRenewal != null &&
        DateTime.now().difference(_lastSessionRenewal!) <
            sessionRenewalInterval) {
      return;
    }
    final activeAPI = api;
    if (activeAPI == null) return;
    _renewingSession = true;
    try {
      await activeAPI.refreshSession();
      if (_disposed || api != activeAPI) return;
      _lastSessionRenewal = DateTime.now();
    } on APIException catch (e) {
      if (_disposed || api != activeAPI) return;
      if (e.status == 401) {
        await logout(revoke: false);
        error = '登录已过期，本机音乐仍可播放。可在设置中重新连接服务器。';
        notifyListeners();
      }
    } catch (_) {
      /* Preserve the saved session across transient network or server outages. */
    } finally {
      _renewingSession = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(renewSessionIfNeeded());
    } else {
      unawaited(savePlaybackState());
    }
  }

  Future<void> reconnect() async {
    if (!authenticated || busy) return;
    _manualOffline = false;
    busy = true;
    notifyListeners();
    try {
      await api!.refreshSession();
      _lastSessionRenewal = DateTime.now();
      offline = false;
      _invalidateCovers();
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
      await _playWork;
      await _player?.stop();
      await relay?.close();
      final oldCache = cache;
      cache = null;
      await oldCache?.stop();
      await _cacheWork;
      api?.close();
      current = null;
      queue = [];
      _invalidateCovers();
      await _activate(session);
      _manualOffline = false;
      _lastSessionRenewal = DateTime.now();
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
          query: {..._trackQuery, 'offset': more ? '${tracks.length}' : '0'},
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

  Map<String, String> get _trackQuery => {
    'library': library,
    'limit': '100',
    if (search.isNotEmpty) 'search': search,
    if (section == '喜欢') 'favorite': 'true',
    if (album.isNotEmpty) 'album': album,
    if (artist.isNotEmpty) 'artist': artist,
  };

  Future<void> playAll({
    bool shuffled = false,
    List<Track>? matchingTracks,
  }) async {
    if (busy || loading || queueLoading || tracks.isEmpty) return;
    final activeAPI = api;
    final request = _request, playRequest = _playRequest;
    final selectedSection = section, wasOffline = offline;
    final query = _trackQuery;
    bool isCurrent() =>
        !_disposed &&
        api == activeAPI &&
        request == _request &&
        playRequest == _playRequest &&
        selectedSection == section &&
        wasOffline == offline &&
        jsonEncode(query) == jsonEncode(_trackQuery);
    queueLoading = true;
    error = null;
    notifyListeners();
    try {
      final all = <Track>[];
      if (matchingTracks != null) {
        all.addAll(matchingTracks);
      } else if (offline || section == '缓存') {
        all.addAll(tracks);
      } else {
        var offset = 0;
        while (true) {
          final data = await activeAPI!.json(
            'GET',
            'tracks',
            query: {...query, 'offset': '$offset'},
          );
          if (!isCurrent()) return;
          final page = (data['items'] as List)
              .map((e) => Track(Map<String, dynamic>.from(e as Map)))
              .toList();
          final count = data['total'] as int;
          if (page.isEmpty && offset < count) {
            throw const APIException('歌曲列表不完整，请刷新后重试。');
          }
          all.addAll(page);
          offset += page.length;
          if (offset >= count) break;
        }
      }
      if (!isCurrent() || busy || all.isEmpty) return;
      final seen = <String>{};
      queue = all.where((track) => seen.add(track.id)).toList();
      shuffle = shuffled;
      if (shuffled) repeatOne = false;
      await play(
        queue[shuffled ? Random().nextInt(queue.length) : 0],
        replaceQueue: false,
      );
    } catch (e) {
      if (isCurrent()) {
        error = e is APIException ? e.message : '无法加载完整播放队列，请重试。';
      }
    } finally {
      queueLoading = false;
      notifyListeners();
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
    _invalidateCovers();
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
        if (isCastingDlna) return;
        playing = value;
        if (!value && !busy && !opening && !_needsPlaybackOpen) {
          unawaited(savePlaybackState());
        }
        notifyListeners();
      }),
      instance.stream.position.listen((value) {
        if (isCastingDlna || busy || opening || _needsPlaybackOpen) return;
        position = value;
        if ((position - _savedPosition).abs() >= const Duration(seconds: 5)) {
          unawaited(savePlaybackState());
        }
        notifyListeners();
      }),
      instance.stream.duration.listen((value) {
        if (isCastingDlna || opening || _needsPlaybackOpen) return;
        duration = value;
        notifyListeners();
      }),
      instance.stream.completed.listen((value) {
        if (isCastingDlna) return;
        if (value) {
          unawaited(next(completed: true));
        }
      }),
      instance.stream.error.listen((value) {
        if (isCastingDlna) return;
        error = '音频播放失败，请检查登录状态和网络后重试。';
        opening = false;
        notifyListeners();
      }),
      instance.stream.audioDevices.listen((devices) {
        _mpvDevices = devices;
        _rebuildLocalOutputs();
      }),
      instance.stream.audioDevice.listen((device) {
        _activeMpvDevice = device;
        if (device.name.isNotEmpty &&
            device.name != 'auto' &&
            selectedLocalOutputId != device.name &&
            localOutputs.any((o) => o.id == device.name)) {
          selectedLocalOutputId = device.name;
        }
        _rebuildLocalOutputs();
      }),
    ]);
    return instance;
  }

  String _relaySecret() => base64UrlEncode(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );

  void _rebuildLocalOutputs() {
    if (Platform.isWindows || _mpvDevices.isNotEmpty) {
      localOutputs = mergeWindowsOutputs(
        _mpvDevices,
        _nativeOutputs,
        selectedId: selectedLocalOutputId,
      );
      if (selectedLocalOutputId == 'auto' &&
          _activeMpvDevice != null &&
          _activeMpvDevice!.name != 'auto') {
        selectedLocalOutputId = _activeMpvDevice!.name;
      }
    } else {
      final list = <LocalAudioOutput>[
        LocalAudioOutput(
          id: 'auto',
          name: '跟随系统音频输出',
          type: AudioOutputType.systemDefault,
          isDefault: true,
          isActive: selectedLocalOutputId == 'auto',
        ),
      ];
      for (final raw in _nativeOutputs) {
        final id = raw['id'] as String? ?? '';
        final name = raw['name'] as String? ?? id;
        final kind = switch (raw['type']) {
          'bluetooth' => AudioOutputType.bluetooth,
          'usb' => AudioOutputType.usb,
          'headphones' => AudioOutputType.headphones,
          'speaker' => AudioOutputType.speaker,
          _ => classifyOutputName(name, isBluetooth: raw['bluetooth'] == true),
        };
        if (id.isEmpty) continue;
        list.add(
          LocalAudioOutput(
            id: id,
            name: name,
            type: kind,
            isDefault: raw['isDefault'] == true,
            isActive: kind == AudioOutputType.bluetooth,
          ),
        );
      }
      localOutputs = list;
    }
    notifyListeners();
  }

  void updateNativeAudioOutputs(
    List<Map<String, dynamic>> raw, {
    bool bluetoothDisconnected = false,
  }) {
    _nativeOutputs = raw;
    if (bluetoothDisconnected) {
      if (!isCastingDlna && playing) {
        playing = false;
        if (!_needsPlaybackOpen && _player != null) {
          unawaited(_player!.pause());
        }
        unawaited(savePlaybackState());
      }
      if (selectedLocalOutputId != 'auto') {
        selectedLocalOutputId = 'auto';
        if (_player != null) {
          unawaited(_player!.setAudioDevice(AudioDevice.auto()));
        }
      }
    }
    _rebuildLocalOutputs();
  }

  Future<void> selectLocalOutput(LocalAudioOutput output) async {
    selectedLocalOutputId = output.id;
    if (isCastingDlna) {
      await selectDlnaDevice(null);
    }
    if (output.mpvDevice != null) {
      await player.setAudioDevice(output.mpvDevice!);
    } else if (output.id == 'auto' && _player != null) {
      await _player!.setAudioDevice(AudioDevice.auto());
    }
    _rebuildLocalOutputs();
  }

  Future<void> scanDlnaDevices() async {
    if (dlnaScanning) return;
    dlnaScanning = true;
    dlnaError = null;
    notifyListeners();
    try {
      await onDlnaScanStart?.call();
      final discovered = await dlnaClient.discover();
      final merged = <String, DlnaDevice>{
        for (final existing in dlnaDevices.where((d) => d.manual)) existing.udn: existing,
        for (final item in discovered) item.udn: item,
      };
      if (api != null && !offline && authenticated) {
        try {
          final remote = await api!.json('GET', 'dlna/devices');
          for (final item in (remote['items'] as List? ?? const [])) {
            if (item is Map) {
              final dev = DlnaDevice.fromServerJson(
                Map<String, dynamic>.from(item),
              );
              merged.putIfAbsent(dev.udn, () => dev);
            }
          }
        } catch (_) {
          /* Server-side DLNA list is optional. */
        }
      }
      dlnaDevices = merged.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (_) {
      dlnaError = '扫描 DLNA 设备失败，请检查网络连接。';
    } finally {
      await onDlnaScanEnd?.call();
      dlnaScanning = false;
      notifyListeners();
    }
  }

  Future<bool> addManualDlnaDevice(String url) async {
    dlnaError = null;
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      dlnaError = '请输入 DLNA 设备描述 XML 地址。';
      notifyListeners();
      return false;
    }
    final device = await dlnaClient.fetchDeviceDescription(trimmed, manual: true);
    if (device == null) {
      dlnaError = '无法连接或解析该 DLNA 设备描述文件。';
      notifyListeners();
      return false;
    }
    dlnaDevices = [
      ...dlnaDevices.where((d) => d.udn != device.udn),
      device,
    ]..sort((a, b) => a.name.compareTo(b.name));
    notifyListeners();
    return true;
  }

  Future<void> selectDlnaDevice(DlnaDevice? device) async {
    dlnaError = null;
    if (device == null) {
      final previous = activeDlnaDevice;
      final resumeTrack = current;
      final resumePosition = position;
      final shouldResume = playing;
      _dlnaManualStop = true;
      _stopDlnaPolling();
      activeDlnaDevice = null;
      _lastDlnaState = '';
      _dlnaActiveTrackId = null;
      notifyListeners();
      if (previous != null) {
        await dlnaClient.stop(previous).catchError((Object _) {});
      }
      if (resumeTrack != null) {
        if (shouldResume) {
          await play(resumeTrack, replaceQueue: false, startPosition: resumePosition);
        } else {
          playing = false;
          _needsPlaybackOpen = true;
          notifyListeners();
        }
      }
      return;
    }
    if (activeDlnaDevice?.udn == device.udn) return;
    final previous = activeDlnaDevice;
    final resumeTrack = current;
    final resumePosition = position;
    _dlnaManualStop = false;
    _stopDlnaPolling();
    if (_player != null) {
      await _player!.pause();
    }
    if (previous != null) {
      await dlnaClient.stop(previous).catchError((Object _) {});
    }
    activeDlnaDevice = device;
    notifyListeners();
    if (resumeTrack != null) {
      await play(resumeTrack, replaceQueue: false, startPosition: resumePosition);
    }
  }

  static bool _isPrivateLanServer(Uri uri) {
    if (uri.scheme != 'http') return false;
    final parts = uri.host.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((v) => v == null || v < 0 || v > 255)) return false;
    final a = octets[0]!, b = octets[1]!;
    return a == 10 ||
        (a == 192 && b == 168) ||
        (a == 172 && b >= 16 && b <= 31);
  }

  Future<({String mediaUrl, String coverUrl})> _prepareDlnaMedia(
    Track track,
    DlnaDevice device,
    bool local,
  ) async {
    if (!local &&
        !offline &&
        api != null &&
        _isPrivateLanServer(api!.session.server)) {
      try {
        final ticket = await api!.json(
          'POST',
          'dlna/ticket',
          body: {'track_id': track.id},
        );
        final mediaPath = ticket['media_path'] as String? ?? '';
        if (mediaPath.isNotEmpty) {
          final base = api!.session.server;
          final mediaUrl = base
              .resolve(mediaPath.replaceFirst(RegExp(r'^/+'), ''))
              .toString();
          final coverPath = ticket['cover_path'] as String? ?? '';
          final coverUrl = coverPath.isEmpty
              ? ''
              : base
                    .resolve(coverPath.replaceFirst(RegExp(r'^/+'), ''))
                    .toString();
          return (mediaUrl: mediaUrl, coverUrl: coverUrl);
        }
      } catch (_) {
        /* Fall back to the local client relay if server tickets are unavailable. */
      }
    }
    _dlnaRelay ??= DlnaMediaRelay(api: api, secret: _relaySecret());
    final targetHost = Uri.tryParse(device.avTransportControlUrl)?.host ?? '';
    final mediaUrl = await _dlnaRelay!.registerTrack(
      track,
      localFile: local ? cache!.audio(track) : null,
      coverFile: local ? cache!.cover(track) : null,
      targetHost: targetHost,
    );
    final coverUrl =
        await _dlnaRelay!.coverUrlFor(track, targetHost: targetHost) ?? '';
    return (mediaUrl: mediaUrl, coverUrl: coverUrl);
  }

  void _startDlnaPolling() {
    _stopDlnaPolling();
    _dlnaPollTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => unawaited(_pollDlnaState()),
    );
  }

  void _stopDlnaPolling() {
    _dlnaPollTimer?.cancel();
    _dlnaPollTimer = null;
  }

  Future<void> _pollDlnaState() async {
    final device = activeDlnaDevice;
    if (_disposed || device == null) return;
    try {
      final state = await dlnaClient.getTransportState(device);
      if (_disposed || activeDlnaDevice?.udn != device.udn) return;
      final prevState = _lastDlnaState;
      final nextState = state.state;
      _lastDlnaState = nextState;
      if (state.duration > Duration.zero) duration = state.duration;
      position = state.position;
      playing = state.playing;
      notifyListeners();
      if (!_dlnaManualStop &&
          prevState == 'PLAYING' &&
          (nextState == 'STOPPED' || nextState == 'NO_MEDIA_PRESENT') &&
          _dlnaActiveTrackId == current?.id &&
          (duration <= Duration.zero ||
              position >= duration - const Duration(seconds: 4))) {
        unawaited(next(completed: true));
      }
    } catch (_) {
      /* Preserve current playback state across transient renderer polling errors. */
    }
  }

  Future<void> play(
    Track track, {
    bool replaceQueue = true,
    Duration startPosition = Duration.zero,
    List<Track>? fromTracks,
  }) async {
    if (busy) return;
    if (api == null ||
        (track.unavailable && !(cache?.contains(track) ?? false))) {
      error = '歌曲暂不可用，请在服务器检查音源状态。';
      notifyListeners();
      return;
    }
    final request = ++_playRequest;
    opening = true;
    error = null;
    notifyListeners();
    try {
      final local = cache?.contains(track) ?? false;
      if (offline && !local) {
        throw const APIException('此歌曲尚未缓存，请连接服务器后播放。');
      }
      final nextDuration = Duration(
        milliseconds: (track.duration * 1000).round(),
      );
      final nextPosition = startPosition >= nextDuration
          ? Duration.zero
          : startPosition;
      final dlnaDevice = activeDlnaDevice;
      if (dlnaDevice != null) {
        final work = _playWork.then((_) async {
          if (request != _playRequest || activeDlnaDevice?.udn != dlnaDevice.udn) {
            return;
          }
          await _player?.pause();
          final urls = await _prepareDlnaMedia(track, dlnaDevice, local);
          if (request != _playRequest || activeDlnaDevice?.udn != dlnaDevice.udn) {
            return;
          }
          await dlnaClient.setUriAndPlay(
            dlnaDevice,
            track,
            urls.mediaUrl,
            coverUrl: urls.coverUrl,
            startPosition: nextPosition,
          );
        });
        _playWork = work.catchError((Object _) {});
        await work;
        if (request != _playRequest) return;
        if (replaceQueue) queue = List.of(fromTracks ?? tracks);
        if (!queue.any((t) => t.id == track.id)) queue = [track];
        current = track;
        lyricText = '';
        duration = nextDuration;
        position = nextPosition;
        playing = true;
        _needsPlaybackOpen = false;
        _dlnaManualStop = false;
        _lastDlnaState = '';
        _dlnaActiveTrackId = track.id;
        _startDlnaPolling();
        unawaited(savePlaybackState());
        unawaited(_lyrics(track, request, local));
        if (!local && cache != null && api != null) {
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
        return;
      }
      final uri = local ? cache!.audio(track).uri : await relay!.url(track);
      if (request != _playRequest) return;
      if (activateAudio != null && !await activateAudio!()) {
        throw const APIException("无法取得音频焦点，请稍后重试。");
      }
      // Serialize decoder opens so a delayed older request cannot replace a newer song.
      final work = _playWork.then((_) async {
        if (request != _playRequest) return;
        if (player.platform is NativePlayer) {
          final native = player.platform as NativePlayer;
          // Lyrics belong to our UI; mpv must not reopen cached sidecars as media.
          await native.setProperty('sub-auto', 'no');
          await native.setProperty('audio-file-auto', 'no');
        }
        if (selectedLocalOutputId != 'auto') {
          final chosen = localOutputs
              .where((o) => o.id == selectedLocalOutputId)
              .firstOrNull
              ?.mpvDevice;
          if (chosen != null) await player.setAudioDevice(chosen);
        }
        await player.setVolume(volume * 100);
        await player.setRate(playbackRate);
        if (request != _playRequest) return;
        try {
          await player.open(Media(uri.toString(), start: nextPosition));
          if (request != _playRequest) {
            await player.stop();
            playing = false;
            _needsPlaybackOpen = current != null;
          }
        } catch (_) {
          await player.stop();
          playing = false;
          _needsPlaybackOpen = current != null;
          rethrow;
        }
      });
      _playWork = work.catchError((Object _) {});
      await work;
      if (request != _playRequest) return;
      if (replaceQueue) queue = List.of(fromTracks ?? tracks);
      if (!queue.any((t) => t.id == track.id)) queue = [track];
      current = track;
      lyricText = '';
      duration = nextDuration;
      position = nextPosition;
      _needsPlaybackOpen = false;
      unawaited(savePlaybackState());
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
        unawaited(savePlaybackState());
      }
    } finally {
      if (request == _playRequest) {
        await _playWork;
        if (request == _playRequest) {
          opening = false;
          notifyListeners();
        }
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
    _dlnaManualStop = true;
    _stopDlnaPolling();
    await _playWork;
    if (activeDlnaDevice != null) {
      await dlnaClient.stop(activeDlnaDevice!).catchError((Object _) {});
    }
    await _player?.stop();
    current = null;
    opening = false;
    playing = false;
    _needsPlaybackOpen = false;
    await savePlaybackState();
    notifyListeners();
  }

  Future<void> next({int delta = 1, bool completed = false}) async {
    if (queue.isEmpty || current == null) return;
    if (completed && repeatOne) {
      await play(current!, replaceQueue: false);
      return;
    }
    final index = queue.indexWhere((t) => t.id == current!.id);
    if (index < 0) return;
    final next = shuffle && delta > 0 && queue.length > 1
        ? (index + 1 + Random().nextInt(queue.length - 1)) % queue.length
        : index + delta;
    if ((next < 0 || next >= queue.length) && !repeat && !repeatOne && !shuffle) {
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
    if (activeDlnaDevice != null) {
      try {
        if (playing) {
          _dlnaManualStop = true;
          await dlnaClient.pause(activeDlnaDevice!);
          playing = false;
        } else {
          _dlnaManualStop = false;
          if (duration > Duration.zero && position >= duration) {
            await dlnaClient.seek(activeDlnaDevice!, Duration.zero);
            position = Duration.zero;
          }
          await dlnaClient.play(activeDlnaDevice!);
          playing = true;
        }
        await savePlaybackState();
      } catch (e) {
        dlnaError = e is APIException ? e.message : 'DLNA 控制失败，请检查设备连接。';
        error = dlnaError;
      }
      notifyListeners();
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
    final previous = position;
    position = Duration(
      milliseconds: (seconds * 1000).round().clamp(0, duration.inMilliseconds),
    );
    if (!_needsPlaybackOpen) {
      if (activeDlnaDevice != null) {
        try {
          await dlnaClient.seek(activeDlnaDevice!, position);
        } catch (e) {
          position = previous;
          dlnaError = e is APIException ? e.message : 'DLNA 控制失败，请检查设备连接。';
          error = dlnaError;
          notifyListeners();
          return;
        }
      } else {
        await player.seek(position);
      }
    }
    await savePlaybackState();
    notifyListeners();
  }

  void enqueue(Track track) => enqueueAll([track]);

  void enqueueAll(Iterable<Track> tracks) {
    final seen = queue.map((track) => track.id).toSet();
    queue.addAll(tracks.where((track) => seen.add(track.id)));
    if (current == null && queue.isNotEmpty) {
      current = queue.first;
      position = Duration.zero;
      duration = Duration(milliseconds: (current!.duration * 1000).round());
      lyricText = '';
      playing = false;
      _needsPlaybackOpen = true;
    }
    unawaited(savePlaybackState());
    notifyListeners();
  }

  Future<bool> runTrackBatch(
    TrackBatchAction action,
    List<Track> chosen,
  ) async {
    if (batchBusy || busy || offline || !authenticated || chosen.isEmpty) {
      return false;
    }
    final activeAPI = api, activeCache = cache;
    batchBusy = true;
    batchCompleted = 0;
    batchTotal = chosen.length;
    error = null;
    notifyListeners();
    try {
      for (final track in chosen) {
        // A batch must never continue against a different account or cache.
        if (_disposed ||
            api != activeAPI ||
            cache != activeCache ||
            offline ||
            busy) {
          return false;
        }
        final latest =
            tracks.where((item) => item.id == track.id).firstOrNull ??
            activeCache?.tracks[track.id] ??
            track;
        switch (action) {
          case TrackBatchAction.favorite:
            if (!latest.favorite) await favorite(latest);
          case TrackBatchAction.download:
            if (activeCache?.downloads.contains(track.id) != true) {
              await download(latest);
              if (activeCache?.downloads.contains(track.id) != true) {
                return false;
              }
            }
        }
        if (_disposed ||
            api != activeAPI ||
            cache != activeCache ||
            offline ||
            error != null) {
          return false;
        }
        batchCompleted++;
        notifyListeners();
      }
      return true;
    } finally {
      batchBusy = false;
      notifyListeners();
    }
  }

  Future<void> favorite(Track track) async {
    if (offline || !authenticated) {
      error = '连接服务器后可修改收藏。';
      notifyListeners();
      return;
    }
    final activeAPI = api!;
    final activeCache = cache;
    try {
      final updated = await activeAPI.json(
        'PUT',
        'tracks/${Uri.encodeComponent(track.id)}/favorite',
        body: {'favorite': !track.favorite},
      );
      if (api != activeAPI) return;
      final replacement = Track({
        ...track.json,
        'favorite': updated['favorite'] ?? !track.favorite,
      });
      tracks = tracks.map((t) => t.id == track.id ? replacement : t).toList();
      queue = queue.map((t) => t.id == track.id ? replacement : t).toList();
      if (current?.id == track.id) current = replacement;
      try {
        await activeCache?.updateFavorite(replacement.id, replacement.favorite);
      } catch (_) {
        error = '收藏已保存，但本机缓存信息更新失败。';
      }
      await savePlaybackState();
    } catch (e) {
      error = e is APIException ? e.message : '收藏保存失败，请重试。';
    }
    notifyListeners();
  }

  void _invalidateCovers() {
    _covers.clear();
    coverEpoch++;
  }

  Future<Uint8List> _rememberCover(
    String key,
    Future<Uint8List> Function() load,
  ) {
    final existing = _covers[key];
    if (existing != null) return existing;
    if (_covers.length >= 100) _covers.remove(_covers.keys.first);
    late final Future<Uint8List> future;
    future = load().then((bytes) {
      if (bytes.isEmpty && identical(_covers[key], future)) _covers.remove(key);
      return bytes;
    });
    _covers[key] = future;
    return future;
  }

  Future<Uint8List> cover(Track track) {
    return _rememberCover(track.id, () async {
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

  Future<Uint8List> artistArtwork(String name, String path) {
    final key = 'artist:${session?.server}:$name:$path';
    return _rememberCover(key, () async {
      try {
        if (!offline && authenticated && path.isNotEmpty) {
          return Uint8List.fromList(await api!.artistArtwork(path));
        }
      } catch (_) {
        /* Keep the artist's initial when artwork is unavailable. */
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
      _invalidateCovers();
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
    _stopSessionKeepalive();
    _lastSessionRenewal = null;
    _manualOffline = false;
    busy = true;
    ++_request;
    ++_playRequest;
    notifyListeners();
    final identity = session == null
        ? null
        : Session(session!.server, session!.username, '');
    try {
      if (!revoke) await savePlaybackState();
      _dlnaManualStop = true;
      _stopDlnaPolling();
      await _playWork;
      if (activeDlnaDevice != null) {
        await dlnaClient.stop(activeDlnaDevice!).catchError((Object _) {});
        activeDlnaDevice = null;
      }
      await _player?.stop();
      await relay?.close();
      await _dlnaRelay?.close();
      _dlnaRelay = null;
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
      _invalidateCovers();
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
    if (activeDlnaDevice != null) {
      try {
        await dlnaClient.setVolume(activeDlnaDevice!, value);
      } catch (e) {
        dlnaError = e is APIException ? e.message : 'DLNA 控制失败，请检查设备连接。';
        error = dlnaError;
      }
    } else {
      await _player?.setVolume(value * 100);
    }
    await savePlaybackState();
    notifyListeners();
  }

  Future<void> setPlaybackRate(double value) async {
    playbackRate = normalizePlaybackRate(value);
    if (!isCastingDlna && _player != null) {
      try {
        await _player!.setRate(playbackRate);
      } catch (_) {
        /* Keep chosen speed ready for the next local playback session. */
      }
    }
    await savePlaybackState();
    notifyListeners();
  }

  Future<void> stepPlaybackRate(int tenths) {
    final currentTenths = (playbackRate * 10).round();
    return setPlaybackRate((currentTenths + tenths) / 10.0);
  }

  void setShuffle(bool value) {
    shuffle = value;
    if (value) repeatOne = false;
    unawaited(savePlaybackState());
    notifyListeners();
  }

  void setRepeat(bool value) {
    repeat = value;
    if (value) repeatOne = false;
    unawaited(savePlaybackState());
    notifyListeners();
  }

  void cycleMode() {
    if (shuffle) {
      shuffle = false;
      repeat = false;
      repeatOne = false;
    } else if (repeatOne) {
      repeatOne = false;
      shuffle = true;
    } else if (repeat) {
      repeat = false;
      repeatOne = true;
    } else {
      repeat = true;
    }
    unawaited(savePlaybackState());
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _stopSessionKeepalive();
    _stopDlnaPolling();
    _lastSessionRenewal = null;
    ++_playRequest;
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(
      _playWork.then((_) async {
        await _player?.dispose();
      }),
    );
    dlnaClient.close();
    unawaited(_dlnaRelay?.close());
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
