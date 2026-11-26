import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';

const dlnaAvTransportService = 'urn:schemas-upnp-org:service:AVTransport:1';
const dlnaRenderingControlService =
    'urn:schemas-upnp-org:service:RenderingControl:1';
const dlnaMediaRendererType = 'urn:schemas-upnp-org:device:MediaRenderer:1';
const dlnaFeaturesFlags =
    'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';

class DlnaDevice {
  final String udn;
  final String name;
  final String manufacturer;
  final String model;
  final String location;
  final String avTransportControlUrl;
  final String renderingControlUrl;
  final bool manual;

  const DlnaDevice({
    required this.udn,
    required this.name,
    this.manufacturer = '',
    this.model = '',
    required this.location,
    required this.avTransportControlUrl,
    this.renderingControlUrl = '',
    this.manual = false,
  });

  factory DlnaDevice.fromServerJson(Map<String, dynamic> json) => DlnaDevice(
    udn: json['udn'] as String? ?? '',
    name: json['name'] as String? ?? '',
    manufacturer: json['manufacturer'] as String? ?? '',
    model: json['model'] as String? ?? '',
    location: json['location'] as String? ?? '',
    avTransportControlUrl: json['av_transport_control'] as String? ?? '',
    renderingControlUrl: json['rendering_control'] as String? ?? '',
    manual: json['manual'] == true,
  );
}

class DlnaTransportState {
  final String state;
  final Duration position;
  final Duration duration;
  final int? volume;

  const DlnaTransportState({
    required this.state,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume,
  });

  bool get playing => state == 'PLAYING' || state == 'TRANSITIONING';
}

String? parseSsdpLocation(String packet) {
  final lines = packet.split(RegExp(r'\r?\n'));
  if (lines.isEmpty ||
      !lines.first.trim().toUpperCase().startsWith('HTTP/1.')) {
    return null;
  }
  for (final line in lines.skip(1)) {
    final idx = line.indexOf(':');
    if (idx <= 0) continue;
    if (line.substring(0, idx).trim().toLowerCase() == 'location') {
      final value = line.substring(idx + 1).trim();
      return value.isEmpty ? null : value;
    }
  }
  return null;
}

String escapeXml(String value) {
  final buf = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x26:
        buf.write('&amp;');
      case 0x3C:
        buf.write('&lt;');
      case 0x3E:
        buf.write('&gt;');
      case 0x22:
        buf.write('&quot;');
      case 0x27:
        buf.write('&apos;');
      default:
        buf.writeCharCode(rune);
    }
  }
  return buf.toString();
}

String unescapeXml(String value) {
  return value.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (
    m,
  ) {
    final token = m.group(1)!;
    switch (token) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      default:
        if (token.startsWith('#x') || token.startsWith('#X')) {
          final code = int.tryParse(token.substring(2), radix: 16);
          if (code != null) return String.fromCharCode(code);
        } else if (token.startsWith('#')) {
          final code = int.tryParse(token.substring(1));
          if (code != null) return String.fromCharCode(code);
        }
        return m.group(0)!;
    }
  });
}

