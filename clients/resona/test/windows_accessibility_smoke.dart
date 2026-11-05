// Runs against the native Windows engine; flutter_test does not use its AXTree.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/main.dart';

Future<void> frames([int count = 1]) async {
  for (var frame = 0; frame < count; frame++) {
    await Future<void>.delayed(const Duration(milliseconds: 16));
    await WidgetsBinding.instance.endOfFrame;
  }
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final semantics = binding.ensureSemantics();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    exit(1);
  };
  final navigator = GlobalKey<NavigatorState>();
  final controller = MusicController()
    ..current = Track({
      'id': 'accessibility-smoke',
      'title': 'Accessibility smoke test',
      'artist': 'Resona',
      'album': 'Regression checks',
      'duration': 180,
    })
    ..duration = const Duration(seconds: 180)
    ..lyricText = '[00:00]First line\n[00:01]Second line';
  controller.tracks = [controller.current!];
  controller.total = 1;
  runApp(
    MaterialApp(
      navigatorKey: navigator,
      theme: ResonaApp(controller: controller).theme(Brightness.light),
      home: AnimatedBuilder(
        animation: controller,
        builder: (_, _) => MusicPage(controller: controller),
      ),
    ),
  );
  await frames(20);
  try {
    for (var iteration = 0; iteration < 12; iteration++) {
      final value = ValueNotifier<double>(0.3);
      final visible = ValueNotifier<bool>(false);
      final portal = OverlayPortalController()..show();
      final first = GlobalKey<TooltipState>();
      final second = GlobalKey<TooltipState>();
      final content = Scaffold(
        body: ListView(
          children: [
            Row(
              children: [
                Tooltip(
                  key: first,
                  message: 'First action',
                  child: const SizedBox(
                    width: 100,
                    height: 60,
                    child: Text('A'),
                  ),
                ),
                Tooltip(
                  key: second,
                  message: 'Second action',
                  child: const SizedBox(
                    width: 100,
                    height: 60,
                    child: Text('B'),
                  ),
                ),
              ],
            ),
            ValueListenableBuilder<double>(
              valueListenable: value,
              builder: (_, current, _) => Slider(
                value: current,
                onChanged: (next) => value.value = next,
              ),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, shown, _) => Opacity(
                opacity: shown ? 1 : 0,
                child: OverlayPortal(
                  controller: portal,
                  overlayChildBuilder: (_) => const Positioned(
                    top: 100,
                    left: 10,
                    child: Text('Overlay child'),
                  ),
                  child: const Text('Overlay anchor'),
                ),
              ),
            ),
          ],
        ),
      );
      final Route<void> route = iteration.isEven
          ? MaterialPageRoute<void>(builder: (_) => content)
          : DialogRoute<void>(
              context: navigator.currentContext!,
              builder: (_) => Dialog(child: content),
            );
      unawaited(navigator.currentState!.push(route));
      await frames(15);
      visible.value = true;
      first.currentState!.ensureTooltipVisible();
      value.value = 0.7;
      await frames(3);
      second.currentState!.ensureTooltipVisible();
      visible.value = false;
      await frames(3);
      Tooltip.dismissAllToolTips();
      navigator.currentState!.pop();
      await frames(20);
      value.dispose();
      visible.dispose();
      controller.position = Duration(seconds: iteration);
      controller.notifyListeners();
      await frames(2);
    }
    semantics.dispose();
    controller.dispose();
    stdout.writeln('Windows accessibility smoke checks passed.');
    await stdout.flush();
    exit(0);
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  }
}
