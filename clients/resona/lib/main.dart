import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide Track;

import 'api.dart';
import 'controller.dart';
import 'android_audio.dart';
import 'track_selection.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final controller = MusicController();
  runApp(ResonaApp(controller: controller));
  unawaited(() async {
    if (Platform.isAndroid) {
      try {
        await initializeAndroidAudio(controller);
      } catch (_) {
        controller.error = "后台音频服务初始化失败，重启应用后可重试。";
      }
    }
    await controller.initialize();
  }());
}

const destinations = ['聆听', '音乐库', '已下载', '搜索', '设置'];
const desktopDestinations = ['全部音乐', '专辑', '艺术家', '我喜欢的', '已下载'];
const desktopIcons = [
  Icons.queue_music,
  Icons.album_outlined,
  Icons.people_outline,
  Icons.favorite_outline,
  Icons.download_for_offline_outlined,
];
const destinationIcons = [
  Icons.graphic_eq,
  Icons.library_music_outlined,
  Icons.download_for_offline_outlined,
  Icons.search,
  Icons.settings_outlined,
];
String clock(Duration value) =>
    '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

class ResonaApp extends StatelessWidget {
  final MusicController controller;
  const ResonaApp({super.key, required this.controller});
  ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final windows = defaultTargetPlatform == TargetPlatform.windows;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xffbe5532),
          brightness: brightness,
        ).copyWith(
          primary: dark ? const Color(0xffffb397) : const Color(0xffa83f22),
          surface: dark ? const Color(0xff201f1c) : const Color(0xfff6f4ee),
          surfaceContainerLow: dark
              ? const Color(0xff262722)
              : const Color(0xfffbfaf7),
          surfaceContainerHighest: dark
              ? const Color(0xff393d33)
              : const Color(0xffeaece2),
          outlineVariant: dark
              ? const Color(0xff55594f)
              : const Color(0xffdfdfd6),
          secondaryContainer: dark
              ? const Color(0xff3c4434)
              : const Color(0xffe5eadb),
          onSecondaryContainer: dark
              ? const Color(0xffdce7cd)
              : const Color(0xff34432e),
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: windows ? 'Microsoft YaHei UI' : null,
      fontFamilyFallback: windows
          ? const ['Microsoft YaHei', 'Segoe UI']
          : null,
      textTheme: windows
          ? const TextTheme(
              headlineLarge: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w500,
                height: 1.3,
                letterSpacing: 0,
              ),
              headlineMedium: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w500,
                height: 1.3,
                letterSpacing: 0,
              ),
              headlineSmall: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                height: 1.35,
                letterSpacing: 0,
              ),
              titleLarge: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w500,
                height: 1.4,
                letterSpacing: 0,
              ),
              titleMedium: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 1.45,
                letterSpacing: 0,
              ),
              titleSmall: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                height: 1.45,
                letterSpacing: 0,
              ),
              bodyLarge: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w400,
                height: 1.5,
                letterSpacing: 0,
              ),
              bodyMedium: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w400,
                height: 1.5,
                letterSpacing: 0,
              ),
              bodySmall: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.45,
                letterSpacing: 0,
              ),
              labelLarge: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.4,
                letterSpacing: 0,
              ),
            )
          : null,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Resona',
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    home: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MusicPage(controller: controller),
    ),
  );
}

class LoginPage extends StatefulWidget {
  final MusicController controller;
  const LoginPage({super.key, required this.controller});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final server = TextEditingController();
  final username = TextEditingController(text: 'admin');
  final password = TextEditingController();
  final form = GlobalKey<FormState>();
  bool visible = false;
  @override
  void dispose() {
    server.dispose();
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    await widget.controller.login(server.text, username.text, password.text);
    if (mounted && widget.controller.authenticated) {
      password.clear();
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('连接服务器')),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: form,
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Resona.',
                      style: Theme.of(context).textTheme.displayMedium
                          ?.copyWith(
                            fontFamily: 'Georgia',
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '连接你的音乐空间',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text('登录自托管服务器，聆听本地与网盘收藏。'),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: server,
                      enabled: !widget.controller.busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'https://music.example.com',
                      ),
                      validator: (value) {
                        try {
                          serverAddress(value ?? '');
                          return null;
                        } catch (_) {
                          return '请输入完整的 HTTP / HTTPS 地址';
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: username,
                      enabled: !widget.controller.busy,
                      autofillHints: const [AutofillHints.username],
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: '用户名'),
                      validator: (v) =>
                          (v?.trim().isEmpty ?? true) ? '请输入用户名' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: password,
                      enabled: !widget.controller.busy,
                      obscureText: !visible,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) {
                        if (!widget.controller.busy) unawaited(submit());
                      },
                      decoration: InputDecoration(
                        labelText: '密码',
                        suffixIcon: IconButton(
                          tooltip: visible ? '隐藏密码' : '显示密码',
                          onPressed: () => setState(() => visible = !visible),
                          icon: Icon(
                            visible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                      validator: (v) => (v?.isEmpty ?? true) ? '请输入密码' : null,
                    ),
                    const SizedBox(height: 24),
                    if (widget.controller.error != null)
                      ErrorNotice(text: widget.controller.error!),
                    FilledButton(
                      onPressed:
                          widget.controller.busy || widget.controller.loading
                          ? null
                          : submit,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          widget.controller.busy
                              ? '正在连接…'
                              : widget.controller.loading
                              ? '正在恢复登录…'
                              : '连接服务器',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '凭据保存在设备安全存储中。首次使用请先在服务端网页设置管理员密码；公网连接建议使用 HTTPS。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AdaptiveShell extends StatelessWidget {
  final int index;
  final ValueChanged<int> onDestination;
  final Widget child;
  final Widget? player;
  final bool desktop;
  final Widget? sidebarFooter;
  const AdaptiveShell({
    super.key,
    required this.index,
    required this.onDestination,
    required this.child,
    this.player,
    this.desktop = false,
    this.sidebarFooter,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final rail = bounds.maxWidth >= 720;
      final labels = desktop ? desktopDestinations : destinations;
      final icons = desktop ? desktopIcons : destinationIcons;
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              if (rail && desktop)
                Container(
                  width: 204,
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  padding: const EdgeInsets.fromLTRB(14, 36, 14, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 12, bottom: 32),
                        child: brand(context),
                      ),
                      for (var i = 0; i < labels.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Material(
                            type: MaterialType.transparency,
                            child: ListTile(
                              dense: true,
                              minTileHeight: 48,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(9),
                              ),
                              leading: Icon(icons[i], size: 21),
                              title: Text(labels[i]),
                              selected: index == i,
                              selectedTileColor: Theme.of(
                                context,
                              ).colorScheme.secondaryContainer,
                              onTap: () => onDestination(i),
                            ),
                          ),
                        ),
                      const Spacer(),
                      ?sidebarFooter,
                    ],
                  ),
                ),
              if (rail && !desktop)
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: onDestination,
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Icon(Icons.graphic_eq),
                  ),
                  destinations: List.generate(
                    labels.length,
                    (i) => NavigationRailDestination(
                      icon: Icon(icons[i]),
                      label: Text(labels[i]),
                    ),
                  ),
                ),
              if (rail) const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    Expanded(child: child),
                    ?player,
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: rail
            ? null
            : NavigationBar(
                selectedIndex: index.clamp(0, labels.length - 1),
                onDestinationSelected: onDestination,
                destinations: List.generate(
                  labels.length,
                  (i) => NavigationDestination(
                    icon: Icon(icons[i]),
                    label: labels[i],
                  ),
                ),
              ),
      );
    },
  );
}

