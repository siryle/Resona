import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Session {
  final Uri server;
  final String username;
  final String token;
  Session(this.server, this.username, this.token);
  factory Session.fromJson(Map<String, dynamic> json) => Session(
    serverAddress(json['server'] as String),
    json['username'] as String,
    json['token'] as String,
  );
  Map<String, dynamic> toJson() => {
    'server': server.toString(),
    'username': username,
    'token': token,
  };
}

Uri serverAddress(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('请输入完整的 HTTP / HTTPS 服务器地址');
  }
  return uri.replace(path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/');
}

class Track {
  final Map<String, dynamic> json;
  Track(Map<String, dynamic> data) : json = Map.unmodifiable(data);
  String get id => json['id'] as String;
  String get title => json['title'] as String? ?? '未命名歌曲';
  String get artist => json['artist'] as String? ?? '未知艺术家';
  String get album => json['album'] as String? ?? '未知专辑';
  String get format => (json['format'] as String? ?? 'audio').replaceAll(
    RegExp('[^a-zA-Z0-9]'),
    '',
  );
  String get library => json['library'] as String? ?? 'local';
  double get duration => (json['duration'] as num? ?? 0).toDouble();
  bool get favorite => json['favorite'] == true;
  bool get unavailable => json['unavailable'] == true;
  bool get hasLyrics =>
      json['has_lrc_lyrics'] == true || json['has_embedded_lyrics'] == true;
  String get artwork => json['artwork'] as String? ?? '';
}

class APIException implements Exception {
  final String message;
  final int? status;
  const APIException(this.message, [this.status]);
  @override
  String toString() => message;
}

bool sameOrigin(Uri a, Uri b) =>
    a.scheme == b.scheme && a.host == b.host && a.port == b.port;

bool trustedMedia(Uri uri, Uri server) {
  if (!['http', 'https'].contains(uri.scheme) || uri.userInfo.isNotEmpty) {
    return false;
  }
  if (sameOrigin(uri, server)) return true;
  if (uri.port != (uri.scheme == 'https' ? 443 : 80)) return false;
  return [
    '115.com',
    '115cdn.com',
    '115cdn.net',
    'anxia.com',
  ].any((domain) => uri.host == domain || uri.host.endsWith('.$domain'));
}

class ResonaAPI {
  Session session;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  ResonaAPI(this.session);
  Uri endpoint(String path, [Map<String, String>? query]) =>
      session.server.resolve('api/v1/$path').replace(queryParameters: query);

  static Future<Session> login(
    String address,
    String username,
    String password,
  ) async {
    final api = ResonaAPI(Session(serverAddress(address), username.trim(), ''));
    try {
      final json = await api.json(
        'POST',
        'auth/login',
        body: {'username': username.trim(), 'password': password},
      );
      return Session(
        api.session.server,
        json['username'] as String? ?? username.trim(),
        json['token'] as String,
      );
    } finally {
      api.close();
    }
  }

  Future<Map<String, dynamic>> json(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final request = await client
        .openUrl(method, endpoint(path, query))
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    if (session.token.isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${session.token}',
      );
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = await limitedBytes(response, 8 << 20);
    final decoded = bytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(bytes));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw APIException(
        response.statusCode == 401
            ? '登录已过期，请重新登录'
            : (decoded is Map ? decoded['error'] as String? : null) ??
                  '服务器返回 ${response.statusCode}',
        response.statusCode,
      );
    }
    return Map<String, dynamic>.from(decoded as Map);
  }

  // Resolve every redirect ourselves: the Resona bearer token never reaches a CDN.
  Future<HttpClientResponse> media(
    HttpClient transport,
    Uri uri, {
    String? range,
  }) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!trustedMedia(uri, session.server)) {
        throw const APIException('服务器返回了不受信任的媒体地址');
      }
      final request = await transport
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Resona/1.0');
      if (sameOrigin(uri, session.server)) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${session.token}',
        );
      }
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 10));
        if (location == null) throw const APIException('播放跳转缺少目标地址');
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw const APIException('播放跳转次数过多');
  }

  Future<List<int>> cover(Track track) async {
    if (track.artwork.isEmpty) return [];
    final response = await media(
      client,
      endpoint('tracks/${Uri.encodeComponent(track.id)}/cover'),
    );
    if (response.statusCode != 200) {
      await response.drain<void>();
      return [];
    }
    return limitedBytes(response, 5 << 20);
  }

  Future<List<int>> artistArtwork(String path) async {
    if (path.isEmpty) return [];
    final uri = session.server.resolve(path.replaceFirst(RegExp(r'^/+'), ''));
    if (!sameOrigin(uri, session.server) || uri.userInfo.isNotEmpty) return [];
    final response = await media(client, uri);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return [];
    }
    return limitedBytes(response, 5 << 20);
  }

  Future<String> lyrics(Track track) async {
    final response = await media(
      client,
      endpoint('tracks/${Uri.encodeComponent(track.id)}/lyrics'),
    );
    if (response.statusCode == 404) {
      await response.drain<void>();
      return '';
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw APIException('歌词读取失败 (${response.statusCode})');
    }
    return utf8.decode(
      await limitedBytes(response, 1 << 20),
      allowMalformed: true,
    );
  }

  void close() => client.close(force: true);
}

Future<List<int>> limitedBytes(Stream<List<int>> stream, int max) async {
  final bytes = <int>[];
  await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
    if (bytes.length + chunk.length > max) {
      throw const APIException('服务器响应超过大小限制');
    }
    bytes.addAll(chunk);
  }
  return bytes;
}
