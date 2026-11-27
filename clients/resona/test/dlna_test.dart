import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show AudioDevice;
import 'package:resona_client/api.dart';
import 'package:resona_client/audio_output.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/dlna.dart';

class TicketAPI extends ResonaAPI {
  TicketAPI()
    : super(Session(Uri.parse('http://192.168.1.10/'), 'user', 'token'));

  @override
  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async => {'media_path': '/media/song.mp3'};

  @override
  Future<String> lyrics(Track track) async => '';
}

class PollingDlnaClient extends DlnaClient {
  DlnaTransportState state = const DlnaTransportState(
    state: 'PLAYING',
    position: Duration(seconds: 178),
    duration: Duration(seconds: 180),
  );
  Completer<DlnaTransportState>? pending;
  int pollCalls = 0;
  final List<String> played = [];

  @override
  Future<DlnaTransportState> getTransportState(DlnaDevice device) {
    pollCalls++;
    return pending?.future ?? Future.value(state);
  }

  @override
  Future<void> setUriAndPlay(
    DlnaDevice device,
    Track track,
    String mediaUrl, {
    String coverUrl = '',
    Duration startPosition = Duration.zero,
  }) async {
    played.add(track.id);
  }

  @override
  Future<void> seek(DlnaDevice device, Duration position) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    HttpOverrides.global = null;
  });

  const pollingDevice = DlnaDevice(
    udn: 'polling-speaker',
    name: 'Polling Speaker',
    location: 'http://192.168.1.20/device.xml',
    avTransportControlUrl: 'http://192.168.1.20/control',
  );
  final pollingTracks = [
    for (final id in ['first', 'second'])
      Track({'id': id, 'title': id, 'format': 'mp3', 'duration': 180.0}),
  ];

  for (final stopped in ['STOPPED', 'NO_MEDIA_PRESENT']) {
    for (final repeatOne in [false, true]) {
      testWidgets('DLNA $stopped at zero advances with repeatOne=$repeatOne', (
        tester,
      ) async {
        final client = PollingDlnaClient();
        final controller = MusicController(dlnaClient: client)
          ..api = TicketAPI()
          ..offline = false
          ..activeDlnaDevice = pollingDevice
          ..tracks = pollingTracks
          ..repeatOne = repeatOne;
        await controller.play(pollingTracks.first);
        await tester.pump(const Duration(milliseconds: 1200));
        expect(controller.position, const Duration(seconds: 178));
        client.state = DlnaTransportState(state: stopped);
        await tester.pump(const Duration(milliseconds: 1200));
        expect(client.played, ['first', repeatOne ? 'first' : 'second']);
        expect(controller.current?.id, repeatOne ? 'first' : 'second');
        controller.dispose();
        await tester.pump();
      });
    }
  }

  testWidgets(
    'DLNA slow polls do not overlap or overwrite a new track or seek',
    (tester) async {
      final client = PollingDlnaClient()
        ..pending = Completer<DlnaTransportState>();
      final controller = MusicController(dlnaClient: client)
        ..api = TicketAPI()
        ..offline = false
        ..activeDlnaDevice = pollingDevice
        ..tracks = pollingTracks;
      await controller.play(pollingTracks.first);
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump(const Duration(milliseconds: 3600));
      expect(client.pollCalls, 1);
      await controller.play(pollingTracks.last);
      client.pending!.complete(client.state);
      await tester.pump();
      expect(controller.current?.id, 'second');
      expect(controller.position, Duration.zero);
      expect(controller.playing, isTrue);

      client.pending = Completer<DlnaTransportState>();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(client.pollCalls, 2);
      await controller.seek(45);
      client.pending!.complete(client.state);
      await tester.pump();
      expect(controller.position, const Duration(seconds: 45));

      client.pending = null;
      client.state = const DlnaTransportState(
        state: 'PLAYING',
        position: Duration(seconds: 46),
      );
      await tester.pump(const Duration(milliseconds: 1200));
      expect(controller.position, const Duration(seconds: 46));
      controller.dispose();
      await tester.pump();
    },
  );

  test('SSDP, XML, DIDL-Lite, SOAP and H:MM:SS helpers handle edge cases', () {
    const ssdp =
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'Location: http://192.168.1.50:49152/description.xml\r\n'
        '\r\n';
    expect(
      parseSsdpLocation(ssdp),
      'http://192.168.1.50:49152/description.xml',
    );
    expect(parseSsdpLocation('M-SEARCH * HTTP/1.1\r\n'), isNull);

    expect(formatHms(const Duration(seconds: 3661)), '1:01:01');
    expect(parseHms('01:02:03.500'), const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(parseHms('NOT_IMPLEMENTED'), Duration.zero);

    expect(escapeXml('<A&B "test">'), '&lt;A&amp;B &quot;test&quot;&gt;');
    expect(unescapeXml('&lt;A&amp;B &#39;&#x41;&gt;'), "<A&B 'A>");

    final track = Track({
      'id': 'trk-1',
      'title': 'Song & Dance',
      'artist': 'Artist <A>',
      'album': 'Album "B"',
      'format': 'flac',
      'duration': 185.0,
    });
    final didl = buildDidlLiteXml(
      track,
      'http://192.168.1.10:9000/s/trk-1/track.flac',
      coverUrl: 'http://192.168.1.10:9000/s/trk-1/cover.jpg',
    );
    expect(didl, contains('Song &amp; Dance'));
    expect(didl, contains('audio/flac'));
    expect(didl, contains('duration="0:03:05"'));
    expect(didl, contains('<upnp:albumArtURI>http://192.168.1.10:9000/s/trk-1/cover.jpg</upnp:albumArtURI>'));

    const descXml = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Living Room Speaker</friendlyName>
    <manufacturer>Sonos</manufacturer>
    <modelName>Era 100</modelName>
    <UDN>uuid:living-room-1</UDN>
    <serviceList>
      <service>
        <serviceType>$dlnaAvTransportService</serviceType>
        <controlURL>/MediaRenderer/AVTransport/Control</controlURL>
      </service>
      <service>
        <serviceType>$dlnaRenderingControlService</serviceType>
        <controlURL>/MediaRenderer/RenderingControl/Control</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';
    final parsed = parseUpnpDeviceXml(
      'http://192.168.1.50:1400/xml/device_description.xml',
      descXml,
      manual: true,
    );
    expect(parsed, isNotNull);
    expect(parsed!.name, 'Living Room Speaker');
    expect(parsed.udn, 'uuid:living-room-1');
    expect(parsed.manual, isTrue);
    expect(
      parsed.avTransportControlUrl,
      'http://192.168.1.50:1400/MediaRenderer/AVTransport/Control',
    );
    expect(
      parsed.renderingControlUrl,
      'http://192.168.1.50:1400/MediaRenderer/RenderingControl/Control',
    );

    const soapBody = '<s:Envelope><u:GetTransportInfoResponse><CurrentTransportState>PLAYING</CurrentTransportState></u:GetTransportInfoResponse></s:Envelope>';
    expect(parseSoapTag(soapBody, 'CurrentTransportState'), 'PLAYING');
  });

  test('audio output classification merges Windows CoreAudio and mpv devices', () {
    expect(classifyOutputName('Sony WH-1000XM5'), AudioOutputType.bluetooth);
    expect(classifyOutputName('FiiO USB DAC'), AudioOutputType.usb);
    expect(
      classifyOutputName('Generic Output', isBluetooth: true),
      AudioOutputType.bluetooth,
    );

    const guidBt = '{0.0.0.00000000}.{11111111-1111-1111-1111-111111111111}';
    const guidSpk = '{0.0.0.00000000}.{22222222-2222-2222-2222-222222222222}';
    final merged = mergeWindowsOutputs(
      [
        AudioDevice.auto(),
        const AudioDevice('wasapi/$guidSpk', 'Speakers (Realtek)'),
        const AudioDevice('wasapi/$guidBt', 'WF-1000XM5 Stereo'),
      ],
      [
        {
          'id': guidBt,
          'name': 'WF-1000XM5 Stereo',
          'bluetooth': true,
          'isDefault': true,
        },
        {
          'id': guidSpk,
          'name': 'Speakers (Realtek)',
          'bluetooth': false,
          'isDefault': false,
        },
      ],
      selectedId: 'wasapi/$guidBt',
    );
    expect(merged, hasLength(3));
    expect(merged[0].id, 'auto');
    expect(merged[1].type, AudioOutputType.bluetooth);
    expect(merged[1].isDefault, isTrue);
    expect(merged[1].isActive, isTrue);
    expect(merged[2].type, AudioOutputType.speaker);
  });

  test('DlnaMediaRelay serves range requests and rejects invalid secrets', () async {
    final lan = await DlnaMediaRelay.selectLanAddress();
    if (lan == null) return;

    final tempDir = Directory.systemTemp.createTempSync('resona_dlna_relay_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final audioFile = File('${tempDir.path}/sample.mp3')
      ..writeAsBytesSync(List<int>.generate(256, (i) => i & 0xff));
    final relay = DlnaMediaRelay(secret: 'secret-relay-token');
    addTearDown(relay.close);

    final track = Track({
      'id': 'trk-relay',
      'title': 'Relay Song',
      'format': 'mp3',
      'duration': 10.0,
    });
    final published = Uri.parse(
      await relay.registerTrack(track, localFile: audioFile),
    );
    final localTarget = Uri.parse(
      'http://127.0.0.1:${published.port}${published.path}',
    );
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final rangeReq = await client.getUrl(localTarget);
    rangeReq.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final rangeResp = await rangeReq.close();
    final slice = await limitedBytes(rangeResp, 1024);
    expect(rangeResp.statusCode, HttpStatus.partialContent);
    expect(rangeResp.headers.value(HttpHeaders.contentRangeHeader), 'bytes 10-19/256');
    expect(rangeResp.headers.value('transfermode.dlna.org'), 'Streaming');
    expect(slice, List<int>.generate(10, (i) => i + 10));

    final badReq = await client.getUrl(
      Uri.parse('http://127.0.0.1:${published.port}/wrong/trk-relay/track.mp3'),
    );
    final badResp = await badReq.close();
    await badResp.drain<void>();
    expect(badResp.statusCode, HttpStatus.notFound);
  });

  test('MusicController casts playback to mock DLNA renderer and pauses on BT disconnect', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final soapActions = <String>[];
    var transportState = 'STOPPED';
    var lastRelTime = '0:00:00';
    var lastVolume = 100;
    var lastDidl = '';

    server.listen((request) async {
      if (request.method == 'GET' && request.uri.path == '/description.xml') {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType('application', 'xml');
        request.response.write('''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Mock DLNA Renderer</friendlyName>
    <manufacturer>Resona</manufacturer>
    <modelName>Virtual</modelName>
    <UDN>uuid:mock-dlna-1</UDN>
    <serviceList>
      <service>
        <serviceType>$dlnaAvTransportService</serviceType>
        <controlURL>/avt</controlURL>
      </service>
      <service>
        <serviceType>$dlnaRenderingControlService</serviceType>
        <controlURL>/rc</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''');
        await request.response.close();
        return;
      }

      final body = utf8.decode(await limitedBytes(request, 1 << 20));
      final actionHeader = request.headers.value('soapaction') ?? '';
      final action = actionHeader.replaceAll('"', '').split('#').last;
      soapActions.add(action);

      String responseInner = '';
      switch (action) {
        case 'SetAVTransportURI':
          lastDidl = parseSoapTag(body, 'CurrentURIMetaData') ?? '';
        case 'Play':
          transportState = 'PLAYING';
        case 'Pause':
          transportState = 'PAUSED_PLAYBACK';
        case 'Stop':
          transportState = 'STOPPED';
        case 'Seek':
          lastRelTime = parseSoapTag(body, 'Target') ?? '0:00:00';
        case 'SetVolume':
          lastVolume =
              int.tryParse(parseSoapTag(body, 'DesiredVolume') ?? '') ?? lastVolume;
        case 'GetTransportInfo':
          responseInner =
              '<CurrentTransportState>$transportState</CurrentTransportState>'
              '<CurrentTransportStatus>OK</CurrentTransportStatus>';
        case 'GetPositionInfo':
          responseInner =
              '<TrackDuration>0:03:00</TrackDuration>'
              '<RelTime>$lastRelTime</RelTime>';
        case 'GetVolume':
          responseInner = '<CurrentVolume>$lastVolume</CurrentVolume>';
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      request.response.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response>$responseInner</u:${action}Response></s:Body>'
        '</s:Envelope>',
      );
      await request.response.close();
    });

    final tempDir = Directory.systemTemp.createTempSync('resona_ctrl_dlna_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final controller = MusicController(supportDirectory: tempDir);
    addTearDown(controller.dispose);
    controller.api = ResonaAPI(
      Session(
        Uri.parse('http://127.0.0.1:${server.port}/'),
        'alice',
        'session-token',
      ),
    );
    controller.offline = false;

    final added = await controller.addManualDlnaDevice(
      'http://127.0.0.1:${server.port}/description.xml',
    );
    expect(added, isTrue);
    expect(controller.dlnaDevices, hasLength(1));

    await controller.selectDlnaDevice(controller.dlnaDevices.first);
    expect(controller.isCastingDlna, isTrue);
    expect(controller.activeOutputLabel, 'DLNA · Mock DLNA Renderer');

    final lan = await DlnaMediaRelay.selectLanAddress();
    if (lan != null) {
      final track = Track({
        'id': 'song-1',
        'title': 'Cast Song',
        'artist': 'Resona',
        'format': 'mp3',
        'duration': 180.0,
      });
      await controller.play(track);
      expect(controller.playing, isTrue);
      expect(controller.current?.id, 'song-1');
      expect(lastDidl, contains('Cast Song'));
      expect(soapActions, containsAllInOrder(['SetAVTransportURI', 'Play']));

      await controller.toggle();
      expect(controller.playing, isFalse);
      expect(soapActions.last, 'Pause');

      await controller.toggle();
      expect(controller.playing, isTrue);
      expect(soapActions.last, 'Play');

      await controller.seek(45);
      expect(lastRelTime, '0:00:45');

      await controller.setVolume(0.55);
      expect(lastVolume, 55);

      await controller.stopPlayback();
      expect(controller.playing, isFalse);
      expect(controller.current, isNull);
      expect(soapActions.last, 'Stop');
    }

    await controller.selectDlnaDevice(null);
    expect(controller.isCastingDlna, isFalse);

    controller.updateNativeAudioOutputs([
      {
        'id': '{bt-1}',
        'name': 'Sony WF-1000XM5',
        'bluetooth': true,
        'isDefault': true,
      },
    ]);
    expect(controller.activeBluetoothOutput?.name, 'Sony WF-1000XM5');
    expect(controller.activeOutputLabel, '蓝牙 · Sony WF-1000XM5');

    controller.playing = true;
    controller.updateNativeAudioOutputs([], bluetoothDisconnected: true);
    expect(controller.playing, isFalse);
    expect(controller.activeBluetoothOutput, isNull);
  });
}