Widget brand(BuildContext context) => Text(
  'Resona.',
  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
    fontFamily: 'Georgia',
    fontWeight: FontWeight.w700,
  ),
);

class MusicPage extends StatefulWidget {
  final MusicController controller;
  const MusicPage({super.key, required this.controller});
  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  Timer? debounce;
  final search = TextEditingController();
  final trackSearch = TextEditingController();
  TrackSelection selection = TrackSelection();
  bool selecting = false;
  Future<bool>? collectionWork;
  int selectionEpoch = 0;
  late Object collectionContext;
  int tab = 0;
  bool listening = false;
  MusicController get c => widget.controller;
  bool get desktop => Theme.of(context).platform == TargetPlatform.windows;
  Object get collectionKey =>
      (c, c.api, c.library, c.section, c.album, c.artist, c.offline);
  bool get songCollection =>
      desktop &&
      !listeningNow &&
      c.section != '设置' &&
      !(['专辑', '艺术家'].contains(c.section) &&
          c.album.isEmpty &&
          c.artist.isEmpty);
  List<Track> get visibleTracks =>
      selection.filtered(c.tracks, c.cache?.downloads ?? {});
  List<Track> get chosenTracks => selection.selected(c.tracks);

  @override
  void initState() {
    super.initState();
    collectionContext = collectionKey;
  }

  @override
  void didUpdateWidget(covariant MusicPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (collectionContext != collectionKey) {
      resetSelection();
      collectionContext = collectionKey;
    }
  }

  void resetSelection() {
    selecting = false;
    selection = TrackSelection();
    trackSearch.clear();
    collectionWork = null;
    selectionEpoch++;
  }

  Future<bool> completeCollection() async {
    if (collectionWork != null) return collectionWork!;
    final epoch = selectionEpoch;
    final key = collectionKey;
    Future<bool> fetch() async {
      while (mounted && epoch == selectionEpoch && collectionKey == key) {
        if (c.loading) return false;
        if (c.tracks.length >= c.total) return true;
        final before = c.tracks.length;
        await c.load(more: true);
        if (!mounted || epoch != selectionEpoch || collectionKey != key) {
          return false;
        }
        if (c.error != null) return false;
        if (c.tracks.length <= before) {
          c.error = '歌曲列表不完整，请刷新后重试。';
          c.notifyListeners();
          return false;
        }
      }
      return false;
    }

    collectionWork = fetch();
    try {
      return await collectionWork!;
    } finally {
      if (epoch == selectionEpoch) collectionWork = null;
    }
  }

  void cancelSelection() => setState(() {
    selecting = false;
    selection.selectedIDs.clear();
  });

  Future<void> selectAll() async {
    if (await completeCollection() && mounted && selecting) {
      setState(() => selection.toggleAll(visibleTracks));
    }
  }

