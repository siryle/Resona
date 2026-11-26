import 'package:media_kit/media_kit.dart';

enum AudioOutputType { systemDefault, speaker, headphones, bluetooth, usb, other }

class LocalAudioOutput {
  final String id;
  final String name;
  final AudioOutputType type;
  final bool isDefault;
  final bool isActive;
  final AudioDevice? mpvDevice;

  const LocalAudioOutput({
    required this.id,
    required this.name,
    required this.type,
    this.isDefault = false,
    this.isActive = false,
    this.mpvDevice,
  });

  String get typeLabel => switch (type) {
    AudioOutputType.bluetooth => '蓝牙',
    AudioOutputType.headphones => '耳机 / 外接',
    AudioOutputType.usb => 'USB 音频',
    AudioOutputType.speaker => '扬声器',
    AudioOutputType.systemDefault => '系统默认',
    AudioOutputType.other => '音频输出',
  };
}

AudioOutputType classifyOutputName(String name, {bool isBluetooth = false}) {
  if (isBluetooth) return AudioOutputType.bluetooth;
  final lower = name.toLowerCase();
  if (RegExp(
    r'bluetooth|airpods|buds|freebuds|wh-|wf-|bose|jbl|beats|sony|hands-free|a2dp|蓝牙',
  ).hasMatch(lower)) {
    return AudioOutputType.bluetooth;
  }
  if (lower.contains('usb') || lower.contains('dac')) return AudioOutputType.usb;
  if (RegExp(r'headphone|headset|earphone|耳机').hasMatch(lower)) {
    return AudioOutputType.headphones;
  }
  if (RegExp(r'speaker|realtek|high definition audio|扬声器').hasMatch(lower)) {
    return AudioOutputType.speaker;
  }
  return AudioOutputType.other;
}

String? _extractGuid(String value) {
  final match = RegExp(
    r'\{[0-9a-fA-F-]{8,}\}',
  ).firstMatch(value);
  return match?.group(0)?.toLowerCase();
}

List<LocalAudioOutput> mergeWindowsOutputs(
  List<AudioDevice> mpvDevices,
  List<Map<String, dynamic>> nativeDevices, {
  String selectedId = 'auto',
}) {
  final nativeByGuid = <String, Map<String, dynamic>>{};
  for (final raw in nativeDevices) {
    final id = raw['id'] as String? ?? '';
    final guid = _extractGuid(id);
    if (guid != null) nativeByGuid[guid] = raw;
  }

  final out = <LocalAudioOutput>[
    LocalAudioOutput(
      id: 'auto',
      name: '跟随系统默认输出',
      type: AudioOutputType.systemDefault,
      isDefault: true,
      isActive: selectedId == 'auto',
      mpvDevice: AudioDevice.auto(),
    ),
  ];

  final seen = <String>{'auto'};
  for (final dev in mpvDevices) {
    if (dev.name == 'auto' || !seen.add(dev.name)) continue;
    final guid = _extractGuid(dev.name);
    final native = guid == null ? null : nativeByGuid[guid];
    final bt = native?['bluetooth'] == true;
    final label = (dev.description.isNotEmpty ? dev.description : dev.name)
        .trim();
    final type = classifyOutputName(label, isBluetooth: bt);
    out.add(
      LocalAudioOutput(
        id: dev.name,
        name: label,
        type: type,
        isDefault: native?['isDefault'] == true,
        isActive: selectedId == dev.name,
        mpvDevice: dev,
      ),
    );
  }

  for (final raw in nativeDevices) {
    final id = raw['id'] as String? ?? '';
    final guid = _extractGuid(id);
    if (id.isEmpty ||
        out.any((o) => o.id == id || (guid != null && _extractGuid(o.id) == guid))) {
      continue;
    }
    final name = raw['name'] as String? ?? id;
    final bt = raw['bluetooth'] == true;
    final syntheticName = 'wasapi/$id';
    out.add(
      LocalAudioOutput(
        id: syntheticName,
        name: name,
        type: classifyOutputName(name, isBluetooth: bt),
        isDefault: raw['isDefault'] == true,
        isActive: selectedId == syntheticName,
        mpvDevice: AudioDevice(syntheticName, name),
      ),
    );
  }

  final prefix = out.first;
  final rest = out.skip(1).toList()
    ..sort((a, b) {
      final pa = a.type == AudioOutputType.bluetooth ? 0 : (a.isDefault ? 1 : 2);
      final pb = b.type == AudioOutputType.bluetooth ? 0 : (b.isDefault ? 1 : 2);
      if (pa != pb) return pa.compareTo(pb);
      return a.name.compareTo(b.name);
    });
  return [prefix, ...rest];
}