String formatHms(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

Duration parseHms(String raw) {
  final cleaned = raw.trim().split('.').first;
  if (cleaned.isEmpty || cleaned.toUpperCase() == 'NOT_IMPLEMENTED') {
    return Duration.zero;
  }
  final parts = cleaned.split(':');
  if (parts.length != 3) return Duration.zero;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final s = int.tryParse(parts[2]);
  if (h == null || m == null || s == null || h < 0 || m < 0 || s < 0) {
    return Duration.zero;
  }
  return Duration(hours: h, minutes: m, seconds: s);
}

String mimeTypeForFormat(String format) {
  switch (format.toLowerCase()) {
    case 'mp3':
      return 'audio/mpeg';
    case 'flac':
      return 'audio/flac';
    case 'm4a':
    case 'alac':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'wav':
      return 'audio/wav';
    case 'ogg':
    case 'opus':
      return 'audio/ogg';
    case 'aif':
    case 'aiff':
      return 'audio/aiff';
    case 'wma':
      return 'audio/x-ms-wma';
    default:
      return 'application/octet-stream';
  }
}

String buildDidlLiteXml(
  Track track,
  String mediaUrl, {
  String coverUrl = '',
  String? mimeType,
}) {
  final mime = mimeType ?? mimeTypeForFormat(track.format);
  final duration = Duration(milliseconds: (track.duration * 1000).round());
  final buf = StringBuffer()
    ..write(
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">',
    )
    ..write('<item id="${escapeXml(track.id)}" parentID="0" restricted="1">')
    ..write('<dc:title>${escapeXml(track.title)}</dc:title>')
    ..write('<dc:creator>${escapeXml(track.artist)}</dc:creator>')
    ..write('<upnp:artist>${escapeXml(track.artist)}</upnp:artist>');
  if (track.album.isNotEmpty) {
    buf.write('<upnp:album>${escapeXml(track.album)}</upnp:album>');
  }
  if (coverUrl.isNotEmpty) {
    buf.write(
      '<upnp:albumArtURI>${escapeXml(coverUrl)}</upnp:albumArtURI>',
    );
  }
  buf
    ..write(
      '<res protocolInfo="http-get:*:${escapeXml(mime)}:$dlnaFeaturesFlags" '
      'duration="${formatHms(duration)}">${escapeXml(mediaUrl)}</res>',
    )
    ..write('<upnp:class>object.item.audioItem.musicTrack</upnp:class>')
    ..write('</item></DIDL-Lite>');
  return buf.toString();
}

String? parseSoapTag(String xml, String tagName) {
  final pattern = RegExp(
    '<(?:[A-Za-z0-9_]+:)?${RegExp.escape(tagName)}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[A-Za-z0-9_]+:)?${RegExp.escape(tagName)}>',
    caseSensitive: false,
  );
  final match = pattern.firstMatch(xml);
  if (match == null) return null;
  return unescapeXml(match.group(1)!.trim());
}

class _UpnpServiceEntry {
  String serviceType = '';
  String controlUrl = '';
}

class _UpnpDeviceEntry {
  String udn = '';
  String friendlyName = '';
  String manufacturer = '';
  String modelName = '';
  final List<_UpnpServiceEntry> services = [];
}

DlnaDevice? parseUpnpDeviceXml(
  String location,
  String xml, {
  bool manual = false,
}) {
  final locationUri = Uri.tryParse(location);
  if (locationUri == null ||
      !['http', 'https'].contains(locationUri.scheme) ||
      locationUri.host.isEmpty) {
    return null;
  }
  final urlBaseRaw = parseSoapTag(xml, 'URLBase');
  final urlBase = urlBaseRaw == null ? null : Uri.tryParse(urlBaseRaw);
  final baseUri =
      (urlBase != null &&
          ['http', 'https'].contains(urlBase.scheme) &&
          urlBase.host.isNotEmpty)
      ? urlBase
      : locationUri;

  final stripped = xml
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<\?[\s\S]*?\?>'), '');
  final tokenPattern = RegExp(r'<([^<>]+)>([^<]*)');
  final deviceStack = <_UpnpDeviceEntry>[];
  _UpnpServiceEntry? currentService;
  final completedDevices = <_UpnpDeviceEntry>[];

  for (final match in tokenPattern.allMatches(stripped)) {
    final tagContent = match.group(1)!.trim();
    final trailingText = unescapeXml(match.group(2)!.trim());
    if (tagContent.isEmpty || tagContent.startsWith('!')) continue;
    final closing = tagContent.startsWith('/');
    final selfClosing = tagContent.endsWith('/');
    var rawName = closing ? tagContent.substring(1) : tagContent;
    if (selfClosing && rawName.endsWith('/')) {
      rawName = rawName.substring(0, rawName.length - 1);
    }
    rawName = rawName.split(RegExp(r'\s+')).first;
    final colon = rawName.indexOf(':');
    final local = (colon >= 0 ? rawName.substring(colon + 1) : rawName)
        .toLowerCase();

    if (closing) {
      if (local == 'service' && currentService != null) {
        if (deviceStack.isNotEmpty) {
          deviceStack.last.services.add(currentService);
        }
        currentService = null;
      } else if (local == 'device' && deviceStack.isNotEmpty) {
        completedDevices.add(deviceStack.removeLast());
      }
      continue;
    }

    if (local == 'device' && !selfClosing) {
      deviceStack.add(_UpnpDeviceEntry());
      continue;
    }
    if (local == 'service' && !selfClosing) {
      currentService = _UpnpServiceEntry();
      continue;
    }
    if (trailingText.isEmpty || selfClosing) continue;
    if (currentService != null) {
      if (local == 'servicetype') currentService.serviceType = trailingText;
      if (local == 'controlurl') currentService.controlUrl = trailingText;
    } else if (deviceStack.isNotEmpty) {
      final dev = deviceStack.last;
      if (local == 'udn' && dev.udn.isEmpty) dev.udn = trailingText;
      if (local == 'friendlyname' && dev.friendlyName.isEmpty) {
        dev.friendlyName = trailingText;
      }
      if (local == 'manufacturer' && dev.manufacturer.isEmpty) {
        dev.manufacturer = trailingText;
      }
      if (local == 'modelname' && dev.modelName.isEmpty) {
        dev.modelName = trailingText;
      }
    }
  }

  for (final dev in completedDevices) {
    String avUrl = '';
    String rcUrl = '';
    for (final svc in dev.services) {
      if (svc.controlUrl.isEmpty) continue;
      final resolved = baseUri.resolve(svc.controlUrl).toString();
      if (svc.serviceType.startsWith('urn:schemas-upnp-org:service:AVTransport:') &&
          avUrl.isEmpty) {
        avUrl = resolved;
      } else if (svc.serviceType.startsWith(
            'urn:schemas-upnp-org:service:RenderingControl:',
          ) &&
          rcUrl.isEmpty) {
        rcUrl = resolved;
      }
    }
    if (avUrl.isNotEmpty) {
      return DlnaDevice(
        udn: dev.udn.isNotEmpty ? dev.udn : location,
        name: dev.friendlyName.isNotEmpty ? dev.friendlyName : locationUri.host,
        manufacturer: dev.manufacturer,
        model: dev.modelName,
        location: location,
        avTransportControlUrl: avUrl,
        renderingControlUrl: rcUrl,
        manual: manual,
      );
    }
  }
  return null;
}

class DlnaClient {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  bool _closed = false;

  Future<List<DlnaDevice>> discover({
    Duration timeout = const Duration(milliseconds: 2200),
    List<String> extraLocations = const [],
  }) async {
    final locations = <String>{...extraLocations};
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.multicastHops = 2;
      final target = InternetAddress('239.255.255.250');
      for (final st in [dlnaMediaRendererType, dlnaAvTransportService]) {
        final packet = utf8.encode(
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $st\r\n\r\n',
        );
        socket.send(packet, target, 1900);
      }
      final done = Completer<void>();
      final timer = Timer(timeout, () {
        if (!done.isCompleted) done.complete();
      });
      final sub = socket.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg;
          while ((dg = socket?.receive()) != null) {
            final loc = parseSsdpLocation(utf8.decode(dg!.data, allowMalformed: true));
            if (loc != null) locations.add(loc);
          }
        }
      });
      await done.future;
      timer.cancel();
      await sub.cancel();
    } catch (_) {
      /* SSDP multicast may be unavailable on virtual or restricted networks. */
    } finally {
      socket?.close();
    }

    final found = <String, DlnaDevice>{};
    await Future.wait(
      locations.map((loc) async {
        final dev = await fetchDeviceDescription(
          loc,
          manual: extraLocations.contains(loc),
        );
        if (dev != null) found[dev.udn] = dev;
      }),
    );
    final list = found.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  Future<DlnaDevice?> fetchDeviceDescription(
    String location, {
    bool manual = false,
  }) async {
    if (_closed) return null;
    final uri = Uri.tryParse(location.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    try {
      final request = await _http.getUrl(uri).timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final bytes = await limitedBytes(response, 1 << 20);
      return parseUpnpDeviceXml(
        uri.toString(),
        utf8.decode(bytes, allowMalformed: true),
        manual: manual,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _soap(
    String controlUrl,
    String serviceType,
    String action,
    String innerXml,
  ) async {
    final uri = Uri.parse(controlUrl);
    final envelope =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$serviceType">$innerXml</u:$action></s:Body>'
        '</s:Envelope>';
    final request = await _http.postUrl(uri).timeout(const Duration(seconds: 5));
    request.headers.set(HttpHeaders.contentTypeHeader, 'text/xml; charset="utf-8"');
    request.headers.set('SOAPAction', '"$serviceType#$action"');
    request.write(envelope);
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = utf8.decode(
      await limitedBytes(response, 1 << 20),
      allowMalformed: true,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail =
          parseSoapTag(body, 'errorDescription') ??
          parseSoapTag(body, 'faultstring');
      throw APIException(
        detail != null && detail.isNotEmpty
            ? 'DLNA 错误：$detail'
            : 'DLNA 控制失败 (${response.statusCode})',
      );
    }
    return body;
  }

  Future<void> setUriAndPlay(
    DlnaDevice device,
    Track track,
    String mediaUrl, {
    String coverUrl = '',
    Duration startPosition = Duration.zero,
  }) async {
    final didl = buildDidlLiteXml(track, mediaUrl, coverUrl: coverUrl);
    await _soap(
      device.avTransportControlUrl,
      dlnaAvTransportService,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
          '<CurrentURI>${escapeXml(mediaUrl)}</CurrentURI>'
          '<CurrentURIMetaData>${escapeXml(didl)}</CurrentURIMetaData>',
    );
    if (startPosition > const Duration(seconds: 1)) {
      await _soap(
        device.avTransportControlUrl,
        dlnaAvTransportService,
        'Seek',
        '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${formatHms(startPosition)}</Target>',
      ).catchError((Object _) => '');
    }
    await play(device);
  }

  Future<void> play(DlnaDevice device) => _soap(
    device.avTransportControlUrl,
    dlnaAvTransportService,
    'Play',
    '<InstanceID>0</InstanceID><Speed>1</Speed>',
  );

  Future<void> pause(DlnaDevice device) => _soap(
    device.avTransportControlUrl,
    dlnaAvTransportService,
    'Pause',
    '<InstanceID>0</InstanceID>',
  );

  Future<void> stop(DlnaDevice device) => _soap(
    device.avTransportControlUrl,
    dlnaAvTransportService,
    'Stop',
    '<InstanceID>0</InstanceID>',
  );

  Future<void> seek(DlnaDevice device, Duration position) => _soap(
    device.avTransportControlUrl,
    dlnaAvTransportService,
    'Seek',
    '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>${formatHms(position)}</Target>',
  );

  Future<void> setVolume(DlnaDevice device, double volume) async {
    if (device.renderingControlUrl.isEmpty) return;
    final scaled = (volume.clamp(0.0, 1.0) * 100).round();
    await _soap(
      device.renderingControlUrl,
      dlnaRenderingControlService,
      'SetVolume',
      '<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>$scaled</DesiredVolume>',
    );
  }

  Future<DlnaTransportState> getTransportState(DlnaDevice device) async {
    final infoXml = await _soap(
      device.avTransportControlUrl,
      dlnaAvTransportService,
      'GetTransportInfo',
      '<InstanceID>0</InstanceID>',
    );
    final posXml = await _soap(
      device.avTransportControlUrl,
      dlnaAvTransportService,
      'GetPositionInfo',
      '<InstanceID>0</InstanceID>',
    );
    int? volume;
    if (device.renderingControlUrl.isNotEmpty) {
      try {
        final volXml = await _soap(
          device.renderingControlUrl,
          dlnaRenderingControlService,
          'GetVolume',
          '<InstanceID>0</InstanceID><Channel>Master</Channel>',
        );
        final rawVol = parseSoapTag(volXml, 'CurrentVolume');
        if (rawVol != null) volume = int.tryParse(rawVol);
      } catch (_) {
        /* RenderingControl volume query is optional across renderers. */
      }
    }
    return DlnaTransportState(
      state: parseSoapTag(infoXml, 'CurrentTransportState') ?? '',
      position: parseHms(parseSoapTag(posXml, 'RelTime') ?? ''),
      duration: parseHms(parseSoapTag(posXml, 'TrackDuration') ?? ''),
      volume: volume,
    );
  }

  void close() {
    _closed = true;
    _http.close(force: true);
  }
}

class _DlnaRelayEntry {
  final Track track;
  final File? localFile;
  final File? coverFile;
  const _DlnaRelayEntry({required this.track, this.localFile, this.coverFile});
}

class DlnaMediaRelay {
  final ResonaAPI? api;
  final String secret;
  HttpServer? _server;
  final Map<String, _DlnaRelayEntry> _entries = {};
  final Set<HttpClient> _clients = {};

  DlnaMediaRelay({this.api, required this.secret});

  Future<String> registerTrack(
    Track track, {
    File? localFile,
    File? coverFile,
    String targetHost = '',
  }) async {
    _server ??= await _start();
    _entries[track.id] = _DlnaRelayEntry(
      track: track,
      localFile: localFile,
      coverFile: coverFile,
    );
    final ip = await selectLanAddress(targetHost: targetHost);
    if (ip == null) {
      throw const APIException('未能找到局域网网卡地址，无法建立 DLNA 音频投屏。');
    }
    final ext = track.format.isEmpty ? 'mp3' : track.format.toLowerCase();
    return Uri(
      scheme: 'http',
      host: ip,
      port: _server!.port,
      pathSegments: [secret, track.id, 'track.$ext'],
    ).toString();
  }

  Future<String?> coverUrlFor(Track track, {String targetHost = ''}) async {
    final server = _server;
    if (server == null) return null;
    final entry = _entries[track.id];
    if (entry == null) return null;
    if ((entry.coverFile == null || !await entry.coverFile!.exists()) &&
        (api == null || track.artwork.isEmpty)) {
      return null;
    }
    final ip = await selectLanAddress(targetHost: targetHost);
    if (ip == null) return null;
    return Uri(
      scheme: 'http',
      host: ip,
      port: server.port,
      pathSegments: [secret, track.id, 'cover.jpg'],
    ).toString();
  }

  static Future<String?> selectLanAddress({String targetHost = ''}) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final targetParts = targetHost.split('.');
      final addresses = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('127.') && !ip.startsWith('169.254.')) {
            addresses.add(ip);
          }
        }
      }
      if (targetParts.length == 4) {
        final same24 = '${targetParts[0]}.${targetParts[1]}.${targetParts[2]}.';
        final match24 = addresses.where((ip) => ip.startsWith(same24)).firstOrNull;
        if (match24 != null) return match24;
        final same16 = '${targetParts[0]}.${targetParts[1]}.';
        final match16 = addresses.where((ip) => ip.startsWith(same16)).firstOrNull;
        if (match16 != null) return match16;
      }
      final preferred = addresses.where(
        (ip) => ip.startsWith('192.168.') || ip.startsWith('10.'),
      );
      return preferred.firstOrNull ?? addresses.firstOrNull;
    } catch (_) {
      return null;
    }
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen((request) async {
      try {
        final segs = request.uri.pathSegments;
        if (!['GET', 'HEAD'].contains(request.method) ||
            segs.length != 3 ||
            segs[0] != secret) {
          request.response.statusCode = HttpStatus.notFound;
          return;
        }
        final entry = _entries[segs[1]];
        if (entry == null) {
          request.response.statusCode = HttpStatus.notFound;
          return;
        }
        if (segs[2] == 'cover.jpg') {
          await _serveCover(request, entry);
          return;
        }
        await _serveAudio(request, entry);
      } catch (_) {
        try {
          request.response.statusCode = HttpStatus.badGateway;
        } catch (_) {
          /* Response headers may already be sent when the client drops the socket. */
        }
      } finally {
        await request.response.close().catchError((Object _) {});
      }
    });
    return server;
  }

  Future<void> _serveCover(HttpRequest request, _DlnaRelayEntry entry) async {
    List<int> bytes = const [];
    if (entry.coverFile != null && await entry.coverFile!.exists()) {
      bytes = await entry.coverFile!.readAsBytes();
    } else if (api != null) {
      bytes = await api!.cover(entry.track);
    }
    if (bytes.isEmpty) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'jpeg');
    request.response.headers.contentLength = bytes.length;
    if (request.method != 'HEAD') request.response.add(bytes);
  }

  Future<void> _serveAudio(HttpRequest request, _DlnaRelayEntry entry) async {
    request.response.headers.set('transferMode.dlna.org', 'Streaming');
    request.response.headers.set('contentFeatures.dlna.org', dlnaFeaturesFlags);
    request.response.headers.set('accept-ranges', 'bytes');

    final file = entry.localFile;
    if (file != null && await file.exists()) {
      final length = await file.length();
      final mime = mimeTypeForFormat(entry.track.format);
      request.response.headers.set(HttpHeaders.contentTypeHeader, mime);
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && length > 0) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader.trim());
        if (match != null) {
          final startRaw = match.group(1)!;
          final endRaw = match.group(2)!;
          int start;
          int end;
          if (startRaw.isEmpty) {
            final suffix = int.tryParse(endRaw) ?? 0;
            start = (length - suffix).clamp(0, length - 1);
            end = length - 1;
          } else {
            start = int.parse(startRaw);
            end = endRaw.isEmpty ? length - 1 : int.parse(endRaw).clamp(start, length - 1);
          }
          if (start >= length || start > end) {
            request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
            return;
          }
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$length',
          );
          request.response.headers.contentLength = end - start + 1;
          if (request.method != 'HEAD') {
            await request.response.addStream(file.openRead(start, end + 1));
          }
          return;
        }
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentLength = length;
      if (request.method != 'HEAD') {
        await request.response.addStream(file.openRead());
      }
      return;
    }

    if (api == null) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _clients.add(client);
    try {
      final response = await api!.media(
        client,
        api!.endpoint('tracks/${Uri.encodeComponent(entry.track.id)}/stream'),
        range: request.headers.value(HttpHeaders.rangeHeader),
      );
      request.response.statusCode = response.statusCode;
      for (final header in [
        'content-type',
        'content-length',
        'content-range',
        'accept-ranges',
      ]) {
        final value = response.headers.value(header);
        if (value != null) request.response.headers.set(header, value);
      }
      if (request.method != 'HEAD') {
        await request.response.addStream(
          response.timeout(const Duration(seconds: 30)),
        );
      }
    } finally {
      client.close(force: true);
      _clients.remove(client);
    }
  }

  Future<void> close() async {
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    await _server?.close(force: true);
    _server = null;
    _entries.clear();
  }
}