  Future<void> playCollection({bool shuffled = false, Track? track}) async {
    if (selection.active) {
      if (!await completeCollection() || !mounted) return;
    }
    final matching = selection.active ? visibleTracks : null;
    if (track != null) {
      if (matching != null && !matching.any((item) => item.id == track.id)) {
        return;
      }
      await c.play(track, fromTracks: matching);
    } else {
      await c.playAll(shuffled: shuffled, matchingTracks: matching);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    trackSearch.dispose();
    super.dispose();
  }

  void navigate(int index) {
    debounce?.cancel();
    search.clear();
    setState(() {
      resetSelection();
      tab = index;
      listening = false;
    });
    c.navigate(
      desktop
          ? ['歌曲', '专辑', '艺术家', '喜欢', '缓存'][index]
          : ['歌曲', '歌曲', '缓存', '搜索', '设置'][index],
    );
  }

  void settingsPage() {
    setState(() {
      resetSelection();
      tab = desktop ? -1 : 4;
      listening = false;
    });
    c.navigate('设置');
  }

  bool get listeningNow => desktop && listening && c.current != null;

  void toggleListening() {
    final expand = !listeningNow;
    if (expand && c.section == '设置') navigate(0);
    setState(() {
      resetSelection();
      listening = expand;
    });
  }

  String get title => c.collectionTitle.isNotEmpty
      ? c.collectionTitle
      : c.section == '设置'
      ? '设置'
      : desktop
      ? (tab >= 0 ? desktopDestinations[tab] : '设置')
      : destinations[tab];
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !selecting && !listeningNow && c.album.isEmpty && c.artist.isEmpty,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) {
        if (selecting) {
          cancelSelection();
        } else if (listeningNow) {
          setState(() => listening = false);
        } else {
          c.navigate(c.section);
        }
      }
    },
    child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.space, control: true):
            ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (!selecting) unawaited(c.toggle());
              return null;
            },
          ),
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              if (selecting) {
                cancelSelection();
              } else if (listeningNow) {
                setState(() => listening = false);
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: AdaptiveShell(
            index: tab,
            onDestination: navigate,
            desktop: desktop,
            sidebarFooter: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.offline ? '离线音乐空间' : '已连接音乐服务器',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '${c.cache?.downloads.length ?? 0} 首已下载 · 随时聆听',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            player: desktop
                ? Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      Visibility(
                        visible: !selecting,
                        maintainState: true,
                        maintainAnimation: true,
                        maintainSize: true,
                        child: DesktopPlayer(
                          controller: c,
                          expanded: listeningNow,
                          onExpand: toggleListening,
                        ),
                      ),
                      if (selecting) Positioned.fill(child: selectionActions()),
                    ],
                  )
                : c.current == null
                ? null
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: MiniPlayer(controller: c),
                    ),
                  ),
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(desktop ? 28 : 20, 16, 12, 8),
                  child: Row(
                    children: [
                      if (listeningNow)
                        IconButton(
                          tooltip: '收起播放页',
                          onPressed: toggleListening,
                          icon: const Icon(Icons.expand_more),
                        )
                      else if (c.album.isNotEmpty || c.artist.isNotEmpty)
                        IconButton(
                          tooltip: '返回列表',
                          onPressed: () => c.navigate(c.section),
                          icon: const Icon(Icons.arrow_back),
                        ),
                      Expanded(
                        child: Text(
                          listeningNow ? '正在播放' : title,
                          style: Theme.of(context).textTheme.titleLarge,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (desktop && songCollection)
                        SizedBox(width: 140, child: scope())
                      else if (desktop && c.section != '设置')
                        SizedBox(width: 255, child: searchField()),
                      if (c.section != '设置')
                        IconButton(
                          tooltip: '刷新音乐库',
                          onPressed: c.loading ? null : () => c.load(),
                          icon: const Icon(Icons.refresh),
                        ),
                      if (desktop)
                        IconButton(
                          tooltip: '设置与服务器登录',
                          onPressed: settingsPage,
                          icon: const Icon(Icons.settings_outlined),
                        ),
                    ],
                  ),
                ),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: ErrorNotice(
                      text: c.error!,
                      dismiss: () {
                        c.error = null;
                        c.notifyListeners();
                      },
                    ),
                  ),
                if (c.loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: listeningNow
                      ? DesktopListening(controller: c)
                      : c.section == '设置'
                      ? settings(context)
                      : library(context),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Widget searchField() => TextField(
    controller: search,
    decoration: const InputDecoration(
      hintText: '搜索歌曲、专辑、艺术家',
      prefixIcon: Icon(Icons.search),
      isDense: true,
    ),
    onChanged: (value) {
      if (listening) setState(() => listening = false);
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 350), () {
        c.search = value;
        unawaited(c.load());
      });
    },
  );
  Widget scope() => DropdownButton<String>(
    value: c.library,
    underline: const SizedBox(),
    items: const [
      DropdownMenuItem(value: 'local', child: Text('本地音乐库')),
      DropdownMenuItem(value: 'cloud', child: Text('网盘音乐库')),
    ],
    onChanged: c.loading
        ? null
        : (value) {
            if (value != null) c.switchLibrary(value);
          },
  );
  Widget collectionIcon(String label, IconData icon, VoidCallback? action) =>
      IconButton(
        tooltip: label,
        onPressed: action,
        style: IconButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          minimumSize: const Size(36, 36),
          maximumSize: const Size(36, 36),
          padding: EdgeInsets.zero,
        ),
        icon: Icon(icon, size: 19),
      );

  Widget selectionActions() {
    final chosen = chosenTracks;
    final enabled = !c.batchBusy && !c.busy && chosen.isNotEmpty;
    final online = enabled && c.authenticated && !c.offline;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('track-selection-actions'),
      color: scheme.brightness == Brightness.dark
          ? const Color(0xff292c2d)
          : const Color(0xffe8e9eb),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                c.batchBusy
                    ? '已选 ${chosen.length} 首 · ${c.batchCompleted} / ${c.batchTotal}'
                    : '已选 ${chosen.length} 首',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (c.batchBusy) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
            ],
            collectionIcon(
              '下载所选歌曲',
              Icons.vertical_align_bottom,
              online &&
                      c.cache != null &&
                      chosen.any(
                        (track) => !c.cache!.downloads.contains(track.id),
                      )
                  ? () => unawaited(
                      c.runTrackBatch(TrackBatchAction.download, chosen),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            collectionIcon(
              '喜欢所选歌曲',
              Icons.favorite_outline,
              online && chosen.any((track) => !track.favorite)
                  ? () => unawaited(
                      c.runTrackBatch(TrackBatchAction.favorite, chosen),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            collectionIcon(
              '加入播放列表',
              Icons.playlist_add,
              enabled
                  ? () {
                      c.enqueueAll(chosen);
                      cancelSelection();
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget collectionControls() {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final tracks = visibleTracks;
    final enabled = !c.loading && !c.busy && !c.queueLoading && !c.batchBusy;
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              if (selecting) ...[
                TextButton.icon(
                  onPressed: enabled && c.tracks.isNotEmpty ? selectAll : null,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    foregroundColor: scheme.onSurface,
                  ),
                  icon: Icon(
                    selection.allSelected(tracks)
                        ? Icons.check_circle
                        : tracks.any(
                            (track) => selection.selectedIDs.contains(track.id),
                          )
                        ? Icons.remove_circle
                        : Icons.circle_outlined,
                    size: 20,
                  ),
                  label: Text(selection.allSelected(tracks) ? '取消全选' : '全选'),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    '已选 ${chosenTracks.length} 首',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(onPressed: cancelSelection, child: const Text('完成')),
              ] else ...[
                TextButton.icon(
                  onPressed: enabled && tracks.isNotEmpty
                      ? () => playCollection()
                      : null,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                    padding: EdgeInsets.zero,
                  ),
                  icon: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: enabled && tracks.isNotEmpty
                          ? scheme.primary
                          : scheme.outline,
                    ),
                    child: Icon(
                      Icons.play_arrow,
                      color: scheme.onPrimary,
                      size: 18,
                    ),
                  ),
                  label: const Text('全部播放'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '（共 ${selection.active ? tracks.length : c.total} 首）',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                collectionIcon(
                  '选歌',
                  Icons.checklist,
                  enabled && tracks.isNotEmpty
                      ? () {
                          setState(() => selecting = true);
                        }
                      : null,
                ),
                const SizedBox(width: 10),
                collectionIcon(
                  '随机播放',
                  Icons.shuffle,
                  enabled && tracks.isNotEmpty
                      ? () => playCollection(shuffled: true)
                      : null,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: trackSearch,
                decoration: InputDecoration(
                  hintText: '搜索歌曲 / 专辑 / 歌手',
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: trackSearch.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除歌曲搜索',
                          onPressed: () => setState(() {
                            trackSearch.clear();
                            selection.query = '';
                          }),
                          icon: const Icon(Icons.cancel_outlined, size: 18),
                        ),
                  filled: true,
                  fillColor: scheme.surfaceContainerLow,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(9),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: theme.textTheme.bodySmall,
                onChanged: (value) {
                  setState(() => selection.query = value);
                  unawaited(completeCollection());
                },
              ),
            ),
            const SizedBox(width: 12),
            PopupMenuButton<void>(
              tooltip: '筛选歌曲',
              icon: Icon(
                Icons.filter_list,
                color: selection.hasFilters ? scheme.primary : scheme.onSurface,
              ),
              style: IconButton.styleFrom(
                backgroundColor: scheme.surfaceContainerLow,
                side: BorderSide(color: scheme.outlineVariant),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              itemBuilder: (_) => [
                PopupMenuItem<void>(
                  enabled: false,
                  child: StatefulBuilder(
                    builder: (context, menuState) {
                      void update(VoidCallback change) {
                        setState(change);
                        menuState(() {});
                        unawaited(completeCollection());
                      }

                      return DefaultTextStyle(
                        style: theme.textTheme.bodyMedium!.copyWith(
                          color: scheme.onSurface,
                        ),
                        child: SizedBox(
                          width: 260,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('筛选歌曲'),
                              DropdownButton<TrackSearchField>(
                                value: selection.searchField,
                                isExpanded: true,
                                items: [
                                  for (final field in TrackSearchField.values)
                                    DropdownMenuItem(
                                      value: field,
                                      child: Text('搜索范围 · ${field.label}'),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    update(() => selection.searchField = value);
                                  }
                                },
                              ),
                              CheckboxListTile(
                                title: const Text('仅我喜欢的'),
                                value: selection.favoritesOnly,
                                contentPadding: EdgeInsets.zero,
                                onChanged: (value) => update(
                                  () => selection.favoritesOnly = value!,
                                ),
                              ),
                              CheckboxListTile(
                                title: const Text('仅已下载'),
                                value: selection.downloadsOnly,
                                contentPadding: EdgeInsets.zero,
                                onChanged: (value) => update(
                                  () => selection.downloadsOnly = value!,
                                ),
                              ),
                              TextButton(
                                onPressed: selection.hasFilters
                                    ? () => update(() {
                                        selection.searchField =
                                            TrackSearchField.all;
                                        selection.favoritesOnly = false;
                                        selection.downloadsOnly = false;
                                      })
                                    : null,
                                child: const Text('重置筛选'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget settings(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => ListView(
      padding: EdgeInsets.symmetric(
        horizontal: desktop
            ? 24
            : ((bounds.maxWidth - 732) / 2).clamp(24.0, double.infinity),
        vertical: desktop ? 16 : 24,
      ),
      children: [
        if (!desktop) ...[brand(context), const SizedBox(height: 28)],
        settingsGroup('服务器', [
          if (c.session != null) ...[
            SelectableText(c.session!.server.toString()),
            Text('账号 · ${c.session!.username}'),
          ],
          Text(c.offline ? '离线，本机音乐可播放' : '已连接'),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: c.busy
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => AnimatedBuilder(
                              animation: c,
                              builder: (_, _) => LoginPage(controller: c),
                            ),
                          ),
                        );
                      },
                child: Text(c.authenticated ? '切换服务器' : '连接服务器'),
              ),
              if (c.authenticated)
                OutlinedButton(
                  onPressed: c.busy ? null : () => c.reconnect(),
                  child: const Text('重新连接与刷新'),
                ),
              if (c.authenticated)
                TextButton(
                  onPressed: c.busy ? null : () => c.logout(),
                  child: const Text('退出登录'),
                ),
            ],
          ),
          if (c.authenticated)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('离线聆听'),
              subtitle: const Text('只读取本机音频，不请求服务器'),
              value: c.offline,
              onChanged: c.busy
                  ? null
                  : (value) {
                      if (!value) {
                        unawaited(c.reconnect());
                      } else {
                        c.offline = true;
                        c.notifyListeners();
                      }
                    },
            ),
        ]),
        settingsGroup('离线音乐', [
          Text('本机下载 · ${c.cache?.downloads.length ?? 0} 首'),
          const Text('通过歌曲右侧菜单下载音频、封面和歌词。退出登录后仍可从「已下载」播放和删除。'),
        ]),
        settingsGroup('播放缓存', [
          Text(
            '占用空间 · ${((c.cache?.size ?? 0) / (1 << 20)).toStringAsFixed(1)} MiB',
          ),
          const Text('播放时自动缓存完整歌曲，再次播放优先读取本机。清理缓存会保留手动下载的音乐。'),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: c.busy || c.cache == null
                  ? null
                  : () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('清理本机播放缓存？'),
                          content: const Text(
                            '当前播放将停止，自动缓存的音频与歌词会被删除。手动下载和服务器文件保持不变。',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('清理缓存'),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) await c.clearCache();
                    },
              child: const Text('清理缓存'),
            ),
          ),
        ]),
        settingsGroup('关于 Resona', [
          const Text('让每一份热爱，产生共鸣。'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Resona',
                applicationLegalese: 'GPL-3.0. 源代码随项目发布标签提供。',
              ),
              child: const Text('开源许可'),
            ),
          ),
          if (desktop) const Text('Ctrl + Space 播放或暂停'),
        ]),
      ],
    ),
  );
  Widget settingsGroup(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: children,
          ),
        ),
      ],
    ),
  );
  Widget library(BuildContext context) {
    final tracks = desktop ? visibleTracks : c.tracks;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            desktop ? 30 : 24,
            16,
            desktop ? 30 : 24,
            16,
          ),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!desktop && tab == 0) ...[
                  Text(
                    '音乐，井然有声。',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontFamily: 'Georgia',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '好音乐，值得好好收藏。',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                c.offline ? '已缓存的旋律，始终在身边。' : '让每一份热爱，产生共鸣。',
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: c.tracks.isEmpty
                                    ? null
                                    : () => c.play(c.tracks.first),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('开始聆听'),
                              ),
                            ],
                          ),
                        ),
                        if (MediaQuery.sizeOf(context).width >= 500)
                          const Padding(
                            padding: EdgeInsets.only(left: 20),
                            child: Icon(Icons.album, size: 88),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                if (desktop) ...[
                  Text(
                    '让每一份热爱，产生共鸣。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (songCollection) collectionControls(),
                ] else
                  Row(
                    children: [
                      Expanded(child: scope()),
                      Text(c.offline ? '离线' : '${c.total} 首'),
                    ],
                  ),
                if (!desktop &&
                    tab == 1 &&
                    c.album.isEmpty &&
                    c.artist.isEmpty) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        for (final value in ['歌曲', '专辑', '艺术家', '喜欢'])
                          ButtonSegment(value: value, label: Text(value)),
                      ],
                      selected: {c.section},
                      onSelectionChanged: (values) {
                        c.navigate(values.first);
                      },
                    ),
                  ),
                ],
                if (!desktop && tab == 3) ...[
                  const SizedBox(height: 16),
                  Text(
                    '寻找共鸣',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 16),
                  searchField(),
                ],
                if (!desktop && (tab == 2 || c.section == '缓存'))
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text('已下载 ${c.total} 首 · 无需登录即可播放'),
                  ),
                if (c.tracks.isNotEmpty && !desktop && tab == 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: c.busy || c.loading || c.queueLoading
                              ? null
                              : () => unawaited(c.playAll()),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('全部播放'),
                        ),
                        OutlinedButton.icon(
                          onPressed: c.busy || c.loading || c.queueLoading
                              ? null
                              : () => unawaited(c.playAll(shuffled: true)),
                          icon: const Icon(Icons.shuffle),
                          label: const Text('随机播放'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (c.collections.isNotEmpty && c.section == '专辑')
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverLayoutBuilder(
              builder: (context, bounds) => SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: (bounds.crossAxisExtent / 190).floor().clamp(
                    1,
                    6,
                  ),
                  mainAxisExtent: 232,
                  crossAxisSpacing: 20,
                  mainAxisSpacing: 16,
                ),
                itemCount: c.collections.length,
                itemBuilder: (context, index) {
                  final value = c.collections[index];
                  final data = value['cover_track'];
                  final artwork =
                      Uri.tryParse(
                        value['artwork'] as String? ?? '',
                      )?.pathSegments ??
                      <String>[];
                  final track = data is Map
                      ? Track(Map<String, dynamic>.from(data))
                      : Track({
                          'id': artwork.length >= 2
                              ? artwork[artwork.length - 2]
                              : value['id'],
                          'artwork': value['artwork'] ?? '',
                        });
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => c.openCollection(value),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Center(
                            child: Cover(
                              controller: c,
                              track: track,
                              size: 170,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          value['title'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          '${value['artist']} · ${value['tracks']} 首',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        if (c.collections.isNotEmpty && c.section == '艺术家')
          SliverList.builder(
            itemCount: c.collections.length,
            itemBuilder: (context, index) {
              final value = c.collections[index];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                leading: ArtistAvatar(
                  controller: c,
                  name: value['name'] as String,
                  path: value['artwork'] as String? ?? '',
                ),
                title: Text(value['name'] as String),
                subtitle: Text('${value['tracks']} 首'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => c.openCollection(value),
              );
            },
          ),
        if (c.collections.isEmpty && tracks.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: desktop ? 30 : 0),
            sliver: SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (context, index) => desktop
                  ? desktopSongRow(tracks[index], index)
                  : songRow(tracks[index], index),
            ),
          ),
        if (tracks.isEmpty && c.collections.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.library_music_outlined, size: 40),
                    const SizedBox(height: 16),
                    Text(
                      c.loading
                          ? '正在读取音乐库…'
                          : desktop && selection.active
                          ? '没有匹配的歌曲'
                          : c.offline
                          ? '还没有可离线播放的音乐'
                          : '这里还没有音乐',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      desktop && selection.active
                          ? '试试其他关键词或取消筛选，已选歌曲会保留。'
                          : c.offline
                          ? '在设置中连接服务器，播放或下载后即可离线聆听。'
                          : '切换音乐库，或在服务器整理并扫描音乐。',
                      textAlign: TextAlign.center,
                    ),
                    if (!c.authenticated)
                      TextButton(
                        onPressed: settingsPage,
                        child: const Text('前往设置'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        if (c.tracks.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: c.tracks.length < c.total
                    ? OutlinedButton(
                        onPressed: c.loading ? null : () => c.load(more: true),
                        child: Text('加载更多 · ${c.tracks.length} / ${c.total}'),
                      )
                    : Text('共 ${tracks.length} 首'),
              ),
            ),
          ),
      ],
    );
  }

  Widget desktopSongRow(Track track, int index) {
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final selected = selection.selectedIDs.contains(track.id);
    final current = c.current?.id == track.id;
    final bitrate = track.json['bitrate'] as num? ?? 0;
    return Column(
      children: [
        Material(
          key: ValueKey('desktop-track-${track.id}'),
          color: (selecting ? selected : current)
              ? scheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    selected: selecting ? selected : current,
                    label: selecting
                        ? '${selected ? '取消选择' : '选择'} ${track.title}'
                        : '播放 ${track.title}',
                    child: InkWell(
                      onTap: selecting
                          ? c.batchBusy
                                ? null
                                : () =>
                                      setState(() => selection.toggle(track.id))
                          : () => playCollection(track: track),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              child: selecting
                                  ? Icon(
                                      selected
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      size: 20,
                                      color: selected
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                    )
                                  : current && c.playing
                                  ? Icon(
                                      Icons.graphic_eq,
                                      size: 16,
                                      color: scheme.primary,
                                    )
                                  : Text(
                                      '${index + 1}'.padLeft(2, '0'),
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(fontSize: 12),
                                    ),
                            ),
                            const SizedBox(width: 14),
                            Cover(controller: c, track: track, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontSize: 14,
                                      color: current && !selecting
                                          ? scheme.primary
                                          : scheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: scheme.outline,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          '${track.format.toUpperCase()}${bitrate > 0 ? ' ${(bitrate / 1000).round()}K' : ''}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontSize: 10,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${track.artist} · ${track.album}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontSize: 12,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Text(
                              clock(Duration(seconds: track.duration.round())),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!selecting) ...[
                  const SizedBox(width: 8),
                  ...songActions(track),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1, thickness: 0.5),
      ],
    );
  }

  List<Widget> songActions(Track track) => [
    IconButton(
      tooltip: track.favorite ? '取消喜欢' : '喜欢',
      onPressed: c.offline || c.batchBusy ? null : () => c.favorite(track),
      color: desktop ? Theme.of(context).colorScheme.primary : null,
      constraints: desktop
          ? const BoxConstraints.tightFor(width: 36, height: 36)
          : null,
      padding: desktop ? EdgeInsets.zero : const EdgeInsets.all(8),
      icon: Icon(track.favorite ? Icons.favorite : Icons.favorite_outline),
      iconSize: 20,
    ),
    PopupMenuButton<String>(
      tooltip: '下载与播放操作',
      padding: desktop ? EdgeInsets.zero : const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 160),
      iconSize: desktop ? 20 : 24,
      iconColor: desktop ? Theme.of(context).colorScheme.primary : null,
      icon: Icon(
        c.downloading.contains(track.id) ? Icons.downloading : Icons.more_horiz,
      ),
      onSelected: (value) {
        if (value == 'download') unawaited(c.download(track));
        if (value == 'remove') unawaited(c.removeDownload(track));
        if (value == 'queue') c.enqueue(track);
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'queue', child: Text('加入播放列表')),
        if (c.cache?.downloads.contains(track.id) == true)
          const PopupMenuItem(value: 'remove', child: Text('删除下载'))
        else
          PopupMenuItem(
            value: 'download',
            enabled: !c.offline && !c.downloading.contains(track.id),
            child: const Text('下载到本机'),
          ),
      ],
    ),
  ];

  Widget songRow(Track track, int index) => Material(
    color: c.current?.id == track.id
        ? Theme.of(context).colorScheme.secondaryContainer
        : Colors.transparent,
    child: InkWell(
      onTap: () => c.play(track),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
        child: Row(
          children: [
            Cover(controller: c, track: track, size: 46),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${track.artist}${track.hasLyrics ? ' · 歌词' : ''}${c.cache?.downloads.contains(track.id) == true ? ' · 已下载' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (MediaQuery.sizeOf(context).width >= 500)
              Text(
                clock(Duration(seconds: track.duration.round())),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ...songActions(track),
          ],
        ),
      ),
    ),
  );
}

class DesktopListening extends StatelessWidget {
  final MusicController controller;
  const DesktopListening({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller, track = c.current!;
    final theme = Theme.of(context), scheme = theme.colorScheme;
    final rate = track.json['sample_rate'];
    final metadata = [
      track.format.toUpperCase(),
      if (rate is num && rate > 0) '${rate / 1000} kHz',
    ].join(' · ');
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.secondaryContainer, scheme.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final wide = bounds.maxWidth >= 620;
          final padding = wide ? 40.0 : 20.0;
          final poster = LayoutBuilder(
            builder: (context, area) {
              final side = (wide ? area.maxHeight - 180 : 110.0).clamp(
                80.0,
                (area.maxWidth - 24).clamp(80.0, 350.0),
              );
              final record = Semantics(
                label: '${track.album} 专辑封面',
                image: true,
                child: Container(
                  width: side,
                  height: side,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xff333333), Color(0xff101010)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x38000000),
                        blurRadius: 18,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      for (var i = 0; i < 12; i++)
                        Container(
                          margin: EdgeInsets.all(8 + i * 4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0x0cffffff)),
                          ),
                        ),
                      ClipOval(
                        child: Cover(
                          controller: c,
                          track: track,
                          size: side * .72,
                        ),
                      ),
                    ],
                  ),
                ),
              );
              final information = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${track.artist} · ${track.album}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    metadata,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              );
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: area.maxHeight),
                  child: wide
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            record,
                            const SizedBox(height: 22),
                            information,
                          ],
                        )
                      : Row(
                          children: [
                            record,
                            const SizedBox(width: 24),
                            Expanded(child: information),
                          ],
                        ),
                ),
              );
            },
          );
          final lyrics = LyricView(
            key: ValueKey(track.id),
            text: c.lyricText,
            position: c.position,
            seek: c.seek,
            desktop: true,
          );
          return Padding(
            padding: EdgeInsets.all(padding),
            child: wide
                ? Row(
                    children: [
                      Expanded(child: poster),
                      const SizedBox(width: 40),
                      Expanded(child: lyrics),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: poster),
                      const SizedBox(height: 20),
                      Expanded(child: lyrics),
                    ],
                  ),
          );
        },
      ),
    );
  }
}

class DesktopPlayer extends StatefulWidget {
  final MusicController controller;
  final bool expanded;
  final VoidCallback onExpand;
  const DesktopPlayer({
    super.key,
    required this.controller,
    required this.onExpand,
    this.expanded = false,
  });
  @override
  State<DesktopPlayer> createState() => _DesktopPlayerState();
}

class _DesktopPlayerState extends State<DesktopPlayer> {
  bool hovered = false, focused = false;
  String? lyricText;
  List<LyricLine> lyrics = [];
  late final progressFocus = FocusNode(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final c = widget.controller;
      if (c.current == null || c.duration <= Duration.zero) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.space) {
        unawaited(c.toggle());
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        unawaited(
          c.seek(
            c.position.inMilliseconds / 1000 +
                (event.logicalKey == LogicalKeyboardKey.arrowRight ? 5 : -5),
          ),
        );
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    },
  );

  @override
  void dispose() {
    progressFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, track = c.current;
    final scheme = Theme.of(context).colorScheme;
    if (lyricText != c.lyricText) {
      lyricText = c.lyricText;
      lyrics = parseLyrics(
        c.lyricText,
      ).where((line) => line.seconds != null && line.text.isNotEmpty).toList();
    }
    final active = lyrics.lastIndexWhere(
      (line) => line.seconds! <= c.position.inMilliseconds / 1000,
    );
    final showLyrics = c.playing && !hovered && !focused && active >= 0;
    final max = c.duration.inMilliseconds.toDouble();
    final canSeek = track != null && max > 0;
    progressFocus.canRequestFocus = canSeek;
    Widget control(
      String label,
      IconData icon,
      VoidCallback? action, {
      Color? color,
    }) => IconButton(
      tooltip: label,
      onPressed: action,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 36),
      icon: Icon(icon, size: 21, color: color),
    );
    final transport = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        control(
          '上一首',
          Icons.skip_previous,
          track == null ? null : () => c.next(delta: -1),
        ),
        const SizedBox(width: 12),
        IconButton.filled(
          tooltip: c.playing ? '暂停' : '播放',
          onPressed: track == null || c.opening ? null : () => c.toggle(),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          padding: EdgeInsets.zero,
          icon: Icon(c.playing ? Icons.pause : Icons.play_arrow, size: 22),
        ),
        const SizedBox(width: 12),
        control('下一首', Icons.skip_next, track == null ? null : () => c.next()),
      ],
    );
    final tools = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 108,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 5,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                      ),
                      child: SizedBox(
                        height: 20,
                        child: Slider(
                          padding: EdgeInsets.zero,
                          value: c.volume,
                          semanticFormatterCallback: (value) =>
                              '音量 ${(value * 100).round()}%',
                          onChanged: c.setVolume,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              FittedBox(
                child: Text(
                  '${clock(c.position)} / ${clock(c.duration)}',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        control(
          track?.favorite == true ? '取消喜欢' : '喜欢',
          track?.favorite == true ? Icons.favorite : Icons.favorite_outline,
          track == null || c.offline || !c.authenticated
              ? null
              : () => c.favorite(track),
          color: track?.favorite == true ? scheme.primary : null,
        ),
        const SizedBox(width: 8),
        control(
          c.modeTitle,
          c.shuffle
              ? Icons.shuffle
              : c.repeatOne
              ? Icons.repeat_one
              : c.repeat
              ? Icons.repeat
              : Icons.playlist_play,
          track == null ? null : c.cycleMode,
          color: c.shuffle || c.repeat || c.repeatOne ? scheme.primary : null,
        ),
        const SizedBox(width: 8),
        control('播放列表', Icons.queue_music, () => showQueue(context, c)),
      ],
    );
    final info = track == null
        ? const Text('选一首，此刻想听的歌', maxLines: 1, overflow: TextOverflow.ellipsis)
        : Tooltip(
            message: widget.expanded ? '收起播放页' : '展开海报与歌词',
            child: InkWell(
              onTap: widget.onExpand,
              borderRadius: BorderRadius.circular(7),
              child: Row(
                children: [
                  Cover(controller: c, track: track, size: 46),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AnimatedSwitcher(
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...previous, ?current],
                      ),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      child: Column(
                        key: ValueKey(showLyrics),
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            showLyrics ? lyrics[active].text : track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            showLyrics
                                ? (active + 1 < lyrics.length
                                      ? lyrics[active + 1].text
                                      : '')
                                : [track.artist, track.album]
                                      .where((value) => value.isNotEmpty)
                                      .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: Focus(
        onFocusChange: (value) => setState(() => focused = value),
        child: Material(
          color: scheme.surfaceContainerLow,
          child: LayoutBuilder(
            builder: (context, bounds) {
              final compact = bounds.maxWidth < 650;
              return Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 3, 20, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 79,
                          child: Row(
                            children: [
                              Expanded(child: info),
                              const SizedBox(width: 22),
                              transport,
                              if (!compact) ...[
                                const SizedBox(width: 22),
                                tools,
                              ],
                            ],
                          ),
                        ),
                        if (compact)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: tools,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: -6,
                    left: 0,
                    right: 0,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        trackShape: const RectangularSliderTrackShape(),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 4,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 8,
                        ),
                      ),
                      child: SizedBox(
                        height: 16,
                        child: Semantics(
                          label: '播放进度',
                          child: Focus.withExternalFocusNode(
                            focusNode: progressFocus,
                            child: ExcludeFocus(
                              child: Slider(
                                key: const ValueKey('desktop-progress'),
                                padding: EdgeInsets.zero,
                                value: c.position.inMilliseconds
                                    .toDouble()
                                    .clamp(0, max > 0 ? max : 1),
                                max: max > 0 ? max : 1,
                                semanticFormatterCallback: (value) =>
                                    '${clock(Duration(milliseconds: value.round()))} / ${clock(c.duration)}',
                                onChanged: canSeek
                                    ? (value) => c.seek(value / 1000)
                                    : null,
                                onChangeStart: canSeek
                                    ? (_) => progressFocus.requestFocus()
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

Future<void> showQueue(BuildContext context, MusicController c) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (_) => AnimatedBuilder(
        animation: c,
        builder: (context, _) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '播放列表 · ${c.queue.length} 首',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: c.queue.length,
                itemBuilder: (context, i) => ListTile(
                  selected: c.current?.id == c.queue[i].id,
                  title: Text(c.queue[i].title),
                  subtitle: Text(c.queue[i].artist),
                  onTap: () {
                    unawaited(c.play(c.queue[i], replaceQueue: false));
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );

class ArtistAvatar extends StatelessWidget {
  final MusicController controller;
  final String name, path;
  const ArtistAvatar({
    super.key,
    required this.controller,
    required this.name,
    required this.path,
  });
  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Center(child: Text(name.isEmpty ? '' : name.characters.first)),
    );
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox(
          width: 48,
          height: 48,
          child: FutureBuilder<Uint8List>(
            key: ValueKey('${controller.session?.server}:$name:$path'),
            future: controller.artistArtwork(name, path),
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return placeholder;
              }
              return Image.memory(
                snapshot.data!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              );
            },
          ),
        ),
      ),
    );
  }
}

class Cover extends StatelessWidget {
  final MusicController controller;
  final Track track;
  final double size;
  const Cover({
    super.key,
    required this.controller,
    required this.track,
    required this.size,
  });
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: FutureBuilder<Uint8List>(
          future: controller.cover(track),
          builder: (context, snapshot) {
            final placeholder = ColoredBox(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: Icon(Icons.music_note_outlined, size: size * .4),
            );
            if (!snapshot.hasData || snapshot.data!.isEmpty) return placeholder;
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
            );
          },
        ),
      ),
    ),
  );
}

class ErrorNotice extends StatelessWidget {
  final String text;
  final VoidCallback? dismiss;
  const ErrorNotice({super.key, required this.text, this.dismiss});
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          if (dismiss != null)
            IconButton(
              tooltip: '关闭提示',
              onPressed: dismiss,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    ),
  );
}

class MiniPlayer extends StatelessWidget {
  final MusicController controller;
  const MiniPlayer({super.key, required this.controller});
  @override
  Widget build(BuildContext context) {
    final c = controller, track = controller.current!;
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.opening)
            const LinearProgressIndicator(minHeight: 2)
          else
            LinearProgressIndicator(
              minHeight: 2,
              value: c.duration.inMilliseconds > 0
                  ? (c.position.inMilliseconds / c.duration.inMilliseconds)
                        .clamp(0, 1)
                  : 0,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                InkWell(
                  onTap: () => showPlayer(context, c),
                  child: Cover(controller: c, track: track, size: 48),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () => showPlayer(context, c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (MediaQuery.sizeOf(context).width >= 500)
                  IconButton(
                    tooltip: '上一首',
                    onPressed: () => c.next(delta: -1),
                    icon: const Icon(Icons.skip_previous),
                  ),
                IconButton(
                  tooltip: c.playing ? '暂停' : '播放',
                  onPressed: c.opening ? null : () => c.toggle(),
                  icon: Icon(c.playing ? Icons.pause : Icons.play_arrow),
                ),
                IconButton(
                  tooltip: '下一首',
                  onPressed: () => c.next(),
                  icon: const Icon(Icons.skip_next),
                ),
                IconButton(
                  tooltip: '播放列表',
                  onPressed: () => showQueue(context, c),
                  icon: const Icon(Icons.queue_music),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showPlayer(
  BuildContext context,
  MusicController c,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 760),
  builder: (context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final track = c.current;
      if (track == null) {
        return const SizedBox(height: 100, child: Center(child: Text('播放已停止')));
      }
      final max = c.duration.inMilliseconds / 1000;
      return SizedBox(
        height: MediaQuery.sizeOf(context).height * .85,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '正在播放',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '收起播放器',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Cover(controller: c, track: track, size: 80),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(track.artist),
                      ],
                    ),
                  ),
                ],
              ),
              Slider(
                value: (c.position.inMilliseconds / 1000).clamp(
                  0,
                  max > 0 ? max : 1,
                ),
                max: max > 0 ? max : 1,
                semanticFormatterCallback: (value) =>
                    clock(Duration(seconds: value.round())),
                onChanged: max > 0 ? (value) => c.seek(value) : null,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [Text(clock(c.position)), Text(clock(c.duration))],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: c.repeat ? '关闭列表循环' : '列表循环',
                    isSelected: c.repeat,
                    onPressed: () => c.setRepeat(!c.repeat),
                    icon: const Icon(Icons.repeat),
                  ),
                  IconButton(
                    tooltip: '上一首',
                    onPressed: () => c.next(delta: -1),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton.filled(
                    iconSize: 32,
                    tooltip: c.playing ? '暂停' : '播放',
                    onPressed: c.opening ? null : () => c.toggle(),
                    icon: Icon(c.playing ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    tooltip: '下一首',
                    onPressed: () => c.next(),
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    tooltip: track.favorite ? '取消喜欢' : '喜欢',
                    onPressed: () => c.favorite(track),
                    icon: Icon(
                      track.favorite ? Icons.favorite : Icons.favorite_outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LyricView(
                  text: c.lyricText,
                  position: c.position,
                  seek: c.seek,
                ),
              ),
            ],
          ),
        ),
      );
    },
  ),
);

class LyricLine {
  final double? seconds;
  final String text;
  LyricLine(this.seconds, this.text);
}

List<LyricLine> parseLyrics(String text) {
  final lines = <LyricLine>[];
  final pattern = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  final offsetMatch = RegExp(
    r'\[offset:([+-]?\d+)\]',
    caseSensitive: false,
  ).firstMatch(text);
  final offset = (int.tryParse(offsetMatch?.group(1) ?? '') ?? 0) / 1000;
  var timed = false;
  for (final row in text.split('\n')) {
    final matches = pattern.allMatches(row).toList();
    if (matches.isEmpty) continue;
    timed = true;
    final body = row.replaceAll(pattern, '').trim();
    for (final match in matches) {
      final seconds =
          int.parse(match[1]!) * 60 +
          int.parse(match[2]!) +
          double.parse('0.${match[3] ?? '0'}') +
          offset;
      lines.add(LyricLine(seconds, body));
    }
  }
  if (timed) {
    lines.sort((a, b) => a.seconds!.compareTo(b.seconds!));
    return lines;
  }
  return text
      .split('\n')
      .where((row) => row.trim().isNotEmpty)
      .map((row) => LyricLine(null, row.trim()))
      .toList();
}

class LyricView extends StatefulWidget {
  final String text;
  final Duration position;
  final ValueChanged<double> seek;
  final bool desktop;
  const LyricView({
    super.key,
    required this.text,
    required this.position,
    required this.seek,
    this.desktop = false,
  });
  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  List<LyricLine> lines = [];
  List<GlobalKey> keys = [];
  int shown = -2;

  @override
  void initState() {
    super.initState();
    readLyrics();
  }

  void readLyrics() {
    lines = parseLyrics(widget.text);
    keys = List.generate(lines.length, (_) => GlobalKey());
    shown = -2;
  }

  @override
  void didUpdateWidget(LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) readLyrics();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (lines.isEmpty) {
      return Center(
        child: Text(
          widget.desktop ? '纯粹聆听，也是共鸣。\n暂无歌词' : '暂无歌词',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.6,
          ),
        ),
      );
    }
    final active = lines.lastIndexWhere(
      (line) =>
          line.seconds != null &&
          line.seconds! <= widget.position.inMilliseconds / 1000,
    );
    if (widget.desktop) {
      if (active != shown) {
        shown = active;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || active < 0 || active >= keys.length) return;
          final target = keys[active].currentContext;
          if (target == null) return;
          Scrollable.ensureVisible(
            target,
            alignment: .5,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        });
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 80),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < lines.length; i++)
              Padding(
                key: keys[i],
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: TextButton(
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    foregroundColor: active == i
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                    disabledForegroundColor: scheme.onSurfaceVariant,
                    textStyle: TextStyle(
                      fontFamily: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.fontFamily,
                      fontFamilyFallback: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.fontFamilyFallback,
                      fontSize: 22,
                      height: 1.5,
                      fontWeight: active == i
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  onPressed: lines[i].seconds == null
                      ? null
                      : () => widget.seek(
                          lines[i].seconds!.clamp(0, double.infinity),
                        ),
                  child: Text(lines[i].text),
                ),
              ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, i) => ListTile(
        title: Text(
          lines[i].text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: active == i ? FontWeight.w700 : FontWeight.normal,
            color: active == i ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
        onTap: lines[i].seconds == null
            ? null
            : () => widget.seek(lines[i].seconds!.clamp(0, double.infinity)),
      ),
    );
  }
}
